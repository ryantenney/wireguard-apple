// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import UIKit
import NetworkExtension

protocol TunnelInTunnelEditDelegate: AnyObject {
    func titGroupSaved(_ tunnel: TunnelContainer)
    func titGroupDeleted(_ tunnel: TunnelContainer)
}

class TunnelInTunnelDetailTableViewController: GroupDetailBaseTableViewController {

    private enum Section {
        case status
        case tunnels
        case outerStats
        case innerStats
        case onDemand
        case diagnostics
        case delete
    }

    private enum StatField {
        case dataReceived
        case dataSent
        case lastHandshake

        var localizedUIString: String {
            switch self {
            case .dataReceived: return tr("tunnelPeerRxBytes")
            case .dataSent: return tr("tunnelPeerTxBytes")
            case .lastHandshake: return tr("tunnelPeerLastHandshakeTime")
            }
        }
    }

    private var outerTunnelName: String = ""
    private var innerTunnelName: String = ""
    private var sections = [Section]()
    private var titState: [String: Any]?
    private var statsTimer: Timer?
    private var visibleOuterStatFields: [StatField] = []
    private var visibleInnerStatFields: [StatField] = []

    override var restorationPrefix: String { "TiTDetailVC" }

    // MARK: - Subclass Hooks

    override func loadGroupData() {
        guard let proto = tunnel.tunnelProvider.protocolConfiguration as? NETunnelProviderProtocol else { return }
        let providerConfig = proto.providerConfiguration ?? [:]
        outerTunnelName = (providerConfig[TunnelInTunnelConfigKeys.outerName] as? String) ?? ""
        innerTunnelName = (providerConfig[TunnelInTunnelConfigKeys.innerName] as? String) ?? ""
    }

    override func loadSections() {
        var s: [Section] = [.status, .tunnels]
        if tunnel.status == .active && !visibleOuterStatFields.isEmpty { s.append(.outerStats) }
        if tunnel.status == .active && !visibleInnerStatFields.isEmpty { s.append(.innerStats) }
        s.append(contentsOf: [.onDemand, .diagnostics, .delete])
        sections = s
    }

    override func startPolling() {
        pollStats()
        stopPolling()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.pollStats()
        }
    }

    override func stopPolling() {
        statsTimer?.invalidate()
        statsTimer = nil
    }

    @objc override func editTapped() {
        let editVC = TunnelInTunnelEditTableViewController(tunnelsManager: tunnelsManager, groupTunnel: tunnel)
        editVC.delegate = self
        let editNC = UINavigationController(rootViewController: editVC)
        editNC.modalPresentationStyle = .formSheet
        present(editNC, animated: true)
    }

    override func onStatusBecameInactive() {
        titState = nil
        visibleOuterStatFields = []
        visibleInnerStatFields = []
        loadSections()
        tableView.reloadData()
    }

    override func updateActivateOnDemandFields() {
        guard let onDemandSection = sections.firstIndex(of: .onDemand) else { return }
        tableView.reloadSections(IndexSet(integer: onDemandSection), with: .automatic)
    }

    // MARK: - Stats Polling

    private func pollStats() {
        tunnelsManager.getTiTState(for: tunnel) { [weak self] state in
            guard let self = self, let state = state else { return }
            DispatchQueue.main.async {
                self.titState = state
                let newOuterFields = self.computeVisibleStatFields(prefix: "outer", from: state)
                let newInnerFields = self.computeVisibleStatFields(prefix: "inner", from: state)
                let hadOuterSection = self.sections.contains(.outerStats)
                let hadInnerSection = self.sections.contains(.innerStats)
                self.visibleOuterStatFields = newOuterFields
                self.visibleInnerStatFields = newInnerFields
                self.loadSections()

                let needsOuterSection = !newOuterFields.isEmpty && self.tunnel.status == .active
                let needsInnerSection = !newInnerFields.isEmpty && self.tunnel.status == .active

                if hadOuterSection != needsOuterSection || hadInnerSection != needsInnerSection {
                    self.tableView.reloadData()
                } else {
                    var reloadSet = IndexSet()
                    if needsOuterSection, let idx = self.sections.firstIndex(of: .outerStats) {
                        reloadSet.insert(idx)
                    }
                    if needsInnerSection, let idx = self.sections.firstIndex(of: .innerStats) {
                        reloadSet.insert(idx)
                    }
                    if !reloadSet.isEmpty {
                        self.tableView.reloadSections(reloadSet, with: .none)
                    }
                }
            }
        }
    }

    private func computeVisibleStatFields(prefix: String, from state: [String: Any]) -> [StatField] {
        var fields = [StatField]()
        if let rx = state["\(prefix)RxBytes"] as? UInt64, rx > 0 { fields.append(.dataReceived) }
        if let tx = state["\(prefix)TxBytes"] as? UInt64, tx > 0 { fields.append(.dataSent) }
        if state["\(prefix)LastHandshakeTime"] as? Double != nil { fields.append(.lastHandshake) }
        return fields
    }

    private func statValue(for field: StatField, prefix: String) -> String {
        guard let state = titState else { return "" }
        switch field {
        case .dataReceived:
            if let rx = state["\(prefix)RxBytes"] as? UInt64 { return FormattingHelpers.prettyBytes(rx) }
            return ""
        case .dataSent:
            if let tx = state["\(prefix)TxBytes"] as? UInt64 { return FormattingHelpers.prettyBytes(tx) }
            return ""
        case .lastHandshake:
            if let timestamp = state["\(prefix)LastHandshakeTime"] as? Double {
                return FormattingHelpers.prettyTimeAgo(since: Date(timeIntervalSince1970: timestamp))
            }
            return ""
        }
    }
}

