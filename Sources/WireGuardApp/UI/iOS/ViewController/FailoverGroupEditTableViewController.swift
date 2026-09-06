// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import UIKit
import NetworkExtension

protocol FailoverGroupEditDelegate: AnyObject {
    func failoverGroupSaved(_ tunnel: TunnelContainer)
    func failoverGroupDeleted(_ tunnel: TunnelContainer)
}

class FailoverGroupEditTableViewController: UITableViewController {

    weak var delegate: FailoverGroupEditDelegate?

    private let tunnelsManager: TunnelsManager
    private var groupTunnel: TunnelContainer?
    private var isNewGroup: Bool

    // Editable state
    private var groupName: String
    private var selectedTunnelNames: [String]
    private var trafficTimeout: TimeInterval
    private var healthCheckInterval: TimeInterval
    private var failbackProbeInterval: TimeInterval
    private var autoFailback: Bool
    private var useBackgroundProbes: Bool
    private var hotSpare: Bool
    private var confirmBeforeFailover = true
    private var confirmationTimeout: TimeInterval = 15
    private var linkDownHoldTime: TimeInterval = 300
    private var adaptiveSensitivity = true
    private var pathChangeGrace: TimeInterval = 15
    private var persistentKeepaliveOverride: UInt16?

    // On-demand activation
    private var onDemandViewModel: ActivateOnDemandViewModel
    private let onDemandFields: [ActivateOnDemandViewModel.OnDemandField] = [.nonWiFiInterface, .wiFiInterface, .ssid]

    // All available tunnel names for selection
    private var availableTunnelNames: [String]

    private enum Section: Int, CaseIterable {
        case name
        case tunnels
        case addTunnel
        case settings
        case onDemand
        case delete
    }

    private enum SettingsRow: Int, CaseIterable {
        case trafficTimeout
        case healthCheckInterval
        case failbackProbeInterval
        case autoFailback
        case useBackgroundProbes
        case hotSpare
        case confirmBeforeFailover
        case confirmationTimeout
        case linkDownHoldTime
        case adaptiveSensitivity
        case pathChangeGrace
        case persistentKeepaliveToggle
        case persistentKeepaliveValue
    }

