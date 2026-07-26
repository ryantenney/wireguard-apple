//go:build darwin

/* SPDX-License-Identifier: MIT
 *
 * Copyright (C) 2026 Ryan Tenney. All Rights Reserved.
 */

package main

// ========== Warm Spare Cellular Failover ==========
//
// Keeps a pre-warmed UDP socket bound to the cellular interface (IP_BOUND_IF)
// while the tunnel rides the default path (typically Wi-Fi). Failover becomes
// an atomic path flip inside the running device instead of a socket rebind:
// WireGuard sessions are keyed to the peer public key, not the 5-tuple, so the
// server re-homes the peer endpoint from the source of the first authenticated
// packet sent out the cellular socket.
//
// Components:
//   dualPathBind        — conn.Bind wrapping StdNetBind (primary/default path)
//                         plus optional interface-bound cellular sockets.
//   warmSpareController — NAT keepalives, quality probes (both paths), EIM
//                         self-test, and stats reporting.
//
// The cellular sockets intentionally survive bind Close()/Open() cycles
// (device.BindUpdate on network change) — tearing them down would destroy the
// carrier NAT mapping that warming exists to preserve.
//
// Invariant: nothing but Send() with activePath == cellular ever writes
// WireGuard traffic to the cellular sockets. Keepalives and probes go to the
// echo responder port only, so the server never re-homes the session
// prematurely (see DESIGN-warm-spare-cellular-failover.md).

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/netip"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
	"golang.zx2c4.com/wireguard/conn"
	"golang.zx2c4.com/wireguard/device"
)

const (
	warmPathPrimary  int32 = 0
	warmPathCellular int32 = 1
)

// ---- Cellular sockets (interface-bound) ----

type cellularSockets struct {
	v4      *net.UDPConn
	v6      *net.UDPConn
	ifindex int
	closed  chan struct{}
}

func boundIfControl(level, opt, ifindex int) func(network, address string, c syscall.RawConn) error {
	return func(network, address string, c syscall.RawConn) error {
		var ctrlErr error
		err := c.Control(func(fd uintptr) {
			ctrlErr = unix.SetsockoptInt(int(fd), level, opt, ifindex)
		})
		if err != nil {
			return err
		}
		return ctrlErr
	}
}

// openCellularSockets creates UDP sockets pinned to the given interface index
// via IP_BOUND_IF / IPV6_BOUND_IF. The kernel forces their packets out that
// interface regardless of routing tables, which both keeps probe traffic off
// the utun and lets the tunnel transmit via cellular while Wi-Fi is the
// default route.
func openCellularSockets(ifindex int, logger *device.Logger) (*cellularSockets, error) {
	cs := &cellularSockets{ifindex: ifindex, closed: make(chan struct{})}

	lc4 := net.ListenConfig{Control: boundIfControl(unix.IPPROTO_IP, unix.IP_BOUND_IF, ifindex)}
	if pc, err := lc4.ListenPacket(context.Background(), "udp4", ":0"); err == nil {
		cs.v4 = pc.(*net.UDPConn)
	} else {
		logger.Verbosef("Warm spare: cellular IPv4 socket unavailable: %v", err)
	}

	lc6 := net.ListenConfig{Control: boundIfControl(unix.IPPROTO_IPV6, unix.IPV6_BOUND_IF, ifindex)}
	if pc, err := lc6.ListenPacket(context.Background(), "udp6", ":0"); err == nil {
		cs.v6 = pc.(*net.UDPConn)
	} else {
		logger.Verbosef("Warm spare: cellular IPv6 socket unavailable: %v", err)
	}

	if cs.v4 == nil && cs.v6 == nil {
		return nil, fmt.Errorf("no cellular socket could be bound to ifindex %d", ifindex)
	}
	return cs, nil
}

func (cs *cellularSockets) sendTo(pkt []byte, dst netip.AddrPort) error {
	addr := dst.Addr().Unmap()
	c := cs.v6
	if addr.Is4() {
		c = cs.v4
	}
	if c == nil {
		return syscall.EAFNOSUPPORT
	}
	_, err := c.WriteToUDPAddrPort(pkt, netip.AddrPortFrom(addr, dst.Port()))
	return err
}

