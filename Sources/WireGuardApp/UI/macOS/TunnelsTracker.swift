// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.
// Copyright © 2026 Ryan Tenney.

import Cocoa

// Keeps track of tunnels and informs the following objects of changes in tunnels:
//   - Status menu
//   - Status item controller
//   - Tunnels list view controller in the Manage Tunnels window

class TunnelsTracker {

    weak var statusMenu: StatusMenu? {
        didSet {
            statusMenu?.currentTunnel = currentTunnel
        }
    }
    weak var statusItemController: StatusItemController? {
        didSet {
            statusItemController?.currentTunnel = currentTunnel
        }
    }
    weak var manageTunnelsRootVC: ManageTunnelsRootViewController?

    private var tunnelsManager: TunnelsManager
    private var tunnelStatusObservers = [AnyObject]()
    private var failoverGroupStatusObservers = [AnyObject]()
    private var titGroupStatusObservers = [AnyObject]()
    private(set) var currentTunnel: TunnelContainer? {
        didSet {
            statusMenu?.currentTunnel = currentTunnel
            statusItemController?.currentTunnel = currentTunnel
        }
    }

    init(tunnelsManager: TunnelsManager) {
        self.tunnelsManager = tunnelsManager
        currentTunnel = tunnelsManager.tunnelInOperation()

        for index in 0 ..< tunnelsManager.numberOfTunnels() {
            let tunnel = tunnelsManager.tunnel(at: index)
            let statusObservationToken = observeStatus(of: tunnel)
            tunnelStatusObservers.insert(statusObservationToken, at: index)
        }

        for index in 0 ..< tunnelsManager.numberOfFailoverGroups() {
            let groupTunnel = tunnelsManager.failoverGroup(at: index)
            let statusObservationToken = observeStatus(of: groupTunnel)
            failoverGroupStatusObservers.insert(statusObservationToken, at: index)
        }

        for index in 0 ..< tunnelsManager.numberOfTiTGroups() {
            let groupTunnel = tunnelsManager.titGroup(at: index)
            let statusObservationToken = observeStatus(of: groupTunnel)
            titGroupStatusObservers.insert(statusObservationToken, at: index)
        }

        tunnelsManager.tunnelsListDelegate = self
        tunnelsManager.groupListDelegate = self
        tunnelsManager.activationDelegate = self
    }

    func observeStatus(of tunnel: TunnelContainer) -> AnyObject {
        return tunnel.observe(\.status) { [weak self] tunnel, _ in
            guard let self = self else { return }
            if tunnel.status == .deactivating || tunnel.status == .inactive {
                if self.currentTunnel == tunnel {
                    self.currentTunnel = self.tunnelsManager.tunnelInOperation()
                }
            } else {
                self.currentTunnel = tunnel
            }
        }
    }
}

extension TunnelsTracker: TunnelsManagerListDelegate {
    func tunnelAdded(at index: Int) {
        let tunnel = tunnelsManager.tunnel(at: index)
        if tunnel.status != .deactivating && tunnel.status != .inactive {
            self.currentTunnel = tunnel
        }
        let statusObservationToken = observeStatus(of: tunnel)
        tunnelStatusObservers.insert(statusObservationToken, at: index)

        statusMenu?.insertTunnelMenuItem(for: tunnel, at: index)
        manageTunnelsRootVC?.tunnelsListVC?.tunnelAdded(at: index)
    }

    func tunnelModified(at index: Int) {
        manageTunnelsRootVC?.tunnelsListVC?.tunnelModified(at: index)
    }

    func tunnelMoved(from oldIndex: Int, to newIndex: Int) {
        let statusObserver = tunnelStatusObservers.remove(at: oldIndex)
        tunnelStatusObservers.insert(statusObserver, at: newIndex)

        statusMenu?.moveTunnelMenuItem(from: oldIndex, to: newIndex)
        manageTunnelsRootVC?.tunnelsListVC?.tunnelMoved(from: oldIndex, to: newIndex)
    }

    func tunnelRemoved(at index: Int, tunnel: TunnelContainer) {
        tunnelStatusObservers.remove(at: index)

        statusMenu?.removeTunnelMenuItem(at: index)
        manageTunnelsRootVC?.tunnelsListVC?.tunnelRemoved(at: index)
    }
}

