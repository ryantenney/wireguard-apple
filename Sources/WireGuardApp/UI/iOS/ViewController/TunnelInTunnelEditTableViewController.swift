// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import UIKit
import NetworkExtension

class TunnelInTunnelEditTableViewController: UITableViewController {

    weak var delegate: TunnelInTunnelEditDelegate?

    private let tunnelsManager: TunnelsManager
    private var groupTunnel: TunnelContainer?
    private var isNewGroup: Bool

    // Editable state
    private var groupName: String
    private var outerTunnelName: String
    private var innerTunnelName: String

    // On-demand activation
    private var onDemandViewModel: ActivateOnDemandViewModel
    private let onDemandFields: [ActivateOnDemandViewModel.OnDemandField] = [.nonWiFiInterface, .wiFiInterface, .ssid]

    // All available tunnel names
    private var availableTunnelNames: [String]

    private enum Section: Int, CaseIterable {
        case name
        case outerTunnel
        case innerTunnel
        case onDemand
        case delete
    }

    init(tunnelsManager: TunnelsManager, groupTunnel: TunnelContainer? = nil) {
        self.tunnelsManager = tunnelsManager
        self.groupTunnel = groupTunnel
        self.isNewGroup = (groupTunnel == nil)

        if let groupTunnel = groupTunnel,
           let proto = groupTunnel.tunnelProvider.protocolConfiguration as? NETunnelProviderProtocol {
            let providerConfig = proto.providerConfiguration ?? [:]
            self.groupName = groupTunnel.name
            self.outerTunnelName = (providerConfig[ProviderConfigurationKeys.titOuterName] as? String) ?? ""
            self.innerTunnelName = (providerConfig[ProviderConfigurationKeys.titInnerName] as? String) ?? ""
            self.onDemandViewModel = ActivateOnDemandViewModel(tunnel: groupTunnel)
        } else {
            self.groupName = ""
            self.outerTunnelName = ""
            self.innerTunnelName = ""
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

        title = isNewGroup ? "New Tunnel-in-Tunnel" : "Edit Tunnel-in-Tunnel"
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .save, target: self, action: #selector(saveTapped))
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancelTapped))

