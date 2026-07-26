// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import Foundation

/// Identifies the type of tunnel group (failover vs tunnel-in-tunnel).
enum TunnelGroupKind: String, CaseIterable {
    case failover
    case tunnelInTunnel

    var displayName: String {
        switch self {
        case .failover: return "Failover Group"
        case .tunnelInTunnel: return "Tunnel-in-Tunnel"
        }
    }

    var serverAddress: String {
        switch self {
        case .failover: return "Failover Group"
        case .tunnelInTunnel: return "Tunnel-in-Tunnel"
        }
    }

    var groupIdKey: String {
        switch self {
        case .failover: return ProviderConfigurationKeys.failoverGroupId
        case .tunnelInTunnel: return ProviderConfigurationKeys.titGroupId
        }
    }

    var ipcMessageType: UInt8 {
        switch self {
        case .failover: return 1
        case .tunnelInTunnel: return 4
        }
    }
}

// MARK: - Unified Group List Delegate

protocol TunnelsManagerGroupListDelegate: AnyObject {
    func groupAdded(kind: TunnelGroupKind, at index: Int)
    func groupModified(kind: TunnelGroupKind, at index: Int)
    func groupMoved(kind: TunnelGroupKind, from oldIndex: Int, to newIndex: Int)
    func groupRemoved(kind: TunnelGroupKind, at index: Int, tunnel: TunnelContainer)
}

// MARK: - Unified Edit Delegates

/// iOS edit delegate for group controllers.
protocol TunnelGroupEditDelegate: AnyObject {
    func groupSaved(_ tunnel: TunnelContainer)
    func groupDeleted(_ tunnel: TunnelContainer)
}

/// macOS edit delegate for group controllers.
protocol TunnelGroupEditViewControllerDelegate: AnyObject {
    func groupSaved(tunnel: TunnelContainer)
    func groupEditingCancelled()
}
