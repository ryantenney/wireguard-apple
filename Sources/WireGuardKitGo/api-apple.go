//go:build darwin

/* SPDX-License-Identifier: MIT
 *
 * Copyright (C) 2018-2019 Jason A. Donenfeld <Jason@zx2c4.com>. All Rights Reserved.
 */

package main

// #include <stdlib.h>
// #include <sys/types.h>
// static void callLogger(void *func, void *ctx, int level, const char *msg)
// {
// 	((void(*)(void *, int, const char *))func)(ctx, level, msg);
// }
import "C"

import (
	"fmt"
	"os"
	"os/signal"
	"runtime"
	"runtime/debug"
	"strings"
	"sync/atomic"
	"unsafe"

	"golang.org/x/sys/unix"
	"golang.zx2c4.com/wireguard/conn"
	"golang.zx2c4.com/wireguard/device"
)

// loggerState bundles the Swift log callback and its context so both are
// published in one atomic store: wgSetLogger is called from Swift threads
// (including wgSetLogger(nil, nil) during adapter teardown) while every
// wireguard-go and warm-spare goroutine reads them through CLogger.Printf.
type loggerState struct {
	fn  unsafe.Pointer
	ctx unsafe.Pointer
}

var loggerHandle atomic.Pointer[loggerState]

type CLogger int

func cstring(s string) *C.char {
	b, err := unix.BytePtrFromString(s)
	if err != nil {
		b := [1]C.char{}
		return &b[0]
	}
	return (*C.char)(unsafe.Pointer(b))
}

func (l CLogger) Printf(format string, args ...interface{}) {
	state := loggerHandle.Load()
	if state == nil || uintptr(state.fn) == 0 {
		return
	}
	C.callLogger(state.fn, state.ctx, C.int(l), cstring(fmt.Sprintf(format, args...)))
}

// ipcGetCString returns the device's UAPI runtime configuration as a newly
// allocated C string (freed by the Swift caller), or nil on error.
func ipcGetCString(dev *device.Device) *C.char {
	settings, err := dev.IpcGet()
	if err != nil {
		return nil
	}
	return C.CString(settings)
}

// newAppleLogger returns a device.Logger routed through the Swift log
// callback registered via wgSetLogger.
func newAppleLogger() *device.Logger {
	return &device.Logger{
		Verbosef: CLogger(0).Printf,
		Errorf:   CLogger(1).Printf,
	}
}

type tunnelHandle struct {
	*device.Device
	*device.Logger
}

var tunnelHandles = newHandleRegistry[tunnelHandle]()

func init() {
	signals := make(chan os.Signal)
	signal.Notify(signals, unix.SIGUSR2)
	go func() {
		buf := make([]byte, os.Getpagesize())
		for {
			select {
			case <-signals:
				n := runtime.Stack(buf, true)
				buf[n] = 0
				if state := loggerHandle.Load(); state != nil && uintptr(state.fn) != 0 {
					C.callLogger(state.fn, state.ctx, 0, (*C.char)(unsafe.Pointer(&buf[0])))
				}
			}
		}
	}()
}

//export wgSetLogger
func wgSetLogger(context, loggerFn uintptr) {
	loggerHandle.Store(&loggerState{
		fn:  unsafe.Pointer(loggerFn),
		ctx: unsafe.Pointer(context),
	})
}

//export wgTurnOn
func wgTurnOn(settings *C.char, tunFd int32) int32 {
	logger := newAppleLogger()
	tunDev, err := dupTUNFile(tunFd)
	if err != nil {
		logger.Errorf("%v", err)
		return -1
	}
	logger.Verbosef("Attaching to interface")
	dev := device.NewDevice(tunDev, conn.NewStdNetBind(), logger)

	err = dev.IpcSet(C.GoString(settings))
	if err != nil {
		logger.Errorf("Unable to set IPC settings: %v", err)
		// The tun (and its fd) now belong to the device; close it as a whole.
		dev.Close()
		return -1
	}

	dev.Up()
	logger.Verbosef("Device started")

	i, ok := tunnelHandles.alloc(tunnelHandle{dev, logger})
	if !ok {
		dev.Close()
		return -1
	}
	return i
}

//export wgTurnOff
func wgTurnOff(tunnelHandle int32) {
	dev, ok := tunnelHandles.remove(tunnelHandle)
	if !ok {
		return
	}
	if ctrl, ok := warmSpareControllers.remove(tunnelHandle); ok {
		ctrl.stop()
	}
	dev.Close()
}

//export wgSetConfig
func wgSetConfig(tunnelHandle int32, settings *C.char) int64 {
	dev, ok := tunnelHandles.get(tunnelHandle)
	if !ok {
		return -1
	}
	return ipcSetWithErrno(dev.Device, dev.Logger, C.GoString(settings), "Tunnel")
}

//export wgGetConfig
func wgGetConfig(tunnelHandle int32) *C.char {
	device, ok := tunnelHandles.get(tunnelHandle)
	if !ok {
		return nil
	}
	return ipcGetCString(device.Device)
}

//export wgBumpSockets
func wgBumpSockets(tunnelHandle int32) {
	dev, ok := tunnelHandles.get(tunnelHandle)
	if !ok {
		return
	}
	bumpSocketsRetry(dev.Device, dev.Logger, "Tunnel")
}

//export wgDisableSomeRoamingForBrokenMobileSemantics
func wgDisableSomeRoamingForBrokenMobileSemantics(tunnelHandle int32) {
	dev, ok := tunnelHandles.get(tunnelHandle)
	if !ok {
		return
	}
	dev.DisableSomeRoamingForBrokenMobileSemantics()
}

//export wgVersion
func wgVersion() *C.char {
	info, ok := debug.ReadBuildInfo()
	if !ok {
		return C.CString("unknown")
	}
	for _, dep := range info.Deps {
		if dep.Path == "golang.zx2c4.com/wireguard" {
			parts := strings.Split(dep.Version, "-")
			if len(parts) == 3 && len(parts[2]) == 12 {
				return C.CString(parts[2][:7])
			}
			return C.CString(dep.Version)
		}
	}
	return C.CString("unknown")
}
