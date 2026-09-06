#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright © 2026 Ryan Tenney.
#
# Compile-checks as much of the Swift code as a Linux toolchain can reach.
#
#   1. `swiftc -parse` over every Swift file, once per platform (syntax only).
#   2. `swiftc -typecheck` over the platform-independent core: the tunnel
#      configuration model, the wg-quick parser, FailoverSettings, the failover
#      engine (ConnectionHealthMonitor) and UapiRuntimeSnapshot. Apple's
#      Network framework is replaced by the small stub next to this script and
#      the WireGuardKitC key helpers are imported through a bridging header.
#
# Anything that imports NetworkExtension, UIKit, AppKit, os.log or Security is
# out of reach here; the macOS CI workflow (.github/workflows/build.yml) builds
# the whole thing with Xcode.
#
# Usage: scripts/linux-swift/typecheck.sh            # parse + typecheck
#        scripts/linux-swift/typecheck.sh --parse     # parse only
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STUB_DIR="$REPO/scripts/linux-swift"
WORK="${TMPDIR:-/tmp}/wgnext-linux-swift"
mkdir -p "$WORK/mod" "$WORK/inc" "$WORK/cache"

if ! command -v swiftc >/dev/null 2>&1; then
    echo "swiftc not found. Run .claude/hooks/session-start.sh or install a Swift toolchain." >&2
    exit 2
fi

cd "$REPO"

parse_platform() {
    local platform="$1" exclude="$2"
    echo "==> parse ($platform)"
    find Sources -name '*.swift' -not -path "*/$exclude/*" -print0 \
        | xargs -0 swiftc -parse -module-cache-path "$WORK/cache"
}

parse_platform iOS macOS
parse_platform macOS iOS

if [ "${1:-}" = "--parse" ]; then
    echo "OK (parse only)"
    exit 0
fi

echo "==> build Network stub module"
swiftc -emit-module -parse-as-library -module-name Network \
    -module-cache-path "$WORK/cache" \
    -emit-module-path "$WORK/mod/Network.swiftmodule" \
    "$STUB_DIR/Network.swift"

# The headers are copied so clang does not pick up the module map that sits
# next to them in Sources/WireGuardKitC and import the module twice.
cp Sources/WireGuardKitC/key.h Sources/WireGuardKitC/x25519.h "$WORK/inc/"
printf '#include "key.h"\n#include "x25519.h"\n' > "$WORK/inc/bridge.h"

CORE_FILES=(
    Sources/WireGuardKit/IPAddressRange.swift
    Sources/WireGuardKit/Endpoint.swift
    Sources/WireGuardKit/DNSServer.swift
    Sources/WireGuardKit/PrivateKey.swift
    Sources/WireGuardKit/InterfaceConfiguration.swift
    Sources/WireGuardKit/PeerConfiguration.swift
    Sources/WireGuardKit/TunnelConfiguration.swift
    Sources/WireGuardKit/FailoverSettings.swift
    Sources/WireGuardKit/ConnectionHealthMonitor.swift
    Sources/WireGuardKit/UapiRuntimeSnapshot.swift
    Sources/Shared/Model/TunnelConfiguration+WgQuickConfig.swift
    Sources/Shared/Model/String+ArrayConversion.swift
)

echo "==> typecheck core (${#CORE_FILES[@]} files)"
swiftc -typecheck -parse-as-library \
    -module-cache-path "$WORK/cache" \
    -I "$WORK/mod" -I "$WORK/inc" \
    -import-objc-header "$WORK/inc/bridge.h" \
    "${CORE_FILES[@]}"

echo "OK"
