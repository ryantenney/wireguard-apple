/* SPDX-License-Identifier: MIT
 *
 * Copyright (C) 2018-2019 Jason A. Donenfeld <Jason@zx2c4.com>. All Rights Reserved.
 */

package main

// #include <stdlib.h>
// #include <sys/types.h>
// static void callLogger(void *func, void *ctx, int level, const char *msg)
// {
// 	((void(*)(void *, int, const char *))func)(ctx, level, msg);
// }
import "C"

import (
	"encoding/binary"
	"fmt"
	"math"
	"net"
	"net/netip"
	"os"
	"os/signal"
	"runtime"
	"runtime/debug"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
	"unsafe"

	"golang.org/x/sys/unix"
	"golang.zx2c4.com/wireguard/conn"
	"golang.zx2c4.com/wireguard/device"
	"golang.zx2c4.com/wireguard/tun"
)

var loggerFunc unsafe.Pointer
var loggerCtx unsafe.Pointer

type CLogger int

func cstring(s string) *C.char {
	b, err := unix.BytePtrFromString(s)
	if err != nil {
		b := [1]C.char{}
		return &b[0]
	}
	return (*C.char)(unsafe.Pointer(b))
}

func (l CLogger) Printf(format string, args ...interface{}) {
	if uintptr(loggerFunc) == 0 {
		return
	}
	C.callLogger(loggerFunc, loggerCtx, C.int(l), cstring(fmt.Sprintf(format, args...)))
}

type tunnelHandle struct {
	*device.Device
	*device.Logger
}

// handlesMu guards tunnelHandles, probeHandles, and titHandles. The Swift
// adapter serializes all bridge calls on one queue today, but unsynchronized
// Go map writes are a hard runtime crash if that invariant is ever broken
// (e.g. a second adapter instance), so the registries lock defensively.
var handlesMu sync.Mutex

var tunnelHandles = make(map[int32]tunnelHandle)

func init() {
	signals := make(chan os.Signal)
	signal.Notify(signals, unix.SIGUSR2)
	go func() {
		buf := make([]byte, os.Getpagesize())
		for {
			select {
			case <-signals:
				n := runtime.Stack(buf, true)
				buf[n] = 0
				if uintptr(loggerFunc) != 0 {
					C.callLogger(loggerFunc, loggerCtx, 0, (*C.char)(unsafe.Pointer(&buf[0])))
				}
			}
		}
	}()
}

//export wgSetLogger
func wgSetLogger(context, loggerFn uintptr) {
	loggerCtx = unsafe.Pointer(context)
	loggerFunc = unsafe.Pointer(loggerFn)
}

//export wgTurnOn
func wgTurnOn(settings *C.char, tunFd int32) int32 {
	handlesMu.Lock()
	defer handlesMu.Unlock()
	logger := &device.Logger{
		Verbosef: CLogger(0).Printf,
		Errorf:   CLogger(1).Printf,
	}
	dupTunFd, err := unix.Dup(int(tunFd))
	if err != nil {
		logger.Errorf("Unable to dup tun fd: %v", err)
		return -1
	}

	err = unix.SetNonblock(dupTunFd, true)
	if err != nil {
		logger.Errorf("Unable to set tun fd as non blocking: %v", err)
		unix.Close(dupTunFd)
		return -1
	}
	tun, err := tun.CreateTUNFromFile(os.NewFile(uintptr(dupTunFd), "/dev/tun"), 0)
	if err != nil {
		logger.Errorf("Unable to create new tun device from fd: %v", err)
		// CreateTUNFromFile closes the file on all of its error paths; closing
		// dupTunFd again could destroy an unrelated descriptor that reused it.
		return -1
	}
	logger.Verbosef("Attaching to interface")
	dev := device.NewDevice(tun, conn.NewStdNetBind(), logger)

	err = dev.IpcSet(C.GoString(settings))
	if err != nil {
		logger.Errorf("Unable to set IPC settings: %v", err)
		// The tun (and its fd) now belong to the device; close it as a whole.
		dev.Close()
		return -1
	}

	dev.Up()
	logger.Verbosef("Device started")

	var i int32
	for i = 0; i < math.MaxInt32; i++ {
		if _, exists := tunnelHandles[i]; !exists {
			break
		}
	}
	if i == math.MaxInt32 {
		dev.Close()
		return -1
	}
	tunnelHandles[i] = tunnelHandle{dev, logger}
	return i
}

//export wgTurnOff
func wgTurnOff(tunnelHandle int32) {
	handlesMu.Lock()
	defer handlesMu.Unlock()
	dev, ok := tunnelHandles[tunnelHandle]
	if !ok {
		return
	}
	delete(tunnelHandles, tunnelHandle)
	if ctrl, ok := warmSpareControllers[tunnelHandle]; ok {
		delete(warmSpareControllers, tunnelHandle)
		ctrl.stop()
	}
	dev.Close()
}

//export wgSetConfig
func wgSetConfig(tunnelHandle int32, settings *C.char) int64 {
	handlesMu.Lock()
	defer handlesMu.Unlock()
	dev, ok := tunnelHandles[tunnelHandle]
	if !ok {
		return 0
	}
	err := dev.IpcSet(C.GoString(settings))
	if err != nil {
		dev.Errorf("Unable to set IPC settings: %v", err)
		if ipcErr, ok := err.(*device.IPCError); ok {
			return ipcErr.ErrorCode()
		}
		return -1
	}
	return 0
}

