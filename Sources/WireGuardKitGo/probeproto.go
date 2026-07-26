/* SPDX-License-Identifier: MIT
 *
 * Copyright (C) 2026 Ryan Tenney. All Rights Reserved.
 */

package main

// Echo probe wire protocol, shared with server/echo-responder (keep the two
// in sync). Used by warm spare cellular failover for NAT keepalives, RTT/loss
// quality probes, and the EIM self-test.
//
// Request (client → server), exactly echoRequestSize bytes:
//   0..3   magic "WGE1"
//   4      type 0x01 (request)
//   5..12  opaque token (8 bytes)
//   13..   zero padding (keeps request >= any reply: amplification factor <= 1)
//
// Reply (server → client), <= 32 bytes:
//   0..3   magic "WGE1"
//   4      type 0x02 (reply)
//   5..12  token echoed
//   13     observed address family (4 or 6)
//   14..15 observed source port (big endian)
//   16..   observed source IP (4 or 16 bytes)

import (
	"crypto/rand"
	"encoding/binary"
	"net/netip"
	"time"
)

const (
	echoMagic       = "WGE1"
	echoTypeRequest = 0x01
	echoTypeReply   = 0x02
	echoRequestSize = 40
)

func buildEchoRequest(token uint64) []byte {
	pkt := make([]byte, echoRequestSize)
	copy(pkt[0:4], echoMagic)
	pkt[4] = echoTypeRequest
	binary.BigEndian.PutUint64(pkt[5:13], token)
	return pkt
}

func parseEchoReply(pkt []byte) (token uint64, observed netip.AddrPort, ok bool) {
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

func newEchoToken() uint64 {
	var b [8]byte
	if _, err := rand.Read(b[:]); err != nil {
		return uint64(time.Now().UnixNano())
	}
	return binary.BigEndian.Uint64(b[:])
}