        tableView.register(EditableTextCell.self)
        tableView.register(SwitchCell.self)
        tableView.register(KeyValueCell.self)
        tableView.register(ButtonCell.self)
        tableView.register(ChevronCell.self)
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 44
        tableView.allowsSelectionDuringEditing = true
    }

    @objc private func saveTapped() {
        let trimmedName = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            showError("Please enter a name for the tunnel-in-tunnel group.")
            return
        }
        guard !outerTunnelName.isEmpty else {
            showError("Please select an outer tunnel.")
            return
        }
        guard !innerTunnelName.isEmpty else {
            showError("Please select an inner tunnel.")
            return
        }
        guard outerTunnelName != innerTunnelName else {
            showError("Outer and inner tunnels must be different.")
            return
        }

        onDemandViewModel.fixSSIDOption()
        let onDemandActivation = onDemandViewModel.toOnDemandActivation()

        if let existingTunnel = groupTunnel {
            tunnelsManager.modifyTiTGroup(
                tunnel: existingTunnel,
                name: trimmedName,
                outerTunnelName: outerTunnelName,
                innerTunnelName: innerTunnelName,
                onDemandActivation: onDemandActivation
            ) { [weak self] error in
                guard let self = self else { return }
                if let error = error {
                    ErrorPresenter.showErrorAlert(error: error, from: self)
                    return
                }
                self.delegate?.titGroupSaved(existingTunnel)
                self.dismiss(animated: true)
            }
        } else {
            tunnelsManager.addTiTGroup(
                name: trimmedName,
                outerTunnelName: outerTunnelName,
                innerTunnelName: innerTunnelName,
                onDemandActivation: onDemandActivation
            ) { [weak self] result in
                guard let self = self else { return }
                switch result {
                case .failure(let error):
                    ErrorPresenter.showErrorAlert(error: error, from: self)
                case .success(let newTunnel):
                    self.delegate?.titGroupSaved(newTunnel)
                    self.dismiss(animated: true)
                }
            }
        }
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
        case .outerTunnel:
            return 1
        case .innerTunnel:
            return 1
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
        case .outerTunnel:
            return "Outer Tunnel (Server A)"
        case .innerTunnel:
            return "Inner Tunnel (Server B)"
        case .onDemand:
            return "On-Demand Activation"
        case .delete:
            return nil
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard let sectionType = Section(rawValue: section) else { return nil }
        switch sectionType {
        case .outerTunnel:
            return "Traffic is encrypted first by the inner tunnel, then by the outer tunnel before reaching the network."
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

        case .outerTunnel:
            let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
            cell.textLabel?.text = outerTunnelName.isEmpty ? "Select Tunnel..." : outerTunnelName
            cell.textLabel?.textColor = outerTunnelName.isEmpty ? .placeholderText : .label
            cell.accessoryType = .disclosureIndicator
            return cell

        case .innerTunnel:
            let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
            cell.textLabel?.text = innerTunnelName.isEmpty ? "Select Tunnel..." : innerTunnelName
            cell.textLabel?.textColor = innerTunnelName.isEmpty ? .placeholderText : .label
            cell.accessoryType = .disclosureIndicator
            return cell

        case .onDemand:
            return onDemandCell(for: tableView, at: indexPath)

        case .delete:
            let cell: ButtonCell = tableView.dequeueReusableCell(for: indexPath)
            cell.buttonText = "Delete Tunnel-in-Tunnel Group"
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

        switch sectionType {
        case .outerTunnel:
            presentTunnelPicker(excluding: innerTunnelName) { [weak self] selected in
                guard let self = self else { return }
                self.outerTunnelName = selected
                self.tableView.reloadSections(IndexSet(integer: Section.outerTunnel.rawValue), with: .none)
            }
        case .innerTunnel:
            presentTunnelPicker(excluding: outerTunnelName) { [weak self] selected in
                guard let self = self else { return }
                self.innerTunnelName = selected
                self.tableView.reloadSections(IndexSet(integer: Section.innerTunnel.rawValue), with: .none)
            }
        case .onDemand:
            if indexPath.row == 2 {
                let ssidOptionVC = SSIDOptionEditTableViewController(option: onDemandViewModel.ssidOption, ssids: onDemandViewModel.selectedSSIDs)
                ssidOptionVC.delegate = self
                navigationController?.pushViewController(ssidOptionVC, animated: true)
            }
        case .delete:
            confirmDelete()
        default:
            break
        }
    }

    // MARK: - Tunnel Picker

    private func presentTunnelPicker(excluding: String, onSelection: @escaping (String) -> Void) {
        let tunnels = availableTunnelNames.filter { $0 != excluding }
        guard !tunnels.isEmpty else {
            showError("No available tunnels.")
            return
        }

        let picker = SingleTunnelPickerTableViewController(tunnelNames: tunnels, onSelection: onSelection)
        navigationController?.pushViewController(picker, animated: true)
    }

    // MARK: - Delete

    private func confirmDelete() {
        guard let groupTunnel = groupTunnel else { return }
        let alert = UIAlertController(
            title: "Delete Tunnel-in-Tunnel Group",
            message: "Are you sure you want to delete '\(groupTunnel.name)'? This won't delete the individual tunnels.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            guard let self = self else { return }
            self.tunnelsManager.removeTiTGroup(tunnel: groupTunnel) { [weak self] error in
                guard let self = self else { return }
                if let error = error {
                    ErrorPresenter.showErrorAlert(error: error, from: self)
                    return
                }
                self.delegate?.titGroupDeleted(groupTunnel)
                self.dismiss(animated: true)
            }
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }
}

// MARK: - SSIDOptionEditTableViewControllerDelegate

extension TunnelInTunnelEditTableViewController: SSIDOptionEditTableViewControllerDelegate {
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

// MARK: - Single Tunnel Picker

class SingleTunnelPickerTableViewController: UITableViewController {

    private let tunnelNames: [String]
    private let onSelection: (String) -> Void

    init(tunnelNames: [String], onSelection: @escaping (String) -> Void) {
        self.tunnelNames = tunnelNames
        self.onSelection = onSelection
        super.init(style: .grouped)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Select Tunnel"
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return tunnelNames.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: "SingleTunnelPickerCell")
        cell.textLabel?.text = tunnelNames[indexPath.row]
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        onSelection(tunnelNames[indexPath.row])
        navigationController?.popViewController(animated: true)
    }
}
