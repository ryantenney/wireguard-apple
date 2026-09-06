// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import Cocoa
import NetworkExtension

class TunnelInTunnelDetailTableViewController: GroupDetailBaseViewController {

    private enum TableViewModelRow {
        case nameRow
        case statusRow
        case toggleStatusRow
        case tunnelRow(name: String, role: String)
        case statRow(label: String, value: String, isHeader: Bool)
        case onDemandRow
        case onDemandSSIDRow
        case spacerRow
    }

    private var outerTunnelName: String = ""
    private var innerTunnelName: String = ""
    private var tableViewModelRows = [TableViewModelRow]()
    private var titEditVC: TunnelInTunnelEditViewController?
    private var titState: [String: Any]?
    private var statsTimer: Timer?

    override var tableColumnIdentifier: String { "TiTDetail" }

    override func loadView() {
        tableView.dataSource = self
        tableView.delegate = self
        super.loadView()
    }

    override func dismissEditSheet() {
        if let titEditVC = titEditVC {
            dismiss(titEditVC)
        }
    }

    override func loadGroupData() {
        guard let proto = tunnel.tunnelProvider.protocolConfiguration as? NETunnelProviderProtocol else { return }
        let providerConfig = proto.providerConfiguration ?? [:]
        outerTunnelName = (providerConfig[TunnelInTunnelConfigKeys.outerName] as? String) ?? ""
        innerTunnelName = (providerConfig[TunnelInTunnelConfigKeys.innerName] as? String) ?? ""
    }

    override func rebuildTableViewModelRows() {
        var rows = [TableViewModelRow]()

        rows.append(.nameRow)
        rows.append(.statusRow)
        rows.append(.toggleStatusRow)
        rows.append(.spacerRow)

        rows.append(.tunnelRow(name: outerTunnelName, role: "Outer (Server A)"))
        rows.append(.tunnelRow(name: innerTunnelName, role: "Inner (Server B)"))
        rows.append(.spacerRow)

        // Stats (when active)
        if tunnel.status == .active, let state = titState {
            appendStatRows(for: "outer", label: "Outer Tunnel (\(outerTunnelName))", state: state, rows: &rows)
            appendStatRows(for: "inner", label: "Inner Tunnel (\(innerTunnelName))", state: state, rows: &rows)
        }

        rows.append(.onDemandRow)
        if onDemandViewModel.isWiFiInterfaceEnabled {
            rows.append(.onDemandSSIDRow)
        }

        tableViewModelRows = rows
    }

    private func appendStatRows(for prefix: String, label: String, state: [String: Any], rows: inout [TableViewModelRow]) {
        var statRows = [TableViewModelRow]()
        if let rx = state["\(prefix)RxBytes"] as? UInt64, rx > 0 {
            statRows.append(.statRow(label: tr("tunnelPeerRxBytes"), value: FormattingHelpers.prettyBytes(rx), isHeader: false))
        }
        if let tx = state["\(prefix)TxBytes"] as? UInt64, tx > 0 {
            statRows.append(.statRow(label: tr("tunnelPeerTxBytes"), value: FormattingHelpers.prettyBytes(tx), isHeader: false))
        }
        if let timestamp = state["\(prefix)LastHandshakeTime"] as? Double {
            statRows.append(.statRow(label: tr("tunnelPeerLastHandshakeTime"), value: FormattingHelpers.prettyTimeAgo(since: Date(timeIntervalSince1970: timestamp)), isHeader: false))
        }
        if !statRows.isEmpty {
            rows.append(.statRow(label: label, value: "", isHeader: true))
            rows.append(contentsOf: statRows)
            rows.append(.spacerRow)
        }
    }

    override func memberTunnelName(forRow row: Int) -> String? {
        guard tableViewModelRows.indices.contains(row), case .tunnelRow(let name, _) = tableViewModelRows[row] else { return nil }
        return name
    }

    override func startPolling() { startPollingStats() }
    override func stopPolling() { stopPollingStats() }

    override func onStatusBecameInactive() {
        titState = nil
        super.onStatusBecameInactive()
    }

    // MARK: - Stats Polling

    private func startPollingStats() {
        pollStats()
        stopPollingStats()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.pollStats()
        }
    }

    private func stopPollingStats() {
        statsTimer?.invalidate()
        statsTimer = nil
    }

    private func pollStats() {
        tunnelsManager.getTiTState(for: tunnel) { [weak self] state in
            guard let self = self, let state = state else { return }
            DispatchQueue.main.async {
                self.titState = state
                self.rebuildTableViewModelRows()
                self.tableView.reloadData()
            }
        }
    }

    @objc override func handleEditAction() {
        let editVC = TunnelInTunnelEditViewController(tunnelsManager: tunnelsManager, tunnel: tunnel)
        editVC.delegate = self
        presentAsSheet(editVC)
        self.titEditVC = editVC
    }
}

