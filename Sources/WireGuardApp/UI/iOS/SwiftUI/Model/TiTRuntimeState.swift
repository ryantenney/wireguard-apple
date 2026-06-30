// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import Foundation

/// Typed view of the tunnel-in-tunnel state dictionary returned by the network
/// extension (IPC message type 4, via `TunnelsManager.getTiTState`). The "outer"
/// layer is the carrier (reached over the physical network); the "inner" layer
/// is the exit (reached inside the outer tunnel).
struct TiTRuntimeState {
    struct LayerStats {
        var rxBytes: UInt64?
        var txBytes: UInt64?
        var lastHandshakeTime: Date?

        var hasTraffic: Bool { (rxBytes ?? 0) > 0 || (txBytes ?? 0) > 0 }
    }

    var outer: LayerStats
    var inner: LayerStats

    init?(dictionary: [String: Any]?) {
        guard let dict = dictionary else { return nil }
        outer = TiTRuntimeState.layer(prefix: "outer", from: dict)
        inner = TiTRuntimeState.layer(prefix: "inner", from: dict)
    }

    private static func layer(prefix: String, from dict: [String: Any]) -> LayerStats {
        var stats = LayerStats()
        stats.rxBytes = dict["\(prefix)RxBytes"] as? UInt64
        stats.txBytes = dict["\(prefix)TxBytes"] as? UInt64
        if let ts = dict["\(prefix)LastHandshakeTime"] as? Double, ts > 0 {
            stats.lastHandshakeTime = Date(timeIntervalSince1970: ts)
        }
        return stats
    }
}