func (cs *cellularSockets) close() {
	select {
	case <-cs.closed:
		return
	default:
		close(cs.closed)
	}
	if cs.v4 != nil {
		cs.v4.Close()
	}
	if cs.v6 != nil {
		cs.v6.Close()
	}
}

// ---- dualPathBind ----

type cellPacket struct {
	data []byte
	src  netip.AddrPort
}

type dualPathBind struct {
	inner      conn.Bind // StdNetBind: sockets on the system default path
	activePath int32     // atomic: warmPathPrimary | warmPathCellular
	logger     *device.Logger

	mu        sync.Mutex
	cell      *cellularSockets // nil while cold
	genClosed chan struct{}    // closed on bind Close(); recreated on Open()

	// recvCh outlives Open/Close cycles: the cellular reader goroutines push
	// inbound WireGuard packets here, and the per-generation receive func
	// hands them to the device.
	recvCh chan cellPacket

	ctrl *warmSpareController // set once, immediately after construction
}

func newDualPathBind(logger *device.Logger) *dualPathBind {
	return &dualPathBind{
		inner:  conn.NewStdNetBind(),
		logger: logger,
		recvCh: make(chan cellPacket, 256),
	}
}

func (b *dualPathBind) Open(port uint16) ([]conn.ReceiveFunc, uint16, error) {
	fns, actualPort, err := b.inner.Open(port)
	if err != nil {
		return nil, 0, err
	}
	b.mu.Lock()
	gen := make(chan struct{})
	b.genClosed = gen
	b.mu.Unlock()
	fns = append(fns, b.makeCellReceive(gen))
	return fns, actualPort, nil
}

func (b *dualPathBind) makeCellReceive(gen chan struct{}) conn.ReceiveFunc {
	return func(buf []byte) (int, conn.Endpoint, error) {
		select {
		case <-gen:
			return 0, nil, net.ErrClosed
		case pkt := <-b.recvCh:
			n := copy(buf, pkt.data)
			return n, conn.StdNetEndpoint(pkt.src), nil
		}
	}
}

func (b *dualPathBind) Close() error {
	b.mu.Lock()
	if b.genClosed != nil {
		close(b.genClosed)
		b.genClosed = nil
	}
	b.mu.Unlock()
	// The cellular sockets deliberately survive: BindUpdate() Close/Open
	// cycles must not destroy the warm NAT mapping. They are torn down by
	// warmSpareController.stop() / clearCellular().
	return b.inner.Close()
}

func (b *dualPathBind) SetMark(mark uint32) error {
	return b.inner.SetMark(mark)
}

func (b *dualPathBind) ParseEndpoint(s string) (conn.Endpoint, error) {
	return b.inner.ParseEndpoint(s)
}

func (b *dualPathBind) Send(buff []byte, ep conn.Endpoint) error {
	if atomic.LoadInt32(&b.activePath) == warmPathCellular {
		b.mu.Lock()
		cs := b.cell
		b.mu.Unlock()
		if cs != nil {
			if nend, ok := ep.(conn.StdNetEndpoint); ok {
				if err := cs.sendTo(buff, netip.AddrPort(nend)); err == nil {
					return nil
				}
				// Cellular send failed (interface went away, data toggled
				// off, ...) — fall through to the primary socket so traffic
				// still has a way out.
			}
		}
	}
	return b.inner.Send(buff, ep)
}

func (b *dualPathBind) setCellular(cs *cellularSockets) {
	b.mu.Lock()
	old := b.cell
	b.cell = cs
	b.mu.Unlock()
	if old != nil {
		old.close()
	}
}

func (b *dualPathBind) cellular() *cellularSockets {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.cell
}

func (b *dualPathBind) setActivePath(path int32) (changed bool) {
	return atomic.SwapInt32(&b.activePath, path) != path
}

