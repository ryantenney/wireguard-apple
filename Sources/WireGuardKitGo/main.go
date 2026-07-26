/* SPDX-License-Identifier: MIT
 *
 * Copyright (C) 2018-2019 Jason A. Donenfeld <Jason@zx2c4.com>. All Rights Reserved.
 */

// Package main is the WireGuard Go bridge for Apple platforms, built as a
// c-archive and driven entirely through the //export functions declared in
// wireguard.h. The main function is never run.
//
// File layout: cgo export files are tagged //go:build darwin; OS-independent
// logic (stats.go, probeproto.go) is untagged so `go vet` and `go test` run
// natively on any development host.
package main

func main() {}
