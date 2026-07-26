//go:build darwin

/* SPDX-License-Identifier: MIT
 *
 * Copyright (C) 2026 Ryan Tenney. All Rights Reserved.
 */

package main

// #include <stdlib.h>
import "C"

// ========== Warm Spare Cellular Failover Exports ==========
//
// See warmspare.go for the mechanism (dualPathBind, warmSpareController) and
// DESIGN-warm-spare-cellular-failover.md for the design.

// Controllers for warm-spare tunnels, keyed by the same handle used in
// tunnelHandles (a warm tunnel is a regular tunnel handle plus a controller,
// so wgSetConfig / wgGetConfig / wgBumpSockets / wgTurnOff all keep working).
var warmSpareControllers = newHandleRegistry[*warmSpareController]()

// wgTurnOnWarm starts a tunnel whose bind supports a warm cellular spare.
// probeAddr must be the resolved IP of the active peer endpoint (so probe
// traffic shares the server's automatic routing exception); probePort is the
// server-side echo responder port and must differ from the WireGuard port.
//
//export wgTurnOnWarm
func wgTurnOnWarm(settings *C.char, probeAddr *C.char, probePort int32, keepaliveInterval int32, tunFd int32) int32 {
	logger := newAppleLogger()
	dev, ctrl, err := newWarmTunnel(C.GoString(settings), C.GoString(probeAddr), int(probePort), int(keepaliveInterval), tunFd, logger)
	if err != nil {
		logger.Errorf("Warm spare: %v", err)
		return -1
	}

	i, ok := tunnelHandles.alloc(tunnelHandle{dev, logger})
	if !ok {
		ctrl.stop()
		dev.Close()
		return -1
	}
	warmSpareControllers.put(i, ctrl)
	return i
}

// wgWarmSetCellular opens (or re-homes) the cellular sockets bound to the
// given interface index and starts NAT keepalives. Returns 0 on success.
//
//export wgWarmSetCellular
func wgWarmSetCellular(tunnelHandle int32, ifindex int32) int32 {
	ctrl, ok := warmSpareControllers.get(tunnelHandle)
	if !ok {
		return -1
	}
	if err := ctrl.warmCellular(int(ifindex)); err != nil {
		ctrl.logger.Errorf("Warm spare: warm failed: %v", err)
		return -1
	}
	return 0
}

// wgWarmClearCellular closes the cellular sockets and stops keepalives (cold).
//
//export wgWarmClearCellular
func wgWarmClearCellular(tunnelHandle int32) {
	ctrl, ok := warmSpareControllers.get(tunnelHandle)
	if !ok {
		return
	}
	ctrl.clearCellular()
}

// wgWarmSetActivePath flips which socket carries WireGuard traffic
// (0 = primary/default path, 1 = cellular) and sends an immediate keepalive
// out the new path so the server re-homes the session. Returns 0 on success.
//
//export wgWarmSetActivePath
func wgWarmSetActivePath(tunnelHandle int32, path int32) int32 {
	ctrl, ok := warmSpareControllers.get(tunnelHandle)
	if !ok {
		return -1
	}
	if path != warmPathPrimary && path != warmPathCellular {
		return -1
	}
	ctrl.setActivePath(path)
	return 0
}

// wgWarmSetPrimaryProbing enables (1) or disables (0) default-path quality
// probes. The path controller disables them while Wi-Fi is not the default
// path — they only inform decisions on Wi-Fi, and probing over cellular
// wastes radio wakes.
//
//export wgWarmSetPrimaryProbing
func wgWarmSetPrimaryProbing(tunnelHandle int32, enabled int32) {
	ctrl, ok := warmSpareControllers.get(tunnelHandle)
	if !ok {
		return
	}
	ctrl.setPrimaryProbing(enabled != 0)
}

// wgWarmGetState returns a JSON snapshot of warm spare state: active path,
// warm/cold, per-path RTT/loss, and the latest EIM self-test result.
//
//export wgWarmGetState
func wgWarmGetState(tunnelHandle int32) *C.char {
	ctrl, ok := warmSpareControllers.get(tunnelHandle)
	if !ok {
		return nil
	}
	return C.CString(ctrl.stateJSON())
}

// wgWarmStartEimTest kicks off the endpoint-independent-mapping self-test on
// the (warm) cellular socket. Asynchronous; the verdict lands in
// wgWarmGetState within ~5 seconds. Returns 0 if the test was started.
//
//export wgWarmStartEimTest
func wgWarmStartEimTest(tunnelHandle int32) int32 {
	ctrl, ok := warmSpareControllers.get(tunnelHandle)
	if !ok {
		return -1
	}
	if err := ctrl.startEimTest(); err != nil {
		ctrl.logger.Verbosef("Warm spare: EIM test not started: %v", err)
		return -1
	}
	return 0
}