// readCellLoop drains one cellular socket. Echo replies from the probe port
// are consumed by the controller; everything else (WireGuard traffic after a
// flip, or during the transition window) is handed to the device.
func (b *dualPathBind) readCellLoop(cs *cellularSockets, c *net.UDPConn) {
	buf := make([]byte, 65535)
	for {
		n, src, err := c.ReadFromUDPAddrPort(buf)
		if err != nil {
			select {
			case <-cs.closed:
			default:
				b.logger.Verbosef("Warm spare: cellular read loop ended: %v", err)
			}
			return
		}
		srcU := netip.AddrPortFrom(src.Addr().Unmap(), src.Port())
		if b.ctrl.maybeHandleEcho(buf[:n], srcU) {
			continue
		}
		data := make([]byte, n)
		copy(data, buf[:n])
		select {
		case b.recvCh <- cellPacket{data: data, src: srcU}:
		default:
			// Channel full — drop. WireGuard treats UDP as lossy.
		}
	}
}

// ---- warmSpareController ----

type pendingProbe struct {
	sent    time.Time
	path    int32
	dstPort uint16
	eim     bool
}

type eimState struct {
	verdict    string // "", "pending", "eim", "edm", "unreachable"
	externalIP string
	ports      map[uint16]uint16 // dst probe port -> observed external port
	testedAt   time.Time
}

type warmSpareController struct {
	logger    *device.Logger
	bind      *dualPathBind
	probeAddr netip.Addr // resolved server IP; must match the active peer endpoint
	probePort uint16

	keepaliveInterval    time.Duration // cellular NAT keepalive cadence
	primaryProbeInterval time.Duration // default-path quality probe cadence

	devMu sync.Mutex
	dev   *device.Device

	mu            sync.Mutex
	pending       map[uint64]pendingProbe
	primaryConn   *net.UDPConn  // unbound socket following the system default path
	keepaliveStop chan struct{} // non-nil while cellular is warm
	stopped       bool

	// primaryProbing gates the default-path quality probes (atomic bool).
	// Probes only inform decisions while Wi-Fi is the default path
	// (degradation detection, recovery dwell); the path controller disables
	// them otherwise so an always-on tunnel doesn't ping over cellular all
	// day. Defaults to enabled.
	primaryProbing int32

	primaryStats  pathStats
	cellularStats pathStats

	eimMu sync.Mutex
	eim   eimState

	stopCh chan struct{}
}

const (
	defaultPrimaryProbeInterval = 3 * time.Second
	probeTimeout                = 3 * time.Second
	eimTestTimeout              = 5 * time.Second
)

func newWarmSpareController(bind *dualPathBind, probeAddr netip.Addr, probePort uint16, keepaliveSeconds int, logger *device.Logger) *warmSpareController {
	if keepaliveSeconds <= 0 {
		keepaliveSeconds = 25
	}
	return &warmSpareController{
		logger:               logger,
		bind:                 bind,
		probeAddr:            probeAddr.Unmap(),
		probePort:            probePort,
		keepaliveInterval:    time.Duration(keepaliveSeconds) * time.Second,
		primaryProbeInterval: defaultPrimaryProbeInterval,
		pending:              make(map[uint64]pendingProbe),
		primaryProbing:       1,
		stopCh:               make(chan struct{}),
	}
}

// setPrimaryProbing enables or disables default-path quality probes. Stats
// are reset on transition so stale samples can't feed later decisions.
func (c *warmSpareController) setPrimaryProbing(enabled bool) {
	var v int32
	if enabled {
		v = 1
	}
	if atomic.SwapInt32(&c.primaryProbing, v) != v {
		c.primaryStats.reset()
		c.logger.Verbosef("Warm spare: primary-path probing %s", map[bool]string{true: "enabled", false: "disabled"}[enabled])
	}
}

func (c *warmSpareController) setDevice(dev *device.Device) {
	c.devMu.Lock()
	c.dev = dev
	c.devMu.Unlock()
}

// eimSecondPort is the second target for the endpoint-independent-mapping
// self-test. probePort+1 by convention, wrapping away from overflow.
func (c *warmSpareController) eimSecondPort() uint16 {
	if c.probePort == 65535 {
		return c.probePort - 1
	}
	return c.probePort + 1
}

func (c *warmSpareController) start() {
	// The default-path probe socket is unconnected, so each sendto follows
	// whatever route is current — it migrates between Wi-Fi and cellular with
	// the default path, measuring "the path WireGuard's primary socket would
	// use right now".
	pc, err := net.ListenUDP("udp", nil)
	if err != nil {
		c.logger.Errorf("Warm spare: unable to open primary probe socket: %v", err)
	} else {
		c.mu.Lock()
		c.primaryConn = pc
		c.mu.Unlock()
		go c.readPrimaryLoop(pc)
		go c.primaryProbeLoop()
	}
	go c.reaperLoop()
}

