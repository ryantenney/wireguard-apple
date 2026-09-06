// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

import UIKit

protocol TunnelEditTableViewControllerDelegate: AnyObject {
    func tunnelSaved(tunnel: TunnelContainer)
    func tunnelEditingCancelled()
}

class TunnelEditTableViewController: UITableViewController {
    private enum Section {
        case interface
        case peer(_ peer: TunnelViewModel.PeerData)
        case addPeer
        case onDemand

        static func == (lhs: Section, rhs: Section) -> Bool {
            switch (lhs, rhs) {
            case (.interface, .interface),
                 (.addPeer, .addPeer),
                 (.onDemand, .onDemand):
                return true
            case let (.peer(peerA), .peer(peerB)):
                return peerA.index == peerB.index
            default:
                return false
            }
        }
    }

    private enum PeerEditRow {
        case field(TunnelViewModel.PeerField)
        case allowedIPsRadio(AllowedIPsPreset)
        case excludePrivateIPs
        case allowedIPsChip(index: Int)
        case allowedIPsAddRange
    }

    weak var delegate: TunnelEditTableViewControllerDelegate?

    let interfaceFieldsBySection: [[TunnelViewModel.InterfaceField]] = [
        [.name],
        [.privateKey, .publicKey, .generateKeyPair],
        [.addresses, .listenPort, .mtu, .dns],
        [.excludedIPs, .excludeLocalNetwork]
    ]

    let peerFields: [TunnelViewModel.PeerField] = [
        .publicKey, .preSharedKey, .endpoint,
        .allowedIPs, .excludePrivateIPs, .persistentKeepAlive,
        .deletePeer
    ]

    let onDemandFields: [ActivateOnDemandViewModel.OnDemandField] = [
        .nonWiFiInterface,
        .wiFiInterface,
        .ssid
    ]

    let tunnelsManager: TunnelsManager
    let tunnel: TunnelContainer?
    let tunnelViewModel: TunnelViewModel
    var onDemandViewModel: ActivateOnDemandViewModel
    private var sections = [Section]()

    private var allowedIPsEditorState: AllowedIPsEditorState?

    private var isSinglePeer: Bool {
        return tunnelViewModel.peersData.count == 1
    }

    // Use this initializer to edit an existing tunnel.
    init(tunnelsManager: TunnelsManager, tunnel: TunnelContainer) {
        self.tunnelsManager = tunnelsManager
        self.tunnel = tunnel
        tunnelViewModel = TunnelViewModel(tunnelConfiguration: tunnel.tunnelConfiguration)
        onDemandViewModel = ActivateOnDemandViewModel(tunnel: tunnel)
        super.init(style: .grouped)
        loadSections()
        updateAllowedIPsEditorState()
    }

