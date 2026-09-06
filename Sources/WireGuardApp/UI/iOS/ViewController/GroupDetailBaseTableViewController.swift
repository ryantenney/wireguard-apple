// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import UIKit
import NetworkExtension

/// Base class for iOS group detail view controllers (failover, TiT).
/// Provides shared status cell, on-demand section, delete cell, polling lifecycle, and observation setup.
class GroupDetailBaseTableViewController: UITableViewController {

    static let onDemandFields: [ActivateOnDemandViewModel.OnDemandField] = [
        .onDemand, .ssid
    ]

    let tunnelsManager: TunnelsManager
    let tunnel: TunnelContainer
    var onDemandViewModel: ActivateOnDemandViewModel

    var statusObservationToken: AnyObject?
    var onDemandObservationToken: AnyObject?

    init(tunnelsManager: TunnelsManager, tunnel: TunnelContainer) {
        self.tunnelsManager = tunnelsManager
        self.tunnel = tunnel
        self.onDemandViewModel = ActivateOnDemandViewModel(tunnel: tunnel)
        super.init(style: .grouped)

        loadGroupData()
        loadSections()
        setupObservation()
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Subclass Hooks

    /// Load group-specific data from the tunnel's providerConfiguration. Called on init and after save.
    func loadGroupData() {
        // Override in subclass
    }

    /// Rebuild the sections array based on current state.
    func loadSections() {
        // Override in subclass
    }

    /// Start polling the network extension for runtime state.
    func startPolling() {
        // Override in subclass
    }

    /// Stop polling the network extension.
    func stopPolling() {
        // Override in subclass
    }

    /// Called when the edit button is tapped. Present the appropriate edit controller.
    @objc func editTapped() {
        // Override in subclass
    }

    /// The restoration identifier prefix for this controller (e.g. "FailoverGroupDetailVC").
    var restorationPrefix: String {
        return "GroupDetailVC"
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = tunnel.name
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .edit, target: self, action: #selector(editTapped))

        tableView.estimatedRowHeight = 44
        tableView.rowHeight = UITableView.automaticDimension
        tableView.register(SwitchCell.self)
        tableView.register(KeyValueCell.self)
        tableView.register(ButtonCell.self)
        tableView.register(ChevronCell.self)

        restorationIdentifier = "\(restorationPrefix):\(tunnel.name)"
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if tunnel.status == .active {
            startPolling()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        stopPolling()
    }

    // MARK: - Observation

    private func setupObservation() {
        statusObservationToken = tunnel.observe(\.status) { [weak self] tunnel, _ in
            guard let self = self else { return }
            if tunnel.status == .active {
                self.startPolling()
            } else if tunnel.status == .inactive {
                self.stopPolling()
                self.onStatusBecameInactive()
            }
        }
        onDemandObservationToken = tunnel.observe(\.isActivateOnDemandEnabled) { [weak self] tunnel, _ in
            self?.onDemandViewModel = ActivateOnDemandViewModel(tunnel: tunnel)
            self?.updateActivateOnDemandFields()
        }
    }

    /// Called when tunnel status transitions to inactive. Override to clear state.
    func onStatusBecameInactive() {
        loadSections()
        tableView.reloadData()
    }

    func updateActivateOnDemandFields() {
        // Subclasses should override to find the onDemand section index and reload it
    }

    /// Called after a group edit is saved. Reloads data and refreshes UI.
    func handleGroupSaved() {
        loadGroupData()
        onDemandViewModel = ActivateOnDemandViewModel(tunnel: tunnel)
        title = tunnel.name
        restorationIdentifier = "\(restorationPrefix):\(tunnel.name)"
        tableView.reloadData()
    }

    // MARK: - Shared Cell Factories

    func statusCell(for tableView: UITableView, at indexPath: IndexPath) -> UITableViewCell {
        let cell: SwitchCell = tableView.dequeueReusableCell(for: indexPath)

        func update(cell: SwitchCell?, with tunnel: TunnelContainer) {
            guard let cell = cell else { return }

            let status = tunnel.status
            let isOnDemandEngaged = tunnel.isActivateOnDemandEnabled
            let isSuspended = tunnel.isOnDemandSuspended

            let isSwitchOn = (status == .activating || status == .active || isOnDemandEngaged || isSuspended)
            cell.switchView.setOn(isSwitchOn, animated: true)

            if isSuspended && !(status == .activating || status == .active) {
                cell.switchView.onTintColor = UIColor.systemGray
            } else if isOnDemandEngaged && !(status == .activating || status == .active) {
                cell.switchView.onTintColor = UIColor.systemYellow
            } else {
                cell.switchView.onTintColor = UIColor.systemGreen
            }

            var text: String
            switch status {
            case .inactive: text = tr("tunnelStatusInactive")
            case .activating: text = tr("tunnelStatusActivating")
            case .active: text = tr("tunnelStatusActive")
            case .deactivating: text = tr("tunnelStatusDeactivating")
            case .reasserting: text = tr("tunnelStatusReasserting")
            case .restarting: text = tr("tunnelStatusRestarting")
            case .waiting: text = tr("tunnelStatusWaiting")
            }

            if tunnel.hasOnDemandRules {
                text += isOnDemandEngaged ? tr("tunnelStatusAddendumOnDemand") : ""
                cell.switchView.isUserInteractionEnabled = true
                cell.isEnabled = true
            } else {
                cell.switchView.isUserInteractionEnabled = (status == .inactive || status == .active)
                cell.isEnabled = (status == .inactive || status == .active)
            }

            if tunnel.hasOnDemandRules && !isOnDemandEngaged && status == .inactive {
                text = tr("tunnelStatusOnDemandDisabled")
            }

            cell.textLabel?.text = text
        }

        update(cell: cell, with: tunnel)
        cell.statusObservationToken = tunnel.observe(\.status) { [weak cell] tunnel, _ in
            update(cell: cell, with: tunnel)
        }
        cell.isOnDemandEnabledObservationToken = tunnel.observe(\.isActivateOnDemandEnabled) { [weak cell] tunnel, _ in
            update(cell: cell, with: tunnel)
        }
        cell.hasOnDemandRulesObservationToken = tunnel.observe(\.hasOnDemandRules) { [weak cell] tunnel, _ in
            update(cell: cell, with: tunnel)
        }
        cell.isOnDemandSuspendedObservationToken = tunnel.observe(\.isOnDemandSuspended) { [weak cell] tunnel, _ in
            update(cell: cell, with: tunnel)
        }

        cell.onSwitchToggled = { [weak self] isOn in
            guard let self = self else { return }
            if self.tunnel.hasOnDemandRules {
                self.tunnelsManager.setOnDemandEnabled(isOn, on: self.tunnel) { error in
                    if error == nil && !isOn {
                        self.tunnelsManager.startDeactivation(of: self.tunnel)
                    }
                }
            } else {
                if isOn {
                    self.tunnelsManager.startActivation(of: self.tunnel)
                } else {
                    self.tunnelsManager.startDeactivation(of: self.tunnel)
                }
            }
        }
        return cell
    }

    func onDemandCell(for tableView: UITableView, at indexPath: IndexPath) -> UITableViewCell {
        let field = GroupDetailBaseTableViewController.onDemandFields[indexPath.row]
        if field == .onDemand {
            let cell: KeyValueCell = tableView.dequeueReusableCell(for: indexPath)
            cell.key = field.localizedUIString
            cell.value = onDemandViewModel.localizedInterfaceDescription
            cell.copyableGesture = false
            return cell
        } else {
            assert(field == .ssid)
            if onDemandViewModel.ssidOption == .anySSID {
                let cell: KeyValueCell = tableView.dequeueReusableCell(for: indexPath)
                cell.key = field.localizedUIString
                cell.value = onDemandViewModel.ssidOption.localizedUIString
                cell.copyableGesture = false
                return cell
            } else {
                let cell: ChevronCell = tableView.dequeueReusableCell(for: indexPath)
                cell.message = field.localizedUIString
                cell.detailMessage = onDemandViewModel.localizedSSIDDescription
                return cell
            }
        }
    }

    func deleteCell(for tableView: UITableView, at indexPath: IndexPath, title deleteTitle: String, message: String, removeAction: @escaping () -> Void) -> UITableViewCell {
        let cell: ButtonCell = tableView.dequeueReusableCell(for: indexPath)
        cell.buttonText = deleteTitle
        cell.hasDestructiveAction = true
        cell.onTapped = { [weak self] in
            guard let self = self else { return }
            let alert = UIAlertController(title: deleteTitle, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { _ in
                removeAction()
            })
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            self.present(alert, animated: true)
        }
        return cell
    }

    // MARK: - Member Tunnels

    /// Open the detail view of a member tunnel, from which it can be edited.
    func showMemberTunnelDetail(named name: String) {
        guard let member = tunnelsManager.tunnel(named: name) else { return }
        let detailVC = TunnelDetailTableViewController(tunnelsManager: tunnelsManager, tunnel: member)
        navigationController?.pushViewController(detailVC, animated: true)
    }

    /// Whether a member row should be tappable (the tunnel exists in the list).
    func isMemberTunnelAvailable(named name: String) -> Bool {
        return tunnelsManager.tunnel(named: name) != nil
    }

    // MARK: - Connection Details

    func diagnosticsCell(for tableView: UITableView, at indexPath: IndexPath) -> UITableViewCell {
        let cell: ChevronCell = tableView.dequeueReusableCell(for: indexPath)
        cell.message = "Connection Details"
        cell.detailMessage = ""
        return cell
    }

    func showConnectionDiagnostics() {
        let diagnosticsVC = ConnectionDiagnosticsTableViewController(tunnelsManager: tunnelsManager, tunnel: tunnel)
        navigationController?.pushViewController(diagnosticsVC, animated: true)
    }

    // MARK: - On-Demand SSID Navigation

    func handleSSIDRowSelection() {
        let ssidDetailVC = SSIDOptionDetailTableViewController(title: onDemandViewModel.ssidOption.localizedUIString, ssids: onDemandViewModel.selectedSSIDs)
        navigationController?.pushViewController(ssidDetailVC, animated: true)
    }
}