//export wgGetConfig
func wgGetConfig(tunnelHandle int32) *C.char {
	handlesMu.Lock()
	defer handlesMu.Unlock()
	device, ok := tunnelHandles[tunnelHandle]
	if !ok {
		return nil
	}
	settings, err := device.IpcGet()
	if err != nil {
		return nil
	}
	return C.CString(settings)
}

//export wgBumpSockets
func wgBumpSockets(tunnelHandle int32) {
	handlesMu.Lock()
	defer handlesMu.Unlock()
	dev, ok := tunnelHandles[tunnelHandle]
	if !ok {
		return
	}
	go func() {
		for i := 0; i < 10; i++ {
			err := dev.BindUpdate()
			if err == nil {
				dev.SendKeepalivesToPeersWithCurrentKeypair()
				return
			}
			dev.Errorf("Unable to update bind, try %d: %v", i+1, err)
			time.Sleep(time.Second / 2)
		}
		dev.Errorf("Gave up trying to update bind; tunnel is likely dysfunctional")
	}()
}

//export wgDisableSomeRoamingForBrokenMobileSemantics
func wgDisableSomeRoamingForBrokenMobileSemantics(tunnelHandle int32) {
	handlesMu.Lock()
	defer handlesMu.Unlock()
	dev, ok := tunnelHandles[tunnelHandle]
	if !ok {
		return
	}
	dev.DisableSomeRoamingForBrokenMobileSemantics()
}

//export wgVersion
func wgVersion() *C.char {
	info, ok := debug.ReadBuildInfo()
	if !ok {
		return C.CString("unknown")
	}
	for _, dep := range info.Deps {
		if dep.Path == "golang.zx2c4.com/wireguard" {
			parts := strings.Split(dep.Version, "-")
			if len(parts) == 3 && len(parts[2]) == 12 {
				return C.CString(parts[2][:7])
			}
			return C.CString(dep.Version)
		}
	}
	return C.CString("unknown")
}

// ========== Background Probe Support ==========
//
// A probe runs a lightweight wireguard-go device with real UDP sockets but a
// swappable tun device (initially null, discards decrypted packets). This lets
// us perform a full Noise IK handshake with a remote peer to verify reachability
// without disrupting the active tunnel's traffic flow.
//
// When a hot spare is promoted to become the active tunnel, we swap the null tun
// for the real utun fd. The wireguard-go goroutines keep running with their
// existing Noise session — no re-handshake needed.

// swappableTunDevice wraps an inner tun.Device and allows atomic replacement.
// Used by probes: starts with a nullTunDevice, can be promoted to a real utun.
// The wireguard-go read/write goroutines see the wrapper and never know the
// inner device changed.
//
// Uses atomic.Value for lock-free reads on the hot path (Read/Write).
// The only write (swap) happens once during probe promotion.
//
// atomic.Value requires every Store/Swap to use the same concrete type, so the
// inner device is always boxed in a tunHolder — storing tun.Device directly
// would panic on swap when the dynamic type changes (nullTunDevice → NativeTun).
type tunHolder struct {
	dev tun.Device
}

type swappableTunDevice struct {
	inner  atomic.Value // always stores tunHolder
	events chan tun.Event
	closed chan struct{}
	fwdWG  sync.WaitGroup // tracks the event-forwarding goroutine started by swap
}

func newSwappableTunDevice(inner tun.Device) *swappableTunDevice {
	dev := &swappableTunDevice{
		events: make(chan tun.Event, 4),
		closed: make(chan struct{}),
	}
	dev.inner.Store(tunHolder{dev: inner})
	// Forward initial EventUp
	dev.events <- tun.EventUp
	return dev
}

func (s *swappableTunDevice) getInner() tun.Device {
	return s.inner.Load().(tunHolder).dev
}

func (s *swappableTunDevice) File() *os.File { return nil }

func (s *swappableTunDevice) Read(data []byte, offset int) (int, error) {
	for {
		inner := s.getInner()
		n, err := inner.Read(data, offset)
		if err != nil {
			// If the inner was a nullTun that got closed during swap, retry with new inner.
			select {
			case <-s.closed:
				return 0, os.ErrClosed
			default:
				// Check if the inner changed (swap happened while we were blocked).
				if s.getInner() != inner {
					// Inner was swapped — retry read with the new device.
					continue
				}
				return 0, err
			}
		}
		return n, nil
	}
}

func (s *swappableTunDevice) Write(data []byte, offset int) (int, error) {
	return s.getInner().Write(data, offset)
}

func (s *swappableTunDevice) Flush() error {
	return s.getInner().Flush()
}

func (s *swappableTunDevice) MTU() (int, error) {
	return s.getInner().MTU()
}

func (s *swappableTunDevice) Name() (string, error) {
	return s.getInner().Name()
}

func (s *swappableTunDevice) Events() <-chan tun.Event { return s.events }

func (s *swappableTunDevice) Close() error {
	select {
	case <-s.closed:
		return nil
	default:
		close(s.closed)
	}
	err := s.getInner().Close()
	// The device's event reader goroutine exits only when the events channel
	// closes; wait out the forwarder (if any) so nothing sends after the close.
	s.fwdWG.Wait()
	close(s.events)
	return err
}

