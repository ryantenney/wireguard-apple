/* SPDX-License-Identifier: MIT
 *
 * Copyright (C) 2026 Ryan Tenney. All Rights Reserved.
 */

package main

import (
	"sync"
	"testing"
)

func TestRegistryAllocatesLowestFree(t *testing.T) {
	r := newHandleRegistry[string]()
	h0, ok := r.alloc("a")
	if !ok || h0 != 0 {
		t.Fatalf("first alloc = (%d, %v), want (0, true)", h0, ok)
	}
	h1, _ := r.alloc("b")
	if h1 != 1 {
		t.Fatalf("second alloc = %d, want 1", h1)
	}
	if _, ok := r.remove(h0); !ok {
		t.Fatal("remove of live handle failed")
	}
	h2, _ := r.alloc("c")
	if h2 != 0 {
		t.Fatalf("alloc after freeing 0 = %d, want reuse of 0", h2)
	}
}

func TestRegistryGetAndRemove(t *testing.T) {
	r := newHandleRegistry[int]()
	h, _ := r.alloc(42)
	if v, ok := r.get(h); !ok || v != 42 {
		t.Fatalf("get = (%d, %v), want (42, true)", v, ok)
	}
	if v, ok := r.remove(h); !ok || v != 42 {
		t.Fatalf("remove = (%d, %v), want (42, true)", v, ok)
	}
	if _, ok := r.get(h); ok {
		t.Fatal("get succeeded after remove")
	}
	if _, ok := r.remove(h); ok {
		t.Fatal("second remove succeeded")
	}
}

func TestRegistryPutSharesNamespace(t *testing.T) {
	r := newHandleRegistry[string]()
	r.put(7, "ctrl")
	if v, ok := r.get(7); !ok || v != "ctrl" {
		t.Fatalf("get(7) = (%q, %v), want (ctrl, true)", v, ok)
	}
	// put overwrites.
	r.put(7, "ctrl2")
	if v, _ := r.get(7); v != "ctrl2" {
		t.Fatalf("get(7) after overwrite = %q, want ctrl2", v)
	}
}

func TestRegistryConcurrentAllocRemove(t *testing.T) {
	r := newHandleRegistry[int]()
	var wg sync.WaitGroup
	for g := 0; g < 8; g++ {
		wg.Add(1)
		go func(g int) {
			defer wg.Done()
			for i := 0; i < 500; i++ {
				h, ok := r.alloc(g)
				if !ok {
					t.Error("alloc failed")
					return
				}
				if v, ok := r.get(h); !ok || v != g {
					t.Errorf("get(%d) = (%d, %v), want (%d, true)", h, v, ok, g)
					return
				}
				if _, ok := r.remove(h); !ok {
					t.Errorf("remove(%d) failed", h)
					return
				}
			}
		}(g)
	}
	wg.Wait()
	// All handles released: next alloc must be 0.
	if h, _ := r.alloc(99); h != 0 {
		t.Fatalf("alloc after drain = %d, want 0", h)
	}
}