    // Use this initializer to create a new tunnel.
    init(tunnelsManager: TunnelsManager) {
        self.tunnelsManager = tunnelsManager
        tunnel = nil
        tunnelViewModel = TunnelViewModel(tunnelConfiguration: nil)
        onDemandViewModel = ActivateOnDemandViewModel()
        super.init(style: .grouped)
        loadSections()
        updateAllowedIPsEditorState()
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = tunnel == nil ? tr("newTunnelViewTitle") : tr("editTunnelViewTitle")
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .save, target: self, action: #selector(saveTapped))
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancelTapped))

        tableView.estimatedRowHeight = 44
        tableView.rowHeight = UITableView.automaticDimension

        tableView.register(TunnelEditKeyValueCell.self)
        tableView.register(TunnelEditEditableKeyValueCell.self)
        tableView.register(ButtonCell.self)
        tableView.register(SwitchCell.self)
        tableView.register(CheckmarkCell.self)
        tableView.register(ChevronCell.self)
    }

    private func loadSections() {
        sections.removeAll()
        interfaceFieldsBySection.forEach { _ in sections.append(.interface) }
        tunnelViewModel.peersData.forEach { sections.append(.peer($0)) }
        sections.append(.addPeer)
        sections.append(.onDemand)
    }

    private func updateAllowedIPsEditorState() {
        if isSinglePeer, let peerData = tunnelViewModel.peersData.first {
            allowedIPsEditorState = AllowedIPsEditorState(peerData: peerData, tunnelViewModel: tunnelViewModel)
        } else {
            allowedIPsEditorState = nil
        }
    }

    private func peerEditRows(for peerData: TunnelViewModel.PeerData) -> [PeerEditRow] {
        guard isSinglePeer, let editorState = allowedIPsEditorState else {
            // Multi-peer: use flat field list
            let peerFieldsToShow = peerData.shouldAllowExcludePrivateIPsControl ? peerFields : peerFields.filter { $0 != .excludePrivateIPs }
            return peerFieldsToShow.map { .field($0) }
        }

        var rows: [PeerEditRow] = [
            .field(.publicKey),
            .field(.preSharedKey),
            .field(.endpoint)
        ]

        // Radio buttons
        for preset in AllowedIPsPreset.allCases {
            rows.append(.allowedIPsRadio(preset))
        }

        // Exclude Private IPs toggle (only for non-custom presets)
        if !editorState.isCustom {
            rows.append(.excludePrivateIPs)
        }

        // Chip rows for each range
        for i in 0..<editorState.ranges.count {
            rows.append(.allowedIPsChip(index: i))
        }

        // Add range button (only in custom mode)
        if editorState.isCustom {
            rows.append(.allowedIPsAddRange)
        }

        rows.append(.field(.persistentKeepAlive))
        rows.append(.field(.deletePeer))

        return rows
    }

    @objc func saveTapped() {
        tableView.endEditing(false)
        let tunnelSaveResult = tunnelViewModel.save()
        switch tunnelSaveResult {
        case .error(let errorMessage):
            let alertTitle = (tunnelViewModel.interfaceData.validatedConfiguration == nil || tunnelViewModel.interfaceData.validatedName == nil) ?
                tr("alertInvalidInterfaceTitle") : tr("alertInvalidPeerTitle")
            ErrorPresenter.showErrorAlert(title: alertTitle, message: errorMessage, from: self)
            tableView.reloadData() // Highlight erroring fields
        case .saved(let tunnelConfiguration):
            let onDemandOption = onDemandViewModel.toOnDemandOption()
            if let tunnel = tunnel {
                // We're modifying an existing tunnel
                tunnelsManager.modify(tunnel: tunnel, tunnelConfiguration: tunnelConfiguration, onDemandOption: onDemandOption) { [weak self] error in
                    if let error = error {
                        ErrorPresenter.showErrorAlert(error: error, from: self)
                    } else {
                        self?.dismiss(animated: true, completion: nil)
                        self?.delegate?.tunnelSaved(tunnel: tunnel)
                    }
                }
            } else {
                // We're adding a new tunnel
                tunnelsManager.add(tunnelConfiguration: tunnelConfiguration, onDemandOption: onDemandOption) { [weak self] result in
                    switch result {
                    case .failure(let error):
                        ErrorPresenter.showErrorAlert(error: error, from: self)
                    case .success(let tunnel):
                        self?.dismiss(animated: true, completion: nil)
                        self?.delegate?.tunnelSaved(tunnel: tunnel)
                    }
                }
            }
        }
    }

    @objc func cancelTapped() {
        dismiss(animated: true, completion: nil)
        delegate?.tunnelEditingCancelled()
    }
}

// MARK: UITableViewDataSource

