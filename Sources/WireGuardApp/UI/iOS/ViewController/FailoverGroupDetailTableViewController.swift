// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import UIKit
import NetworkExtension

class FailoverGroupDetailTableViewController: GroupDetailBaseTableViewController {

    private enum Section {
        case status
        case tunnels
        case activeConnection
        case settings
        case onDemand
        #if FAILOVER_TESTING
        case debug
        #endif
        case delete
    }

    private enum SettingsField: CaseIterable {
        case trafficTimeout
        case healthCheckInterval
        case failbackProbeInterval
        case autoFailback

        var localizedUIString: String {
            switch self {
            case .trafficTimeout: return "Traffic Timeout"
            case .healthCheckInterval: return "Health Check Interval"
            case .failbackProbeInterval: return "Failback Probe Interval"
            case .autoFailback: return "Auto Failback"
            }
        }
    }

    private enum ConnectionStatus {
        case active
        case unhealthy
        case signInRequired
        case waitingForNetwork
        case hotSpareReady
        case hotSpareWaiting
        case probing
        case idle

        var indicatorColor: UIColor {
            switch self {
            case .active, .hotSpareReady: return .systemGreen
            case .unhealthy, .hotSpareWaiting, .probing: return .systemYellow
            case .signInRequired: return .systemOrange
            case .waitingForNetwork, .idle: return .systemGray
            }
        }

        var label: String {
            switch self {
            case .active: return "Active"
            case .unhealthy: return "Unhealthy"
            case .signInRequired: return "Wi-Fi Sign-in Required"
            case .waitingForNetwork: return "Waiting for Network"
            case .hotSpareReady: return "Standby"
            case .hotSpareWaiting: return "Connecting"
            case .probing: return "Probing"
            case .idle: return "Idle"
            }
        }
    }

    private enum ActiveConnectionField {
        case network
        case dataReceived
        case dataSent
        case lastHandshake
        case failoverCount
        case lastFailover
        case healthStatus
        case failbackProbe
        case hotSpare

        var localizedUIString: String {
            switch self {
            case .network: return "Network"
            case .dataReceived: return tr("tunnelPeerRxBytes")
            case .dataSent: return tr("tunnelPeerTxBytes")
            case .lastHandshake: return tr("tunnelPeerLastHandshakeTime")
            case .failoverCount: return "Failover Count"
            case .lastFailover: return "Last Failover"
            case .healthStatus: return "Health"
            case .failbackProbe: return "Failback Probe"
            case .hotSpare: return "Hot Spare"
            }
        }
    }

    private var tunnelNames: [String] = []
    private var settings = FailoverSettings()
    private var sections = [Section]()
    private var activeConfigName: String?
    private var failoverStateTimer: Timer?
    private var failoverState: [String: Any]?
    private var visibleActiveConnectionFields: [ActiveConnectionField] = []

    override var restorationPrefix: String { "FailoverGroupDetailVC" }

    // MARK: - Subclass Hooks

    override func loadGroupData() {
        guard let proto = tunnel.tunnelProvider.protocolConfiguration as? NETunnelProviderProtocol else { return }
        let providerConfig = proto.providerConfiguration ?? [:]
        tunnelNames = (providerConfig["FailoverConfigNames"] as? [String]) ?? []
        if let settingsData = providerConfig["FailoverSettings"] as? Data {
            settings = (try? JSONDecoder().decode(FailoverSettings.self, from: settingsData)) ?? FailoverSettings()
        } else {
            settings = FailoverSettings()
        }
    }

    override func loadSections() {
        var s: [Section] = [.status, .tunnels]
        if tunnel.status == .active && !visibleActiveConnectionFields.isEmpty {
            s.append(.activeConnection)
        }
        s.append(contentsOf: [.settings, .onDemand])
        #if FAILOVER_TESTING
        if tunnel.status == .active {
            s.append(.debug)
        }
        #endif
        s.append(.delete)
        sections = s
    }

