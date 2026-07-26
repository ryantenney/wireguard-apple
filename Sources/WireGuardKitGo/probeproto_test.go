/* SPDX-License-Identifier: MIT
 *
 * Copyright (C) 2026 Ryan Tenney. All Rights Reserved.
 */

package main

import (
	"encoding/binary"
	"net/netip"
	"testing"
)

// buildServerReply mirrors the responder in server/echo-responder/main.go
// (buildReply). Keep the two in sync.
func buildServerReply(req []byte, src netip.AddrPort) []byte {
	if len(req) != echoRequestSize || string(req[0:4]) != echoMagic || req[4] != echoTypeRequest {
		return nil
	}
	addr := src.Addr().Unmap()
	var reply []byte
	if addr.Is4() {
		reply = make([]byte, 20)
	} else {
		reply = make([]byte, 32)
	}
	copy(reply[0:4], echoMagic)
	reply[4] = echoTypeReply
	copy(reply[5:13], req[5:13])
	binary.BigEndian.PutUint16(reply[14:16], src.Port())
	if addr.Is4() {
		reply[13] = 4
		b := addr.As4()
		copy(reply[16:20], b[:])
	} else {
		reply[13] = 6
		b := addr.As16()
		copy(reply[16:32], b[:])
	}
	return reply
}

func TestEchoRoundTripIPv4(t *testing.T) {
	token := newEchoToken()
	req := buildEchoRequest(token)
	if len(req) != echoRequestSize {
		t.Fatalf("request size = %d, want %d", len(req), echoRequestSize)
	}

	src := netip.MustParseAddrPort("203.0.113.9:41641")
	reply := buildServerReply(req, src)
	if reply == nil {
		t.Fatal("server rejected a valid request")
	}
	if len(reply) > len(req) {
		t.Fatalf("amplification: reply %d > request %d", len(reply), len(req))
	}

	gotToken, observed, ok := parseEchoReply(reply)
	if !ok {
		t.Fatal("reply failed to parse")
	}
	if gotToken != token {
		t.Fatalf("token = %x, want %x", gotToken, token)
	}
	if observed != src {
		t.Fatalf("observed = %s, want %s", observed, src)
	}
}

func TestEchoRoundTripIPv6(t *testing.T) {
	req := buildEchoRequest(7)
	src := netip.MustParseAddrPort("[2001:db8::42]:5000")
	reply := buildServerReply(req, src)
	if reply == nil {
		t.Fatal("server rejected a valid request")
	}
	_, observed, ok := parseEchoReply(reply)
	if !ok || observed != src {
		t.Fatalf("observed = %s, want %s", observed, src)
	}
}

func TestParseRejectsMalformedReplies(t *testing.T) {
	valid := buildServerReply(buildEchoRequest(1), netip.MustParseAddrPort("203.0.113.9:1"))

	cases := map[string][]byte{
		"empty":                {},
		"short":                valid[:12],
		"bad magic":            append([]byte("XGE1"), valid[4:]...),
		"request type":         buildEchoRequest(1),
		"bad family":           func() []byte { p := append([]byte{}, valid...); p[13] = 9; return p }(),
		"v6 family, v4 length": func() []byte { p := append([]byte{}, valid...); p[13] = 6; return p }(),
	}
	for name, pkt := range cases {
		if _, _, ok := parseEchoReply(pkt); ok {
			t.Errorf("%s: parseEchoReply accepted malformed packet", name)
		}
	}
}

func TestEchoTokensVary(t *testing.T) {
	seen := make(map[uint64]bool)
	for i := 0; i < 64; i++ {
		tok := newEchoToken()
		if seen[tok] {
			t.Fatalf("duplicate token %x within 64 draws", tok)
		}
		seen[tok] = true
	}
}
