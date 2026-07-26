// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import Foundation

/// IPC message types exchanged with the network extension via
/// `NETunnelProviderSession.sendProviderMessage`. Byte 0 of every message is
/// the raw value; `.debugForceWarmSparePath` carries a payload byte. This
/// file is compiled into both the app and the extension — the single source
/// of truth for the wire values (previously magic numbers spelled at both
/// ends).
enum ProviderMessage: UInt8 {
    /// Active tunnel's UAPI runtime configuration. Response: UTF-8 string.
    case runtimeConfiguration = 0

    /// Failover group state + runtime stats. Response: JSON object.
    case failoverState = 1

    /// Debug (`FAILOVER_TESTING`): force failover to the next config.
    case debugForceFailover = 2

    /// Debug (`FAILOVER_TESTING`): force failback to the primary config.
    case debugForceFailback = 3

    /// TiT inner + outer runtime stats. Response: JSON object.
    case titState = 4

    /// Everything the connection details view needs. Response: JSON object.
    case connectionDiagnostics = 5

    /// Reload a running group's configuration in place. Bytes 1... are a JSON
    /// payload. Response: `{"success": Bool}`.
    case groupReload = 6

    /// Warm spare status (Go bridge stats + path controller state).
    /// Response: JSON object.
    case warmSpareStatus = 7

    /// Start the warm spare EIM self-test. Response: `{"started": Bool}`.
    case warmSpareRunEimTest = 8

    /// Debug (`FAILOVER_TESTING`): force the warm spare active path.
    /// Byte 1 is a `WarmSparePathOverride` raw value.
    case debugForceWarmSparePath = 9

    /// The message as sent over IPC (no payload).
    var data: Data {
        return Data([rawValue])
    }
}

/// Payload byte for `ProviderMessage.debugForceWarmSparePath`.
enum WarmSparePathOverride: UInt8 {
    case primary = 0
    case cellular = 1
    case automatic = 2

    /// The full two-byte message for this override.
    var message: Data {
        return Data([ProviderMessage.debugForceWarmSparePath.rawValue, rawValue])
    }
}
