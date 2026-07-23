/* SPDX-License-Identifier: MIT
 *
 * Copyright (C) 2026 Ryan Tenney. All Rights Reserved.
 */

// wgnext-echo-responder is the server-side component of warm spare cellular
// failover (see DESIGN-warm-spare-cellular-failover.md in the app repo).
//
// It is a stateless UDP echo service: for each valid request it replies with
// the echoed token plus the source ip:port it observed. Clients use it for
//   - NAT keepalives (preserving the carrier CGNAT mapping on the warm socket),
//   - RTT/loss quality probes on both network paths, and
//   - the endpoint-independent-mapping (EIM) self-test, which compares the
//     observed external port across two listening ports.
//
// It listens on N consecutive ports (default 2) because the EIM test needs
// two distinct destination ports on the same host.
//
// No authentication: the reply reveals nothing beyond what any UDP service
// observes about its callers. Two properties keep it useless as a reflection
// primitive:
//   - amplification factor <= 1: requests are fixed-size (40 bytes) and
//     replies are 20 or 32 bytes; anything not exactly request-sized is
//     dropped silently;
//   - per-source-IP rate limiting (token bucket).
package main

import (
	"encoding/binary"
	"flag"
	"fmt"
	"log"
	"net"
	"net/netip"
	"os"
	"sync"
	"time"
)

const (
	echoMagic       = "WGE1"
	echoTypeRequest = 0x01
	echoTypeReply   = 0x02
	echoRequestSize = 40
)

// buildReply constructs the reply for a valid request packet, reporting the
// observed source address. Returns nil if the request is invalid.
func buildReply(req []byte, src netip.AddrPort) []byte {
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
	copy(reply[5:13], req[5:13]) // token
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

// rateLimiter is a per-source-IP token bucket. Sources refill at `rate`
// tokens/second up to `burst`. Stale entries are pruned periodically; when the
// table is full, packets from unknown sources are dropped until pruning frees
// space (bounds memory under spoofed-source floods).
type rateLimiter struct {
	mu         sync.Mutex
	buckets    map[netip.Addr]*bucket
	rate       float64
	burst      float64
	maxSources int
}

type bucket struct {
	tokens   float64
	lastSeen time.Time
}

func newRateLimiter(rate, burst float64, maxSources int) *rateLimiter {
	return &rateLimiter{
		buckets:    make(map[netip.Addr]*bucket),
		rate:       rate,
		burst:      burst,
		maxSources: maxSources,
	}
}

func (r *rateLimiter) allow(addr netip.Addr, now time.Time) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	b, ok := r.buckets[addr]
	if !ok {
		if len(r.buckets) >= r.maxSources {
			return false
		}
		r.buckets[addr] = &bucket{tokens: r.burst - 1, lastSeen: now}
		return true
	}
	b.tokens += now.Sub(b.lastSeen).Seconds() * r.rate
	if b.tokens > r.burst {
		b.tokens = r.burst
	}
	b.lastSeen = now
	if b.tokens < 1 {
		return false
	}
	b.tokens--
	return true
}

func (r *rateLimiter) prune(olderThan time.Duration) {
	r.mu.Lock()
	defer r.mu.Unlock()
	cutoff := time.Now().Add(-olderThan)
	for addr, b := range r.buckets {
		if b.lastSeen.Before(cutoff) {
			delete(r.buckets, addr)
		}
	}
}

func serve(conn *net.UDPConn, limiter *rateLimiter, verbose bool) {
	buf := make([]byte, 2048)
	for {
		n, src, err := conn.ReadFromUDPAddrPort(buf)
		if err != nil {
			log.Printf("read error on %s: %v", conn.LocalAddr(), err)
			return
		}
		if n != echoRequestSize {
			continue
		}
		if !limiter.allow(src.Addr().Unmap(), time.Now()) {
			continue
		}
		reply := buildReply(buf[:n], src)
		if reply == nil {
			continue
		}
		if len(reply) > n {
			// Defense in depth: never amplify.
			continue
		}
		if _, err := conn.WriteToUDPAddrPort(reply, src); err != nil && verbose {
			log.Printf("write error to %s: %v", src, err)
		}
		if verbose {
			log.Printf("echo %s -> observed %s:%d", conn.LocalAddr(), src.Addr().Unmap(), src.Port())
		}
	}
}

func main() {
	bindAddr := flag.String("bind", "", "address to bind (default: all interfaces)")
	basePort := flag.Int("port", 51821, "first UDP port to listen on")
	portCount := flag.Int("ports", 2, "number of consecutive ports to listen on (EIM self-test needs 2)")
	rate := flag.Float64("rate", 5, "per-source sustained packets/second")
	burst := flag.Float64("burst", 10, "per-source burst size")
	maxSources := flag.Int("max-sources", 65536, "maximum tracked source IPs")
	verbose := flag.Bool("v", false, "log every echo")
	flag.Parse()

	if *portCount < 1 || *basePort < 1 || *basePort+*portCount-1 > 65535 {
		fmt.Fprintln(os.Stderr, "invalid port range")
		os.Exit(1)
	}

	limiter := newRateLimiter(*rate, *burst, *maxSources)
	go func() {
		for range time.Tick(time.Minute) {
			limiter.prune(time.Minute)
		}
	}()

	for i := 0; i < *portCount; i++ {
		port := *basePort + i
		conn, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.ParseIP(*bindAddr), Port: port})
		if err != nil {
			log.Fatalf("listen :%d: %v", port, err)
		}
		log.Printf("listening on %s", conn.LocalAddr())
		go serve(conn, limiter, *verbose)
	}
	select {}
}
