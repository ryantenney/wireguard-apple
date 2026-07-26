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
	"time"

	"golang.org/x/sys/unix"
	"golang.zx2c4.com/wireguard/device"
	"golang.zx2c4.com/wireguard/tun"
)

// bumpSocketsRetry rebinds the device's UDP sockets after a network change,
// retrying for up to five seconds, then sends keepalives with the current
// keypair so the peer re-learns the new source address. Asynchronous.
// name prefixes log lines ("Tunnel", "Probe", "TiT").
func bumpSocketsRetry(dev *device.Device, logger *device.Logger, name string) {
	go func() {
		for i := 0; i < 10; i++ {
			err := dev.BindUpdate()
			if err == nil {
				dev.SendKeepalivesToPeersWithCurrentKeypair()
				return
			}
			logger.Errorf("%s: unable to update bind, try %d: %v", name, i+1, err)
			time.Sleep(time.Second / 2)
		}
		logger.Errorf("%s: gave up trying to update bind; tunnel is likely dysfunctional", name)
	}()
}

// ipcSetWithErrno applies a UAPI configuration and maps failures to the
// negative errno convention the exports return. name prefixes log lines.
func ipcSetWithErrno(dev *device.Device, logger *device.Logger, settings string, name string) int64 {
	err := dev.IpcSet(settings)
	if err == nil {
		return 0
	}
	logger.Errorf("%s: unable to set IPC settings: %v", name, err)
	if ipcErr, ok := err.(*device.IPCError); ok {
		return ipcErr.ErrorCode()
	}
	return -1
}

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