// swap replaces the inner tun device atomically. Closes the old inner (which
// unblocks any goroutine stuck in nullTunDevice.Read). The read loop in
// swappableTunDevice.Read will detect the change and retry with the new device.
func (s *swappableTunDevice) swap(newInner tun.Device) {
	old := s.inner.Swap(tunHolder{dev: newInner}).(tunHolder).dev
	old.Close() // Unblocks any Read() call stuck on the old (null) tun

	// Forward the new inner's events (MTU updates, up/down) to the device.
	// Without a reader, a NativeTun's route listener fills its 10-slot event
	// channel and blocks forever, and the device never sees MTU changes.
	s.fwdWG.Add(1)
	go func() {
		defer s.fwdWG.Done()
		for {
			select {
			case ev, ok := <-newInner.Events():
				if !ok {
					return
				}
				select {
				case s.events <- ev:
				case <-s.closed:
					return
				}
			case <-s.closed:
				return
			}
		}
	}()

	// Nudge the device to re-read the MTU: it snapshotted the null tun's
	// placeholder MTU at NewDevice time, while the real utun may differ.
	select {
	case s.events <- tun.EventMTUUpdate:
	default:
	}
}

// nullTunDevice implements tun.Device by discarding all writes and blocking
// reads until closed. Used as the initial inner device for probes.
type nullTunDevice struct {
	closed chan struct{}
	events chan tun.Event
	mtu    int
}

func newNullTunDevice(mtu int) *nullTunDevice {
	return &nullTunDevice{
		closed: make(chan struct{}),
		events: make(chan tun.Event),
		mtu:    mtu,
	}
}

func (t *nullTunDevice) File() *os.File            { return nil }
func (t *nullTunDevice) Flush() error              { return nil }
func (t *nullTunDevice) MTU() (int, error)         { return t.mtu, nil }
func (t *nullTunDevice) Name() (string, error)     { return "probe0", nil }
func (t *nullTunDevice) Events() <-chan tun.Event   { return t.events }

func (t *nullTunDevice) Read(data []byte, offset int) (int, error) {
	// Block until closed — no packets to deliver from a null tun.
	<-t.closed
	return 0, os.ErrClosed
}

func (t *nullTunDevice) Write(data []byte, offset int) (int, error) {
	// Discard decrypted packets — they have nowhere to go.
	return len(data) - offset, nil
}

func (t *nullTunDevice) Close() error {
	select {
	case <-t.closed:
	default:
		close(t.closed)
	}
	return nil
}

// probeHandle stores a background probe's WireGuard device and its swappable tun.
type probeHandle struct {
	*device.Device
	*device.Logger
	tunDev *swappableTunDevice
}

var probeHandles = make(map[int32]probeHandle)

//export wgProbeOn
func wgProbeOn(settings *C.char, keepaliveOverride int32) int32 {
	handlesMu.Lock()
	defer handlesMu.Unlock()
	logger := &device.Logger{
		Verbosef: CLogger(0).Printf,
		Errorf:   CLogger(1).Printf,
	}

	nullTun := newNullTunDevice(1420)
	swappable := newSwappableTunDevice(nullTun)
	dev := device.NewDevice(swappable, conn.NewStdNetBind(), logger)

	// Build UAPI config, injecting persistent_keepalive if requested.
	config := C.GoString(settings)
	if keepaliveOverride > 0 {
		config = injectKeepalive(config, int(keepaliveOverride))
	}

	err := dev.IpcSet(config)
	if err != nil {
		logger.Errorf("Probe: unable to set IPC settings: %v", err)
		dev.Close()
		return -1
	}

	dev.Up()
	logger.Verbosef("Probe: device started")

	var i int32
	for i = 0; i < math.MaxInt32; i++ {
		if _, exists := probeHandles[i]; !exists {
			break
		}
	}
	if i == math.MaxInt32 {
		dev.Close()
		return -1
	}
	probeHandles[i] = probeHandle{dev, logger, swappable}
	return i
}

//export wgProbeOff
func wgProbeOff(handle int32) {
	handlesMu.Lock()
	defer handlesMu.Unlock()
	h, ok := probeHandles[handle]
	if !ok {
		return
	}
	delete(probeHandles, handle)
	h.Close()
}

//export wgProbeGetConfig
func wgProbeGetConfig(handle int32) *C.char {
	handlesMu.Lock()
	defer handlesMu.Unlock()
	h, ok := probeHandles[handle]
	if !ok {
		return nil
	}
	settings, err := h.IpcGet()
	if err != nil {
		return nil
	}
	return C.CString(settings)
}

//export wgProbeSetConfig
func wgProbeSetConfig(handle int32, settings *C.char) int64 {
	handlesMu.Lock()
	defer handlesMu.Unlock()
	h, ok := probeHandles[handle]
	if !ok {
		return 0
	}
	err := h.IpcSet(C.GoString(settings))
	if err != nil {
		h.Errorf("Probe: unable to set IPC settings: %v", err)
		if ipcErr, ok := err.(*device.IPCError); ok {
			return ipcErr.ErrorCode()
		}
		return -1
	}
	return 0
}

//export wgProbeBumpSockets
func wgProbeBumpSockets(handle int32) {
	handlesMu.Lock()
	defer handlesMu.Unlock()
	h, ok := probeHandles[handle]
	if !ok {
		return
	}
	go func() {
		for i := 0; i < 10; i++ {
			err := h.BindUpdate()
			if err == nil {
				h.SendKeepalivesToPeersWithCurrentKeypair()
				return
			}
			h.Errorf("Probe: unable to update bind, try %d: %v", i+1, err)
			time.Sleep(time.Second / 2)
		}
		h.Errorf("Probe: gave up trying to update bind")
	}()
}

