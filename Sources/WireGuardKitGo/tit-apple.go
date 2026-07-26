//go:build darwin

/* SPDX-License-Identifier: MIT
 *
 * Copyright (C) 2026 Ryan Tenney. All Rights Reserved.
 */

package main

// #include <stdlib.h>
import "C"

import (
	"encoding/binary"
	"fmt"
	"net"
	"net/netip"
	"os"
	"sync"
	"sync/atomic"

	"golang.zx2c4.com/wireguard/conn"
	"golang.zx2c4.com/wireguard/device"
	"golang.zx2c4.com/wireguard/tun"
)

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
	pt *pipedTunnel

	// Guards closeSignal: Open/Close are called from device.BindUpdate while
	// a previous generation's receive func may still be blocked on the old
	// channel. Same pattern as dualPathBind's genClosed (warmspare.go).
	mu          sync.Mutex
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
	b.mu.Lock()
	gen := make(chan struct{})
	b.closeSignal = gen
	b.mu.Unlock()
	receive := func(data []byte) (int, conn.Endpoint, error) {
		select {
		case <-gen:
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
	b.mu.Lock()
	if b.closeSignal != nil {
		close(b.closeSignal)
		b.closeSignal = nil
	}
	b.mu.Unlock()
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
	pkt[8] = 64                                                                        // TTL
	pkt[9] = 17                                                                        // protocol: UDP
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
	pkt[0] = 0x60                                       // version=6
	binary.BigEndian.PutUint16(pkt[4:], uint16(udpLen)) // payload length
	pkt[6] = 17                                         // next header: UDP
	pkt[7] = 64                                         // hop limit
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

var titHandles = newHandleRegistry[titHandle]()

//export wgTurnOnTiT
func wgTurnOnTiT(outerSettings *C.char, innerSettings *C.char, outerIfaceIPStr *C.char, tunFd int32) int32 {
	innerLogger := newAppleLogger()
	outerLogger := newAppleLogger()

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
	innerTunDev, err := dupTUNFile(tunFd)
	if err != nil {
		innerLogger.Errorf("TiT: %v", err)
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

	i, ok := titHandles.alloc(titHandle{innerDev, innerLogger, outerDev, outerLogger, tunnel})
	if !ok {
		innerDev.Close()
		outerDev.Close()
		return -1
	}
	return i
}

//export wgTurnOffTiT
func wgTurnOffTiT(handle int32) {
	h, ok := titHandles.remove(handle)
	if !ok {
		return
	}
	h.innerDev.Close()
	h.outerDev.Close()
}

//export wgGetConfigTiT
func wgGetConfigTiT(handle int32) *C.char {
	h, ok := titHandles.get(handle)
	if !ok {
		return nil
	}
	return ipcGetCString(h.innerDev)
}

//export wgGetOuterConfigTiT
func wgGetOuterConfigTiT(handle int32) *C.char {
	h, ok := titHandles.get(handle)
	if !ok {
		return nil
	}
	return ipcGetCString(h.outerDev)
}

//export wgSetInnerConfigTiT
func wgSetInnerConfigTiT(handle int32, settings *C.char) int64 {
	h, ok := titHandles.get(handle)
	if !ok {
		return -1
	}
	return ipcSetWithErrno(h.innerDev, h.innerLogger, C.GoString(settings), "TiT inner")
}

//export wgBumpSocketsTiT
func wgBumpSocketsTiT(handle int32) {
	h, ok := titHandles.get(handle)
	if !ok {
		return
	}
	bumpSocketsRetry(h.outerDev, h.outerLogger, "TiT")
}

//export wgDisableSomeRoamingForBrokenMobileSemanticsForOuterTiT
func wgDisableSomeRoamingForBrokenMobileSemanticsForOuterTiT(handle int32) {
	h, ok := titHandles.get(handle)
	if !ok {
		return
	}
	h.outerDev.DisableSomeRoamingForBrokenMobileSemantics()
}
