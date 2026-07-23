// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import Foundation

/// Configuration for warm spare cellular failover: keeping a pre-warmed UDP
/// socket on the cellular interface while Wi-Fi carries the tunnel, so that
/// losing Wi-Fi becomes a sub-second path flip instead of a teardown/reconnect
/// cycle. See `DESIGN-warm-spare-cellular-failover.md`.
///
/// Warm spare requires an always-connected tunnel (the provider process must
/// be running while on Wi-Fi for a warm socket to exist), i.e. on-demand
/// "Always On" (`NEOnDemandRuleConnect` for any interface) or a manually kept
/// connection. iOS only.
public struct WarmSpareSettings: Codable, Equatable {
    /// Master switch. When false, behavior is byte-identical to the regular
    /// tunnel start path (`wgTurnOn`).
    public var enabled: Bool

    /// When true (default), the cellular socket stays cold until Wi-Fi
    /// quality trends toward the switch thresholds, and returns to cold after
    /// a quiet period of healthy Wi-Fi. When false, keepalives run
    /// continuously whenever Wi-Fi carries the tunnel (higher battery cost).
    public var adaptiveWarming: Bool

    /// Seconds between NAT keepalives on the warm cellular socket. Must stay
    /// inside typical carrier UDP mapping timeouts (RFC 4787 REQ-5 floor is
    /// 30s; 30–120s common in practice).
    public var warmKeepaliveInterval: TimeInterval

    /// Server-side echo responder port. Must differ from the WireGuard port —
    /// any authenticated packet from the cellular socket to the WireGuard
    /// port would re-home the session prematurely. The responder listens on
    /// this port and the next one up (EIM self-test).
    public var probePort: UInt16

    /// Median default-path RTT (milliseconds) above which the controller
    /// proactively flips to cellular.
    public var switchRttMs: Int

    /// Default-path probe loss percentage above which the controller
    /// proactively flips to cellular.
    public var switchLossPct: Int

    /// Seconds of sustained healthy Wi-Fi required before flipping back from
    /// cellular. Hysteresis against flapping on marginal Wi-Fi.
    public var dwellSeconds: TimeInterval

    public init(
        enabled: Bool = false,
        adaptiveWarming: Bool = true,
        warmKeepaliveInterval: TimeInterval = 25,
        probePort: UInt16 = 51821,
        switchRttMs: Int = 300,
        switchLossPct: Int = 20,
        dwellSeconds: TimeInterval = 10
    ) {
        self.enabled = enabled
        self.adaptiveWarming = adaptiveWarming
        self.warmKeepaliveInterval = warmKeepaliveInterval
        self.probePort = probePort
        self.switchRttMs = switchRttMs
        self.switchLossPct = switchLossPct
        self.dwellSeconds = dwellSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case adaptiveWarming
        case warmKeepaliveInterval
        case probePort
        case switchRttMs
        case switchLossPct
        case dwellSeconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        self.adaptiveWarming = try container.decodeIfPresent(Bool.self, forKey: .adaptiveWarming) ?? true
        self.warmKeepaliveInterval = try container.decodeIfPresent(TimeInterval.self, forKey: .warmKeepaliveInterval) ?? 25
        self.probePort = try container.decodeIfPresent(UInt16.self, forKey: .probePort) ?? 51821
        self.switchRttMs = try container.decodeIfPresent(Int.self, forKey: .switchRttMs) ?? 300
        self.switchLossPct = try container.decodeIfPresent(Int.self, forKey: .switchLossPct) ?? 20
        self.dwellSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .dwellSeconds) ?? 10
    }
}
