/* SPDX-License-Identifier: MIT
 *
 * Copyright (C) 2026 Ryan Tenney. All Rights Reserved.
 */

package main

import (
	"encoding/binary"
	"net/netip"
	"testing"
	"time"
)

func makeRequest(token uint64) []byte {
	pkt := make([]byte, echoRequestSize)
	copy(pkt[0:4], echoMagic)
	pkt[4] = echoTypeRequest
	binary.BigEndian.PutUint64(pkt[5:13], token)
	return pkt
}

// parseReply mirrors the client-side parser in the app's Go bridge
// (Sources/WireGuardKitGo/warmspare.go). Keep the two in sync.
func parseReply(pkt []byte) (token uint64, observed netip.AddrPort, ok bool) {
	if len(pkt) < 16 || string(pkt[0:4]) != echoMagic || pkt[4] != echoTypeReply {
		return 0, netip.AddrPort{}, false
	}
	token = binary.BigEndian.Uint64(pkt[5:13])
	family := pkt[13]
	port := binary.BigEndian.Uint16(pkt[14:16])
	switch {
	case family == 4 && len(pkt) >= 20:
		var b [4]byte
		copy(b[:], pkt[16:20])
		observed = netip.AddrPortFrom(netip.AddrFrom4(b), port)
	case family == 6 && len(pkt) >= 32:
		var b [16]byte
		copy(b[:], pkt[16:32])
		observed = netip.AddrPortFrom(netip.AddrFrom16(b), port)
	default:
		return 0, netip.AddrPort{}, false
	}
	return token, observed, true
}

func TestReplyRoundTripIPv4(t *testing.T) {
	src := netip.MustParseAddrPort("203.0.113.9:41641")
	reply := buildReply(makeRequest(0xdeadbeefcafe1234), src)
	if reply == nil {
		t.Fatal("valid request rejected")
	}
	if len(reply) > echoRequestSize {
		t.Fatalf("amplification: reply %d > request %d", len(reply), echoRequestSize)
	}
	token, observed, ok := parseReply(reply)
	if !ok {
		t.Fatal("reply failed to parse")
	}
	if token != 0xdeadbeefcafe1234 {
		t.Fatalf("token mismatch: %x", token)
	}
	if observed != src {
		t.Fatalf("observed %s, want %s", observed, src)
	}
}

func TestReplyRoundTripIPv6(t *testing.T) {
	src := netip.MustParseAddrPort("[2001:db8::42]:5000")
	reply := buildReply(makeRequest(7), src)
	if reply == nil {
		t.Fatal("valid request rejected")
	}
	if len(reply) > echoRequestSize {
		t.Fatalf("amplification: reply %d > request %d", len(reply), echoRequestSize)
	}
	_, observed, ok := parseReply(reply)
	if !ok || observed != src {
		t.Fatalf("observed %s, want %s", observed, src)
	}
}

func TestReplyUnmapsV4MappedV6(t *testing.T) {
	// A dual-stack socket reports IPv4 clients as ::ffff:a.b.c.d — the reply
	// must report family 4 with the unmapped address.
	src := netip.MustParseAddrPort("[::ffff:198.51.100.7]:1234")
	reply := buildReply(makeRequest(1), src)
	if reply == nil {
		t.Fatal("valid request rejected")
	}
	if reply[13] != 4 {
		t.Fatalf("family = %d, want 4", reply[13])
	}
	_, observed, ok := parseReply(reply)
	if !ok || observed.Addr() != netip.MustParseAddr("198.51.100.7") || observed.Port() != 1234 {
		t.Fatalf("observed %s", observed)
	}
}

func TestInvalidRequestsRejected(t *testing.T) {
	src := netip.MustParseAddrPort("203.0.113.9:41641")
	short := makeRequest(1)[:20]
	if buildReply(short, src) != nil {
		t.Fatal("short request accepted")
	}
	badMagic := makeRequest(1)
	badMagic[0] = 'X'
	if buildReply(badMagic, src) != nil {
		t.Fatal("bad magic accepted")
	}
	badType := makeRequest(1)
	badType[4] = echoTypeReply
	if buildReply(badType, src) != nil {
		t.Fatal("reply-typed request accepted")
	}
}

func TestRateLimiter(t *testing.T) {
	rl := newRateLimiter(5, 10, 100)
	addr := netip.MustParseAddr("203.0.113.9")
	now := time.Now()
	for i := 0; i < 10; i++ {
		if !rl.allow(addr, now) {
			t.Fatalf("burst packet %d rejected", i)
		}
	}
	if rl.allow(addr, now) {
		t.Fatal("packet beyond burst allowed")
	}
	// After one second, ~5 tokens refill.
	later := now.Add(time.Second)
	allowed := 0
	for i := 0; i < 10; i++ {
		if rl.allow(addr, later) {
			allowed++
		}
	}
	if allowed != 5 {
		t.Fatalf("allowed %d after refill, want 5", allowed)
	}
}

func TestRateLimiterMaxSources(t *testing.T) {
	rl := newRateLimiter(5, 10, 2)
	now := time.Now()
	if !rl.allow(netip.MustParseAddr("192.0.2.1"), now) || !rl.allow(netip.MustParseAddr("192.0.2.2"), now) {
		t.Fatal("initial sources rejected")
	}
	if rl.allow(netip.MustParseAddr("192.0.2.3"), now) {
		t.Fatal("source beyond table limit allowed")
	}
	rl.prune(0)
	if !rl.allow(netip.MustParseAddr("192.0.2.3"), now.Add(time.Millisecond)) {
		t.Fatal("source rejected after prune")
	}
}