func (c *warmSpareController) stop() {
	c.mu.Lock()
	if c.stopped {
		c.mu.Unlock()
		return
	}
	c.stopped = true
	pc := c.primaryConn
	c.primaryConn = nil
	c.mu.Unlock()

	close(c.stopCh)
	c.clearCellular()
	if pc != nil {
		pc.Close()
	}
}

// warmCellular opens interface-bound sockets and starts the NAT keepalive
// scheduler. Idempotent for the same ifindex; re-warms if the index changed.
func (c *warmSpareController) warmCellular(ifindex int) error {
	c.mu.Lock()
	if c.stopped {
		c.mu.Unlock()
		return fmt.Errorf("controller stopped")
	}
	c.mu.Unlock()

	if existing := c.bind.cellular(); existing != nil {
		if existing.ifindex == ifindex {
			return nil
		}
		c.clearCellular()
	}

	cs, err := openCellularSockets(ifindex, c.logger)
	if err != nil {
		return err
	}
	c.bind.setCellular(cs)
	if cs.v4 != nil {
		go c.bind.readCellLoop(cs, cs.v4)
	}
	if cs.v6 != nil {
		go c.bind.readCellLoop(cs, cs.v6)
	}

	stop := make(chan struct{})
	c.mu.Lock()
	if c.keepaliveStop != nil {
		close(c.keepaliveStop)
	}
	c.keepaliveStop = stop
	c.mu.Unlock()
	go c.cellKeepaliveLoop(stop)

	// Pre-verify with an immediate echo: creates the NAT mapping right away
	// and produces the first cellular RTT sample.
	c.sendProbe(warmPathCellular, c.probePort, false)
	c.logger.Verbosef("Warm spare: cellular warm on ifindex %d", ifindex)
	return nil
}

func (c *warmSpareController) clearCellular() {
	c.mu.Lock()
	if c.keepaliveStop != nil {
		close(c.keepaliveStop)
		c.keepaliveStop = nil
	}
	c.mu.Unlock()
	c.bind.setCellular(nil)
	c.cellularStats.reset()
	c.logger.Verbosef("Warm spare: cellular cold")
}

// setActivePath flips which socket Send() uses and immediately pushes an
// authenticated keepalive out the new path so the server re-homes the peer
// endpoint without waiting for user traffic. If the session has expired the
// keepalive is a no-op and the next outbound packet triggers a handshake over
// the same (warm) socket instead — still one RTT.
func (c *warmSpareController) setActivePath(path int32) {
	if !c.bind.setActivePath(path) {
		return
	}
	name := "primary"
	if path == warmPathCellular {
		name = "cellular"
	}
	c.logger.Verbosef("Warm spare: active path -> %s", name)
	c.devMu.Lock()
	dev := c.dev
	c.devMu.Unlock()
	if dev != nil {
		go dev.SendKeepalivesToPeersWithCurrentKeypair()
	}
}

func (c *warmSpareController) activePath() int32 {
	return atomic.LoadInt32(&c.bind.activePath)
}

// ---- Probe transmission and echo handling ----

func (c *warmSpareController) sendProbe(path int32, dstPort uint16, eim bool) {
	token := newEchoToken()
	c.mu.Lock()
	if c.stopped {
		c.mu.Unlock()
		return
	}
	c.pending[token] = pendingProbe{sent: time.Now(), path: path, dstPort: dstPort, eim: eim}
	pc := c.primaryConn
	c.mu.Unlock()

	pkt := buildEchoRequest(token)
	dst := netip.AddrPortFrom(c.probeAddr, dstPort)

	var err error
	if path == warmPathCellular {
		cs := c.bind.cellular()
		if cs == nil {
			err = fmt.Errorf("cellular cold")
		} else {
			err = cs.sendTo(pkt, dst)
		}
	} else {
		if pc == nil {
			err = fmt.Errorf("no primary probe socket")
		} else {
			_, err = pc.WriteToUDPAddrPort(pkt, dst)
		}
	}
	if err != nil {
		c.mu.Lock()
		delete(c.pending, token)
		c.mu.Unlock()
		c.logger.Verbosef("Warm spare: probe send failed (path %d, port %d): %v", path, dstPort, err)
		if eim {
			c.finalizeEim()
		}
	}
}

