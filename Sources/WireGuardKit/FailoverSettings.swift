// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import Foundation

/// Configuration for connection failover behavior between tunnel configurations.
public struct FailoverSettings: Codable, Equatable {
    /// Seconds of transmitting data without receiving any before declaring the connection unhealthy.
    /// The monitor detects the pattern of tx_bytes increasing while rx_bytes stays stagnant,
    /// which indicates the tunnel endpoint is unreachable.
    public var trafficTimeout: TimeInterval

    /// How often (in seconds) to poll the WireGuard backend for traffic counters.
    public var healthCheckInterval: TimeInterval

    /// How often (in seconds) to probe higher-priority configurations when running on a fallback.
    public var failbackProbeInterval: TimeInterval

    /// Whether to automatically attempt to return to higher-priority configurations.
    public var autoFailback: Bool

    /// Whether to use background WireGuard probes for non-disruptive failback testing.
    /// When true, failback probes run a separate lightweight WireGuard device that performs
    /// a handshake without disrupting the active tunnel's traffic.
    /// When false, falls back to the legacy swap-wait-check-revert approach.
    public var useBackgroundProbes: Bool

    /// Whether to maintain a hot spare — a continuously running background probe for the
    /// next failover target. Provides pre-validated, near-instantaneous failover.
    public var hotSpare: Bool

    /// Optional override for persistent keepalive on all peers when tunnels are activated
    /// within this failover group. `nil` means no override (use whatever the tunnel has configured).
    /// A value of 0 means explicitly disable persistent keepalive.
    public var persistentKeepaliveOverride: UInt16?

    /// Whether to verify the underlying network before switching configs. When the network
    /// itself is captive or offline, every failover target is equally unreachable, so the
    /// monitor holds instead of cycling configs. See DESIGN-captive-portal-handling.md.
    public var captivePortalDetection: Bool

    /// Before switching, require the next configuration's server to complete a WireGuard
    /// handshake (via the hot spare, or a temporary probe). If no server can be reached the
    /// outage is treated as the local link's fault and failover is held back.
    public var confirmBeforeFailover: Bool

    /// How long a temporary confirmation probe may take to handshake before the outage is
    /// classified as a link problem.
    public var confirmationTimeout: TimeInterval

    /// Maximum time to hold failover while no server is reachable. After this the monitor
    /// switches anyway, in case only the current server is blocked on this network. 0 = never.
    public var linkDownHoldTime: TimeInterval

    /// Scale the traffic timeout up (×1.5 per false alarm, capped at ×4) after outages that
    /// turned out to be the link, decaying back after a quiet half hour.
    public var adaptiveSensitivity: Bool

    /// Ignore tx-without-rx for this long after a network path change (roaming blips).
    public var pathChangeGrace: TimeInterval

    public init(
        trafficTimeout: TimeInterval = 30,
        healthCheckInterval: TimeInterval = 10,
        failbackProbeInterval: TimeInterval = 300,
        autoFailback: Bool = true,
        useBackgroundProbes: Bool = true,
        hotSpare: Bool = false,
        persistentKeepaliveOverride: UInt16? = nil,
        captivePortalDetection: Bool = true,
        confirmBeforeFailover: Bool = true,
        confirmationTimeout: TimeInterval = 15,
        linkDownHoldTime: TimeInterval = 300,
        adaptiveSensitivity: Bool = true,
        pathChangeGrace: TimeInterval = 15
    ) {
        self.trafficTimeout = trafficTimeout
        self.healthCheckInterval = healthCheckInterval
        self.failbackProbeInterval = failbackProbeInterval
        self.autoFailback = autoFailback
        self.useBackgroundProbes = useBackgroundProbes
        self.hotSpare = hotSpare
        self.persistentKeepaliveOverride = persistentKeepaliveOverride
        self.captivePortalDetection = captivePortalDetection
        self.confirmBeforeFailover = confirmBeforeFailover
        self.confirmationTimeout = confirmationTimeout
        self.linkDownHoldTime = linkDownHoldTime
        self.adaptiveSensitivity = adaptiveSensitivity
        self.pathChangeGrace = pathChangeGrace
    }