extension TunnelEditTableViewController {
    override func numberOfSections(in tableView: UITableView) -> Int {
        return sections.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch sections[section] {
        case .interface:
            return interfaceFieldsBySection[section].count
        case .peer(let peerData):
            return peerEditRows(for: peerData).count
        case .addPeer:
            return 1
        case .onDemand:
            if onDemandViewModel.isWiFiInterfaceEnabled {
                return 3
            } else {
                return 2
            }
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch sections[section] {
        case .interface:
            if section == 0 {
                return tr("tunnelSectionTitleInterface")
            }
            return interfaceFieldsBySection[section].contains(.excludedIPs) ? tr("tunnelSectionTitleBypass") : nil
        case .peer:
            return tr("tunnelSectionTitlePeer")
        case .addPeer:
            return nil
        case .onDemand:
            return tr("tunnelSectionTitleOnDemand")
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if case .interface = sections[section], interfaceFieldsBySection[section].contains(.excludedIPs) {
            return tr("tunnelSectionFooterBypass")
        }
        return nil
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch sections[indexPath.section] {
        case .interface:
            return interfaceFieldCell(for: tableView, at: indexPath)
        case .peer(let peerData):
            return peerCell(for: tableView, at: indexPath, with: peerData)
        case .addPeer:
            return addPeerCell(for: tableView, at: indexPath)
        case .onDemand:
            return onDemandCell(for: tableView, at: indexPath)
        }
    }

    private func interfaceFieldCell(for tableView: UITableView, at indexPath: IndexPath) -> UITableViewCell {
        let field = interfaceFieldsBySection[indexPath.section][indexPath.row]
        switch field {
        case .generateKeyPair:
            return generateKeyPairCell(for: tableView, at: indexPath, with: field)
        case .publicKey:
            return publicKeyCell(for: tableView, at: indexPath, with: field)
        case .excludeLocalNetwork:
            return excludeLocalNetworkCell(for: tableView, at: indexPath, with: field)
        default:
            return interfaceFieldKeyValueCell(for: tableView, at: indexPath, with: field)
        }
    }

    private func excludeLocalNetworkCell(for tableView: UITableView, at indexPath: IndexPath, with field: TunnelViewModel.InterfaceField) -> UITableViewCell {
        let cell: SwitchCell = tableView.dequeueReusableCell(for: indexPath)
        cell.message = field.localizedUIString
        cell.isEnabled = true
        cell.isOn = tunnelViewModel.interfaceData[field] == TunnelViewModel.excludeLocalNetworkOnValue
        cell.onSwitchToggled = { [weak self] isOn in
            self?.tunnelViewModel.interfaceData[field] = isOn ? TunnelViewModel.excludeLocalNetworkOnValue : ""
        }
        return cell
    }

    private func generateKeyPairCell(for tableView: UITableView, at indexPath: IndexPath, with field: TunnelViewModel.InterfaceField) -> UITableViewCell {
        let cell: ButtonCell = tableView.dequeueReusableCell(for: indexPath)
        cell.buttonText = field.localizedUIString
        cell.onTapped = { [weak self] in
            guard let self = self else { return }

            self.tunnelViewModel.interfaceData[.privateKey] = PrivateKey().base64Key
            if let privateKeyRow = self.interfaceFieldsBySection[indexPath.section].firstIndex(of: .privateKey),
                let publicKeyRow = self.interfaceFieldsBySection[indexPath.section].firstIndex(of: .publicKey) {
                let privateKeyIndex = IndexPath(row: privateKeyRow, section: indexPath.section)
                let publicKeyIndex = IndexPath(row: publicKeyRow, section: indexPath.section)
                self.tableView.reloadRows(at: [privateKeyIndex, publicKeyIndex], with: .fade)
            }
        }
        return cell
    }

    private func publicKeyCell(for tableView: UITableView, at indexPath: IndexPath, with field: TunnelViewModel.InterfaceField) -> UITableViewCell {
        let cell: TunnelEditKeyValueCell = tableView.dequeueReusableCell(for: indexPath)
        cell.key = field.localizedUIString
        cell.value = tunnelViewModel.interfaceData[field]
        return cell
    }

    private func interfaceFieldKeyValueCell(for tableView: UITableView, at indexPath: IndexPath, with field: TunnelViewModel.InterfaceField) -> UITableViewCell {
        let cell: TunnelEditEditableKeyValueCell = tableView.dequeueReusableCell(for: indexPath)
        cell.key = field.localizedUIString

        switch field {
        case .name, .privateKey:
            cell.placeholderText = tr("tunnelEditPlaceholderTextRequired")
            cell.keyboardType = .default
        case .addresses:
            cell.placeholderText = tr("tunnelEditPlaceholderTextStronglyRecommended")
            cell.keyboardType = .numbersAndPunctuation
        case .dns:
            cell.placeholderText = tunnelViewModel.peersData.contains(where: { $0.shouldStronglyRecommendDNS }) ? tr("tunnelEditPlaceholderTextStronglyRecommended") : tr("tunnelEditPlaceholderTextOptional")
            cell.keyboardType = .numbersAndPunctuation
        case .listenPort, .mtu:
            cell.placeholderText = tr("tunnelEditPlaceholderTextAutomatic")
            cell.keyboardType = .numberPad
        case .excludedIPs:
            cell.placeholderText = tr("tunnelEditPlaceholderTextOptional")
            cell.keyboardType = .numbersAndPunctuation
        case .publicKey, .generateKeyPair:
            cell.keyboardType = .default
        case .status, .toggleStatus, .excludeLocalNetwork:
            fatalError("Unexpected interface field")
        }

        cell.isValueValid = (!tunnelViewModel.interfaceData.fieldsWithError.contains(field))
        // Bind values to view model
        cell.value = tunnelViewModel.interfaceData[field]
        if field == .dns { // While editing DNS, you might directly set exclude private IPs
            cell.onValueBeingEdited = { [weak self] value in
                self?.tunnelViewModel.interfaceData[field] = value
            }
            cell.onValueChanged = { [weak self] oldValue, newValue in
                guard let self = self else { return }
                let isAllowedIPsChanged = self.tunnelViewModel.updateDNSServersInAllowedIPsIfRequired(oldDNSServers: oldValue, newDNSServers: newValue)
                if isAllowedIPsChanged {
                    let peerSection = self.sections.firstIndex { if case .peer = $0 { return true } else { return false } }
                    if let section = peerSection {
                        if self.isSinglePeer, let peerData = self.tunnelViewModel.peersData.first {
                            // Refresh editor state and reload chip rows
                            self.allowedIPsEditorState = AllowedIPsEditorState(peerData: peerData, tunnelViewModel: self.tunnelViewModel)
                            self.tableView.reloadSections(IndexSet(integer: section), with: .none)
                        } else if let row = self.peerFields.firstIndex(of: .allowedIPs) {
                            self.tableView.reloadRows(at: [IndexPath(row: row, section: section)], with: .none)
                        }
                    }
                }
            }
        } else {
            cell.onValueChanged = { [weak self] _, value in
                self?.tunnelViewModel.interfaceData[field] = value
            }
        }
        // Compute public key live
        if field == .privateKey {
            cell.onValueBeingEdited = { [weak self] value in
                guard let self = self else { return }

                self.tunnelViewModel.interfaceData[.privateKey] = value
                if let row = self.interfaceFieldsBySection[indexPath.section].firstIndex(of: .publicKey) {
                    self.tableView.reloadRows(at: [IndexPath(row: row, section: indexPath.section)], with: .none)
                }
            }
        }
        return cell
    }

    private func peerCell(for tableView: UITableView, at indexPath: IndexPath, with peerData: TunnelViewModel.PeerData) -> UITableViewCell {
        let rows = peerEditRows(for: peerData)
        let row = rows[indexPath.row]

        switch row {
        case .field(let field):
            switch field {
            case .deletePeer:
                return deletePeerCell(for: tableView, at: indexPath, peerData: peerData, field: field)
            case .excludePrivateIPs:
                return excludePrivateIPsCell(for: tableView, at: indexPath, peerData: peerData, field: field)
            default:
                return peerFieldKeyValueCell(for: tableView, at: indexPath, peerData: peerData, field: field)
            }
        case .allowedIPsRadio(let preset):
            return allowedIPsRadioCell(for: tableView, at: indexPath, preset: preset)
        case .excludePrivateIPs:
            return allowedIPsExcludePrivateIPsCell(for: tableView, at: indexPath, peerData: peerData)
        case .allowedIPsChip(let index):
            return allowedIPsChipCell(for: tableView, at: indexPath, rangeIndex: index)
        case .allowedIPsAddRange:
            return allowedIPsAddRangeCell(for: tableView, at: indexPath)
        }
    }

    private func deletePeerCell(for tableView: UITableView, at indexPath: IndexPath, peerData: TunnelViewModel.PeerData, field: TunnelViewModel.PeerField) -> UITableViewCell {
        let cell: ButtonCell = tableView.dequeueReusableCell(for: indexPath)
        cell.buttonText = field.localizedUIString
        cell.hasDestructiveAction = true
        cell.onTapped = { [weak self, weak peerData] in
            guard let self = self, let peerData = peerData else { return }
            ConfirmationAlertPresenter.showConfirmationAlert(message: tr("deletePeerConfirmationAlertMessage"),
                                                             buttonTitle: tr("deletePeerConfirmationAlertButtonTitle"),
                                                             from: cell, presentingVC: self) { [weak self] in
                guard let self = self else { return }
                let wasMultiPeer = !self.isSinglePeer
                let removedSectionIndices = self.deletePeer(peer: peerData)
                self.updateAllowedIPsEditorState()

                // swiftlint:disable:next trailing_closure
                tableView.performBatchUpdates({
                    self.tableView.deleteSections(removedSectionIndices, with: .fade)
                    if wasMultiPeer && self.isSinglePeer {
                        // Reload remaining peer section — editor expands from raw text field
                        let firstPeerSection = self.interfaceFieldsBySection.count
                        self.tableView.reloadSections(IndexSet(integer: firstPeerSection), with: .fade)
                    }
                })
            }
        }
        return cell
    }

    private func excludePrivateIPsCell(for tableView: UITableView, at indexPath: IndexPath, peerData: TunnelViewModel.PeerData, field: TunnelViewModel.PeerField) -> UITableViewCell {
        let cell: SwitchCell = tableView.dequeueReusableCell(for: indexPath)
        cell.message = field.localizedUIString
        cell.isEnabled = peerData.shouldAllowExcludePrivateIPsControl
        cell.isOn = peerData.excludePrivateIPsValue
        cell.onSwitchToggled = { [weak self] isOn in
            guard let self = self else { return }
            peerData.excludePrivateIPsValueChanged(isOn: isOn, dnsServers: self.tunnelViewModel.interfaceData[.dns])
            if let row = self.peerFields.firstIndex(of: .allowedIPs) {
                self.tableView.reloadRows(at: [IndexPath(row: row, section: indexPath.section)], with: .none)
            }
        }
        return cell
    }

    private func allowedIPsRadioCell(for tableView: UITableView, at indexPath: IndexPath, preset: AllowedIPsPreset) -> UITableViewCell {
        let cell: CheckmarkCell = tableView.dequeueReusableCell(for: indexPath)
        switch preset {
        case .routeAll:
            cell.message = tr("allowedIPsPresetRouteAll")
        case .routeIPv4Only:
            cell.message = tr("allowedIPsPresetRouteIPv4Only")
        case .custom:
            cell.message = tr("allowedIPsPresetCustom")
        }
        cell.isChecked = allowedIPsEditorState?.preset == preset
        return cell
    }

    private func allowedIPsExcludePrivateIPsCell(for tableView: UITableView, at indexPath: IndexPath, peerData: TunnelViewModel.PeerData) -> UITableViewCell {
        let cell: SwitchCell = tableView.dequeueReusableCell(for: indexPath)
        cell.message = TunnelViewModel.PeerField.excludePrivateIPs.localizedUIString
        cell.isEnabled = true
        cell.isOn = allowedIPsEditorState?.excludePrivateIPs ?? false
        cell.onSwitchToggled = { [weak self] isOn in
            guard let self = self, let editorState = self.allowedIPsEditorState else { return }
            let oldRangeCount = editorState.ranges.count
            editorState.setExcludePrivateIPs(isOn)
            let newRangeCount = editorState.ranges.count
            self.reloadChipRows(in: indexPath.section, oldCount: oldRangeCount, newCount: newRangeCount)
        }
        return cell
    }

    private func allowedIPsChipCell(for tableView: UITableView, at indexPath: IndexPath, rangeIndex: Int) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        if let editorState = allowedIPsEditorState, rangeIndex < editorState.ranges.count {
            cell.textLabel?.text = editorState.ranges[rangeIndex]
        }
        cell.textLabel?.font = UIFont.monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize, weight: .regular)
        cell.textLabel?.textColor = .secondaryLabel
        cell.selectionStyle = .none
        return cell
    }