//export wgProbePromote
func wgProbePromote(probeHandleID int32, tunFd int32) int32 {
	handlesMu.Lock()
	defer handlesMu.Unlock()
	h, ok := probeHandles[probeHandleID]
	if !ok {
		return -1
	}

	// Create a real tun device from the file descriptor.
	dupTunFd, err := unix.Dup(int(tunFd))
	if err != nil {
		h.Errorf("Probe promote: unable to dup tun fd: %v", err)
		return -1
	}
	if err = unix.SetNonblock(dupTunFd, true); err != nil {
		h.Errorf("Probe promote: unable to set tun fd non-blocking: %v", err)
		unix.Close(dupTunFd)
		return -1
	}
	realTun, err := tun.CreateTUNFromFile(os.NewFile(uintptr(dupTunFd), "/dev/tun"), 0)
	if err != nil {
		h.Errorf("Probe promote: unable to create tun device: %v", err)
		// CreateTUNFromFile closes the file on all of its error paths; closing
		// dupTunFd again could destroy an unrelated descriptor that reused it.
		return -1
	}

	// Swap the null tun for the real tun. This unblocks the read goroutine
	// which will start processing real packets with the existing Noise session.
	h.tunDev.swap(realTun)
	h.Verbosef("Probe promote: swapped null tun for real utun — session preserved")

	// Remove from probeHandles and add to tunnelHandles.
	delete(probeHandles, probeHandleID)

	var i int32
	for i = 0; i < math.MaxInt32; i++ {
		if _, exists := tunnelHandles[i]; !exists {
			break
		}
	}
	if i == math.MaxInt32 {
		h.Errorf("Probe promote: no free tunnel handle slot")
		h.Close()
		return -1
	}

	tunnelHandles[i] = tunnelHandle{h.Device, h.Logger}
	h.Verbosef("Probe promote: probe %d → tunnel %d", probeHandleID, i)
	return i
}

// injectKeepalive ensures every peer section has a persistent_keepalive_interval
// at most `seconds`. If the peer already has a smaller positive value, that value
// is preserved. If the peer is missing the line, has it set to 0, or has it set
// to a larger value, it is replaced with `seconds`.
//
// The probe needs at least one keepalive within a few seconds to trigger the
// initial handshake — without traffic flowing through the null tun, keepalive
// is the only thing that drives wireguard-go to start a session.
func injectKeepalive(uapi string, seconds int) string {
	var result strings.Builder
	inPeer := false
	hasKeepalive := false

	for _, line := range strings.Split(uapi, "\n") {
		if strings.HasPrefix(line, "public_key=") {
			if inPeer && !hasKeepalive {
				result.WriteString(fmt.Sprintf("persistent_keepalive_interval=%d\n", seconds))
			}
			inPeer = true
			hasKeepalive = false
		}
		if strings.HasPrefix(line, "persistent_keepalive_interval=") {
			value, err := strconv.Atoi(strings.TrimPrefix(line, "persistent_keepalive_interval="))
			chosen := seconds
			if err == nil && value > 0 && value < seconds {
				chosen = value
			}
			result.WriteString(fmt.Sprintf("persistent_keepalive_interval=%d\n", chosen))
			hasKeepalive = true
			continue
		}
		if line != "" {
			result.WriteString(line)
			result.WriteByte('\n')
		}
	}
	if inPeer && !hasKeepalive {
		result.WriteString(fmt.Sprintf("persistent_keepalive_interval=%d\n", seconds))
	}
	return result.String()
}

// ========== Warm Spare Cellular Failover Exports ==========
//
// See warmspare.go for the mechanism (dualPathBind, warmSpareController) and
// DESIGN-warm-spare-cellular-failover.md for the design.

// Controllers for warm-spare tunnels, keyed by the same handle used in
// tunnelHandles (a warm tunnel is a regular tunnel handle plus a controller,
// so wgSetConfig / wgGetConfig / wgBumpSockets / wgTurnOff all keep working).
var warmSpareControllers = make(map[int32]*warmSpareController)

// wgTurnOnWarm starts a tunnel whose bind supports a warm cellular spare.
// probeAddr must be the resolved IP of the active peer endpoint (so probe
// traffic shares the server's automatic routing exception); probePort is the
// server-side echo responder port and must differ from the WireGuard port.
//
//export wgTurnOnWarm
func wgTurnOnWarm(settings *C.char, probeAddr *C.char, probePort int32, keepaliveInterval int32, tunFd int32) int32 {
	logger := &device.Logger{
		Verbosef: CLogger(0).Printf,
		Errorf:   CLogger(1).Printf,
	}
	dev, ctrl, err := newWarmTunnel(C.GoString(settings), C.GoString(probeAddr), int(probePort), int(keepaliveInterval), tunFd, logger)
	if err != nil {
		logger.Errorf("Warm spare: %v", err)
		return -1
	}

	var i int32
	for i = 0; i < math.MaxInt32; i++ {
		if _, exists := tunnelHandles[i]; !exists {
			break
		}
	}
	if i == math.MaxInt32 {
		ctrl.stop()
		dev.Close()
		return -1
	}
	tunnelHandles[i] = tunnelHandle{dev, logger}
	warmSpareControllers[i] = ctrl
	return i
}

// wgWarmSetCellular opens (or re-homes) the cellular sockets bound to the
// given interface index and starts NAT keepalives. Returns 0 on success.
//
//export wgWarmSetCellular
func wgWarmSetCellular(tunnelHandle int32, ifindex int32) int32 {
	ctrl, ok := warmSpareControllers[tunnelHandle]
	if !ok {
		return -1
	}
	if err := ctrl.warmCellular(int(ifindex)); err != nil {
		ctrl.logger.Errorf("Warm spare: warm failed: %v", err)
		return -1
	}
	return 0
}

