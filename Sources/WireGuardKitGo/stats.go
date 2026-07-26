/* SPDX-License-Identifier: MIT
 *
 * Copyright (C) 2026 Ryan Tenney. All Rights Reserved.
 */

package main

// Rolling path-quality statistics for warm spare cellular failover: a fixed
// window of probe outcomes per path, summarized as median RTT, loss
// percentage, and last-reply age.

import (
	"sort"
	"sync"
	"time"
)

const statsWindowSize = 20

type probeOutcome struct {
	rttMs float64 // < 0 means lost
	at    time.Time
}

type pathStats struct {
	mu        sync.Mutex
	window    []probeOutcome
	lastReply time.Time
}

func (s *pathStats) record(rttMs float64) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.window = append(s.window, probeOutcome{rttMs: rttMs, at: time.Now()})
	if len(s.window) > statsWindowSize {
		s.window = s.window[len(s.window)-statsWindowSize:]
	}
	if rttMs >= 0 {
		s.lastReply = time.Now()
	}
}

func (s *pathStats) reset() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.window = nil
}

type pathStatsJSON struct {
	RttMs           float64 `json:"rttMs"`   // median over window; -1 if no successful samples
	LossPct         int     `json:"lossPct"` // -1 if no samples
	Samples         int     `json:"samples"`
	LastReplyAgeSec float64 `json:"lastReplyAgeSec"` // -1 if never
}

func (s *pathStats) snapshot() pathStatsJSON {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := pathStatsJSON{RttMs: -1, LossPct: -1, Samples: len(s.window), LastReplyAgeSec: -1}
	if !s.lastReply.IsZero() {
		out.LastReplyAgeSec = time.Since(s.lastReply).Seconds()
	}
	if len(s.window) == 0 {
		return out
	}
	var rtts []float64
	lost := 0
	for _, o := range s.window {
		if o.rttMs < 0 {
			lost++
		} else {
			rtts = append(rtts, o.rttMs)
		}
	}
	out.LossPct = lost * 100 / len(s.window)
	if len(rtts) > 0 {
		sort.Float64s(rtts)
		out.RttMs = rtts[len(rtts)/2]
	}
	return out
}