    // MARK: - Migration from older settings

    private enum CodingKeys: String, CodingKey {
        case trafficTimeout
        case healthCheckInterval
        case failbackProbeInterval
        case autoFailback
        case useBackgroundProbes
        case hotSpare
        case persistentKeepaliveOverride
        case captivePortalDetection
        case confirmBeforeFailover
        case confirmationTimeout
        case linkDownHoldTime
        case adaptiveSensitivity
        case pathChangeGrace
        // Legacy key
        case handshakeTimeout
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Try trafficTimeout first, fall back to legacy handshakeTimeout
        if let timeout = try container.decodeIfPresent(TimeInterval.self, forKey: .trafficTimeout) {
            self.trafficTimeout = timeout
        } else if try container.decodeIfPresent(TimeInterval.self, forKey: .handshakeTimeout) != nil {
            // Legacy settings had much larger timeouts (e.g. 180s); use the new default instead
            self.trafficTimeout = 30
        } else {
            self.trafficTimeout = 30
        }
        self.healthCheckInterval = try container.decodeIfPresent(TimeInterval.self, forKey: .healthCheckInterval) ?? 10
        self.failbackProbeInterval = try container.decodeIfPresent(TimeInterval.self, forKey: .failbackProbeInterval) ?? 300
        self.autoFailback = try container.decodeIfPresent(Bool.self, forKey: .autoFailback) ?? true
        self.useBackgroundProbes = try container.decodeIfPresent(Bool.self, forKey: .useBackgroundProbes) ?? true
        self.hotSpare = try container.decodeIfPresent(Bool.self, forKey: .hotSpare) ?? false
        self.persistentKeepaliveOverride = try container.decodeIfPresent(UInt16.self, forKey: .persistentKeepaliveOverride)
        self.captivePortalDetection = try container.decodeIfPresent(Bool.self, forKey: .captivePortalDetection) ?? true
        self.confirmBeforeFailover = try container.decodeIfPresent(Bool.self, forKey: .confirmBeforeFailover) ?? true
        self.confirmationTimeout = try container.decodeIfPresent(TimeInterval.self, forKey: .confirmationTimeout) ?? 15
        self.linkDownHoldTime = try container.decodeIfPresent(TimeInterval.self, forKey: .linkDownHoldTime) ?? 300
        self.adaptiveSensitivity = try container.decodeIfPresent(Bool.self, forKey: .adaptiveSensitivity) ?? true
        self.pathChangeGrace = try container.decodeIfPresent(TimeInterval.self, forKey: .pathChangeGrace) ?? 15
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(trafficTimeout, forKey: .trafficTimeout)
        try container.encode(healthCheckInterval, forKey: .healthCheckInterval)
        try container.encode(failbackProbeInterval, forKey: .failbackProbeInterval)
        try container.encode(autoFailback, forKey: .autoFailback)
        try container.encode(useBackgroundProbes, forKey: .useBackgroundProbes)
        try container.encode(hotSpare, forKey: .hotSpare)
        try container.encodeIfPresent(persistentKeepaliveOverride, forKey: .persistentKeepaliveOverride)
        try container.encode(captivePortalDetection, forKey: .captivePortalDetection)
        try container.encode(confirmBeforeFailover, forKey: .confirmBeforeFailover)
        try container.encode(confirmationTimeout, forKey: .confirmationTimeout)
        try container.encode(linkDownHoldTime, forKey: .linkDownHoldTime)
        try container.encode(adaptiveSensitivity, forKey: .adaptiveSensitivity)
        try container.encode(pathChangeGrace, forKey: .pathChangeGrace)
    }
}
