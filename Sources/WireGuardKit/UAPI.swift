// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import Foundation

/// Parsers for wireguard-go's UAPI runtime-configuration format (key=value,
/// newline-delimited). Pure string processing with no failover dependency —
/// used by the health monitor, the provider's stats writers, and the IPC
/// handlers alike.
public enum UAPI {

    /// Total tx_bytes and rx_bytes summed across all peers.
    public static func parseTxRxBytes(from uapiConfig: String) -> (tx: UInt64, rx: UInt64) {
        var totalTx: UInt64 = 0
        var totalRx: UInt64 = 0

        for line in uapiConfig.split(separator: "\n") {
            if line.hasPrefix("tx_bytes=") {
                let value = line.dropFirst("tx_bytes=".count)
                if let bytes = UInt64(value) {
                    totalTx += bytes
                }
            } else if line.hasPrefix("rx_bytes=") {
                let value = line.dropFirst("rx_bytes=".count)
                if let bytes = UInt64(value) {
                    totalRx += bytes
                }
            }
        }

        return (totalTx, totalRx)
    }

    /// Age of the most recent handshake across all peers, in seconds.
    /// Returns `.infinity` if no handshake has ever occurred.
    public static func parseLastHandshakeAge(from uapiConfig: String) -> TimeInterval {
        var latestHandshakeTimestamp: TimeInterval = 0

        for line in uapiConfig.split(separator: "\n") {
            if line.hasPrefix("last_handshake_time_sec=") {
                let value = line.dropFirst("last_handshake_time_sec=".count)
                if let timestamp = TimeInterval(value), timestamp > latestHandshakeTimestamp {
                    latestHandshakeTimestamp = timestamp
                }
            }
        }

        if latestHandshakeTimestamp > 0 {
            return Date().timeIntervalSince1970 - latestHandshakeTimestamp
        }
        return .infinity
    }

    /// Strip private_key / preshared_key values from a UAPI dump for safe logging.
    public static func redactSecrets(from uapiConfig: String) -> String {
        return uapiConfig.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            if line.hasPrefix("private_key=") { return "private_key=<redacted>" }
            if line.hasPrefix("preshared_key=") { return "preshared_key=<redacted>" }
            return String(line)
        }.joined(separator: "\n")
    }
}