    override func startPolling() {
        pollFailoverState()
        stopPolling()
        failoverStateTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.pollFailoverState()
        }
    }

    override func stopPolling() {
        failoverStateTimer?.invalidate()
        failoverStateTimer = nil
    }

    @objc override func editTapped() {
        let editVC = FailoverGroupEditTableViewController(tunnelsManager: tunnelsManager, groupTunnel: tunnel)
        editVC.delegate = self
        let editNC = UINavigationController(rootViewController: editVC)
        editNC.modalPresentationStyle = .formSheet
        present(editNC, animated: true)
    }

    override func onStatusBecameInactive() {
        activeConfigName = nil
        failoverState = nil
        visibleActiveConnectionFields = []
        loadSections()
        tableView.reloadData()
    }

    override func updateActivateOnDemandFields() {
        guard let onDemandSection = sections.firstIndex(of: .onDemand) else { return }
        tableView.reloadSections(IndexSet(integer: onDemandSection), with: .automatic)
    }

    // MARK: - Failover State Polling

    private func pollFailoverState() {
        tunnelsManager.getFailoverState(for: tunnel) { [weak self] state in
            guard let self = self, let state = state else { return }
            DispatchQueue.main.async {
                self.failoverState = state

                let newActiveConfig = state["activeConfig"] as? String
                self.activeConfigName = newActiveConfig

                let newVisibleFields = self.computeVisibleActiveConnectionFields(from: state)
                let hadSection = self.sections.contains(.activeConnection)
                let needsSection = !newVisibleFields.isEmpty && self.tunnel.status == .active
                self.visibleActiveConnectionFields = newVisibleFields
                self.loadSections()

                if !hadSection && needsSection {
                    if let idx = self.sections.firstIndex(of: .activeConnection) {
                        self.tableView.insertSections(IndexSet(integer: idx), with: .automatic)
                    }
                    if let tunnelsIdx = self.sections.firstIndex(of: .tunnels) {
                        self.tableView.reloadSections(IndexSet(integer: tunnelsIdx), with: .none)
                    }
                } else if hadSection && !needsSection {
                    self.tableView.reloadData()
                } else {
                    var reloadSet = IndexSet()
                    if let tunnelsIdx = self.sections.firstIndex(of: .tunnels) {
                        reloadSet.insert(tunnelsIdx)
                    }
                    if needsSection, let idx = self.sections.firstIndex(of: .activeConnection) {
                        reloadSet.insert(idx)
                    }
                    if !reloadSet.isEmpty {
                        self.tableView.reloadSections(reloadSet, with: .none)
                    }
                }
            }
        }
    }

    private func computeVisibleActiveConnectionFields(from state: [String: Any]) -> [ActiveConnectionField] {
        var fields = [ActiveConnectionField]()
        if let blocked = state["networkBlocked"] as? Bool, blocked { fields.append(.network) }
        if let rx = state["rxBytes"] as? UInt64, rx > 0 { fields.append(.dataReceived) }
        if let tx = state["txBytes"] as? UInt64, tx > 0 { fields.append(.dataSent) }
        if state["lastHandshakeTime"] as? Double != nil { fields.append(.lastHandshake) }
        if let count = state["consecutiveCycles"] as? Int, count > 0 { fields.append(.failoverCount) }
        if state["lastSwitchTime"] as? Double != nil { fields.append(.lastFailover) }
        if state["txWithoutRxSince"] as? Double != nil { fields.append(.healthStatus) }
        if let probing = state["isProbing"] as? Bool, probing { fields.append(.failbackProbe) }
        if state["hotSpareConfigIndex"] as? Int != nil { fields.append(.hotSpare) }
        return fields
    }

    // MARK: - Per-Tunnel Status

    private func connectionStatus(forTunnelAt index: Int) -> ConnectionStatus {
        guard tunnel.status == .active, let state = failoverState else { return .idle }
        let name = tunnelNames[index]

        if let activeName = activeConfigName, activeName == name {
            if let blocked = state["networkBlocked"] as? Bool, blocked {
                let isCaptive = state["captivePortalDetected"] as? Bool ?? false
                return isCaptive ? .signInRequired : .waitingForNetwork
            }
            if state["txWithoutRxSince"] as? Double != nil { return .unhealthy }
            return .active
        }
        if let hotSpareIndex = state["hotSpareConfigIndex"] as? Int, hotSpareIndex == index {
            // WireGuard rejects session reuse after REJECT_AFTER_TIME (180s); anything
            // fresher than that is still promotable without a fresh handshake.
            if let age = state["hotSpareHandshakeAge"] as? Double, age < 180 { return .hotSpareReady }
            let isActive = state["hotSpareActive"] as? Bool ?? false
            return isActive ? .hotSpareWaiting : .idle
        }
        if index == 0, let probing = state["isProbing"] as? Bool, probing { return .probing }
        return .idle
    }
}