// maybeHandleEcho consumes echo replies arriving on the cellular sockets.
// Returns true if the packet was an echo reply (even a stale one), so the
// caller doesn't forward it to the device.
func (c *warmSpareController) maybeHandleEcho(pkt []byte, src netip.AddrPort) bool {
	if src.Addr() != c.probeAddr {
		return false
	}
	if src.Port() != c.probePort && src.Port() != c.eimSecondPort() {
		return false
	}
	token, observed, ok := parseEchoReply(pkt)
	if !ok {
		return false
	}
	c.handleEchoReply(token, observed)
	return true
}

func (c *warmSpareController) readPrimaryLoop(pc *net.UDPConn) {
	buf := make([]byte, 2048)
	for {
		n, src, err := pc.ReadFromUDPAddrPort(buf)
		if err != nil {
			return
		}
		srcU := netip.AddrPortFrom(src.Addr().Unmap(), src.Port())
		if srcU.Addr() != c.probeAddr {
			continue
		}
		if token, observed, ok := parseEchoReply(buf[:n]); ok {
			c.handleEchoReply(token, observed)
		}
	}
}

func (c *warmSpareController) handleEchoReply(token uint64, observed netip.AddrPort) {
	c.mu.Lock()
	p, exists := c.pending[token]
	if exists {
		delete(c.pending, token)
	}
	c.mu.Unlock()
	if !exists {
		return
	}
	rttMs := float64(time.Since(p.sent)) / float64(time.Millisecond)
	if p.path == warmPathCellular {
		c.cellularStats.record(rttMs)
	} else {
		c.primaryStats.record(rttMs)
	}
	if p.eim {
		c.recordEimObservation(p.dstPort, observed)
	}
}

func (c *warmSpareController) primaryProbeLoop() {
	ticker := time.NewTicker(c.primaryProbeInterval)
	defer ticker.Stop()
	for {
		select {
		case <-c.stopCh:
			return
		case <-ticker.C:
			if atomic.LoadInt32(&c.primaryProbing) == 1 {
				c.sendProbe(warmPathPrimary, c.probePort, false)
			}
		}
	}
}

func (c *warmSpareController) cellKeepaliveLoop(stop chan struct{}) {
	ticker := time.NewTicker(c.keepaliveInterval)
	defer ticker.Stop()
	for {
		select {
		case <-c.stopCh:
			return
		case <-stop:
			return
		case <-ticker.C:
			c.sendProbe(warmPathCellular, c.probePort, false)
		}
	}
}

// reaperLoop expires unanswered probes into loss samples.
func (c *warmSpareController) reaperLoop() {
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-c.stopCh:
			return
		case <-ticker.C:
			now := time.Now()
			var lost []pendingProbe
			c.mu.Lock()
			for token, p := range c.pending {
				if now.Sub(p.sent) > probeTimeout {
					delete(c.pending, token)
					lost = append(lost, p)
				}
			}
			c.mu.Unlock()
			for _, p := range lost {
				if p.path == warmPathCellular {
					c.cellularStats.record(-1)
				} else {
					c.primaryStats.record(-1)
				}
				if p.eim {
					c.finalizeEim()
				}
			}
		}
	}
}

// ---- EIM self-test ----

// startEimTest probes two distinct server ports from the cellular socket and
// compares the externally observed source ports. Equal ports mean the carrier
// NAT does endpoint-independent mapping (RFC 4787 REQ-1): the mapping kept
// alive on the probe port is the same one WireGuard traffic will use, so warm
// spare is fully effective.
func (c *warmSpareController) startEimTest() error {
	if c.bind.cellular() == nil {
		return fmt.Errorf("cellular is cold")
	}
	c.eimMu.Lock()
	c.eim = eimState{verdict: "pending", ports: make(map[uint16]uint16), testedAt: time.Now()}
	c.eimMu.Unlock()

	c.sendProbe(warmPathCellular, c.probePort, true)
	c.sendProbe(warmPathCellular, c.eimSecondPort(), true)

	time.AfterFunc(eimTestTimeout, c.finalizeEim)
	return nil
}