// wgWarmClearCellular closes the cellular sockets and stops keepalives (cold).
//
//export wgWarmClearCellular
func wgWarmClearCellular(tunnelHandle int32) {
	ctrl, ok := warmSpareControllers[tunnelHandle]
	if !ok {
		return
	}
	ctrl.clearCellular()
}

// wgWarmSetActivePath flips which socket carries WireGuard traffic
// (0 = primary/default path, 1 = cellular) and sends an immediate keepalive
// out the new path so the server re-homes the session. Returns 0 on success.
//
//export wgWarmSetActivePath
func wgWarmSetActivePath(tunnelHandle int32, path int32) int32 {
	ctrl, ok := warmSpareControllers[tunnelHandle]
	if !ok {
		return -1
	}
	if path != warmPathPrimary && path != warmPathCellular {
		return -1
	}
	ctrl.setActivePath(path)
	return 0
}

// wgWarmGetState returns a JSON snapshot of warm spare state: active path,
// warm/cold, per-path RTT/loss, and the latest EIM self-test result.
//
//export wgWarmGetState
func wgWarmGetState(tunnelHandle int32) *C.char {
	ctrl, ok := warmSpareControllers[tunnelHandle]
	if !ok {
		return nil
	}
	return C.CString(ctrl.stateJSON())
}

// wgWarmStartEimTest kicks off the endpoint-independent-mapping self-test on
// the (warm) cellular socket. Asynchronous; the verdict lands in
// wgWarmGetState within ~5 seconds. Returns 0 if the test was started.
//
//export wgWarmStartEimTest
func wgWarmStartEimTest(tunnelHandle int32) int32 {
	ctrl, ok := warmSpareControllers[tunnelHandle]
	if !ok {
		return -1
	}
	if err := ctrl.startEimTest(); err != nil {
		ctrl.logger.Verbosef("Warm spare: EIM test not started: %v", err)
		return -1
	}
	return 0
}

// ========== Tunnel-in-Tunnel (TiT) Support ==========
//
// TiT runs two wireguard-go instances in-process:
//   INNER — owns the real utun fd; handles user traffic; uses PipedBind instead of real UDP sockets.
//   OUTER — owns a virtual PipedTun; uses real UDP sockets (StdNetBind) to reach Server A.
//
// Packet flow (outbound):
//   user IP pkt → INNER TUN (utun) → INNER encrypts → PipedBind.Send wraps as IP+UDP
//   → PipedTun.Read (OUTER reads) → OUTER encrypts → StdNetBind.Send → Server A → Server B
//
// Packet flow (inbound):
//   Server A → StdNetBind.Receive → OUTER decrypts → PipedTun.Write (IP+UDP)
//   → PipedBind.ReceiveFunc unwraps → INNER decrypts → TUN write → user IP pkt

// pipedTunnel holds the channels shared between PipedTun and PipedBind.
type pipedTunnel struct {
	// toOuter: INNER's PipedBind puts wrapped IP+UDP packets here; OUTER's PipedTun reads from here.
	toOuter chan []byte
	// fromOuter: OUTER's PipedTun puts decrypted IP+UDP packets here; INNER's PipedBind reads from here.
	fromOuter    chan []byte
	outerIfaceIP netip.Addr // source IP used when wrapping INNER's WireGuard UDP as IP+UDP
	closed       chan struct{}
}

// ---- PipedTun: tun.Device implementation for OUTER ----

type pipedTunDevice struct {
	pt         *pipedTunnel
	events     chan tun.Event
	eventsOnce sync.Once // events channel may be closed via Close from several paths
	mtu        int
}

func (t *pipedTunDevice) File() *os.File { return nil }

// Read is called by OUTER to get the next IP packet to encrypt and send.
func (t *pipedTunDevice) Read(data []byte, offset int) (int, error) {
	select {
	case <-t.pt.closed:
		return 0, os.ErrClosed
	case pkt := <-t.pt.toOuter:
		n := copy(data[offset:], pkt)
		return n, nil
	}
}

// Write is called by OUTER when it has a decrypted IP packet to deliver.
func (t *pipedTunDevice) Write(data []byte, offset int) (int, error) {
	pkt := make([]byte, len(data)-offset)
	copy(pkt, data[offset:])
	select {
	case <-t.pt.closed:
		return 0, os.ErrClosed
	case t.pt.fromOuter <- pkt:
		return len(pkt), nil
	}
}

func (t *pipedTunDevice) Flush() error             { return nil }
func (t *pipedTunDevice) MTU() (int, error)        { return t.mtu, nil }
func (t *pipedTunDevice) Name() (string, error)    { return "tit-outer0", nil }
func (t *pipedTunDevice) Events() <-chan tun.Event { return t.events }
func (t *pipedTunDevice) Close() error {
	select {
	case <-t.pt.closed:
	default:
		close(t.pt.closed)
	}
	// The device's event reader goroutine exits only when the events channel
	// closes; nothing sends on it after construction, so this is safe.
	t.eventsOnce.Do(func() { close(t.events) })
	return nil
}

// ---- PipedBind: conn.Bind implementation for INNER ----

type pipedBind struct {
	pt          *pipedTunnel
	closeSignal chan struct{}
}

// pipedEndpoint implements conn.Endpoint for pipe-based addressing.
type pipedEndpoint struct {
	addrPort netip.AddrPort
}