// MARK: - TunnelInTunnelEditDelegate

extension TunnelInTunnelDetailTableViewController: TunnelInTunnelEditDelegate {
    func titGroupSaved(_ tunnel: TunnelContainer) {
        handleGroupSaved()
    }

    func titGroupDeleted(_ tunnel: TunnelContainer) {
        // Navigation cleanup handled by TunnelsListTableViewController
    }
}

// MARK: - UITableViewDataSource & UITableViewDelegate

extension TunnelInTunnelDetailTableViewController {
    override func numberOfSections(in tableView: UITableView) -> Int {
        return sections.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch sections[section] {
        case .status: return 1
        case .tunnels: return 2
        case .outerStats: return visibleOuterStatFields.count
        case .innerStats: return visibleInnerStatFields.count
        case .onDemand: return onDemandViewModel.isWiFiInterfaceEnabled ? 2 : 1
        case .diagnostics: return 1
        case .delete: return 1
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch sections[section] {
        case .status: return tr("tunnelSectionTitleStatus")
        case .tunnels: return "Tunnel Chain"
        case .outerStats: return "Outer Tunnel (\(outerTunnelName))"
        case .innerStats: return "Inner Tunnel (\(innerTunnelName))"
        case .onDemand: return tr("tunnelSectionTitleOnDemand")
        case .diagnostics: return nil
        case .delete: return nil
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch sections[indexPath.section] {
        case .status:
            return statusCell(for: tableView, at: indexPath)
        case .tunnels:
            return tunnelCell(for: tableView, at: indexPath)
        case .outerStats:
            return statCell(for: tableView, field: visibleOuterStatFields[indexPath.row], prefix: "outer")
        case .innerStats:
            return statCell(for: tableView, field: visibleInnerStatFields[indexPath.row], prefix: "inner")
        case .onDemand:
            return onDemandCell(for: tableView, at: indexPath)
        case .diagnostics:
            return diagnosticsCell(for: tableView, at: indexPath)
        case .delete:
            return deleteCell(for: tableView, at: indexPath, title: "Delete Tunnel-in-Tunnel Group",
                              message: "Are you sure you want to delete '\(tunnel.name)'? This won't delete the individual tunnels.") { [weak self] in
                guard let self = self else { return }
                self.tunnelsManager.removeTiTGroup(tunnel: self.tunnel) { error in
                    if error != nil { print("Error removing TiT group: \(String(describing: error))") }
                }
            }
        }
    }

    private func tunnelCell(for tableView: UITableView, at indexPath: IndexPath) -> UITableViewCell {
        let cell: KeyValueCell = tableView.dequeueReusableCell(for: indexPath)
        if indexPath.row == 0 {
            cell.key = outerTunnelName
            cell.value = "Outer (Server A)"
        } else {
            cell.key = innerTunnelName
            cell.value = "Inner (Server B)"
        }
        cell.copyableGesture = false
        return cell
    }

    private func statCell(for tableView: UITableView, field: StatField, prefix: String) -> UITableViewCell {
        let cell: KeyValueCell = tableView.dequeueReusableCell(for: IndexPath(row: 0, section: 0))
        cell.key = field.localizedUIString
        cell.value = statValue(for: field, prefix: prefix)
        cell.copyableGesture = false
        return cell
    }
}

// MARK: - Row Selection

extension TunnelInTunnelDetailTableViewController {
    override func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        if case .onDemand = sections[indexPath.section],
           case .ssid = GroupDetailBaseTableViewController.onDemandFields[indexPath.row] {
            return indexPath
        }
        if case .diagnostics = sections[indexPath.section] {
            return indexPath
        }
        return nil
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        if case .onDemand = sections[indexPath.section],
           case .ssid = GroupDetailBaseTableViewController.onDemandFields[indexPath.row] {
            handleSSIDRowSelection()
        } else if case .diagnostics = sections[indexPath.section] {
            showConnectionDiagnostics()
        }
        tableView.deselectRow(at: indexPath, animated: true)
    }
}