func (c *warmSpareController) recordEimObservation(dstPort uint16, observed netip.AddrPort) {
	c.eimMu.Lock()
	defer c.eimMu.Unlock()
	if c.eim.ports == nil {
		return
	}
	c.eim.ports[dstPort] = observed.Port()
	c.eim.externalIP = observed.Addr().String()
	if len(c.eim.ports) == 2 {
		p1 := c.eim.ports[c.probePort]
		p2 := c.eim.ports[c.eimSecondPort()]
		if p1 == p2 {
			c.eim.verdict = "eim"
		} else {
			c.eim.verdict = "edm"
		}
		c.logger.Verbosef("Warm spare: EIM self-test verdict=%s (ports %d/%d)", c.eim.verdict, p1, p2)
	}
}

func (c *warmSpareController) finalizeEim() {
	c.eimMu.Lock()
	defer c.eimMu.Unlock()
	if c.eim.verdict == "pending" {
		c.eim.verdict = "unreachable"
		c.logger.Verbosef("Warm spare: EIM self-test got %d/2 replies; verdict=unreachable", len(c.eim.ports))
	}
}

// ---- State reporting ----

type warmSpareStateJSON struct {
	ActivePath      string        `json:"activePath"`
	CellularWarm    bool          `json:"cellularWarm"`
	CellularIfindex int           `json:"cellularIfindex,omitempty"`
	Primary         pathStatsJSON `json:"primaryPath"`
	Cellular        pathStatsJSON `json:"cellularPath"`
	Eim             *eimJSON      `json:"eim,omitempty"`
}

type eimJSON struct {
	Verdict      string  `json:"verdict"`
	ExternalIP   string  `json:"externalIP,omitempty"`
	TestedAgeSec float64 `json:"testedAgeSec"`
}

func (c *warmSpareController) stateJSON() string {
	state := warmSpareStateJSON{
		ActivePath: "primary",
		Primary:    c.primaryStats.snapshot(),
		Cellular:   c.cellularStats.snapshot(),
	}
	if c.activePath() == warmPathCellular {
		state.ActivePath = "cellular"
	}
	if cs := c.bind.cellular(); cs != nil {
		state.CellularWarm = true
		state.CellularIfindex = cs.ifindex
	}
	c.eimMu.Lock()
	if c.eim.verdict != "" {
		state.Eim = &eimJSON{
			Verdict:      c.eim.verdict,
			ExternalIP:   c.eim.externalIP,
			TestedAgeSec: time.Since(c.eim.testedAt).Seconds(),
		}
	}
	c.eimMu.Unlock()

	b, err := json.Marshal(state)
	if err != nil {
		return "{}"
	}
	return string(b)
}

// ---- Device construction ----

// newWarmTunnel builds a WireGuard device whose bind is a dualPathBind, plus
// the controller managing its warm spare machinery. Mirrors wgTurnOn's tun
// setup. The caller owns handle bookkeeping.
func newWarmTunnel(settings string, probeAddrStr string, probePort int, keepaliveSeconds int, tunFd int32, logger *device.Logger) (*device.Device, *warmSpareController, error) {
	probeAddr, err := netip.ParseAddr(probeAddrStr)
	if err != nil {
		return nil, nil, fmt.Errorf("invalid probe address %q: %w", probeAddrStr, err)
	}
	if probePort <= 0 || probePort > 65535 {
		return nil, nil, fmt.Errorf("invalid probe port %d", probePort)
	}

	tunDev, err := dupTUNFile(tunFd)
	if err != nil {
		return nil, nil, err
	}

	bind := newDualPathBind(logger)
	ctrl := newWarmSpareController(bind, probeAddr, uint16(probePort), keepaliveSeconds, logger)
	bind.ctrl = ctrl

	dev := device.NewDevice(tunDev, bind, logger)
	if err := dev.IpcSet(settings); err != nil {
		dev.Close()
		return nil, nil, fmt.Errorf("unable to set IPC settings: %w", err)
	}
	dev.Up()
	ctrl.setDevice(dev)
	ctrl.start()
	logger.Verbosef("Warm spare: device started (probe target %s:%d, keepalive %ds)", probeAddr, probePort, keepaliveSeconds)
	return dev, ctrl, nil
}
