/* SPDX-License-Identifier: MIT
 *
 * Copyright (C) 2026 Ryan Tenney. All Rights Reserved.
 */

package main

import (
	"sync"
	"testing"
)

func TestSnapshotEmpty(t *testing.T) {
	var s pathStats
	snap := s.snapshot()
	if snap.RttMs != -1 || snap.LossPct != -1 || snap.Samples != 0 || snap.LastReplyAgeSec != -1 {
		t.Fatalf("empty snapshot = %+v, want all sentinel values", snap)
	}
}

func TestSnapshotMedianAndLoss(t *testing.T) {
	var s pathStats
	for _, rtt := range []float64{10, 20, 30, 40} {
		s.record(rtt)
	}
	s.record(-1) // one lost probe

	snap := s.snapshot()
	if snap.Samples != 5 {
		t.Fatalf("samples = %d, want 5", snap.Samples)
	}
	if snap.LossPct != 20 {
		t.Fatalf("lossPct = %d, want 20", snap.LossPct)
	}
	// Median of [10 20 30 40] is the upper-middle element (index len/2).
	if snap.RttMs != 30 {
		t.Fatalf("rttMs = %v, want 30", snap.RttMs)
	}
	if snap.LastReplyAgeSec < 0 {
		t.Fatalf("lastReplyAgeSec = %v, want >= 0 after successful replies", snap.LastReplyAgeSec)
	}
}

func TestSnapshotAllLost(t *testing.T) {
	var s pathStats
	for i := 0; i < 4; i++ {
		s.record(-1)
	}
	snap := s.snapshot()
	if snap.LossPct != 100 {
		t.Fatalf("lossPct = %d, want 100", snap.LossPct)
	}
	if snap.RttMs != -1 {
		t.Fatalf("rttMs = %v, want -1 with no successful samples", snap.RttMs)
	}
	if snap.LastReplyAgeSec != -1 {
		t.Fatalf("lastReplyAgeSec = %v, want -1 with no replies ever", snap.LastReplyAgeSec)
	}
}

func TestWindowTrimsToFixedSize(t *testing.T) {
	var s pathStats
	// Fill beyond the window with losses, then overwrite with successes.
	for i := 0; i < statsWindowSize; i++ {
		s.record(-1)
	}
	for i := 0; i < statsWindowSize; i++ {
		s.record(50)
	}
	snap := s.snapshot()
	if snap.Samples != statsWindowSize {
		t.Fatalf("samples = %d, want window size %d", snap.Samples, statsWindowSize)
	}
	if snap.LossPct != 0 {
		t.Fatalf("lossPct = %d, want 0 — old losses should have been trimmed", snap.LossPct)
	}
}

func TestRecordConcurrent(t *testing.T) {
	var s pathStats
	var wg sync.WaitGroup
	for g := 0; g < 8; g++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := 0; i < 200; i++ {
				s.record(float64(i % 7))
				s.snapshot()
			}
		}()
	}
	wg.Wait()
	if snap := s.snapshot(); snap.Samples != statsWindowSize {
		t.Fatalf("samples = %d, want %d", snap.Samples, statsWindowSize)
	}
}