func (e *pipedEndpoint) ClearSrc()           {}
func (e *pipedEndpoint) SrcToString() string { return "" }
func (e *pipedEndpoint) DstToString() string { return e.addrPort.String() }
func (e *pipedEndpoint) DstToBytes() []byte {
	b, _ := e.addrPort.MarshalBinary()
	return b
}
func (e *pipedEndpoint) DstIP() netip.Addr { return e.addrPort.Addr() }
func (e *pipedEndpoint) SrcIP() netip.Addr { return netip.Addr{} }

func (b *pipedBind) Open(port uint16) ([]conn.ReceiveFunc, uint16, error) {
	b.closeSignal = make(chan struct{})
	receive := func(data []byte) (int, conn.Endpoint, error) {
		select {
		case <-b.closeSignal:
			return 0, nil, net.ErrClosed
		case <-b.pt.closed:
			return 0, nil, net.ErrClosed
		case pkt := <-b.pt.fromOuter:
			payload, srcAddrPort, err := titUnwrapIPUDP(pkt)
			if err != nil {
				return 0, nil, fmt.Errorf("tit: unwrap: %w", err)
			}
			n := copy(data, payload)
			return n, &pipedEndpoint{addrPort: srcAddrPort}, nil
		}
	}
	return []conn.ReceiveFunc{receive}, 0, nil
}

func (b *pipedBind) Close() error {
	if b.closeSignal != nil {
		select {
		case <-b.closeSignal:
		default:
			close(b.closeSignal)
		}
	}
	return nil
}

func (b *pipedBind) SetMark(mark uint32) error { return nil }

func (b *pipedBind) Send(data []byte, ep conn.Endpoint) error {
	pkt, err := titWrapIPUDP(data, b.pt.outerIfaceIP, ep)
	if err != nil {
		return fmt.Errorf("tit: wrap: %w", err)
	}
	select {
	case <-b.pt.closed:
		return net.ErrClosed
	case b.pt.toOuter <- pkt:
		return nil
	}
}

func (b *pipedBind) ParseEndpoint(s string) (conn.Endpoint, error) {
	addrPort, err := netip.ParseAddrPort(s)
	if err != nil {
		return nil, err
	}
	return &pipedEndpoint{addrPort: addrPort}, nil
}

// ---- IP+UDP wrapping/unwrapping ----

// titWrapIPUDP wraps a WireGuard UDP payload in an IP+UDP packet.
// srcIP is OUTER's tunnel interface address; ep is INNER's peer endpoint (Server B).
func titWrapIPUDP(payload []byte, srcIP netip.Addr, ep conn.Endpoint) ([]byte, error) {
	dstAddrPort, err := netip.ParseAddrPort(ep.DstToString())
	if err != nil {
		return nil, fmt.Errorf("bad endpoint %q: %w", ep.DstToString(), err)
	}
	// A 4-in-6 mapped endpoint (::ffff:a.b.c.d) is IPv4 on the wire; unmap it
	// so it takes the IPv4 path instead of producing an invalid v4-mapped
	// source in an IPv6 header.
	dst := dstAddrPort.Addr().Unmap()
	dstPort := dstAddrPort.Port()
	const srcPort = 51820

	if dst.Is4() {
		src4 := srcIP.As4()
		if !srcIP.Is4() {
			src4 = [4]byte{10, 200, 0, 1} // fallback if outer iface is not IPv4
		}
		return titWrapIPv4UDP(payload, src4, dst.As4(), srcPort, dstPort), nil
	}
	// IPv6
	src6 := srcIP.As16()
	return titWrapIPv6UDP(payload, src6, dst.As16(), srcPort, dstPort), nil
}

// titIPv4PacketID provides unique IPv4 Identification values. With DF clear, a
// constant ID would corrupt packets via reassembly collisions if the
// Server A → Server B leg ever fragments concurrent packets.
var titIPv4PacketID uint32 // accessed atomically (go.mod predates atomic.Uint32)

func titWrapIPv4UDP(payload []byte, src, dst [4]byte, srcPort, dstPort uint16) []byte {
	totalLen := 20 + 8 + len(payload)
	pkt := make([]byte, totalLen)

	// IPv4 header
	pkt[0] = 0x45 // version=4, IHL=5
	binary.BigEndian.PutUint16(pkt[2:], uint16(totalLen))
	binary.BigEndian.PutUint16(pkt[4:], uint16(atomic.AddUint32(&titIPv4PacketID, 1))) // identification
	pkt[8] = 64  // TTL
	pkt[9] = 17  // protocol: UDP
	copy(pkt[12:16], src[:])
	copy(pkt[16:20], dst[:])
	cksum := titIPv4Checksum(pkt[:20])
	binary.BigEndian.PutUint16(pkt[10:], cksum)

	// UDP header
	binary.BigEndian.PutUint16(pkt[20:], srcPort)
	binary.BigEndian.PutUint16(pkt[22:], dstPort)
	binary.BigEndian.PutUint16(pkt[24:], uint16(8+len(payload)))
	// UDP checksum left as 0 (optional for IPv4)

	copy(pkt[28:], payload)
	return pkt
}

