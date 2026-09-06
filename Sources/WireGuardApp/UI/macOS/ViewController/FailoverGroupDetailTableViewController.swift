// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import Cocoa
import NetworkExtension

class FailoverGroupDetailTableViewController: GroupDetailBaseViewController {

    private enum TableViewModelRow {
        case nameRow
        case statusRow
        case toggleStatusRow
        case tunnelRow(name: String, index: Int)
        case activeConnectionRow(field: ActiveConnectionField)
        case settingsRow(field: SettingsField)
        case onDemandRow
        case onDemandSSIDRow
        #if FAILOVER_TESTING
        case debugRow(action: DebugAction)
        #endif
        case spacerRow
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
            case .trafficTimeout: return "Traffic Timeout"
            case .healthCheckInterval: return "Health Check Interval"
            case .failbackProbeInterval: return "Failback Probe Interval"
            case .autoFailback: return "Auto Failback"
            case .confirmBeforeFailover: return "Confirm Before Failover"
            case .confirmationTimeout: return "Confirmation Timeout"
            case .linkDownHoldTime: return "Link-Down Hold"
            case .adaptiveSensitivity: return "Adaptive Sensitivity"
            case .pathChangeGrace: return "Path Change Grace"
            }
        }
    }

    private enum ConnectionStatus {
        case active
        case unhealthy
        case hotSpareReady
        case hotSpareWaiting
        case probing
        case idle

        var indicatorColor: NSColor {
            switch self {
            case .active, .hotSpareReady: return .systemGreen
            case .unhealthy, .hotSpareWaiting, .probing: return .systemYellow
            case .idle: return .systemGray
            }
        }

        var label: String {
            switch self {
            case .active: return "Active"
            case .unhealthy: return "Unhealthy"
            case .hotSpareReady: return "Standby"
            case .hotSpareWaiting: return "Connecting"
            case .probing: return "Probing"
            case .idle: return "Idle"
            }
        }
    }

    private enum ActiveConnectionField {
        case activeConfig
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
            case .activeConfig: return "Active Connection"
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

    #if FAILOVER_TESTING
    private enum DebugAction {
        case forceFailover
        case forceFailback
    }
    #endif

    private var tunnelNames: [String] = []
    private var settings = FailoverSettings()

    private var tableViewModelRows = [TableViewModelRow]()

    private var failoverEditVC: FailoverGroupEditViewController?
    private var failoverStateTimer: Timer?
    private var failoverState: [String: Any]?
    private var activeConfigName: String?

    override var tableColumnIdentifier: String { "FailoverGroupDetail" }

    override func loadView() {
        tableView.dataSource = self
        tableView.delegate = self
        super.loadView()
    }

    override func dismissEditSheet() {
        if let failoverEditVC = failoverEditVC {
            dismiss(failoverEditVC)
        }
    }

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

    override func rebuildTableViewModelRows() {
        var rows = [TableViewModelRow]()

        // Name + Status + Toggle
        rows.append(.nameRow)
        rows.append(.statusRow)
        rows.append(.toggleStatusRow)
        rows.append(.spacerRow)

        // Connections
        for (index, name) in tunnelNames.enumerated() {
            rows.append(.tunnelRow(name: name, index: index))
        }
        rows.append(.spacerRow)

        // Active Connection (when active)
        if tunnel.status == .active, let state = failoverState {
            let fields = computeVisibleActiveConnectionFields(from: state)
            if !fields.isEmpty {
                for field in fields {
                    rows.append(.activeConnectionRow(field: field))
                }
                rows.append(.spacerRow)
            }
        }

        // Settings
        for field in SettingsField.allCases {
            rows.append(.settingsRow(field: field))
        }
        rows.append(.spacerRow)

        // On-Demand
        rows.append(.onDemandRow)
        if onDemandViewModel.isWiFiInterfaceEnabled {
            rows.append(.onDemandSSIDRow)
        }

        #if FAILOVER_TESTING
        if tunnel.status == .active {
            rows.append(.spacerRow)
            rows.append(.debugRow(action: .forceFailover))
            rows.append(.debugRow(action: .forceFailback))
        }
        #endif

        tableViewModelRows = rows
    }

    @objc override func handleEditAction() {
        let editVC = FailoverGroupEditViewController(tunnelsManager: tunnelsManager, tunnel: tunnel)
        editVC.delegate = self
        presentAsSheet(editVC)
        self.failoverEditVC = editVC
    }

    override func memberTunnelName(forRow row: Int) -> String? {
        guard tableViewModelRows.indices.contains(row), case .tunnelRow(let name, _) = tableViewModelRows[row] else { return nil }
        return name
    }

    override func startPolling() { startPollingFailoverState() }
    override func stopPolling() { stopPollingFailoverState() }

    override func onStatusBecameInactive() {
        activeConfigName = nil
        failoverState = nil
        super.onStatusBecameInactive()
    }

    // MARK: - Failover State Polling

    private func startPollingFailoverState() {
        pollFailoverState()
        stopPollingFailoverState()
        failoverStateTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.pollFailoverState()
        }
    }

    private func stopPollingFailoverState() {
        failoverStateTimer?.invalidate()
        failoverStateTimer = nil
    }

    private func pollFailoverState() {
        tunnelsManager.getFailoverState(for: tunnel) { [weak self] state in
            guard let self = self, let state = state else { return }
            DispatchQueue.main.async {
                self.failoverState = state
                self.activeConfigName = state["activeConfig"] as? String
                self.rebuildTableViewModelRows()
                self.tableView.reloadData()
            }
        }
    }

    private func computeVisibleActiveConnectionFields(from state: [String: Any]) -> [ActiveConnectionField] {
        var fields = [ActiveConnectionField]()
        fields.append(.activeConfig)

        if let rx = state["rxBytes"] as? UInt64, rx > 0 {
            fields.append(.dataReceived)
        }
        if let tx = state["txBytes"] as? UInt64, tx > 0 {
            fields.append(.dataSent)
        }
        if state["lastHandshakeTime"] as? Double != nil {
            fields.append(.lastHandshake)
        }
        if let count = state["consecutiveCycles"] as? Int, count > 0 {
            fields.append(.failoverCount)
        }
        if state["lastSwitchTime"] as? Double != nil {
            fields.append(.lastFailover)
        }
        if state["txWithoutRxSince"] as? Double != nil {
            fields.append(.healthStatus)
        }
        if let probing = state["isProbing"] as? Bool, probing {
            fields.append(.failbackProbe)
        }
        if state["hotSpareConfigIndex"] as? Int != nil {
            fields.append(.hotSpare)
        }
        return fields
    }

    // MARK: - Per-Tunnel Status

    private func connectionStatus(forTunnelAt index: Int) -> ConnectionStatus {
        guard tunnel.status == .active, let state = failoverState else { return .idle }

        let name = tunnelNames[index]

        if let activeName = activeConfigName, activeName == name {
            if state["txWithoutRxSince"] as? Double != nil {
                return .unhealthy
            }
            return .active
        }

        if let hotSpareIndex = state["hotSpareConfigIndex"] as? Int, hotSpareIndex == index {
            if let age = state["hotSpareHandshakeAge"] as? Double, age < settings.trafficTimeout {
                return .hotSpareReady
            }
            let isActive = state["hotSpareActive"] as? Bool ?? false
            return isActive ? .hotSpareWaiting : .idle
        }

        if index == 0, let probing = state["isProbing"] as? Bool, probing {
            return .probing
        }

        return .idle
    }

    // MARK: - Active Connection Values

    private func activeConnectionValue(for field: ActiveConnectionField) -> String {
        guard let state = failoverState else { return "" }

        switch field {
        case .activeConfig:
            return activeConfigName ?? ""
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
                    return "Unhealthy, holding \(Int(Date().timeIntervalSince1970 - heldSince))s: no server reachable"
                }
                if state["confirmationProbeHandle"] as? Int != nil {
                    return "Unhealthy (\(duration)s), confirming next server…"
                }
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
                    if age < settings.trafficTimeout {
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

    // MARK: - Image Helper

    private static func image(for tunnel: TunnelContainer?) -> NSImage? {
        return TunnelListRow.image(for: tunnel)
    }
}

// MARK: - NSTableViewDataSource

extension FailoverGroupDetailTableViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        return tableViewModelRows.count
    }
}