    init(tunnelsManager: TunnelsManager, groupTunnel: TunnelContainer? = nil) {
        self.tunnelsManager = tunnelsManager
        self.groupTunnel = groupTunnel
        self.isNewGroup = (groupTunnel == nil)

        if let groupTunnel = groupTunnel,
           let proto = groupTunnel.tunnelProvider.protocolConfiguration as? NETunnelProviderProtocol {
            let providerConfig = proto.providerConfiguration ?? [:]
            self.groupName = groupTunnel.name
            self.selectedTunnelNames = (providerConfig["FailoverConfigNames"] as? [String]) ?? []

            var settings = FailoverSettings()
            if let settingsData = providerConfig["FailoverSettings"] as? Data {
                settings = (try? JSONDecoder().decode(FailoverSettings.self, from: settingsData)) ?? FailoverSettings()
            }
            self.trafficTimeout = settings.trafficTimeout
            self.healthCheckInterval = settings.healthCheckInterval
            self.failbackProbeInterval = settings.failbackProbeInterval
            self.autoFailback = settings.autoFailback
            self.useBackgroundProbes = settings.useBackgroundProbes
            self.hotSpare = settings.hotSpare
            self.persistentKeepaliveOverride = settings.persistentKeepaliveOverride
            self.confirmBeforeFailover = settings.confirmBeforeFailover
            self.confirmationTimeout = settings.confirmationTimeout
            self.linkDownHoldTime = settings.linkDownHoldTime
            self.adaptiveSensitivity = settings.adaptiveSensitivity
            self.pathChangeGrace = settings.pathChangeGrace

            self.onDemandViewModel = ActivateOnDemandViewModel(tunnel: groupTunnel)
        } else {
            self.groupName = ""
            self.selectedTunnelNames = []
            self.trafficTimeout = 30
            self.healthCheckInterval = 10
            self.failbackProbeInterval = 300
            self.autoFailback = true
            self.useBackgroundProbes = true
            self.hotSpare = false
            self.persistentKeepaliveOverride = nil
            self.onDemandViewModel = ActivateOnDemandViewModel(from: OnDemandActivation())
        }

        self.availableTunnelNames = tunnelsManager.mapTunnels { $0.name }

        super.init(style: .grouped)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        title = isNewGroup ? "New Failover Group" : "Edit Failover Group"
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .save, target: self, action: #selector(saveTapped))
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancelTapped))

        tableView.register(EditableTextCell.self)
        tableView.register(CheckmarkCell.self)
        tableView.register(SwitchCell.self)
        tableView.register(KeyValueCell.self)
        tableView.register(ButtonCell.self)
        tableView.register(TextCell.self)
        tableView.register(ChevronCell.self)
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 44
        tableView.isEditing = true
        tableView.allowsSelectionDuringEditing = true
    }

    @objc private func saveTapped() {
        let trimmedName = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            showError("Please enter a name for the failover group.")
            return
        }
        guard selectedTunnelNames.count >= 2 else {
            showError("A failover group needs at least 2 tunnels.")
            return
        }

        let doSave = { [weak self] in
            guard let self = self else { return }
            let settings = FailoverSettings(
                trafficTimeout: self.trafficTimeout,
                healthCheckInterval: self.healthCheckInterval,
                failbackProbeInterval: self.failbackProbeInterval,
                autoFailback: self.autoFailback,
                useBackgroundProbes: self.useBackgroundProbes,
                hotSpare: self.hotSpare,
                persistentKeepaliveOverride: self.persistentKeepaliveOverride,
                confirmBeforeFailover: self.confirmBeforeFailover,
                confirmationTimeout: self.confirmationTimeout,
                linkDownHoldTime: self.linkDownHoldTime,
                adaptiveSensitivity: self.adaptiveSensitivity,
                pathChangeGrace: self.pathChangeGrace
            )
            self.onDemandViewModel.fixSSIDOption()
            let onDemandActivation = self.onDemandViewModel.toOnDemandActivation()

            if let existingTunnel = self.groupTunnel {
                self.tunnelsManager.modifyFailoverGroup(
                    tunnel: existingTunnel,
                    name: trimmedName,
                    tunnelNames: self.selectedTunnelNames,
                    settings: settings,
                    onDemandActivation: onDemandActivation
                ) { [weak self] error in
                    guard let self = self else { return }
                    if let error = error {
                        ErrorPresenter.showErrorAlert(error: error, from: self)
                        return
                    }
                    self.delegate?.failoverGroupSaved(existingTunnel)
                    self.dismiss(animated: true)
                }
            } else {
                self.tunnelsManager.addFailoverGroup(
                    name: trimmedName,
                    tunnelNames: self.selectedTunnelNames,
                    settings: settings,
                    onDemandActivation: onDemandActivation
                ) { [weak self] result in
                    guard let self = self else { return }
                    switch result {
                    case .failure(let error):
                        ErrorPresenter.showErrorAlert(error: error, from: self)
                    case .success(let newTunnel):
                        self.delegate?.failoverGroupSaved(newTunnel)
                        self.dismiss(animated: true)
                    }
                }
            }
        }

        doSave()
    }

    @objc private func cancelTapped() {
        dismiss(animated: true)
    }

    private func showError(_ message: String) {
        let alert = UIAlertController(title: "Error", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    // MARK: - UITableViewDataSource

    override func numberOfSections(in tableView: UITableView) -> Int {
        var count = Section.allCases.count
        if isNewGroup { count -= 1 } // No delete section for new groups
        return count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        guard let sectionType = Section(rawValue: section) else { return 0 }
        switch sectionType {
        case .name:
            return 1
        case .tunnels:
            return selectedTunnelNames.count
        case .addTunnel:
            return 1
        case .settings:
            return persistentKeepaliveOverride != nil ? SettingsRow.allCases.count : SettingsRow.allCases.count - 1
        case .onDemand:
            return onDemandViewModel.isWiFiInterfaceEnabled ? 3 : 2
        case .delete:
            return 1
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard let sectionType = Section(rawValue: section) else { return nil }
        switch sectionType {
        case .name:
            return "Name"
        case .tunnels:
            return "Connections (in priority order)"
        case .addTunnel:
            return nil
        case .settings:
            return "Failover Settings"
        case .onDemand:
            return "On-Demand Activation"
        case .delete:
            return nil
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard let sectionType = Section(rawValue: section) else { return nil }
        switch sectionType {
        case .tunnels:
            return "First tunnel is primary. Drag to reorder priority."
        case .settings:
            return "Failover triggers when the tunnel is sending data but not receiving any for the configured timeout. With confirmation on, the next server must handshake first; if no server answers the outage is treated as your link being down and failover is held (up to the link-down hold). Adaptive sensitivity lengthens the timeout after such false alarms."
        default:
            return nil
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let sectionType = Section(rawValue: indexPath.section) else {
            return UITableViewCell()
        }

        switch sectionType {
        case .name:
            let cell: EditableTextCell = tableView.dequeueReusableCell(for: indexPath)
            cell.message = groupName
            cell.placeholder = "Group Name"
            cell.onValueBeingEdited = { [weak self] newValue in
                self?.groupName = newValue
            }
            return cell

        case .tunnels:
            let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
            let name = selectedTunnelNames[indexPath.row]
            cell.textLabel?.text = name
            cell.detailTextLabel?.text = indexPath.row == 0 ? "Primary" : "Fallback #\(indexPath.row)"
            cell.detailTextLabel?.textColor = indexPath.row == 0 ? .systemBlue : .secondaryLabel
            cell.showsReorderControl = true
            return cell

        case .addTunnel:
            let cell: ButtonCell = tableView.dequeueReusableCell(for: indexPath)
            cell.buttonText = "Add Tunnel"
            return cell

        case .settings:
            guard let row = SettingsRow(rawValue: indexPath.row) else { return UITableViewCell() }
            switch row {
            case .trafficTimeout:
                let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
                cell.textLabel?.text = "Traffic Timeout"
                cell.detailTextLabel?.text = "\(Int(trafficTimeout))s"
                cell.accessoryType = .disclosureIndicator
                return cell
            case .healthCheckInterval:
                let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
                cell.textLabel?.text = "Health Check Interval"
                cell.detailTextLabel?.text = "\(Int(healthCheckInterval))s"
                cell.accessoryType = .disclosureIndicator
                return cell
            case .failbackProbeInterval:
                let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
                cell.textLabel?.text = "Failback Probe Interval"
                cell.detailTextLabel?.text = "\(Int(failbackProbeInterval))s"
                cell.accessoryType = .disclosureIndicator
                return cell
            case .autoFailback:
                let cell: SwitchCell = tableView.dequeueReusableCell(for: indexPath)
                cell.message = "Auto Failback"
                cell.isOn = autoFailback
                cell.onSwitchToggled = { [weak self] isOn in
                    self?.autoFailback = isOn
                }
                return cell
            case .useBackgroundProbes:
                let cell: SwitchCell = tableView.dequeueReusableCell(for: indexPath)
                cell.message = "Background Probes"
                cell.isOn = useBackgroundProbes
                cell.onSwitchToggled = { [weak self] isOn in
                    self?.useBackgroundProbes = isOn
                }
                return cell
            case .hotSpare:
                let cell: SwitchCell = tableView.dequeueReusableCell(for: indexPath)
                cell.message = "Hot Spare"
                cell.isOn = hotSpare
                cell.onSwitchToggled = { [weak self] isOn in
                    self?.hotSpare = isOn
                }
                return cell
            case .confirmBeforeFailover:
                let cell: SwitchCell = tableView.dequeueReusableCell(for: indexPath)
                cell.message = "Confirm Before Failover"
                cell.isOn = confirmBeforeFailover
                cell.onSwitchToggled = { [weak self] isOn in
                    self?.confirmBeforeFailover = isOn
                }
                return cell
            case .confirmationTimeout:
                let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
                cell.textLabel?.text = "Confirmation Timeout"
                cell.detailTextLabel?.text = "\(Int(confirmationTimeout))s"
                cell.accessoryType = .disclosureIndicator
                return cell
            case .linkDownHoldTime:
                let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
                cell.textLabel?.text = "Link-Down Hold"
                cell.detailTextLabel?.text = linkDownHoldTime > 0 ? "\(Int(linkDownHoldTime))s" : "Forever"
                cell.accessoryType = .disclosureIndicator
                return cell
            case .adaptiveSensitivity:
                let cell: SwitchCell = tableView.dequeueReusableCell(for: indexPath)
                cell.message = "Adaptive Sensitivity"
                cell.isOn = adaptiveSensitivity
                cell.onSwitchToggled = { [weak self] isOn in
                    self?.adaptiveSensitivity = isOn
                }
                return cell
            case .pathChangeGrace:
                let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
                cell.textLabel?.text = "Path Change Grace"
                cell.detailTextLabel?.text = "\(Int(pathChangeGrace))s"
                cell.accessoryType = .disclosureIndicator
                return cell
            case .persistentKeepaliveToggle:
                let cell: SwitchCell = tableView.dequeueReusableCell(for: indexPath)
                cell.message = "Override Persistent Keepalive"
                cell.isOn = persistentKeepaliveOverride != nil
                cell.onSwitchToggled = { [weak self] isOn in
                    guard let self = self else { return }
                    let hadOverride = self.persistentKeepaliveOverride != nil
                    self.persistentKeepaliveOverride = isOn ? 25 : nil
                    let valueIndexPath = IndexPath(row: SettingsRow.persistentKeepaliveValue.rawValue, section: Section.settings.rawValue)
                    if isOn && !hadOverride {
                        tableView.insertRows(at: [valueIndexPath], with: .fade)
                    } else if !isOn && hadOverride {
                        tableView.deleteRows(at: [valueIndexPath], with: .fade)
                    }
                }
                return cell
            case .persistentKeepaliveValue:
                let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
                cell.textLabel?.text = "Keepalive Interval"
                cell.detailTextLabel?.text = "\(persistentKeepaliveOverride ?? 25)s"
                cell.accessoryType = .disclosureIndicator
                return cell
            }

        case .onDemand:
            return onDemandCell(for: tableView, at: indexPath)

        case .delete:
            let cell: ButtonCell = tableView.dequeueReusableCell(for: indexPath)
            cell.buttonText = "Delete Failover Group"
            cell.hasDestructiveAction = true
            return cell
        }
    }

    private func onDemandCell(for tableView: UITableView, at indexPath: IndexPath) -> UITableViewCell {
        let field = onDemandFields[indexPath.row]
        if indexPath.row < 2 {
            let cell: SwitchCell = tableView.dequeueReusableCell(for: indexPath)
            cell.message = field.localizedUIString
            cell.isOn = onDemandViewModel.isEnabled(field: field)
            cell.onSwitchToggled = { [weak self] isOn in
                guard let self = self else { return }
                self.onDemandViewModel.setEnabled(field: field, isEnabled: isOn)
                let section = Section.onDemand.rawValue
                let indexPath = IndexPath(row: 2, section: section)
                if field == .wiFiInterface {
                    if isOn {
                        tableView.insertRows(at: [indexPath], with: .fade)
                    } else {
                        tableView.deleteRows(at: [indexPath], with: .fade)
                    }
                }
            }
            return cell
        } else {
            let cell: ChevronCell = tableView.dequeueReusableCell(for: indexPath)
            cell.message = field.localizedUIString
            cell.detailMessage = onDemandViewModel.localizedSSIDDescription
            return cell
        }
    }

    // MARK: - UITableViewDelegate

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)

        guard let sectionType = Section(rawValue: indexPath.section) else { return }

        if sectionType == .addTunnel {
            presentTunnelPicker()
        } else if sectionType == .settings {
            guard let row = SettingsRow(rawValue: indexPath.row),
                  ![.autoFailback, .useBackgroundProbes, .hotSpare, .confirmBeforeFailover, .adaptiveSensitivity, .persistentKeepaliveToggle].contains(row) else { return }
            if row == .persistentKeepaliveValue {
                presentKeepaliveEditor()
                return
            }
            presentValueEditor(for: row)
        } else if sectionType == .onDemand && indexPath.row == 2 {
            let ssidOptionVC = SSIDOptionEditTableViewController(option: onDemandViewModel.ssidOption, ssids: onDemandViewModel.selectedSSIDs)
            ssidOptionVC.delegate = self
            navigationController?.pushViewController(ssidOptionVC, animated: true)
        } else if sectionType == .delete {
            confirmDelete()
        }
    }

    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        guard let sectionType = Section(rawValue: indexPath.section) else { return false }
        return sectionType == .tunnels
    }

    override func tableView(_ tableView: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle {
        // Return .none to show reorder handles without delete buttons in editing mode.
        // Swipe-to-delete still works via trailingSwipeActionsConfigurationForRowAt.
        return .none
    }

    override func tableView(_ tableView: UITableView, shouldIndentWhileEditingRowAt indexPath: IndexPath) -> Bool {
        return false
    }

    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let sectionType = Section(rawValue: indexPath.section), sectionType == .tunnels else { return nil }
        let deleteAction = UIContextualAction(style: .destructive, title: "Remove") { [weak self] _, _, completionHandler in
            guard let self = self else { return }
            self.selectedTunnelNames.remove(at: indexPath.row)
            tableView.deleteRows(at: [indexPath], with: .automatic)
            let remaining = (0..<self.selectedTunnelNames.count).map { IndexPath(row: $0, section: Section.tunnels.rawValue) }
            tableView.reloadRows(at: remaining, with: .none)
            completionHandler(true)
        }
        return UISwipeActionsConfiguration(actions: [deleteAction])
    }

    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        if editingStyle == .delete {
            selectedTunnelNames.remove(at: indexPath.row)
            tableView.deleteRows(at: [indexPath], with: .automatic)
            // Reload remaining rows to update Primary/Fallback labels
            let remainingIndexPaths = (0..<selectedTunnelNames.count).map { IndexPath(row: $0, section: Section.tunnels.rawValue) }
            tableView.reloadRows(at: remainingIndexPaths, with: .none)
        }
    }

    override func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
        guard let sectionType = Section(rawValue: indexPath.section) else { return false }
        return sectionType == .tunnels
    }

    override func tableView(_ tableView: UITableView, moveRowAt sourceIndexPath: IndexPath, to destinationIndexPath: IndexPath) {
        let item = selectedTunnelNames.remove(at: sourceIndexPath.row)
        selectedTunnelNames.insert(item, at: destinationIndexPath.row)
        // Defer reload so it runs after the move animation completes;
        // calling reloadSections inside moveRowAt duplicates rows.
        DispatchQueue.main.async {
            let rows = (0..<self.selectedTunnelNames.count).map { IndexPath(row: $0, section: Section.tunnels.rawValue) }
            tableView.reloadRows(at: rows, with: .none)
        }
    }

    override func tableView(_ tableView: UITableView, targetIndexPathForMoveFromRowAt sourceIndexPath: IndexPath, toProposedIndexPath proposedDestinationIndexPath: IndexPath) -> IndexPath {
        // Constrain moves to the tunnels section
        if proposedDestinationIndexPath.section < Section.tunnels.rawValue {
            return IndexPath(row: 0, section: Section.tunnels.rawValue)
        } else if proposedDestinationIndexPath.section > Section.tunnels.rawValue {
            return IndexPath(row: selectedTunnelNames.count - 1, section: Section.tunnels.rawValue)
        }
        return proposedDestinationIndexPath
    }

    // MARK: - Tunnel Picker

    private func presentTunnelPicker() {
        let unusedTunnels = availableTunnelNames.filter { !selectedTunnelNames.contains($0) }
        guard !unusedTunnels.isEmpty else {
            showError("All available tunnels are already in this group.")
            return
        }

        let picker = TunnelPickerTableViewController(tunnelNames: unusedTunnels) { [weak self] selected in
            guard let self = self else { return }
            for name in selected {
                self.selectedTunnelNames.append(name)
            }
            self.tableView.reloadSections(IndexSet(integer: Section.tunnels.rawValue), with: .automatic)
        }
        navigationController?.pushViewController(picker, animated: true)
    }

    // MARK: - Settings Value Editor

    private func presentValueEditor(for row: SettingsRow) {
        let title: String
        let currentValue: Int
        switch row {
        case .trafficTimeout:
            title = "Traffic Timeout (seconds)"
            currentValue = Int(trafficTimeout)
        case .healthCheckInterval:
            title = "Health Check Interval (seconds)"
            currentValue = Int(healthCheckInterval)
        case .failbackProbeInterval:
            title = "Failback Probe Interval (seconds)"
            currentValue = Int(failbackProbeInterval)
        case .confirmationTimeout:
            title = "Confirmation Timeout (seconds)"
            currentValue = Int(confirmationTimeout)
        case .linkDownHoldTime:
            title = "Link-Down Hold (seconds, 0 = forever)"
            currentValue = Int(linkDownHoldTime)
        case .pathChangeGrace:
            title = "Path Change Grace (seconds)"
            currentValue = Int(pathChangeGrace)
        case .autoFailback, .useBackgroundProbes, .hotSpare, .confirmBeforeFailover, .adaptiveSensitivity, .persistentKeepaliveToggle, .persistentKeepaliveValue:
            return
        }

        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        alert.addTextField { textField in
            textField.text = "\(currentValue)"
            textField.keyboardType = .numberPad
        }
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self, weak alert] _ in
            guard let self = self,
                  let text = alert?.textFields?.first?.text,
                  let value = Int(text), value >= 0, value > 0 || row == .linkDownHoldTime || row == .pathChangeGrace else { return }
            switch row {
            case .trafficTimeout:
                self.trafficTimeout = TimeInterval(value)
            case .healthCheckInterval:
                self.healthCheckInterval = TimeInterval(value)
            case .failbackProbeInterval:
                self.failbackProbeInterval = TimeInterval(value)
            case .confirmationTimeout:
                self.confirmationTimeout = TimeInterval(value)
            case .linkDownHoldTime:
                self.linkDownHoldTime = TimeInterval(value)
            case .pathChangeGrace:
                self.pathChangeGrace = TimeInterval(value)
            case .autoFailback, .useBackgroundProbes, .hotSpare, .confirmBeforeFailover, .adaptiveSensitivity, .persistentKeepaliveToggle, .persistentKeepaliveValue:
                break
            }
            self.tableView.reloadSections(IndexSet(integer: Section.settings.rawValue), with: .none)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    // MARK: - Keepalive Value Editor

    private func presentKeepaliveEditor() {
        let currentValue = Int(persistentKeepaliveOverride ?? 25)
        let alert = UIAlertController(title: "Keepalive Interval (seconds)", message: nil, preferredStyle: .alert)
        alert.addTextField { textField in
            textField.text = "\(currentValue)"
            textField.keyboardType = .numberPad
        }
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self, weak alert] _ in
            guard let self = self,
                  let text = alert?.textFields?.first?.text,
                  let value = UInt16(text), value > 0 else { return }
            self.persistentKeepaliveOverride = value
            self.tableView.reloadSections(IndexSet(integer: Section.settings.rawValue), with: .none)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    // MARK: - Delete

    private func confirmDelete() {
        guard let groupTunnel = groupTunnel else { return }
        let alert = UIAlertController(
            title: "Delete Failover Group",
            message: "Are you sure you want to delete '\(groupTunnel.name)'? This won't delete the individual tunnels.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            guard let self = self else { return }
            self.tunnelsManager.removeFailoverGroup(tunnel: groupTunnel) { [weak self] error in
                guard let self = self else { return }
                if let error = error {
                    ErrorPresenter.showErrorAlert(error: error, from: self)
                    return
                }
                self.delegate?.failoverGroupDeleted(groupTunnel)
                self.dismiss(animated: true)
            }
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }
}

