// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

#if os(iOS)

import Foundation
import WidgetKit

/// Maps the tunnel list's aggregate status to the shared `VPNStatusData`
/// the widget reads, and pokes WidgetKit to reload. Extracted from
/// TunnelsManager, which calls `update(tunnels:)` on every status change.
final class WidgetStatusWriter {

    /// Stable connection timestamp, set once when a tunnel transitions to
    /// active and cleared on any other aggregate state.
    private var connectedAt: Date?

    func update(tunnels: [TunnelContainer]) {
        if let activeTunnel = tunnels.first(where: { $0.status == .active }) {
            // Only set connectedAt once when transitioning to active
            if connectedAt == nil {
                connectedAt = Date()
            }
            let status = VPNStatusData(
                state: .connected,
                tunnelName: activeTunnel.name,
                connectedAt: connectedAt,
                isOnDemandEnabled: activeTunnel.isActivateOnDemandEnabled,
                hasOnDemandRules: activeTunnel.hasOnDemandRules
            )
            VPNStatusData.save(status)
        } else if let activatingTunnel = tunnels.first(where: { $0.status == .activating || $0.status == .waiting || $0.status == .reasserting || $0.status == .restarting }) {
            connectedAt = nil
            let status = VPNStatusData(
                state: .connecting,
                tunnelName: activatingTunnel.name,
                connectedAt: nil,
                isOnDemandEnabled: activatingTunnel.isActivateOnDemandEnabled,
                hasOnDemandRules: activatingTunnel.hasOnDemandRules
            )
            VPNStatusData.save(status)
        } else if let deactivatingTunnel = tunnels.first(where: { $0.status == .deactivating }) {
            connectedAt = nil
            let status = VPNStatusData(
                state: .disconnecting,
                tunnelName: deactivatingTunnel.name,
                connectedAt: nil
            )
            VPNStatusData.save(status)
        } else {
            connectedAt = nil
            // When disconnected, report on-demand status from any configured tunnel
            let onDemandTunnel = tunnels.first(where: { $0.hasOnDemandRules })
            let status = VPNStatusData(
                state: .disconnected,
                tunnelName: "",
                connectedAt: nil,
                isOnDemandEnabled: onDemandTunnel?.isActivateOnDemandEnabled,
                hasOnDemandRules: onDemandTunnel != nil
            )
            VPNStatusData.save(status)
        }
        if #available(iOS 14.0, *) {
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}

#endif
