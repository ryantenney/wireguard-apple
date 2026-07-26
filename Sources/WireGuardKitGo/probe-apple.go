//go:build darwin

/* SPDX-License-Identifier: MIT
 *
 * Copyright (C) 2026 Ryan Tenney. All Rights Reserved.
 */

package main

// #include <stdlib.h>
import "C"

import (
	"fmt"
	"os"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"

	"golang.zx2c4.com/wireguard/conn"
	"golang.zx2c4.com/wireguard/device"
	"golang.zx2c4.com/wireguard/tun"
)

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

func (t *nullTunDevice) File() *os.File           { return nil }
func (t *nullTunDevice) Flush() error             { return nil }
func (t *nullTunDevice) MTU() (int, error)        { return t.mtu, nil }
func (t *nullTunDevice) Name() (string, error)    { return "probe0", nil }
func (t *nullTunDevice) Events() <-chan tun.Event { return t.events }

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

var probeHandles = newHandleRegistry[probeHandle]()

//export wgProbeOn
func wgProbeOn(settings *C.char, keepaliveOverride int32) int32 {
	logger := newAppleLogger()

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

	i, ok := probeHandles.alloc(probeHandle{dev, logger, swappable})
	if !ok {
		dev.Close()
		return -1
	}
	return i
}

//export wgProbeOff
func wgProbeOff(handle int32) {
	h, ok := probeHandles.remove(handle)
	if !ok {
		return
	}
	h.Close()
}

//export wgProbeGetConfig
func wgProbeGetConfig(handle int32) *C.char {
	h, ok := probeHandles.get(handle)
	if !ok {
		return nil
	}
	return ipcGetCString(h.Device)
}

//export wgProbeBumpSockets
func wgProbeBumpSockets(handle int32) {
	h, ok := probeHandles.get(handle)
	if !ok {
		return
	}
	bumpSocketsRetry(h.Device, h.Logger, "Probe")
}

//export wgProbePromote
func wgProbePromote(probeHandleID int32, tunFd int32) int32 {
	h, ok := probeHandles.get(probeHandleID)
	if !ok {
		return -1
	}

	// Create a real tun device from the file descriptor.
	realTun, err := dupTUNFile(tunFd)
	if err != nil {
		h.Errorf("Probe promote: %v", err)
		return -1
	}

	// Swap the null tun for the real tun. This unblocks the read goroutine
	// which will start processing real packets with the existing Noise session.
	h.tunDev.swap(realTun)
	h.Verbosef("Probe promote: swapped null tun for real utun — session preserved")

	// Remove from probeHandles and add to tunnelHandles.
	probeHandles.remove(probeHandleID)

	i, ok := tunnelHandles.alloc(tunnelHandle{h.Device, h.Logger})
	if !ok {
		h.Errorf("Probe promote: no free tunnel handle slot")
		h.Close()
		return -1
	}
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