// MARK: - SSIDOptionEditTableViewControllerDelegate

extension FailoverGroupEditTableViewController: SSIDOptionEditTableViewControllerDelegate {
    func ssidOptionSaved(option: ActivateOnDemandViewModel.OnDemandSSIDOption, ssids: [String]) {
        onDemandViewModel.selectedSSIDs = ssids
        onDemandViewModel.ssidOption = option
        onDemandViewModel.fixSSIDOption()
        let onDemandSection = Section.onDemand.rawValue
        if let ssidRowIndex = onDemandFields.firstIndex(of: .ssid) {
            let indexPath = IndexPath(row: ssidRowIndex, section: onDemandSection)
            tableView.reloadRows(at: [indexPath], with: .none)
        }
    }
}

// MARK: - Tunnel Picker

class TunnelPickerTableViewController: UITableViewController {

    private let tunnelNames: [String]
    private var selectedNames: Set<String> = []
    private let onSelection: ([String]) -> Void

    init(tunnelNames: [String], onSelection: @escaping ([String]) -> Void) {
        self.tunnelNames = tunnelNames
        self.onSelection = onSelection
        super.init(style: .grouped)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Add Tunnels"
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Add", style: .done, target: self, action: #selector(addTapped))
        updateAddButton()
    }

    @objc private func addTapped() {
        let ordered = tunnelNames.filter { selectedNames.contains($0) }
        onSelection(ordered)
        navigationController?.popViewController(animated: true)
    }

    private func updateAddButton() {
        navigationItem.rightBarButtonItem?.isEnabled = !selectedNames.isEmpty
        if !selectedNames.isEmpty {
            navigationItem.rightBarButtonItem?.title = "Add (\(selectedNames.count))"
        } else {
            navigationItem.rightBarButtonItem?.title = "Add"
        }
    }

    // MARK: - Data Source

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return tunnelNames.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let name = tunnelNames[indexPath.row]
        let cell = UITableViewCell(style: .default, reuseIdentifier: "TunnelPickerCell")
        cell.textLabel?.text = name
        cell.accessoryType = selectedNames.contains(name) ? .checkmark : .none
        return cell
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        return "Tap to select tunnels, then press Add."
    }

    // MARK: - Delegate

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let name = tunnelNames[indexPath.row]
        if selectedNames.contains(name) {
            selectedNames.remove(name)
        } else {
            selectedNames.insert(name)
        }
        tableView.reloadRows(at: [indexPath], with: .none)
        updateAddButton()
    }
}