extension TunnelsTracker: TunnelsManagerGroupListDelegate {
    func groupAdded(kind: TunnelGroupKind, at index: Int) {
        let groupTunnel = tunnelsManager.group(kind: kind, at: index)
        if groupTunnel.status != .deactivating && groupTunnel.status != .inactive {
            self.currentTunnel = groupTunnel
        }
        // Each kind has its own observer array — the index is kind-local, so
        // inserting into the wrong array shifts/drops other groups' observers.
        let statusObservationToken = observeStatus(of: groupTunnel)

        switch kind {
        case .failover:
            failoverGroupStatusObservers.insert(statusObservationToken, at: index)
            statusMenu?.insertFailoverGroupMenuItem(for: groupTunnel, at: index)
            manageTunnelsRootVC?.tunnelsListVC?.failoverGroupAdded(at: index)
        case .tunnelInTunnel:
            titGroupStatusObservers.insert(statusObservationToken, at: index)
            manageTunnelsRootVC?.tunnelsListVC?.titGroupAdded(at: index)
        }
    }

    func groupModified(kind: TunnelGroupKind, at index: Int) {
        switch kind {
        case .failover:
            manageTunnelsRootVC?.tunnelsListVC?.failoverGroupModified(at: index)
        case .tunnelInTunnel:
            manageTunnelsRootVC?.tunnelsListVC?.titGroupModified(at: index)
        }
    }

    func groupMoved(kind: TunnelGroupKind, from oldIndex: Int, to newIndex: Int) {
        switch kind {
        case .failover:
            let statusObserver = failoverGroupStatusObservers.remove(at: oldIndex)
            failoverGroupStatusObservers.insert(statusObserver, at: newIndex)
            statusMenu?.moveFailoverGroupMenuItem(from: oldIndex, to: newIndex)
            manageTunnelsRootVC?.tunnelsListVC?.failoverGroupMoved(from: oldIndex, to: newIndex)
        case .tunnelInTunnel:
            let statusObserver = titGroupStatusObservers.remove(at: oldIndex)
            titGroupStatusObservers.insert(statusObserver, at: newIndex)
            manageTunnelsRootVC?.tunnelsListVC?.titGroupMoved(from: oldIndex, to: newIndex)
        }
    }

    func groupRemoved(kind: TunnelGroupKind, at index: Int, tunnel: TunnelContainer) {
        switch kind {
        case .failover:
            failoverGroupStatusObservers.remove(at: index)
            statusMenu?.removeFailoverGroupMenuItem(at: index)
            manageTunnelsRootVC?.tunnelsListVC?.failoverGroupRemoved(at: index)
        case .tunnelInTunnel:
            titGroupStatusObservers.remove(at: index)
            manageTunnelsRootVC?.tunnelsListVC?.titGroupRemoved(at: index)
        }
    }
}

extension TunnelsTracker: TunnelsManagerActivationDelegate {
    func tunnelActivationAttemptFailed(tunnel: TunnelContainer, error: TunnelsManagerActivationAttemptError) {
        if let manageTunnelsRootVC = manageTunnelsRootVC, manageTunnelsRootVC.view.window?.isVisible ?? false {
            ErrorPresenter.showErrorAlert(error: error, from: manageTunnelsRootVC)
        } else {
            ErrorPresenter.showErrorAlert(error: error, from: nil)
        }
    }

    func tunnelActivationAttemptSucceeded(tunnel: TunnelContainer) {
        // Nothing to do
    }

    func tunnelActivationFailed(tunnel: TunnelContainer, error: TunnelsManagerActivationError) {
        if let manageTunnelsRootVC = manageTunnelsRootVC, manageTunnelsRootVC.view.window?.isVisible ?? false {
            ErrorPresenter.showErrorAlert(error: error, from: manageTunnelsRootVC)
        } else {
            ErrorPresenter.showErrorAlert(error: error, from: nil)
        }
    }

    func tunnelActivationSucceeded(tunnel: TunnelContainer) {
        // Nothing to do
    }
}
