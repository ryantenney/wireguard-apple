// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.
// Copyright © 2026 Ryan Tenney.

import Cocoa
import NetworkExtension

protocol TunnelsListTableViewControllerDelegate: AnyObject {
    func tunnelsSelected(tunnelIndices: [Int])
    func failoverGroupSelected(at index: Int)
    func titGroupSelected(at index: Int)
    func tunnelsListEmpty()
}

class TunnelsListTableViewController: NSViewController {

    let tunnelsManager: TunnelsManager
    weak var delegate: TunnelsListTableViewControllerDelegate?
    var isRemovingTunnelsFromWithinTheApp = false

    private var failoverGroupCount: Int {
        return tunnelsManager.numberOfFailoverGroups()
    }

    private var titGroupCount: Int {
        return tunnelsManager.numberOfTiTGroups()
    }

    private var groupCount: Int {
        return failoverGroupCount + titGroupCount
    }

    let tableView: NSTableView = {
        let tableView = NSTableView()
        tableView.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("TunnelsList")))
        tableView.headerView = nil
        tableView.rowSizeStyle = .medium
        tableView.allowsMultipleSelection = true
        return tableView
    }()

    let addButton: NSPopUpButton = {
        let imageItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        imageItem.image = NSImage(named: NSImage.addTemplateName)!

        let menu = NSMenu()
        menu.addItem(imageItem)
        menu.addItem(withTitle: tr("macMenuAddEmptyTunnel"), action: #selector(handleAddEmptyTunnelAction), keyEquivalent: "n")
        menu.addItem(withTitle: "Create Failover Group", action: #selector(handleAddFailoverGroupAction), keyEquivalent: "")
        menu.addItem(withTitle: "Create Tunnel-in-Tunnel", action: #selector(handleAddTiTGroupAction), keyEquivalent: "")
        menu.addItem(withTitle: tr("macMenuImportTunnels"), action: #selector(handleImportTunnelAction), keyEquivalent: "o")
        menu.autoenablesItems = false

        let button = NSPopUpButton(frame: NSRect.zero, pullsDown: true)
        button.menu = menu
        button.bezelStyle = .smallSquare
        (button.cell as? NSPopUpButtonCell)?.arrowPosition = .arrowAtBottom
        return button
    }()

    let removeButton: NSButton = {
        let image = NSImage(named: NSImage.removeTemplateName)!
        let button = NSButton(image: image, target: self, action: #selector(handleRemoveTunnelAction))
        button.bezelStyle = .smallSquare
        button.imagePosition = .imageOnly
        return button
    }()

    let actionButton: NSPopUpButton = {
        let imageItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        imageItem.image = NSImage(named: NSImage.actionTemplateName)!

        let menu = NSMenu()
        menu.addItem(imageItem)
        menu.addItem(withTitle: tr("macMenuViewLog"), action: #selector(handleViewLogAction), keyEquivalent: "")
        menu.addItem(withTitle: tr("macMenuSessionHistory"), action: #selector(handleViewSessionHistoryAction), keyEquivalent: "")
        menu.addItem(withTitle: tr("macMenuExportTunnels"), action: #selector(handleExportTunnelsAction), keyEquivalent: "")
        menu.autoenablesItems = false

        let button = NSPopUpButton(frame: NSRect.zero, pullsDown: true)
        button.menu = menu
        button.bezelStyle = .smallSquare
        (button.cell as? NSPopUpButtonCell)?.arrowPosition = .arrowAtBottom
        return button
    }()

    init(tunnelsManager: TunnelsManager) {
        self.tunnelsManager = tunnelsManager
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        tableView.dataSource = self
        tableView.delegate = self

        tableView.doubleAction = #selector(listDoubleClicked(sender:))

        let isSelected = selectTunnelInOperation() || selectRow(at: 0)
        if !isSelected {
            delegate?.tunnelsListEmpty()
        }
        tableView.allowsEmptySelection = false

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder

        let clipView = NSClipView()
        clipView.documentView = tableView
        scrollView.contentView = clipView

        let buttonBar = NSStackView(views: [addButton, removeButton, actionButton])
        buttonBar.orientation = .horizontal
        buttonBar.spacing = -1

        NSLayoutConstraint.activate([
            removeButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 26),
            removeButton.topAnchor.constraint(equalTo: buttonBar.topAnchor),
            removeButton.bottomAnchor.constraint(equalTo: buttonBar.bottomAnchor)
        ])

        let fillerButton = FillerButton()

        let containerView = NSView()
        containerView.addSubview(scrollView)
        containerView.addSubview(buttonBar)
        containerView.addSubview(fillerButton)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        buttonBar.translatesAutoresizingMaskIntoConstraints = false
        fillerButton.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            containerView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            containerView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: buttonBar.topAnchor, constant: 1),
            containerView.leadingAnchor.constraint(equalTo: buttonBar.leadingAnchor),
            containerView.bottomAnchor.constraint(equalTo: buttonBar.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: fillerButton.topAnchor, constant: 1),
            containerView.bottomAnchor.constraint(equalTo: fillerButton.bottomAnchor),
            buttonBar.trailingAnchor.constraint(equalTo: fillerButton.leadingAnchor, constant: 1),
            fillerButton.trailingAnchor.constraint(equalTo: containerView.trailingAnchor)
        ])

        NSLayoutConstraint.activate([
            containerView.widthAnchor.constraint(equalToConstant: 180),
            containerView.heightAnchor.constraint(greaterThanOrEqualToConstant: 120)
        ])

        addButton.menu?.items.forEach { $0.target = self }
        actionButton.menu?.items.forEach { $0.target = self }

        view = containerView
    }

    override func viewWillAppear() {
        selectTunnelInOperation()
    }

    @discardableResult
    func selectTunnelInOperation() -> Bool {
        if let currentTunnel = tunnelsManager.tunnelInOperation() {
            if let groupIndex = tunnelsManager.failoverGroupIndex(of: currentTunnel) {
                return selectRow(at: groupIndex)
            }
            if let titIndex = tunnelsManager.titGroupIndex(of: currentTunnel) {
                return selectRow(at: failoverGroupCount + titIndex)
            }
            if let tunnelIndex = tunnelsManager.index(of: currentTunnel) {
                return selectRow(at: groupCount + tunnelIndex)
            }
        }
        return false
    }

    @objc func handleAddEmptyTunnelAction() {
        let tunnelEditVC = TunnelEditViewController(tunnelsManager: tunnelsManager, tunnel: nil)
        tunnelEditVC.delegate = self
        presentAsSheet(tunnelEditVC)
    }

    @objc func handleAddFailoverGroupAction() {
        let editVC = FailoverGroupEditViewController(tunnelsManager: tunnelsManager, tunnel: nil)
        editVC.delegate = self
        presentAsSheet(editVC)
    }

    @objc func handleAddTiTGroupAction() {
        let editVC = TunnelInTunnelEditViewController(tunnelsManager: tunnelsManager, tunnel: nil)
        editVC.delegate = self
        presentAsSheet(editVC)
    }

    @objc func handleImportTunnelAction() {
        ImportPanelPresenter.presentImportPanel(tunnelsManager: tunnelsManager, sourceVC: self)
    }

    @objc func handleRemoveTunnelAction() {
        guard let window = view.window else { return }
        let selectedRows = tableView.selectedRowIndexes.sorted()
        guard !selectedRows.isEmpty else { return }

        // Separate into failover group rows, TiT group rows, and tunnel rows
        let failoverIndices = selectedRows.filter { $0 < failoverGroupCount }
        let titIndices = selectedRows.filter { $0 >= failoverGroupCount && $0 < groupCount }.map { $0 - failoverGroupCount }
        let tunnelIndices = selectedRows.filter { $0 >= groupCount }.map { $0 - groupCount }

        // Handle failover group deletion
        if !failoverIndices.isEmpty && titIndices.isEmpty && tunnelIndices.isEmpty {
            let groupIndex = failoverIndices.first!
            let groupTunnel = tunnelsManager.failoverGroup(at: groupIndex)
            let alert = DeleteTunnelsConfirmationAlert()
            alert.messageText = "Are you sure you want to delete the failover group '\(groupTunnel.name)'?"
            alert.informativeText = "This won't delete the individual tunnels."
            alert.onDeleteClicked = { [weak self] completion in
                guard let self = self else { return }
                self.tunnelsManager.removeFailoverGroup(tunnel: groupTunnel) { error in
                    defer { completion() }
                    if let error = error {
                        ErrorPresenter.showErrorAlert(error: error, from: self)
                    }
                }
            }
            alert.beginSheetModal(for: window)
            return
        }

        // Handle TiT group deletion
        if !titIndices.isEmpty && failoverIndices.isEmpty && tunnelIndices.isEmpty {
            let titIndex = titIndices.first!
            let groupTunnel = tunnelsManager.titGroup(at: titIndex)
            let alert = DeleteTunnelsConfirmationAlert()
            alert.messageText = "Are you sure you want to delete the tunnel-in-tunnel group '\(groupTunnel.name)'?"
            alert.informativeText = "This won't delete the individual tunnels."
            alert.onDeleteClicked = { [weak self] completion in
                guard let self = self else { return }
                self.tunnelsManager.removeTiTGroup(tunnel: groupTunnel) { error in
                    defer { completion() }
                    if let error = error {
                        ErrorPresenter.showErrorAlert(error: error, from: self)
                    }
                }
            }
            alert.beginSheetModal(for: window)
            return
        }

        // Handle tunnel deletion (original logic, adjusted for offset)
        let selectedTunnelIndices = tunnelIndices.filter { $0 >= 0 && $0 < tunnelsManager.numberOfTunnels() }
        guard !selectedTunnelIndices.isEmpty else { return }
        var nextSelection = selectedTunnelIndices.last! + 1
        if nextSelection >= tunnelsManager.numberOfTunnels() {
            nextSelection = max(selectedTunnelIndices.first! - 1, 0)
        }

        let alert = DeleteTunnelsConfirmationAlert()
        if selectedTunnelIndices.count == 1 {
            let firstSelectedTunnel = tunnelsManager.tunnel(at: selectedTunnelIndices.first!)
            alert.messageText = tr(format: "macDeleteTunnelConfirmationAlertMessage (%@)", firstSelectedTunnel.name)
        } else {
            alert.messageText = tr(format: "macDeleteMultipleTunnelsConfirmationAlertMessage (%d)", selectedTunnelIndices.count)
        }
        alert.informativeText = tr("macDeleteTunnelConfirmationAlertInfo")
        alert.onDeleteClicked = { [weak self] completion in
            guard let self = self else { return }
            self.selectRow(at: self.groupCount + nextSelection)
            let selectedTunnels = selectedTunnelIndices.map { self.tunnelsManager.tunnel(at: $0) }
            self.isRemovingTunnelsFromWithinTheApp = true
            self.tunnelsManager.removeMultiple(tunnels: selectedTunnels) { [weak self] error in
                guard let self = self else { return }
                self.isRemovingTunnelsFromWithinTheApp = false
                defer { completion() }
                if let error = error {
                    ErrorPresenter.showErrorAlert(error: error, from: self)
                    return
                }
             }
        }
        alert.beginSheetModal(for: window)
    }

    @objc func handleViewLogAction() {
        let logVC = LogViewController()
        self.presentAsSheet(logVC)
    }

    @objc func handleViewSessionHistoryAction() {
        let historyVC = SessionHistoryViewController()
        self.presentAsSheet(historyVC)
    }

    @objc func handleExportTunnelsAction() {
        PrivateDataConfirmation.confirmAccess(to: tr("macExportPrivateData")) { [weak self] in
            guard let self = self else { return }
            guard let window = self.view.window else { return }
            let savePanel = NSSavePanel()
            savePanel.allowedFileTypes = ["zip"]
            savePanel.prompt = tr("macSheetButtonExportZip")
            savePanel.nameFieldLabel = tr("macNameFieldExportZip")
            savePanel.nameFieldStringValue = "wireguard-export.zip"
            let tunnelsManager = self.tunnelsManager
            savePanel.beginSheetModal(for: window) { [weak tunnelsManager] response in
                guard let tunnelsManager = tunnelsManager else { return }
                guard response == .OK else { return }
                guard let destinationURL = savePanel.url else { return }
                let count = tunnelsManager.numberOfTunnels()
                let tunnelConfigurations = (0 ..< count).compactMap { tunnelsManager.tunnel(at: $0).tunnelConfiguration }

                // Gather failover group configs for export
                var failoverGroups = [(name: String, config: String)]()
                for index in 0 ..< tunnelsManager.numberOfFailoverGroups() {
                    let groupTunnel = tunnelsManager.failoverGroup(at: index)
                    if let proto = groupTunnel.tunnelProvider.protocolConfiguration as? NETunnelProviderProtocol,
                       let providerConfig = proto.providerConfiguration,
                       let configString = FailoverGroupConfig.configString(from: providerConfig) {
                        failoverGroups.append((name: groupTunnel.name, config: configString))
                    }
                }

                // Gather tunnel-in-tunnel group configs for export. UI-created groups
                // live in NETunnelProviderManager providerConfiguration (not the
                // legacy tit-groups.json sidecar), so read them from the manager.
                var tunnelInTunnelGroups = [(name: String, config: String)]()
                for index in 0 ..< tunnelsManager.numberOfTiTGroups() {
                    let groupTunnel = tunnelsManager.titGroup(at: index)
                    if let proto = groupTunnel.tunnelProvider.protocolConfiguration as? NETunnelProviderProtocol,
                       let providerConfig = proto.providerConfiguration,
                       let configString = TunnelInTunnelGroupConfig.configString(from: providerConfig) {
                        tunnelInTunnelGroups.append((name: groupTunnel.name, config: configString))
                    }
                }

                ZipExporter.exportConfigFiles(tunnelConfigurations: tunnelConfigurations, failoverGroups: failoverGroups, tunnelInTunnelGroups: tunnelInTunnelGroups, to: destinationURL) { [weak self] error in
                    if let error = error {
                        ErrorPresenter.showErrorAlert(error: error, from: self)
                        return
                    }
                }
            }
        }
    }

    @objc func listDoubleClicked(sender: AnyObject) {
        let row = tableView.clickedRow
        guard row >= 0 else { return }

        let tunnel: TunnelContainer
        if row < failoverGroupCount {
            tunnel = tunnelsManager.failoverGroup(at: row)
        } else if row < groupCount {
            tunnel = tunnelsManager.titGroup(at: row - failoverGroupCount)
        } else {
            let tunnelIndex = row - groupCount
            guard tunnelIndex < tunnelsManager.numberOfTunnels() else { return }
            tunnel = tunnelsManager.tunnel(at: tunnelIndex)
        }

        if tunnel.hasOnDemandRules {
            let turnOn = !tunnel.isActivateOnDemandEnabled
            tunnelsManager.setOnDemandEnabled(turnOn, on: tunnel) { error in
                if error == nil && !turnOn {
                    self.tunnelsManager.startDeactivation(of: tunnel)
                }
            }
        } else {
            if tunnel.status == .inactive {
                tunnelsManager.startActivation(of: tunnel)
            } else if tunnel.status == .active {
                tunnelsManager.startDeactivation(of: tunnel)
            }
        }
    }

    @discardableResult
    private func selectRow(at index: Int) -> Bool {
        let totalRows = groupCount + tunnelsManager.numberOfTunnels()
        if index >= 0 && index < totalRows {
            tableView.scrollRowToVisible(index)
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            return true
        }
        return false
    }

    // Keep old name for compatibility but delegate to new name
    @discardableResult
    private func selectTunnel(at index: Int) -> Bool {
        return selectRow(at: groupCount + index)
    }
}

extension TunnelsListTableViewController: TunnelEditViewControllerDelegate {
    func tunnelSaved(tunnel: TunnelContainer) {
        if let tunnelIndex = tunnelsManager.index(of: tunnel), tunnelIndex >= 0 {
            self.selectTunnel(at: tunnelIndex)
        }
    }

    func tunnelEditingCancelled() {
        // Nothing to do
    }
}

extension TunnelsListTableViewController: FailoverGroupEditViewControllerDelegate {
    func failoverGroupSaved(tunnel: TunnelContainer) {
        if let groupIndex = tunnelsManager.failoverGroupIndex(of: tunnel) {
            selectRow(at: groupIndex)
        }
    }

    func failoverGroupEditingCancelled() {
        // Nothing to do
    }
}

extension TunnelsListTableViewController: TunnelInTunnelEditViewControllerDelegate {
    func titGroupSaved(tunnel: TunnelContainer) {
        if let titIndex = tunnelsManager.titGroupIndex(of: tunnel) {
            selectRow(at: failoverGroupCount + titIndex)
        }
    }

    func titGroupEditingCancelled() {
        // Nothing to do
    }
}

// MARK: - Tunnel list delegate methods (called by TunnelsTracker)

extension TunnelsListTableViewController {
    func tunnelAdded(at index: Int) {
        let row = groupCount + index
        tableView.insertRows(at: IndexSet(integer: row), withAnimation: .slideLeft)
        if tunnelsManager.numberOfTunnels() == 1 && groupCount == 0 {
            selectRow(at: row)
        }
        if !NSApp.isActive {
            // macOS's VPN prompt might have caused us to lose focus
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func tunnelModified(at index: Int) {
        let row = groupCount + index
        tableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
    }

    func tunnelMoved(from oldIndex: Int, to newIndex: Int) {
        let oldRow = groupCount + oldIndex
        let newRow = groupCount + newIndex
        tableView.moveRow(at: oldRow, to: newRow)
    }

    func tunnelRemoved(at index: Int) {
        let row = groupCount + index
        let selectedIndices = tableView.selectedRowIndexes
        let isSingleSelectedTunnelBeingRemoved = selectedIndices.contains(row) && selectedIndices.count == 1
        tableView.removeRows(at: IndexSet(integer: row), withAnimation: .slideLeft)
        let totalRows = groupCount + tunnelsManager.numberOfTunnels()
        if totalRows == 0 {
            delegate?.tunnelsListEmpty()
        } else if !isRemovingTunnelsFromWithinTheApp && isSingleSelectedTunnelBeingRemoved {
            let newSelection = min(row, totalRows - 1)
            tableView.selectRowIndexes(IndexSet(integer: newSelection), byExtendingSelection: false)
        }
    }
}

// MARK: - Failover group list delegate methods (called by TunnelsTracker)

extension TunnelsListTableViewController {
    func failoverGroupAdded(at index: Int) {
        tableView.insertRows(at: IndexSet(integer: index), withAnimation: .slideLeft)
        if failoverGroupCount == 1 && titGroupCount == 0 && tunnelsManager.numberOfTunnels() == 0 {
            selectRow(at: 0)
        }
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func failoverGroupModified(at index: Int) {
        tableView.reloadData(forRowIndexes: IndexSet(integer: index), columnIndexes: IndexSet(integer: 0))
    }

    func failoverGroupMoved(from oldIndex: Int, to newIndex: Int) {
        tableView.moveRow(at: oldIndex, to: newIndex)
    }

    func failoverGroupRemoved(at index: Int) {
        let selectedIndices = tableView.selectedRowIndexes
        let isSingleSelectedBeingRemoved = selectedIndices.contains(index) && selectedIndices.count == 1
        tableView.removeRows(at: IndexSet(integer: index), withAnimation: .slideLeft)
        let totalRows = groupCount + tunnelsManager.numberOfTunnels()
        if totalRows == 0 {
            delegate?.tunnelsListEmpty()
        } else if isSingleSelectedBeingRemoved {
            let newSelection = min(index, totalRows - 1)
            tableView.selectRowIndexes(IndexSet(integer: newSelection), byExtendingSelection: false)
        }
    }
}

// MARK: - TiT group list delegate methods

extension TunnelsListTableViewController {
    func titGroupAdded(at index: Int) {
        let row = failoverGroupCount + index
        tableView.insertRows(at: IndexSet(integer: row), withAnimation: .slideLeft)
        if titGroupCount == 1 && failoverGroupCount == 0 && tunnelsManager.numberOfTunnels() == 0 {
            selectRow(at: row)
        }
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func titGroupModified(at index: Int) {
        let row = failoverGroupCount + index
        tableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
    }

    func titGroupMoved(from oldIndex: Int, to newIndex: Int) {
        let oldRow = failoverGroupCount + oldIndex
        let newRow = failoverGroupCount + newIndex
        tableView.moveRow(at: oldRow, to: newRow)
    }

    func titGroupRemoved(at index: Int) {
        let row = failoverGroupCount + index
        let selectedIndices = tableView.selectedRowIndexes
        let isSingleSelectedBeingRemoved = selectedIndices.contains(row) && selectedIndices.count == 1
        tableView.removeRows(at: IndexSet(integer: row), withAnimation: .slideLeft)
        let totalRows = groupCount + tunnelsManager.numberOfTunnels()
        if totalRows == 0 {
            delegate?.tunnelsListEmpty()
        } else if isSingleSelectedBeingRemoved {
            let newSelection = min(row, totalRows - 1)
            tableView.selectRowIndexes(IndexSet(integer: newSelection), byExtendingSelection: false)
        }
    }
}

// MARK: - NSTableViewDataSource

extension TunnelsListTableViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        return groupCount + tunnelsManager.numberOfTunnels()
    }
}

// MARK: - NSTableViewDelegate

extension TunnelsListTableViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if row < failoverGroupCount {
            let cell: FailoverGroupListRow = tableView.dequeueReusableCell()
            cell.tunnel = tunnelsManager.failoverGroup(at: row)
            return cell
        } else if row < groupCount {
            let cell: FailoverGroupListRow = tableView.dequeueReusableCell()
            cell.tunnel = tunnelsManager.titGroup(at: row - failoverGroupCount)
            return cell
        } else {
            let cell: TunnelListRow = tableView.dequeueReusableCell()
            cell.tunnel = tunnelsManager.tunnel(at: row - groupCount)
            return cell
        }
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if row < groupCount {
            return 36  // Taller row to accommodate subtitle
        }
        return tableView.rowHeight
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let selectedRows = tableView.selectedRowIndexes.sorted()
        guard !selectedRows.isEmpty else { return }

        // If a single failover group is selected
        if selectedRows.count == 1 && selectedRows.first! < failoverGroupCount {
            delegate?.failoverGroupSelected(at: selectedRows.first!)
            return
        }

        // If a single TiT group is selected
        if selectedRows.count == 1 {
            let row = selectedRows.first!
            if row >= failoverGroupCount && row < groupCount {
                delegate?.titGroupSelected(at: row - failoverGroupCount)
                return
            }
        }

        // Otherwise, treat as tunnel selection (adjusted for offset)
        let tunnelIndices = selectedRows.filter { $0 >= groupCount }.map { $0 - groupCount }
        if !tunnelIndices.isEmpty {
            delegate?.tunnelsSelected(tunnelIndices: tunnelIndices)
        }
    }
}

// MARK: - Key handling

extension TunnelsListTableViewController {
    override func keyDown(with event: NSEvent) {
        if event.specialKey == .delete {
            handleRemoveTunnelAction()
        }
    }
}

extension TunnelsListTableViewController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(TunnelsListTableViewController.handleRemoveTunnelAction) {
            return !tableView.selectedRowIndexes.isEmpty
        }
        return true
    }
}

class FillerButton: NSButton {
    override var intrinsicContentSize: NSSize {
        return NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    init() {
        super.init(frame: CGRect.zero)
        title = ""
        bezelStyle = .smallSquare
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        // Eat mouseDown event, so that the button looks enabled but is unresponsive
    }
}