// MARK: - NSTableViewDelegate

extension FailoverGroupDetailTableViewController: NSTableViewDelegate {
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
            return statusCell()

        case .toggleStatusRow:
            return toggleStatusCell()

        case .tunnelRow(let name, let index):
            let cell: KeyValueRow = tableView.dequeueReusableCell()
            let role = index == 0 ? "Primary" : "Failover #\(index)"
            let status = connectionStatus(forTunnelAt: index)
            let circle = NSAttributedString(string: "\u{25CF} ", attributes: [
                .foregroundColor: status.indicatorColor,
                .font: NSFont.systemFont(ofSize: 12)
            ])
            let nameAttr = NSAttributedString(string: name, attributes: [
                .foregroundColor: NSColor.labelColor,
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize)
            ])
            let combined = NSMutableAttributedString()
            combined.append(circle)
            combined.append(nameAttr)
            cell.keyLabel.attributedStringValue = combined
            cell.value = "\(role) · \(status.label)"
            cell.toolTip = "Double-click to open '\(name)'"
            return cell

        case .activeConnectionRow(let field):
            let cell: KeyValueRow = tableView.dequeueReusableCell()
            cell.key = tr(format: "macFieldKey (%@)", field.localizedUIString)
            cell.value = activeConnectionValue(for: field)
            cell.isKeyInBold = field == .activeConfig
            return cell

        case .settingsRow(let field):
            let cell: KeyValueRow = tableView.dequeueReusableCell()
            cell.key = tr(format: "macFieldKey (%@)", field.localizedUIString)
            switch field {
            case .trafficTimeout:
                cell.value = "\(Int(settings.trafficTimeout))s"
            case .healthCheckInterval:
                cell.value = "\(Int(settings.healthCheckInterval))s"
            case .failbackProbeInterval:
                cell.value = "\(Int(settings.failbackProbeInterval))s"
            case .autoFailback:
                cell.value = settings.autoFailback ? "Yes" : "No"
            case .confirmBeforeFailover:
                cell.value = settings.confirmBeforeFailover ? "Yes" : "No"
            case .confirmationTimeout:
                cell.value = "\(Int(settings.confirmationTimeout))s"
            case .linkDownHoldTime:
                cell.value = settings.linkDownHoldTime > 0 ? "\(Int(settings.linkDownHoldTime))s" : "Forever"
            case .adaptiveSensitivity:
                cell.value = settings.adaptiveSensitivity ? "Yes" : "No"
            case .pathChangeGrace:
                cell.value = "\(Int(settings.pathChangeGrace))s"
            }
            cell.isKeyInBold = false
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

        #if FAILOVER_TESTING
        case .debugRow(let action):
            let cell: ButtonRow = tableView.dequeueReusableCell()
            switch action {
            case .forceFailover:
                cell.buttonTitle = "Force Failover"
                cell.onButtonClicked = { [weak self] in
                    guard let self = self else { return }
                    self.tunnelsManager.debugForceFailover(for: self.tunnel) { success in
                        DispatchQueue.main.async {
                            if success { self.pollFailoverState() }
                        }
                    }
                }
            case .forceFailback:
                cell.buttonTitle = "Force Failback to Primary"
                cell.onButtonClicked = { [weak self] in
                    guard let self = self else { return }
                    self.tunnelsManager.debugForceFailback(for: self.tunnel) { success in
                        DispatchQueue.main.async {
                            if success { self.pollFailoverState() }
                        }
                    }
                }
            }
            return cell
        #endif

        case .spacerRow:
            return NSView()
        }
    }

    func statusCell() -> NSView {
        let cell: KeyValueImageRow = tableView.dequeueReusableCell()
        cell.key = tr(format: "macFieldKey (%@)", tr("tunnelInterfaceStatus"))
        cell.value = GroupDetailBaseViewController.localizedStatusDescription(for: tunnel)
        cell.valueImage = FailoverGroupDetailTableViewController.image(for: tunnel)
        let changeHandler: (TunnelContainer, Any) -> Void = { [weak cell] tunnel, _ in
            guard let cell = cell else { return }
            cell.value = GroupDetailBaseViewController.localizedStatusDescription(for: tunnel)
            cell.valueImage = FailoverGroupDetailTableViewController.image(for: tunnel)
        }
        cell.statusObservationToken = tunnel.observe(\.status, changeHandler: changeHandler)
        cell.isOnDemandEnabledObservationToken = tunnel.observe(\.isActivateOnDemandEnabled, changeHandler: changeHandler)
        cell.hasOnDemandRulesObservationToken = tunnel.observe(\.hasOnDemandRules, changeHandler: changeHandler)
        return cell
    }

    func toggleStatusCell() -> NSView {
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
    }
}

// MARK: - FailoverGroupEditViewControllerDelegate

extension FailoverGroupDetailTableViewController: FailoverGroupEditViewControllerDelegate {
    func failoverGroupSaved(tunnel: TunnelContainer) {
        handleGroupSaved()
        self.failoverEditVC = nil
    }

    func failoverGroupEditingCancelled() {
        self.failoverEditVC = nil
    }
}
