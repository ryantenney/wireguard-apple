/* SPDX-License-Identifier: MIT
 *
 * Copyright (C) 2026 Ryan Tenney. All Rights Reserved.
 */

package main

import (
	"math"
	"sync"
)

// handleRegistry is a mutex-guarded map from int32 handles to values,
// allocating the lowest free non-negative handle. One registry exists per
// handle kind (tunnels, probes, TiT pairs, warm spare controllers); their
// handle namespaces overlap by design — handle 0 can simultaneously name a
// tunnel and a probe — and the Swift side keeps them in separate containers.
//
// Entry points are normally serialized by the Swift adapter's work queue;
// the internal lock protects map integrity against the exceptions
// (WireGuardAdapter.deinit runs on the deallocating thread). The lock is
// never held across blocking device calls — callers extract the value, then
// operate on it unlocked.
type handleRegistry[T any] struct {
	mu sync.Mutex
	m  map[int32]T
}

func newHandleRegistry[T any]() *handleRegistry[T] {
	return &handleRegistry[T]{m: make(map[int32]T)}
}

// alloc stores v under the lowest free handle and returns it. ok is false if
// the handle space is exhausted; the caller owns cleaning up v in that case.
func (r *handleRegistry[T]) alloc(v T) (handle int32, ok bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	var i int32
	for i = 0; i < math.MaxInt32; i++ {
		if _, exists := r.m[i]; !exists {
			r.m[i] = v
			return i, true
		}
	}
	return -1, false
}

// put stores v under a caller-chosen handle (used by the warm spare
// controller registry, which shares the tunnel handle namespace).
func (r *handleRegistry[T]) put(handle int32, v T) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.m[handle] = v
}

func (r *handleRegistry[T]) get(handle int32) (T, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	v, ok := r.m[handle]
	return v, ok
}

// remove deletes and returns the value, so the caller can tear it down
// outside the lock.
func (r *handleRegistry[T]) remove(handle int32) (T, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	v, ok := r.m[handle]
	if ok {
		delete(r.m, handle)
	}
	return v, ok
}