// MARK: - FailoverGroupEditDelegate

extension FailoverGroupDetailTableViewController: FailoverGroupEditDelegate {
    func failoverGroupSaved(_ tunnel: TunnelContainer) {
        handleGroupSaved()
    }

    func failoverGroupDeleted(_ tunnel: TunnelContainer) {
        // Navigation cleanup handled by TunnelsListTableViewController
    }
}

// MARK: - UITableViewDataSource & UITableViewDelegate

extension FailoverGroupDetailTableViewController {
    override func numberOfSections(in tableView: UITableView) -> Int {
        return sections.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch sections[section] {
        case .status: return 1
        case .tunnels: return tunnelNames.count
        case .activeConnection: return visibleActiveConnectionFields.count
        case .settings: return SettingsField.allCases.count
        case .onDemand: return onDemandViewModel.isWiFiInterfaceEnabled ? 2 : 1
        #if FAILOVER_TESTING
        case .debug: return 2
        #endif
        case .delete: return 1
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch sections[section] {
        case .status: return tr("tunnelSectionTitleStatus")
        case .tunnels: return "Connections"
        case .activeConnection: return "Active Connection"
        case .settings: return "Failover Settings"
        case .onDemand: return tr("tunnelSectionTitleOnDemand")
        #if FAILOVER_TESTING
        case .debug: return "Debug"
        #endif
        case .delete: return nil
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch sections[indexPath.section] {
        case .status:
            return statusCell(for: tableView, at: indexPath)
        case .tunnels:
            return tunnelCell(for: tableView, at: indexPath)
        case .activeConnection:
            return activeConnectionCell(for: tableView, at: indexPath)
        case .settings:
            return settingsCell(for: tableView, at: indexPath)
        case .onDemand:
            return onDemandCell(for: tableView, at: indexPath)
        #if FAILOVER_TESTING
        case .debug:
            return debugCell(for: tableView, at: indexPath)
        #endif
        case .delete:
            return deleteCell(for: tableView, at: indexPath, title: "Delete Failover Group",
                              message: "Are you sure you want to delete '\(tunnel.name)'? This won't delete the individual tunnels.") { [weak self] in
                guard let self = self else { return }
                self.tunnelsManager.removeFailoverGroup(tunnel: self.tunnel) { error in
                    if error != nil { print("Error removing failover group: \(String(describing: error))") }
                }
            }
        }
    }

    private func tunnelCell(for tableView: UITableView, at indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: "TunnelCell")
        let name = tunnelNames[indexPath.row]
        let role = indexPath.row == 0 ? "Primary" : "Failover #\(indexPath.row)"
        let status = connectionStatus(forTunnelAt: indexPath.row)

        let circle = NSAttributedString(string: "\u{25CF} ", attributes: [
            .foregroundColor: status.indicatorColor,
            .font: UIFont.systemFont(ofSize: 14)
        ])
        let nameAttr = NSAttributedString(string: name, attributes: [
            .foregroundColor: UIColor.label,
            .font: UIFont.systemFont(ofSize: 17)
        ])
        let combined = NSMutableAttributedString()
        combined.append(circle)
        combined.append(nameAttr)
        cell.textLabel?.attributedText = combined

        cell.detailTextLabel?.text = "\(role) · \(status.label)"
        cell.detailTextLabel?.textColor = .secondaryLabel
        cell.selectionStyle = .none
        return cell
    }

    private func activeConnectionCell(for tableView: UITableView, at indexPath: IndexPath) -> UITableViewCell {
        let field = visibleActiveConnectionFields[indexPath.row]
        let cell: KeyValueCell = tableView.dequeueReusableCell(for: indexPath)
        cell.key = field.localizedUIString
        cell.value = activeConnectionValue(for: field)
        cell.copyableGesture = false
        return cell
    }

    private func activeConnectionValue(for field: ActiveConnectionField) -> String {
        guard let state = failoverState else { return "" }
        switch field {
        case .network:
            let isCaptive = state["captivePortalDetected"] as? Bool ?? false
            var text = isCaptive ? "Captive portal — Wi-Fi requires sign-in" : "Offline — waiting to reconnect"
            if let since = state["networkBlockedSince"] as? Double {
                let duration = Int(Date().timeIntervalSince1970 - since)
                text += " (\(duration)s)"
            }
            return text
        case .dataReceived:
            if let rx = state["rxBytes"] as? UInt64 { return FormattingHelpers.prettyBytes(rx) }
            return ""
        case .dataSent:
            if let tx = state["txBytes"] as? UInt64 { return FormattingHelpers.prettyBytes(tx) }
            return ""
        case .lastHandshake:
            if let timestamp = state["lastHandshakeTime"] as? Double {
                return FormattingHelpers.prettyTimeAgo(since: Date(timeIntervalSince1970: timestamp))
            }
            return ""
        case .failoverCount:
            if let count = state["consecutiveCycles"] as? Int { return "\(count)" }
            return ""
        case .lastFailover:
            if let timestamp = state["lastSwitchTime"] as? Double {
                return FormattingHelpers.prettyTimeAgo(since: Date(timeIntervalSince1970: timestamp))
            }
            return ""
        case .healthStatus:
            if let since = state["txWithoutRxSince"] as? Double {
                let duration = Int(Date().timeIntervalSince1970 - since)
                return "Unhealthy (tx without rx for \(duration)s)"
            }
            return "Healthy"
        case .failbackProbe:
            if let bgProbe = state["backgroundProbeActive"] as? Bool, bgProbe {
                return "Background probe running..."
            }
            return "Probing primary..."
        case .hotSpare:
            if let index = state["hotSpareConfigIndex"] as? Int {
                let name = index < tunnelNames.count ? tunnelNames[index] : "config #\(index)"
                if let age = state["hotSpareHandshakeAge"] as? Double {
                    if age < 180 {
                        return "\(name): Connected (\(Int(age))s ago)"
                    } else {
                        return "\(name): Stale handshake (\(Int(age))s ago)"
                    }
                }
                let isActive = state["hotSpareActive"] as? Bool ?? false
                return isActive ? "\(name): Waiting for handshake..." : "\(name): Starting..."
            }
            return "Active"
        }
    }

    private func settingsCell(for tableView: UITableView, at indexPath: IndexPath) -> UITableViewCell {
        let field = SettingsField.allCases[indexPath.row]
        let cell: KeyValueCell = tableView.dequeueReusableCell(for: indexPath)
        cell.key = field.localizedUIString
        switch field {
        case .trafficTimeout: cell.value = "\(Int(settings.trafficTimeout))s"
        case .healthCheckInterval: cell.value = "\(Int(settings.healthCheckInterval))s"
        case .failbackProbeInterval: cell.value = "\(Int(settings.failbackProbeInterval))s"
        case .autoFailback: cell.value = settings.autoFailback ? "Yes" : "No"
        }
        cell.copyableGesture = false
        return cell
    }

    #if FAILOVER_TESTING
    private func debugCell(for tableView: UITableView, at indexPath: IndexPath) -> UITableViewCell {
        let cell: ButtonCell = tableView.dequeueReusableCell(for: indexPath)
        if indexPath.row == 0 {
            cell.buttonText = "Force Failover"
            cell.hasDestructiveAction = false
            cell.onTapped = { [weak self] in
                guard let self = self else { return }
                self.tunnelsManager.debugForceFailover(for: self.tunnel) { success in
                    DispatchQueue.main.async {
                        if success { self.pollFailoverState() }
                    }
                }
            }
        } else {
            cell.buttonText = "Force Failback to Primary"
            cell.hasDestructiveAction = false
            cell.onTapped = { [weak self] in
                guard let self = self else { return }
                self.tunnelsManager.debugForceFailback(for: self.tunnel) { success in
                    DispatchQueue.main.async {
                        if success { self.pollFailoverState() }
                    }
                }
            }
        }
        return cell
    }
    #endif
}

// MARK: - Row Selection

extension FailoverGroupDetailTableViewController {
    override func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        if case .onDemand = sections[indexPath.section],
           case .ssid = GroupDetailBaseTableViewController.onDemandFields[indexPath.row] {
            return indexPath
        }
        return nil
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        if case .onDemand = sections[indexPath.section],
           case .ssid = GroupDetailBaseTableViewController.onDemandFields[indexPath.row] {
            handleSSIDRowSelection()
        }
        tableView.deselectRow(at: indexPath, animated: true)
    }
}
