// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import Foundation
import Combine
import NetworkExtension

/// The SwiftUI source of truth. Wraps `TunnelsManager`, becomes its list and
/// group delegates, exposes observable node arrays, drives runtime-stats
/// polling, and provides intent methods that call through to the manager.
final class TunnelStore: ObservableObject {
    let manager: TunnelsManager

    @Published private(set) var tunnels: [TunnelNode] = []
    @Published private(set) var failoverGroups: [TunnelNode] = []
    @Published private(set) var titGroups: [TunnelNode] = []

    private(set) var nodesByID: [ObjectIdentifier: TunnelNode] = [:]
    private var nodeForwarders: [ObjectIdentifier: AnyCancellable] = [:]
    private var polledNodeIDs: Set<ObjectIdentifier> = []
    private var homePolling = false
    private var pollTimer: Timer?

    init(manager: TunnelsManager) {
        self.manager = manager
        manager.tunnelsListDelegate = self
        manager.groupListDelegate = self
        rebuild()
    }

    deinit {
        pollTimer?.invalidate()
    }

    // MARK: - Derived presentation helpers

    var allNodes: [TunnelNode] { failoverGroups + titGroups + tunnels }

    /// Whether the app currently has any non-inactive tunnel/group.
    var hasActiveConnection: Bool { allNodes.contains { $0.status != .inactive } }

    /// The failover group that should headline the Home screen: the busy one,
    /// otherwise the first configured group.
    var primaryFailoverGroup: TunnelNode? {
        failoverGroups.first { $0.status != .inactive } ?? failoverGroups.first
    }

    /// A plain tunnel the user activated manually (the manual-override case).
    var activePlainTunnel: TunnelNode? {
        tunnels.first { $0.status != .inactive }
    }

    var isEmpty: Bool {
        tunnels.isEmpty && failoverGroups.isEmpty && titGroups.isEmpty
    }

    // MARK: - Intents

    /// Activate or deactivate, honoring on-demand the same way the legacy list
    /// did (see `TunnelsListTableViewController.cellForRowAt`).
    func setActive(_ shouldBeActive: Bool, node: TunnelNode) {
        let tunnel = node.container
        if node.hasOnDemandRules {
            manager.setOnDemandEnabled(shouldBeActive, on: tunnel) { [weak self] error in
                if error == nil && !shouldBeActive {
                    self?.manager.startDeactivation(of: tunnel)
                }
            }
        } else if shouldBeActive {
            manager.startActivation(of: tunnel)
        } else {
            manager.startDeactivation(of: tunnel)
        }
    }

    func toggle(_ node: TunnelNode) {
        setActive(!node.switchIsOn, node: node)
    }

    /// Resume an active-on-demand failover group after a manual override.
    func resumeFailoverGroup(_ node: TunnelNode) {
        setActive(true, node: node)
    }

    func remove(_ node: TunnelNode, completion: @escaping (TunnelsManagerError?) -> Void) {
        if node.isFailoverGroup {
            manager.removeFailoverGroup(tunnel: node.container, completionHandler: completion)
        } else if node.isTiTGroup {
            manager.removeTiTGroup(tunnel: node.container, completionHandler: completion)
        } else {
            manager.remove(tunnel: node.container, completionHandler: completion)
        }
    }

    func refreshStatuses() {
        manager.refreshStatuses()
    }

    /// Persist updated failover settings for a group in place, preserving its
    /// member configs and on-demand rules. Takes effect on the group's next
    /// activation.
    func updateFailoverSettings(_ settings: FailoverSettings, for node: TunnelNode) {
        guard node.isFailoverGroup,
              let proto = node.container.tunnelProvider.protocolConfiguration as? NETunnelProviderProtocol,
              var providerConfiguration = proto.providerConfiguration,
              let data = try? JSONEncoder().encode(settings) else { return }
        providerConfiguration["FailoverSettings"] = data
        proto.providerConfiguration = providerConfiguration
        node.container.tunnelProvider.saveToPreferences { error in
            if let error = error {
                wg_log(.error, message: "Failed to save failover settings: \(error)")
            }
        }
        objectWillChange.send()
    }

    func allTunnelNames() -> [String] {
        manager.mapTunnels { $0.name }
    }

