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
        case diagnostics
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
        case confirmBeforeFailover
        case confirmationTimeout
        case linkDownHoldTime
        case adaptiveSensitivity
        case pathChangeGrace

        var localizedUIString: String {
            switch self {
            case .trafficTimeout: return tr("failoverGroupFieldTrafficTimeout")
            case .healthCheckInterval: return tr("failoverGroupFieldHealthCheckInterval")
            case .failbackProbeInterval: return tr("failoverGroupFieldFailbackProbeInterval")
            case .autoFailback: return tr("failoverGroupToggleAutoFailback")
            case .confirmBeforeFailover: return tr("failoverGroupToggleConfirmBeforeFailover")
            case .confirmationTimeout: return tr("failoverGroupFieldConfirmationTimeout")
            case .linkDownHoldTime: return tr("failoverGroupFieldLinkDownHold")
            case .adaptiveSensitivity: return tr("failoverGroupToggleAdaptiveSensitivity")
            case .pathChangeGrace: return tr("failoverGroupFieldPathChangeGrace")
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
            case .active: return tr("failoverGroupMemberStatusActive")
            case .unhealthy: return tr("failoverGroupMemberStatusUnhealthy")
            case .signInRequired: return tr("failoverGroupMemberStatusSignInRequired")
            case .waitingForNetwork: return tr("failoverGroupMemberStatusWaitingForNetwork")
            case .hotSpareReady: return tr("failoverGroupMemberStatusHotSpareReady")
            case .hotSpareWaiting: return tr("failoverGroupMemberStatusHotSpareWaiting")
            case .probing: return tr("failoverGroupMemberStatusProbing")
            case .idle: return tr("failoverGroupMemberStatusIdle")
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
            case .network: return tr("failoverGroupFieldNetwork")
            case .dataReceived: return tr("tunnelPeerRxBytes")
            case .dataSent: return tr("tunnelPeerTxBytes")
            case .lastHandshake: return tr("tunnelPeerLastHandshakeTime")
            case .failoverCount: return tr("failoverGroupFieldFailoverCount")
            case .lastFailover: return tr("failoverGroupFieldLastFailover")
            case .healthStatus: return tr("failoverGroupFieldHealthStatus")
            case .failbackProbe: return tr("failoverGroupFieldFailbackProbe")
            case .hotSpare: return tr("failoverGroupFieldHotSpare")
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
        tunnelNames = (providerConfig[ProviderConfigurationKeys.failoverConfigNames] as? [String]) ?? []
        if let settingsData = providerConfig[ProviderConfigurationKeys.failoverSettings] as? Data {
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
        s.append(contentsOf: [.settings, .onDemand, .diagnostics])
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
        case .diagnostics: return 1
        #if FAILOVER_TESTING
        case .debug: return 2
        #endif
        case .delete: return 1
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch sections[section] {
        case .status: return tr("tunnelSectionTitleStatus")
        case .tunnels: return tr("failoverGroupSectionTunnels")
        case .activeConnection: return tr("failoverGroupSectionActiveConnection")
        case .settings: return tr("failoverGroupSectionSettings")
        case .onDemand: return tr("tunnelSectionTitleOnDemand")
        case .diagnostics: return nil
        #if FAILOVER_TESTING
        case .debug: return tr("failoverGroupSectionDebug")
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
        case .diagnostics:
            return diagnosticsCell(for: tableView, at: indexPath)
        #if FAILOVER_TESTING
        case .debug:
            return debugCell(for: tableView, at: indexPath)
        #endif
        case .delete:
            return deleteCell(for: tableView, at: indexPath, title: tr("failoverGroupDeleteButtonTitle"),
                              message: tr(format: "failoverGroupDeleteConfirmation (%@)", tunnel.name)) { [weak self] in
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
        let role = indexPath.row == 0 ? tr("failoverGroupRolePrimary") : tr(format: "failoverGroupRoleFailover (%d)", indexPath.row)
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

        cell.detailTextLabel?.text = tr(format: "failoverGroupRoleAndStatus (%1$@ and %2$@)", role, status.label)
        cell.detailTextLabel?.textColor = .secondaryLabel
        if isMemberTunnelAvailable(named: name) {
            cell.selectionStyle = .default
            cell.accessoryType = .disclosureIndicator
        } else {
            cell.selectionStyle = .none
            cell.accessoryType = .none
        }
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
            var text = isCaptive ? tr("failoverGroupHealthCaptive") : tr("failoverGroupHealthOffline")
            if let since = state["networkBlockedSince"] as? Double {
                let duration = Int(Date().timeIntervalSince1970 - since)
                text = tr(format: "failoverGroupHealthBlockedDuration (%1$@ and %2$d)", text, duration)
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
                if let heldSince = state["suppressedSince"] as? Double {
                    return tr(format: "failoverGroupHealthHolding (%d)", Int(Date().timeIntervalSince1970 - heldSince))
                }
                if state["confirmationProbeHandle"] as? Int != nil {
                    return tr(format: "failoverGroupHealthConfirming (%d)", duration)
                }
                return tr(format: "failoverGroupHealthUnhealthy (%d)", duration)
            }
            return tr("failoverGroupHealthHealthy")
        case .failbackProbe:
            if let bgProbe = state["backgroundProbeActive"] as? Bool, bgProbe {
                return tr("failoverGroupProbeBackgroundRunning")
            }
            return tr("failoverGroupProbePrimary")
        case .hotSpare:
            if let index = state["hotSpareConfigIndex"] as? Int {
                let name = index < tunnelNames.count ? tunnelNames[index] : tr(format: "failoverGroupConfigFallbackName (%d)", index)
                if let age = state["hotSpareHandshakeAge"] as? Double {
                    if age < 180 {
                        return tr(format: "failoverGroupHotSpareConnected (%1$@ and %2$d)", name, Int(age))
                    } else {
                        return tr(format: "failoverGroupHotSpareStale (%1$@ and %2$d)", name, Int(age))
                    }
                }
                let isActive = state["hotSpareActive"] as? Bool ?? false
                return isActive ? tr(format: "failoverGroupHotSpareWaiting (%@)", name) : tr(format: "failoverGroupHotSpareStarting (%@)", name)
            }
            return tr("failoverGroupMemberStatusActive")
        }
    }

    private func settingsCell(for tableView: UITableView, at indexPath: IndexPath) -> UITableViewCell {
        let field = SettingsField.allCases[indexPath.row]
        let cell: KeyValueCell = tableView.dequeueReusableCell(for: indexPath)
        cell.key = field.localizedUIString
        switch field {
        case .trafficTimeout: cell.value = tr(format: "failoverGroupValueSeconds (%d)", Int(settings.trafficTimeout))
        case .healthCheckInterval: cell.value = tr(format: "failoverGroupValueSeconds (%d)", Int(settings.healthCheckInterval))
        case .failbackProbeInterval: cell.value = tr(format: "failoverGroupValueSeconds (%d)", Int(settings.failbackProbeInterval))
        case .autoFailback: cell.value = settings.autoFailback ? tr("actionYes") : tr("actionNo")
        case .confirmBeforeFailover: cell.value = settings.confirmBeforeFailover ? tr("actionYes") : tr("actionNo")
        case .confirmationTimeout: cell.value = tr(format: "failoverGroupValueSeconds (%d)", Int(settings.confirmationTimeout))
        case .linkDownHoldTime: cell.value = settings.linkDownHoldTime > 0 ? tr(format: "failoverGroupValueSeconds (%d)", Int(settings.linkDownHoldTime)) : tr("failoverGroupValueForever")
        case .adaptiveSensitivity: cell.value = settings.adaptiveSensitivity ? tr("actionYes") : tr("actionNo")
        case .pathChangeGrace: cell.value = tr(format: "failoverGroupValueSeconds (%d)", Int(settings.pathChangeGrace))
        }
        cell.copyableGesture = false
        return cell
    }

    #if FAILOVER_TESTING
    private func debugCell(for tableView: UITableView, at indexPath: IndexPath) -> UITableViewCell {
        let cell: ButtonCell = tableView.dequeueReusableCell(for: indexPath)
        if indexPath.row == 0 {
            cell.buttonText = tr("failoverGroupForceFailoverButtonTitle")
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
            cell.buttonText = tr("failoverGroupForceFailbackButtonTitle")
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
        if case .diagnostics = sections[indexPath.section] {
            return indexPath
        }
        if case .tunnels = sections[indexPath.section], isMemberTunnelAvailable(named: tunnelNames[indexPath.row]) {
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
        } else if case .tunnels = sections[indexPath.section] {
            showMemberTunnelDetail(named: tunnelNames[indexPath.row])
        }
        tableView.deselectRow(at: indexPath, animated: true)
    }
}
