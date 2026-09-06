// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import Foundation
import NetworkExtension

enum ActivationReason: String, Codable {
    case manual
    case onDemand
    case unknown
}

enum DeactivationReason: String, Codable {
    case userInitiated
    case providerFailed
    case noNetworkAvailable
    case unrecoverableNetworkChange
    case providerDisabled
    case authenticationCanceled
    case configurationFailed
    case idleTimeout
    case configurationDisabled
    case configurationRemoved
    case superceded
    case userLogout
    case userSwitch
    case connectionFailed
    case sleep
    case appUpdate
    case internalError
    case endedUnexpectedly

    init(from reason: NEProviderStopReason) {
        switch reason {
        case .none: self = .internalError
        case .userInitiated: self = .userInitiated
        case .providerFailed: self = .providerFailed
        case .noNetworkAvailable: self = .noNetworkAvailable
        case .unrecoverableNetworkChange: self = .unrecoverableNetworkChange
        case .providerDisabled: self = .providerDisabled
        case .authenticationCanceled: self = .authenticationCanceled
        case .configurationFailed: self = .configurationFailed
        case .idleTimeout: self = .idleTimeout
        case .configurationDisabled: self = .configurationDisabled
        case .configurationRemoved: self = .configurationRemoved
        case .superceded: self = .superceded
        case .userLogout: self = .userLogout
        case .userSwitch: self = .userSwitch
        case .connectionFailed: self = .connectionFailed
        case .sleep: self = .sleep
        case .appUpdate: self = .appUpdate
        case .internalError: self = .internalError
        @unknown default: self = .internalError
        }
    }
}

struct FailoverEvent: Codable {
    enum Kind: String, Codable {
        case switched
        case failedBack
        case unhealthy
        /// Failover was warranted by traffic but held back because no server could be reached
        /// (the underlying link is down, not the VPN server).
        case suppressed
        /// The group's configuration was reloaded in place after an edit.
        case configReloaded
    }

    var kind: Kind
    var timestamp: Date
    var fromConfigName: String?
    var toConfigName: String?
    /// Only populated for `.unhealthy` events.
    var txWithoutRxDuration: TimeInterval?
}

struct SessionRecord: Codable, Identifiable {
    var id: UUID
    var tunnelName: String
    var startedAt: Date
    var endedAt: Date?
    var rxBytes: UInt64
    var txBytes: UInt64
    var activationReason: ActivationReason
    var deactivationReason: DeactivationReason?
    var failoverEvents: [FailoverEvent]
    /// Initial active config name when the session started (failover group / TiT group).
    var initialActiveConfigName: String?

    var duration: TimeInterval {
        (endedAt ?? Date()).timeIntervalSince(startedAt)
    }

    enum CodingKeys: String, CodingKey {
        case id, tunnelName, startedAt, endedAt, rxBytes, txBytes
        case activationReason, deactivationReason, failoverEvents, initialActiveConfigName
    }

    init(id: UUID = UUID(), tunnelName: String, startedAt: Date, endedAt: Date? = nil,
         rxBytes: UInt64 = 0, txBytes: UInt64 = 0,
         activationReason: ActivationReason, deactivationReason: DeactivationReason? = nil,
         failoverEvents: [FailoverEvent] = [], initialActiveConfigName: String? = nil) {
        self.id = id
        self.tunnelName = tunnelName
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.rxBytes = rxBytes
        self.txBytes = txBytes
        self.activationReason = activationReason
        self.deactivationReason = deactivationReason
        self.failoverEvents = failoverEvents
        self.initialActiveConfigName = initialActiveConfigName
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        tunnelName = try c.decode(String.self, forKey: .tunnelName)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        rxBytes = try c.decodeIfPresent(UInt64.self, forKey: .rxBytes) ?? 0
        txBytes = try c.decodeIfPresent(UInt64.self, forKey: .txBytes) ?? 0
        activationReason = try c.decodeIfPresent(ActivationReason.self, forKey: .activationReason) ?? .unknown
        deactivationReason = try c.decodeIfPresent(DeactivationReason.self, forKey: .deactivationReason)
        failoverEvents = try c.decodeIfPresent([FailoverEvent].self, forKey: .failoverEvents) ?? []
        initialActiveConfigName = try c.decodeIfPresent(String.self, forKey: .initialActiveConfigName)
    }
}