    private func allowedIPsAddRangeCell(for tableView: UITableView, at indexPath: IndexPath) -> UITableViewCell {
        let cell: ButtonCell = tableView.dequeueReusableCell(for: indexPath)
        cell.buttonText = tr("allowedIPsAddRange")
        cell.onTapped = { [weak self] in
            self?.presentAddRangeAlert()
        }
        return cell
    }

    private func presentAddRangeAlert() {
        let alert = UIAlertController(title: tr("allowedIPsAddRangeTitle"), message: nil, preferredStyle: .alert)
        alert.addTextField { textField in
            textField.placeholder = tr("allowedIPsAddRangePlaceholder")
            textField.keyboardType = .numbersAndPunctuation
        }
        alert.addAction(UIAlertAction(title: tr("actionCancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: tr("actionSave"), style: .default) { [weak self] _ in
            guard let self = self, let editorState = self.allowedIPsEditorState else { return }
            guard let text = alert.textFields?.first?.text else { return }
            let peerSection = self.sections.firstIndex { if case .peer = $0 { return true } else { return false } }
            guard let section = peerSection else { return }
            if editorState.addRange(text) {
                let rows = self.peerEditRows(for: self.tunnelViewModel.peersData[0])
                // The new chip is inserted before the add-range button
                let newChipRow = rows.count - 3 // before addRange row, persistentKeepAlive, deletePeer
                self.tableView.insertRows(at: [IndexPath(row: newChipRow, section: section)], with: .automatic)
            } else {
                let errorAlert = UIAlertController(title: tr("allowedIPsAddRangeInvalid"), message: nil, preferredStyle: .alert)
                errorAlert.addAction(UIAlertAction(title: tr("actionOK"), style: .default))
                self.present(errorAlert, animated: true)
            }
        })
        present(alert, animated: true)
    }

    private func reloadChipRows(in section: Int, oldCount: Int, newCount: Int) {
        tableView.reloadSections(IndexSet(integer: section), with: .automatic)
    }

    private func peerFieldKeyValueCell(for tableView: UITableView, at indexPath: IndexPath, peerData: TunnelViewModel.PeerData, field: TunnelViewModel.PeerField) -> UITableViewCell {
        let cell: TunnelEditEditableKeyValueCell = tableView.dequeueReusableCell(for: indexPath)
        cell.key = field.localizedUIString

        switch field {
        case .publicKey:
            cell.placeholderText = tr("tunnelEditPlaceholderTextRequired")
            cell.keyboardType = .default
        case .preSharedKey, .endpoint:
            cell.placeholderText = tr("tunnelEditPlaceholderTextOptional")
            cell.keyboardType = .default
        case .allowedIPs:
            cell.placeholderText = tr("tunnelEditPlaceholderTextOptional")
            cell.keyboardType = .numbersAndPunctuation
        case .persistentKeepAlive:
            cell.placeholderText = tr("tunnelEditPlaceholderTextOff")
            cell.keyboardType = .numberPad
        case .excludePrivateIPs, .deletePeer:
            cell.keyboardType = .default
        case .rxBytes, .txBytes, .lastHandshakeTime:
            fatalError()
        }

        cell.isValueValid = !peerData.fieldsWithError.contains(field)
        cell.value = peerData[field]

        if field == .allowedIPs {
            let firstInterfaceSection = sections.firstIndex { $0 == .interface }!
            let interfaceSubSection = interfaceFieldsBySection.firstIndex { $0.contains(.dns) }!
            let dnsRow = interfaceFieldsBySection[interfaceSubSection].firstIndex { $0 == .dns }!

            cell.onValueBeingEdited = { [weak self, weak peerData] value in
                guard let self = self, let peerData = peerData else { return }

                let oldValue = peerData.shouldAllowExcludePrivateIPsControl
                peerData[.allowedIPs] = value
                if oldValue != peerData.shouldAllowExcludePrivateIPsControl, let row = self.peerFields.firstIndex(of: .excludePrivateIPs) {
                    if peerData.shouldAllowExcludePrivateIPsControl {
                        self.tableView.insertRows(at: [IndexPath(row: row, section: indexPath.section)], with: .fade)
                    } else {
                        self.tableView.deleteRows(at: [IndexPath(row: row, section: indexPath.section)], with: .fade)
                    }
                }

                tableView.reloadRows(at: [IndexPath(row: dnsRow, section: firstInterfaceSection + interfaceSubSection)], with: .none)
            }
        } else {
            cell.onValueChanged = { [weak peerData] _, value in
                peerData?[field] = value
            }
        }

        return cell
    }

    private func addPeerCell(for tableView: UITableView, at indexPath: IndexPath) -> UITableViewCell {
        let cell: ButtonCell = tableView.dequeueReusableCell(for: indexPath)
        cell.buttonText = tr("addPeerButtonTitle")
        cell.onTapped = { [weak self] in
            guard let self = self else { return }
            let wasSinglePeer = self.isSinglePeer
            let addedSectionIndices = self.appendEmptyPeer()
            self.updateAllowedIPsEditorState()
            tableView.performBatchUpdates({
                tableView.insertSections(addedSectionIndices, with: .fade)
                if wasSinglePeer {
                    // Reload first peer section — editor collapses to raw text field
                    let firstPeerSection = self.interfaceFieldsBySection.count
                    tableView.reloadSections(IndexSet(integer: firstPeerSection), with: .fade)
                }
            }, completion: nil)
        }
        return cell
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
                let section = self.sections.firstIndex { $0 == .onDemand }!
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

    func appendEmptyPeer() -> IndexSet {
        tunnelViewModel.appendEmptyPeer()
        loadSections()
        let addedPeerIndex = tunnelViewModel.peersData.count - 1
        return IndexSet(integer: interfaceFieldsBySection.count + addedPeerIndex)
    }

    func deletePeer(peer: TunnelViewModel.PeerData) -> IndexSet {
        tunnelViewModel.deletePeer(peer: peer)
        loadSections()
        return IndexSet(integer: interfaceFieldsBySection.count + peer.index)
    }
}

extension TunnelEditTableViewController {
    override func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        switch sections[indexPath.section] {
        case .peer(let peerData):
            let rows = peerEditRows(for: peerData)
            let row = rows[indexPath.row]
            switch row {
            case .allowedIPsRadio:
                return indexPath
            default:
                return nil
            }
        case .onDemand:
            if indexPath.row == 2 {
                return indexPath
            }
            return nil
        default:
            return nil
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        switch sections[indexPath.section] {
        case .peer(let peerData):
            let rows = peerEditRows(for: peerData)
            let row = rows[indexPath.row]
            if case .allowedIPsRadio(let preset) = row {
                tableView.deselectRow(at: indexPath, animated: true)
                handlePresetSelection(preset, in: indexPath.section, peerData: peerData)
            }
        case .onDemand:
            assert(indexPath.row == 2)
            tableView.deselectRow(at: indexPath, animated: true)
            let ssidOptionVC = SSIDOptionEditTableViewController(option: onDemandViewModel.ssidOption, ssids: onDemandViewModel.selectedSSIDs)
            ssidOptionVC.delegate = self
            navigationController?.pushViewController(ssidOptionVC, animated: true)
        default:
            break
        }
    }

    private func handlePresetSelection(_ preset: AllowedIPsPreset, in section: Int, peerData: TunnelViewModel.PeerData) {
        guard let editorState = allowedIPsEditorState else { return }
        let oldPreset = editorState.preset
        guard preset != oldPreset else { return }

        let oldRows = peerEditRows(for: peerData)
        editorState.selectPreset(preset)
        let newRows = peerEditRows(for: peerData)

        tableView.beginUpdates()

        // Compute index paths to delete (old rows not in new)
        var deleteIndexPaths = [IndexPath]()
        var insertIndexPaths = [IndexPath]()

        // Find ranges of dynamic rows in old and new
        for (i, row) in oldRows.enumerated() {
            switch row {
            case .excludePrivateIPs, .allowedIPsChip, .allowedIPsAddRange:
                deleteIndexPaths.append(IndexPath(row: i, section: section))
            default:
                break
            }
        }
        for (i, row) in newRows.enumerated() {
            switch row {
            case .excludePrivateIPs, .allowedIPsChip, .allowedIPsAddRange:
                insertIndexPaths.append(IndexPath(row: i, section: section))
            default:
                break
            }
        }

        tableView.deleteRows(at: deleteIndexPaths, with: .fade)
        tableView.insertRows(at: insertIndexPaths, with: .fade)

        // Reload radio rows to update checkmarks
        let radioIndexPaths = newRows.enumerated().compactMap { (i, row) -> IndexPath? in
            if case .allowedIPsRadio = row { return IndexPath(row: i, section: section) }
            return nil
        }
        tableView.reloadRows(at: radioIndexPaths, with: .none)

        tableView.endUpdates()
    }

    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        guard case .peer(let peerData) = sections[indexPath.section] else { return false }
        guard let editorState = allowedIPsEditorState, editorState.isCustom else { return false }
        let rows = peerEditRows(for: peerData)
        if case .allowedIPsChip = rows[indexPath.row] {
            return true
        }
        return false
    }

    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete else { return }
        guard let editorState = allowedIPsEditorState else { return }
        guard case .peer(let peerData) = sections[indexPath.section] else { return }
        let rows = peerEditRows(for: peerData)
        if case .allowedIPsChip(let rangeIndex) = rows[indexPath.row] {
            editorState.removeRange(at: rangeIndex)
            // Reload the entire section since chip indices shift
            tableView.reloadSections(IndexSet(integer: indexPath.section), with: .automatic)
        }
    }
}

extension TunnelEditTableViewController: SSIDOptionEditTableViewControllerDelegate {
    func ssidOptionSaved(option: ActivateOnDemandViewModel.OnDemandSSIDOption, ssids: [String]) {
        onDemandViewModel.selectedSSIDs = ssids
        onDemandViewModel.ssidOption = option
        onDemandViewModel.fixSSIDOption()
        if let onDemandSection = sections.firstIndex(where: { $0 == .onDemand }) {
            if let ssidRowIndex = onDemandFields.firstIndex(of: .ssid) {
                let indexPath = IndexPath(row: ssidRowIndex, section: onDemandSection)
                tableView.reloadRows(at: [indexPath], with: .none)
            }
        }
    }
}
