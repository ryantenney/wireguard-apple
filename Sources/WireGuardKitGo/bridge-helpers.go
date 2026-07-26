//go:build darwin

/* SPDX-License-Identifier: MIT
 *
 * Copyright (C) 2026 Ryan Tenney. All Rights Reserved.
 */

package main

// Shared helpers for the cgo export files. Non-cgo so they are vetted under
// GOOS=darwin CGO_ENABLED=0 (the export files themselves cannot be).

import (
	"fmt"
	"os"

	"golang.org/x/sys/unix"
	"golang.zx2c4.com/wireguard/tun"
)

// dupTUNFile duplicates the packet tunnel provider's utun fd, marks it
// non-blocking, and wraps it in a tun.Device. Nothing is leaked on error.
func dupTUNFile(tunFd int32) (tun.Device, error) {
	dupTunFd, err := unix.Dup(int(tunFd))
	if err != nil {
		return nil, fmt.Errorf("unable to dup tun fd: %w", err)
	}
	if err := unix.SetNonblock(dupTunFd, true); err != nil {
		unix.Close(dupTunFd)
		return nil, fmt.Errorf("unable to set tun fd as non blocking: %w", err)
	}
	tunDev, err := tun.CreateTUNFromFile(os.NewFile(uintptr(dupTunFd), "/dev/tun"), 0)
	if err != nil {
		// CreateTUNFromFile closes the file on all of its error paths; closing
		// dupTunFd again could destroy an unrelated descriptor that reused it.
		return nil, fmt.Errorf("unable to create new tun device from fd: %w", err)
	}
	return tunDev, nil
}