// MARK: - NSTableViewDataSource

extension TunnelInTunnelDetailTableViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        return tableViewModelRows.count
    }
}

// MARK: - NSTableViewDelegate

extension TunnelInTunnelDetailTableViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let modelRow = tableViewModelRows[row]
        switch modelRow {
        case .nameRow:
            let cell: KeyValueRow = tableView.dequeueReusableCell()
            cell.key = tr(format: "macFieldKey (%@)", tr("tunnelInterfaceName"))
            cell.value = tunnel.name
            cell.isKeyInBold = true
            return cell

        case .statusRow:
            let cell: KeyValueImageRow = tableView.dequeueReusableCell()
            cell.key = tr(format: "macFieldKey (%@)", tr("tunnelInterfaceStatus"))
            cell.value = GroupDetailBaseViewController.localizedStatusDescription(for: tunnel)
            cell.valueImage = TunnelListRow.image(for: tunnel)
            let changeHandler: (TunnelContainer, Any) -> Void = { [weak cell] tunnel, _ in
                guard let cell = cell else { return }
                cell.value = GroupDetailBaseViewController.localizedStatusDescription(for: tunnel)
                cell.valueImage = TunnelListRow.image(for: tunnel)
            }
            cell.statusObservationToken = tunnel.observe(\.status, changeHandler: changeHandler)
            cell.isOnDemandEnabledObservationToken = tunnel.observe(\.isActivateOnDemandEnabled, changeHandler: changeHandler)
            cell.hasOnDemandRulesObservationToken = tunnel.observe(\.hasOnDemandRules, changeHandler: changeHandler)
            return cell

        case .toggleStatusRow:
            let cell: ButtonRow = tableView.dequeueReusableCell()
            cell.buttonTitle = GroupDetailBaseViewController.localizedToggleStatusActionText(for: tunnel)
            cell.isButtonEnabled = (tunnel.hasOnDemandRules || tunnel.status == .active || tunnel.status == .inactive)
            cell.buttonToolTip = tr("macToolTipToggleStatus")
            cell.onButtonClicked = { [weak self] in
                self?.handleToggleActiveStatusAction()
            }
            let changeHandler: (TunnelContainer, Any) -> Void = { [weak cell] tunnel, _ in
                guard let cell = cell else { return }
                cell.buttonTitle = GroupDetailBaseViewController.localizedToggleStatusActionText(for: tunnel)
                cell.isButtonEnabled = (tunnel.hasOnDemandRules || tunnel.status == .active || tunnel.status == .inactive)
            }
            cell.statusObservationToken = tunnel.observe(\.status, changeHandler: changeHandler)
            cell.isOnDemandEnabledObservationToken = tunnel.observe(\.isActivateOnDemandEnabled, changeHandler: changeHandler)
            cell.hasOnDemandRulesObservationToken = tunnel.observe(\.hasOnDemandRules, changeHandler: changeHandler)
            return cell

        case .tunnelRow(let name, let role):
            let cell: KeyValueRow = tableView.dequeueReusableCell()
            cell.key = tr(format: "macFieldKey (%@)", name)
            cell.value = role
            cell.isKeyInBold = false
            cell.toolTip = "Double-click to open '\(name)'"
            return cell

        case .statRow(let label, let value, let isHeader):
            let cell: KeyValueRow = tableView.dequeueReusableCell()
            cell.key = tr(format: "macFieldKey (%@)", label)
            cell.value = value
            cell.isKeyInBold = isHeader
            return cell

        case .onDemandRow:
            let cell: KeyValueRow = tableView.dequeueReusableCell()
            cell.key = tr("macFieldOnDemand")
            cell.value = onDemandViewModel.localizedInterfaceDescription
            cell.isKeyInBold = true
            return cell

        case .onDemandSSIDRow:
            let cell: KeyValueRow = tableView.dequeueReusableCell()
            cell.key = tr("macFieldOnDemandSSIDs")
            let value: String
            if onDemandViewModel.ssidOption == .anySSID {
                value = onDemandViewModel.ssidOption.localizedUIString
            } else {
                value = tr(format: "tunnelOnDemandSSIDOptionDescriptionMac (%1$@: %2$@)",
                           onDemandViewModel.ssidOption.localizedUIString,
                           onDemandViewModel.selectedSSIDs.joined(separator: ", "))
            }
            cell.value = value
            cell.isKeyInBold = false
            return cell

        case .spacerRow:
            return NSView()
        }
    }
}

// MARK: - TunnelInTunnelEditViewControllerDelegate

extension TunnelInTunnelDetailTableViewController: TunnelInTunnelEditViewControllerDelegate {
    func titGroupSaved(tunnel: TunnelContainer) {
        handleGroupSaved()
        self.titEditVC = nil
    }

    func titGroupEditingCancelled() {
        self.titEditVC = nil
    }
}