func titWrapIPv6UDP(payload []byte, src, dst [16]byte, srcPort, dstPort uint16) []byte {
	udpLen := 8 + len(payload)
	totalLen := 40 + udpLen
	pkt := make([]byte, totalLen)

	// IPv6 header
	pkt[0] = 0x60 // version=6
	binary.BigEndian.PutUint16(pkt[4:], uint16(udpLen)) // payload length
	pkt[6] = 17                                          // next header: UDP
	pkt[7] = 64                                          // hop limit
	copy(pkt[8:24], src[:])
	copy(pkt[24:40], dst[:])

	// UDP header
	binary.BigEndian.PutUint16(pkt[40:], srcPort)
	binary.BigEndian.PutUint16(pkt[42:], dstPort)
	binary.BigEndian.PutUint16(pkt[44:], uint16(udpLen))

	// The payload must be in place before the checksum is computed — the
	// mandatory IPv6 UDP checksum covers the entire UDP segment.
	copy(pkt[48:], payload)
	cksum := titIPv6UDPChecksum(src, dst, pkt[40:40+udpLen], uint32(udpLen))
	if cksum == 0 {
		// RFC 768/8200: a computed checksum of zero is transmitted as all ones.
		cksum = 0xffff
	}
	binary.BigEndian.PutUint16(pkt[46:], cksum)
	return pkt
}

// titUnwrapIPUDP extracts WireGuard payload and source address from a decrypted IP+UDP packet.
func titUnwrapIPUDP(pkt []byte) (payload []byte, src netip.AddrPort, err error) {
	if len(pkt) < 1 {
		return nil, netip.AddrPort{}, fmt.Errorf("packet too short")
	}
	version := pkt[0] >> 4
	switch version {
	case 4:
		if len(pkt) < 28 {
			return nil, netip.AddrPort{}, fmt.Errorf("IPv4+UDP packet too short (%d bytes)", len(pkt))
		}
		if pkt[9] != 17 {
			return nil, netip.AddrPort{}, fmt.Errorf("not UDP (IPv4 protocol %d)", pkt[9])
		}
		// Fragments (MF set or nonzero offset) don't carry a complete UDP
		// segment at the expected offset; the anti-replay/MAC layer would
		// reject the garbage anyway, but don't feed it to the device.
		if pkt[6]&0x20 != 0 || binary.BigEndian.Uint16(pkt[6:])&0x1fff != 0 {
			return nil, netip.AddrPort{}, fmt.Errorf("fragmented IPv4 packet")
		}
		ihl := int(pkt[0]&0x0f) * 4
		if ihl < 20 || len(pkt) < ihl+8 {
			return nil, netip.AddrPort{}, fmt.Errorf("IPv4+UDP packet too short for IHL")
		}
		srcAddr := netip.AddrFrom4([4]byte{pkt[12], pkt[13], pkt[14], pkt[15]})
		srcPort := binary.BigEndian.Uint16(pkt[ihl:])
		return pkt[ihl+8:], netip.AddrPortFrom(srcAddr, srcPort), nil
	case 6:
		if len(pkt) < 48 {
			return nil, netip.AddrPort{}, fmt.Errorf("IPv6+UDP packet too short (%d bytes)", len(pkt))
		}
		if pkt[6] != 17 {
			// Extension headers (incl. fragments) are not parsed; Server B is
			// not expected to send them for plain UDP.
			return nil, netip.AddrPort{}, fmt.Errorf("not UDP (IPv6 next header %d)", pkt[6])
		}
		var srcB [16]byte
		copy(srcB[:], pkt[8:24])
		srcAddr := netip.AddrFrom16(srcB)
		srcPort := binary.BigEndian.Uint16(pkt[40:])
		return pkt[48:], netip.AddrPortFrom(srcAddr, srcPort), nil
	default:
		return nil, netip.AddrPort{}, fmt.Errorf("unknown IP version %d", version)
	}
}

func titIPv4Checksum(header []byte) uint16 {
	var sum uint32
	for i := 0; i+1 < len(header); i += 2 {
		sum += uint32(header[i])<<8 | uint32(header[i+1])
	}
	for sum > 0xffff {
		sum = (sum >> 16) + (sum & 0xffff)
	}
	return ^uint16(sum)
}

func titIPv6UDPChecksum(src, dst [16]byte, udpSegment []byte, udpLen uint32) uint16 {
	var sum uint32
	for i := 0; i < 16; i += 2 {
		sum += uint32(src[i])<<8 | uint32(src[i+1])
		sum += uint32(dst[i])<<8 | uint32(dst[i+1])
	}
	sum += uint32(udpLen) & 0xffff
	sum += uint32(udpLen) >> 16
	sum += 17 // next header = UDP
	for i := 0; i+1 < len(udpSegment); i += 2 {
		sum += uint32(udpSegment[i])<<8 | uint32(udpSegment[i+1])
	}
	if len(udpSegment)%2 != 0 {
		sum += uint32(udpSegment[len(udpSegment)-1]) << 8
	}
	for sum > 0xffff {
		sum = (sum >> 16) + (sum & 0xffff)
	}
	return ^uint16(sum)
}

// ---- TiT handle management ----

type titHandle struct {
	innerDev    *device.Device
	innerLogger *device.Logger
	outerDev    *device.Device
	outerLogger *device.Logger
	tunnel      *pipedTunnel
}

var titHandles = make(map[int32]titHandle)