    func node(named name: String) -> TunnelNode? {
        allNodes.first { $0.name == name }
    }

    // MARK: - Polling

    /// Begin polling runtime stats for a node while a screen showing it is visible.
    func startPolling(_ node: TunnelNode) {
        polledNodeIDs.insert(node.id)
        pollOnce(node)
        ensureTimerRunning()
    }

    func stopPolling(_ node: TunnelNode) {
        polledNodeIDs.remove(node.id)
        stopTimerIfIdle()
    }

    /// While the Home screen is visible, poll every active node so the hero and
    /// member cards stay live regardless of which one the user just toggled.
    func beginHomePolling() {
        homePolling = true
        ensureTimerRunning()
        tick()
    }

    func endHomePolling() {
        homePolling = false
        stopTimerIfIdle()
    }

    private func stopTimerIfIdle() {
        if !homePolling && polledNodeIDs.isEmpty {
            pollTimer?.invalidate()
            pollTimer = nil
        }
    }

    private func ensureTimerRunning() {
        guard pollTimer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func tick() {
        var seen = Set<ObjectIdentifier>()
        if homePolling {
            for node in allNodes where node.status == .active {
                if seen.insert(node.id).inserted { pollOnce(node) }
            }
        }
        for id in polledNodeIDs {
            guard let node = nodesByID[id], seen.insert(id).inserted else { continue }
            pollOnce(node)
        }
    }

    private func pollOnce(_ node: TunnelNode) {
        guard node.status == .active else { return }
        if node.isFailoverGroup {
            node.refreshFailoverState(using: manager)
        } else if node.isPlainTunnel {
            node.refreshRuntimeConfiguration()
        }
    }

    // MARK: - Node graph maintenance

    private func rebuild() {
        tunnels = manager.tunnels.map { node(for: $0) }
        failoverGroups = manager.failoverGroupTunnels.map { node(for: $0) }
        titGroups = manager.titGroupTunnels.map { node(for: $0) }

        let liveIDs = Set((manager.tunnels + manager.failoverGroupTunnels + manager.titGroupTunnels)
            .map { ObjectIdentifier($0) })
        for key in nodesByID.keys where !liveIDs.contains(key) {
            nodesByID[key] = nil
            nodeForwarders[key] = nil
            polledNodeIDs.remove(key)
        }
    }

    private func node(for container: TunnelContainer) -> TunnelNode {
        let key = ObjectIdentifier(container)
        if let existing = nodesByID[key] {
            return existing
        }
        let node = TunnelNode(container: container)
        nodesByID[key] = node
        // Forward each node's changes up so views observing the store re-derive
        // the hero/override layout when a member's status or throughput changes.
        nodeForwarders[key] = node.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
        return node
    }
}

// MARK: - Switch state

extension TunnelNode {
    /// Whether the tunnel is in any non-inactive operational state.
    var isOperational: Bool {
        switch status {
        case .active, .activating, .restarting, .reasserting, .waiting:
            return true
        case .inactive, .deactivating:
            return false
        }
    }

    /// Whether the row's switch should read as "on": operational, or armed via
    /// on-demand rules.
    var switchIsOn: Bool {
        isOperational || (hasOnDemandRules && isOnDemandEnabled)
    }
}

// MARK: - TunnelsManagerListDelegate

extension TunnelStore: TunnelsManagerListDelegate {
    func tunnelAdded(at index: Int) { rebuild() }
    func tunnelModified(at index: Int) { rebuild() }
    func tunnelMoved(from oldIndex: Int, to newIndex: Int) { rebuild() }
    func tunnelRemoved(at index: Int, tunnel: TunnelContainer) { rebuild() }
}

// MARK: - TunnelsManagerGroupListDelegate

extension TunnelStore: TunnelsManagerGroupListDelegate {
    func groupAdded(kind: TunnelGroupKind, at index: Int) { rebuild() }
    func groupModified(kind: TunnelGroupKind, at index: Int) { rebuild() }
    func groupMoved(kind: TunnelGroupKind, from oldIndex: Int, to newIndex: Int) { rebuild() }
    func groupRemoved(kind: TunnelGroupKind, at index: Int, tunnel: TunnelContainer) { rebuild() }
}
