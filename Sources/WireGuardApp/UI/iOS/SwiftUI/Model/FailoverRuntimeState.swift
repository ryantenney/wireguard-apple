// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import Foundation

/// Typed view of the failover state dictionary returned by the network
/// extension (IPC message type 1, via `TunnelsManager.getFailoverState`).
struct FailoverRuntimeState {
    var activeConfig: String?
    var rxBytes: UInt64?
    var txBytes: UInt64?
    var lastHandshakeTime: Date?
    var consecutiveCycles: Int?
    var lastSwitchTime: Date?
    var txWithoutRxSince: Date?
    var isProbing: Bool
    var backgroundProbeActive: Bool
    var hotSpareActive: Bool
    var hotSpareConfigIndex: Int?
    var hotSpareHandshakeAge: TimeInterval?

    init?(dictionary: [String: Any]?) {
        guard let dict = dictionary else { return nil }
        activeConfig = dict["activeConfig"] as? String
        rxBytes = dict["rxBytes"] as? UInt64
        txBytes = dict["txBytes"] as? UInt64
        if let ts = dict["lastHandshakeTime"] as? Double, ts > 0 {
            lastHandshakeTime = Date(timeIntervalSince1970: ts)
        }
        consecutiveCycles = dict["consecutiveCycles"] as? Int
        if let ts = dict["lastSwitchTime"] as? Double, ts > 0 {
            lastSwitchTime = Date(timeIntervalSince1970: ts)
        }
        if let ts = dict["txWithoutRxSince"] as? Double, ts > 0 {
            txWithoutRxSince = Date(timeIntervalSince1970: ts)
        }
        isProbing = (dict["isProbing"] as? Bool) ?? false
        backgroundProbeActive = (dict["backgroundProbeActive"] as? Bool) ?? false
        hotSpareActive = (dict["hotSpareActive"] as? Bool) ?? false
        hotSpareConfigIndex = dict["hotSpareConfigIndex"] as? Int
        hotSpareHandshakeAge = dict["hotSpareHandshakeAge"] as? Double
    }

    var isHealthy: Bool { txWithoutRxSince == nil }

    // MARK: - Per-member health

    /// Health of a single group member, mirroring the classification in
    /// `FailoverGroupDetailTableViewController.connectionStatus(forTunnelAt:)`,
    /// with an explicit `.standby` for healthy non-active members.
    enum MemberHealth {
        case carrying
        case unhealthy
        case hotSpareReady
        case hotSpareWaiting
        case probing
        case standby
        case idle

        /// WireGuard rejects session reuse after REJECT_AFTER_TIME (180s).
        static let hotSpareFreshnessThreshold: TimeInterval = 180
    }

    func health(forMemberAt index: Int, name: String, groupIsActive: Bool) -> MemberHealth {
        guard groupIsActive else { return .standby }

        if let active = activeConfig, active == name {
            return isHealthy ? .carrying : .unhealthy
        }
        if let hotIndex = hotSpareConfigIndex, hotIndex == index {
            if let age = hotSpareHandshakeAge, age < MemberHealth.hotSpareFreshnessThreshold {
                return .hotSpareReady
            }
            return hotSpareActive ? .hotSpareWaiting : .standby
        }
        if index == 0 && isProbing {
            return .probing
        }
        return .standby
    }
}