//export wgTurnOnTiT
func wgTurnOnTiT(outerSettings *C.char, innerSettings *C.char, outerIfaceIPStr *C.char, tunFd int32) int32 {
	handlesMu.Lock()
	defer handlesMu.Unlock()
	innerLogger := &device.Logger{
		Verbosef: CLogger(0).Printf,
		Errorf:   CLogger(1).Printf,
	}
	outerLogger := &device.Logger{
		Verbosef: CLogger(0).Printf,
		Errorf:   CLogger(1).Printf,
	}

	outerIfaceIP, ok := netip.AddrFromSlice(net.ParseIP(C.GoString(outerIfaceIPStr)))
	if !ok {
		outerLogger.Errorf("TiT: invalid outer interface IP %q", C.GoString(outerIfaceIPStr))
		return -1
	}
	outerIfaceIP = outerIfaceIP.Unmap()

	tunnel := &pipedTunnel{
		toOuter:      make(chan []byte, 128),
		fromOuter:    make(chan []byte, 128),
		outerIfaceIP: outerIfaceIP,
		closed:       make(chan struct{}),
	}

	// Build OUTER device: virtual PipedTun + real UDP sockets
	outerTunDev := &pipedTunDevice{
		pt:     tunnel,
		events: make(chan tun.Event, 1),
		mtu:    1420,
	}
	outerTunDev.events <- tun.EventUp
	outerDev := device.NewDevice(outerTunDev, conn.NewStdNetBind(), outerLogger)
	if err := outerDev.IpcSet(C.GoString(outerSettings)); err != nil {
		outerLogger.Errorf("TiT: unable to configure outer device: %v", err)
		outerDev.Close()
		return -1
	}
	outerDev.Up()

	// Build INNER device: real utun + PipedBind
	dupTunFd, err := unix.Dup(int(tunFd))
	if err != nil {
		innerLogger.Errorf("TiT: unable to dup tun fd: %v", err)
		outerDev.Close()
		return -1
	}
	if err = unix.SetNonblock(dupTunFd, true); err != nil {
		innerLogger.Errorf("TiT: unable to set tun fd non-blocking: %v", err)
		unix.Close(dupTunFd)
		outerDev.Close()
		return -1
	}
	innerTunDev, err := tun.CreateTUNFromFile(os.NewFile(uintptr(dupTunFd), "/dev/tun"), 0)
	if err != nil {
		innerLogger.Errorf("TiT: unable to create tun device: %v", err)
		// CreateTUNFromFile closes the file on all of its error paths; closing
		// dupTunFd again could destroy an unrelated descriptor that reused it.
		outerDev.Close()
		return -1
	}
	innerBind := &pipedBind{pt: tunnel}
	innerDev := device.NewDevice(innerTunDev, innerBind, innerLogger)
	if err = innerDev.IpcSet(C.GoString(innerSettings)); err != nil {
		innerLogger.Errorf("TiT: unable to configure inner device: %v", err)
		innerDev.Close()
		outerDev.Close()
		return -1
	}
	innerDev.Up()
	innerLogger.Verbosef("TiT: devices started")

	var i int32
	for i = 0; i < math.MaxInt32; i++ {
		if _, exists := titHandles[i]; !exists {
			break
		}
	}
	if i == math.MaxInt32 {
		innerDev.Close()
		outerDev.Close()
		return -1
	}
	titHandles[i] = titHandle{innerDev, innerLogger, outerDev, outerLogger, tunnel}
	return i
}

//export wgTurnOffTiT
func wgTurnOffTiT(handle int32) {
	handlesMu.Lock()
	defer handlesMu.Unlock()
	h, ok := titHandles[handle]
	if !ok {
		return
	}
	delete(titHandles, handle)
	h.innerDev.Close()
	h.outerDev.Close()
}

//export wgGetConfigTiT
func wgGetConfigTiT(handle int32) *C.char {
	handlesMu.Lock()
	defer handlesMu.Unlock()
	h, ok := titHandles[handle]
	if !ok {
		return nil
	}
	settings, err := h.innerDev.IpcGet()
	if err != nil {
		return nil
	}
	return C.CString(settings)
}

//export wgGetOuterConfigTiT
func wgGetOuterConfigTiT(handle int32) *C.char {
	handlesMu.Lock()
	defer handlesMu.Unlock()
	h, ok := titHandles[handle]
	if !ok {
		return nil
	}
	settings, err := h.outerDev.IpcGet()
	if err != nil {
		return nil
	}
	return C.CString(settings)
}

//export wgSetInnerConfigTiT
func wgSetInnerConfigTiT(handle int32, settings *C.char) int64 {
	handlesMu.Lock()
	defer handlesMu.Unlock()
	h, ok := titHandles[handle]
	if !ok {
		return 0
	}
	if err := h.innerDev.IpcSet(C.GoString(settings)); err != nil {
		h.innerLogger.Errorf("TiT: unable to update inner config: %v", err)
		if ipcErr, ok := err.(*device.IPCError); ok {
			return ipcErr.ErrorCode()
		}
		return -1
	}
	return 0
}

//export wgBumpSocketsTiT
func wgBumpSocketsTiT(handle int32) {
	handlesMu.Lock()
	defer handlesMu.Unlock()
	h, ok := titHandles[handle]
	if !ok {
		return
	}
	go func() {
		for i := 0; i < 10; i++ {
			if err := h.outerDev.BindUpdate(); err == nil {
				h.outerDev.SendKeepalivesToPeersWithCurrentKeypair()
				return
			}
			h.outerLogger.Errorf("TiT: unable to update bind, try %d", i+1)
			time.Sleep(time.Second / 2)
		}
		h.outerLogger.Errorf("TiT: gave up trying to update bind")
	}()
}

//export wgDisableSomeRoamingForBrokenMobileSemanticsForOuterTiT
func wgDisableSomeRoamingForBrokenMobileSemanticsForOuterTiT(handle int32) {
	handlesMu.Lock()
	defer handlesMu.Unlock()
	h, ok := titHandles[handle]
	if !ok {
		return
	}
	h.outerDev.DisableSomeRoamingForBrokenMobileSemantics()
}

func main() {}
