// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.
// Copyright © 2026 Ryan Tenney.

import UIKit
import MobileCoreServices
import UserNotifications

class TunnelsListTableViewController: UIViewController {

    var tunnelsManager: TunnelsManager?

    enum TableState: Equatable {
        case normal
        case rowSwiped
        case multiSelect(selectionCount: Int)
    }

    enum ListSection: Int, CaseIterable {
        case failoverGroups = 0
        case titGroups = 1
        case tunnels = 2
    }

    // Failover state polling for the active config name display
    private var failoverStateTimer: Timer?
    private var failoverStateConfigNames: [String: String] = [:] // groupId -> activeConfigName

    // Deferred presentation of Map Home at launch, until the view is in a window
    private var pendingMapHomeAtLaunch = false

    let tableView: UITableView = {
        let tableView = UITableView(frame: CGRect.zero, style: .grouped)
        tableView.estimatedRowHeight = 60
        tableView.rowHeight = UITableView.automaticDimension
        tableView.separatorStyle = .none
        tableView.register(TunnelListCell.self)
        tableView.register(FailoverGroupCell.self)
        return tableView
    }()

    let centeredAddButton: BorderedTextButton = {
        let button = BorderedTextButton()
        button.title = tr("tunnelsListCenteredAddTunnelButtonTitle")
        button.isHidden = true
        return button
    }()

    let busyIndicator: UIActivityIndicatorView = {
        let busyIndicator: UIActivityIndicatorView
        busyIndicator = UIActivityIndicatorView(style: .medium)
        busyIndicator.hidesWhenStopped = true
        return busyIndicator
    }()

    var detailDisplayedTunnel: TunnelContainer?
    var tableState: TableState = .normal {
        didSet {
            handleTableStateChange()
        }
    }

    override func loadView() {
        view = UIView()
        view.backgroundColor = .systemBackground

        tableView.dataSource = self
        tableView.delegate = self

        view.addSubview(tableView)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        view.addSubview(busyIndicator)
        busyIndicator.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            busyIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            busyIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])

        view.addSubview(centeredAddButton)
        centeredAddButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            centeredAddButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            centeredAddButton.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])

        centeredAddButton.onTapped = { [weak self] in
            guard let self = self else { return }
            self.addButtonTapped(sender: self.centeredAddButton)
        }

        busyIndicator.startAnimating()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        tableState = .normal
        restorationIdentifier = "TunnelsListVC"
    }

    func handleTableStateChange() {
        switch tableState {
        case .normal:
            let addItem = UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(addButtonTapped(sender:)))
            let mapItem = UIBarButtonItem(image: UIImage(systemName: "globe.americas.fill"), style: .plain, target: self, action: #selector(mapHomeButtonTapped))
            navigationItem.rightBarButtonItems = [addItem, mapItem]
            navigationItem.leftBarButtonItem = UIBarButtonItem(title: tr("tunnelsListSettingsButtonTitle"), style: .plain, target: self, action: #selector(settingsButtonTapped(sender:)))
        case .rowSwiped:
            navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(doneButtonTapped))
            navigationItem.leftBarButtonItem = UIBarButtonItem(title: tr("tunnelsListSelectButtonTitle"), style: .plain, target: self, action: #selector(selectButtonTapped))
        case .multiSelect(let selectionCount):
            if selectionCount > 0 {
                navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancelButtonTapped))
                navigationItem.leftBarButtonItem = UIBarButtonItem(title: tr("tunnelsListDeleteButtonTitle"), style: .plain, target: self, action: #selector(deleteButtonTapped(sender:)))
            } else {
                navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancelButtonTapped))
                navigationItem.leftBarButtonItem = UIBarButtonItem(title: tr("tunnelsListSelectAllButtonTitle"), style: .plain, target: self, action: #selector(selectAllButtonTapped))
            }
        }
        if case .multiSelect(let selectionCount) = tableState, selectionCount > 0 {
            navigationItem.title = tr(format: "tunnelsListSelectedTitle (%d)", selectionCount)
        } else {
            navigationItem.title = tr("tunnelsListTitle")
        }
        if case .multiSelect = tableState {
            tableView.allowsMultipleSelectionDuringEditing = true
        } else {
            tableView.allowsMultipleSelectionDuringEditing = false
        }
    }

    func setTunnelsManager(tunnelsManager: TunnelsManager) {
        self.tunnelsManager = tunnelsManager
        tunnelsManager.tunnelsListDelegate = self
        tunnelsManager.groupListDelegate = self

        busyIndicator.stopAnimating()
        tableView.reloadData()
        centeredAddButton.isHidden = (tunnelsManager.numberOfTunnels() > 0 || tunnelsManager.numberOfFailoverGroups() > 0 || tunnelsManager.numberOfTiTGroups() > 0)

        startPollingFailoverState()
    }

    override func viewWillAppear(_: Bool) {
        if let selectedRowIndexPath = tableView.indexPathForSelectedRow {
            tableView.deselectRow(at: selectedRowIndexPath, animated: false)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if pendingMapHomeAtLaunch {
            pendingMapHomeAtLaunch = false
            presentMapHome(animated: false)
        }
    }

    @objc func addButtonTapped(sender: AnyObject) {
        guard tunnelsManager != nil else { return }

        let alert = UIAlertController(title: "", message: tr("addTunnelMenuHeader"), preferredStyle: .actionSheet)
        let importFileAction = UIAlertAction(title: tr("addTunnelMenuImportFile"), style: .default) { [weak self] _ in
            self?.presentViewControllerForFileImport()
        }
        alert.addAction(importFileAction)

        let scanQRCodeAction = UIAlertAction(title: tr("addTunnelMenuQRCode"), style: .default) { [weak self] _ in
            self?.presentViewControllerForScanningQRCode()
        }
        alert.addAction(scanQRCodeAction)

        let createFromScratchAction = UIAlertAction(title: tr("addTunnelMenuFromScratch"), style: .default) { [weak self] _ in
            if let self = self, let tunnelsManager = self.tunnelsManager {
                self.presentViewControllerForTunnelCreation(tunnelsManager: tunnelsManager)
            }
        }
        alert.addAction(createFromScratchAction)

        let createFailoverGroupAction = UIAlertAction(title: "Create Failover Group", style: .default) { [weak self] _ in
            if let self = self, let tunnelsManager = self.tunnelsManager {
                self.presentFailoverGroupEditor(tunnelsManager: tunnelsManager)
            }
        }
        alert.addAction(createFailoverGroupAction)

        let createTiTGroupAction = UIAlertAction(title: "Create Tunnel-in-Tunnel", style: .default) { [weak self] _ in
            if let self = self, let tunnelsManager = self.tunnelsManager {
                self.presentTiTGroupEditor(tunnelsManager: tunnelsManager)
            }
        }
        alert.addAction(createTiTGroupAction)

        let cancelAction = UIAlertAction(title: tr("actionCancel"), style: .cancel)
        alert.addAction(cancelAction)

        if let sender = sender as? UIBarButtonItem {
            alert.popoverPresentationController?.barButtonItem = sender
        } else if let sender = sender as? UIView {
            alert.popoverPresentationController?.sourceView = sender
            alert.popoverPresentationController?.sourceRect = sender.bounds
        }
        present(alert, animated: true, completion: nil)
    }

    @objc func settingsButtonTapped(sender: UIBarButtonItem) {
        guard tunnelsManager != nil else { return }

        let settingsVC = SettingsTableViewController(tunnelsManager: tunnelsManager)
        let settingsNC = UINavigationController(rootViewController: settingsVC)
        settingsNC.modalPresentationStyle = .formSheet
        present(settingsNC, animated: true)
    }

    @objc func mapHomeButtonTapped() {
        presentMapHome(animated: true)
    }

    /// Presents the Map Home landing page as soon as this view controller is
    /// in a window (called at launch when the user has enabled "Open at launch").
    func presentMapHomeAtLaunch() {
        if viewIfLoaded?.window != nil {
            presentMapHome(animated: false)
        } else {
            pendingMapHomeAtLaunch = true
        }
    }

    func presentMapHome(animated: Bool) {
        guard let tunnelsManager = tunnelsManager else { return }
        guard presentedViewController == nil else { return }
        let mapHomeVC = MapHomeViewController(tunnelsManager: tunnelsManager)
        present(mapHomeVC, animated: animated)
    }

    func presentViewControllerForTunnelCreation(tunnelsManager: TunnelsManager) {
        let editVC = TunnelEditTableViewController(tunnelsManager: tunnelsManager)
        let editNC = UINavigationController(rootViewController: editVC)
        editNC.modalPresentationStyle = .fullScreen
        present(editNC, animated: true)
    }

    func presentFailoverGroupEditor(tunnelsManager: TunnelsManager, groupTunnel: TunnelContainer? = nil) {
        let editVC = FailoverGroupEditTableViewController(tunnelsManager: tunnelsManager, groupTunnel: groupTunnel)
        editVC.delegate = self
        let editNC = UINavigationController(rootViewController: editVC)
        editNC.modalPresentationStyle = .formSheet
        present(editNC, animated: true)
    }

    func presentViewControllerForFileImport() {
        let documentTypes = ["com.wireguard.config.quick", String(kUTTypeText), String(kUTTypeZipArchive)]
        let filePicker = UIDocumentPickerViewController(documentTypes: documentTypes, in: .import)
        filePicker.delegate = self
        present(filePicker, animated: true)
    }

    func presentViewControllerForScanningQRCode() {
        let scanQRCodeVC = QRScanViewController()
        scanQRCodeVC.delegate = self
        let scanQRCodeNC = UINavigationController(rootViewController: scanQRCodeVC)
        scanQRCodeNC.modalPresentationStyle = .fullScreen
        present(scanQRCodeNC, animated: true)
    }

    @objc func selectButtonTapped() {
        let shouldCancelSwipe = tableState == .rowSwiped
        tableState = .multiSelect(selectionCount: 0)
        if shouldCancelSwipe {
            tableView.setEditing(false, animated: false)
        }
        tableView.setEditing(true, animated: true)
    }

    @objc func doneButtonTapped() {
        tableState = .normal
        tableView.setEditing(false, animated: true)
    }

    @objc func selectAllButtonTapped() {
        guard tableView.isEditing else { return }
        guard let tunnelsManager = tunnelsManager else { return }
        for index in 0 ..< tunnelsManager.numberOfTunnels() {
            tableView.selectRow(at: IndexPath(row: index, section: ListSection.tunnels.rawValue), animated: false, scrollPosition: .none)
        }
        tableState = .multiSelect(selectionCount: tableView.indexPathsForSelectedRows?.count ?? 0)
    }

    @objc func cancelButtonTapped() {
        tableState = .normal
        tableView.setEditing(false, animated: true)
    }

    @objc func deleteButtonTapped(sender: AnyObject?) {
        guard let sender = sender as? UIBarButtonItem else { return }
        guard let tunnelsManager = tunnelsManager else { return }

        let selectedTunnelIndices = tableView.indexPathsForSelectedRows?
            .filter { $0.section == ListSection.tunnels.rawValue }
            .map { $0.row } ?? []
        let selectedTunnels = selectedTunnelIndices.compactMap { tunnelIndex in
            tunnelIndex >= 0 && tunnelIndex < tunnelsManager.numberOfTunnels() ? tunnelsManager.tunnel(at: tunnelIndex) : nil
        }
        guard !selectedTunnels.isEmpty else { return }
        let message = selectedTunnels.count == 1 ?
            tr(format: "deleteTunnelConfirmationAlertButtonMessage (%d)", selectedTunnels.count) :
            tr(format: "deleteTunnelsConfirmationAlertButtonMessage (%d)", selectedTunnels.count)
        let title = tr("deleteTunnelsConfirmationAlertButtonTitle")
        ConfirmationAlertPresenter.showConfirmationAlert(message: message, buttonTitle: title,
                                                         from: sender, presentingVC: self) { [weak self] in
            self?.tunnelsManager?.removeMultiple(tunnels: selectedTunnels) { [weak self] error in
                guard let self = self else { return }
                if let error = error {
                    ErrorPresenter.showErrorAlert(error: error, from: self)
                    return
                }
                self.tableState = .normal
                self.tableView.setEditing(false, animated: true)
            }
        }
    }

    func showTunnelDetail(for tunnel: TunnelContainer, animated: Bool) {
        guard let tunnelsManager = tunnelsManager else { return }
        guard let splitViewController = splitViewController else { return }
        guard let navController = navigationController else { return }

        let tunnelDetailVC = TunnelDetailTableViewController(tunnelsManager: tunnelsManager,
                                                             tunnel: tunnel)
        let tunnelDetailNC = UINavigationController(rootViewController: tunnelDetailVC)
        tunnelDetailNC.restorationIdentifier = "DetailNC"
        if splitViewController.isCollapsed && navController.viewControllers.count > 1 {
            navController.setViewControllers([self, tunnelDetailNC], animated: animated)
        } else {
            splitViewController.showDetailViewController(tunnelDetailNC, sender: self, animated: animated)
        }
        detailDisplayedTunnel = tunnel
        self.presentedViewController?.dismiss(animated: false, completion: nil)
    }

    func presentTiTGroupEditor(tunnelsManager: TunnelsManager, groupTunnel: TunnelContainer? = nil) {
        let editVC = TunnelInTunnelEditTableViewController(tunnelsManager: tunnelsManager, groupTunnel: groupTunnel)
        editVC.delegate = self
        let editNC = UINavigationController(rootViewController: editVC)
        editNC.modalPresentationStyle = .formSheet
        present(editNC, animated: true)
    }

    func showTiTGroupDetail(for tunnel: TunnelContainer, animated: Bool) {
        guard let tunnelsManager = tunnelsManager else { return }
        guard let splitViewController = splitViewController else { return }
        guard let navController = navigationController else { return }

        let detailVC = TunnelInTunnelDetailTableViewController(tunnelsManager: tunnelsManager,
                                                               tunnel: tunnel)
        let detailNC = UINavigationController(rootViewController: detailVC)
        detailNC.restorationIdentifier = "DetailNC"
        if splitViewController.isCollapsed && navController.viewControllers.count > 1 {
            navController.setViewControllers([self, detailNC], animated: animated)
        } else {
            splitViewController.showDetailViewController(detailNC, sender: self, animated: animated)
        }
        detailDisplayedTunnel = tunnel
        self.presentedViewController?.dismiss(animated: false, completion: nil)
    }

    func showFailoverGroupDetail(for tunnel: TunnelContainer, animated: Bool) {
        guard let tunnelsManager = tunnelsManager else { return }
        guard let splitViewController = splitViewController else { return }
        guard let navController = navigationController else { return }

        let detailVC = FailoverGroupDetailTableViewController(tunnelsManager: tunnelsManager,
                                                              tunnel: tunnel)
        let detailNC = UINavigationController(rootViewController: detailVC)
        detailNC.restorationIdentifier = "DetailNC"
        if splitViewController.isCollapsed && navController.viewControllers.count > 1 {
            navController.setViewControllers([self, detailNC], animated: animated)
        } else {
            splitViewController.showDetailViewController(detailNC, sender: self, animated: animated)
        }
        detailDisplayedTunnel = tunnel
        self.presentedViewController?.dismiss(animated: false, completion: nil)
    }
}

extension TunnelsListTableViewController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let tunnelsManager = tunnelsManager else { return }
        TunnelImporter.importFromFile(urls: urls, into: tunnelsManager, sourceVC: self, errorPresenterType: ErrorPresenter.self)
    }
}

extension TunnelsListTableViewController: QRScanViewControllerDelegate {
    func addScannedQRCode(tunnelConfiguration: TunnelConfiguration, qrScanViewController: QRScanViewController,
                          completionHandler: (() -> Void)?) {
        tunnelsManager?.add(tunnelConfiguration: tunnelConfiguration) { result in
            switch result {
            case .failure(let error):
                ErrorPresenter.showErrorAlert(error: error, from: qrScanViewController, onDismissal: completionHandler)
            case .success:
                completionHandler?()
            }
        }
    }
}

extension TunnelsListTableViewController: UITableViewDataSource {
    func numberOfSections(in tableView: UITableView) -> Int {
        return ListSection.allCases.count
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard let listSection = ListSection(rawValue: section) else { return nil }
        let hasGroups = (tunnelsManager?.numberOfFailoverGroups() ?? 0) > 0 || (tunnelsManager?.numberOfTiTGroups() ?? 0) > 0
        switch listSection {
        case .failoverGroups:
            return (tunnelsManager?.numberOfFailoverGroups() ?? 0) == 0 ? nil : "Failover Groups"
        case .titGroups:
            return (tunnelsManager?.numberOfTiTGroups() ?? 0) == 0 ? nil : "Tunnel-in-Tunnel"
        case .tunnels:
            return hasGroups ? "Tunnels" : nil
        }
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        guard let listSection = ListSection(rawValue: section) else { return 0 }
        switch listSection {
        case .failoverGroups:
            return tunnelsManager?.numberOfFailoverGroups() ?? 0
        case .titGroups:
            return tunnelsManager?.numberOfTiTGroups() ?? 0
        case .tunnels:
            return tunnelsManager?.numberOfTunnels() ?? 0
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let listSection = ListSection(rawValue: indexPath.section) else { return UITableViewCell() }

        switch listSection {
        case .failoverGroups:
            let cell: FailoverGroupCell = tableView.dequeueReusableCell(for: indexPath)
            if let tunnelsManager = tunnelsManager {
                let groupTunnel = tunnelsManager.failoverGroup(at: indexPath.row)
                cell.tunnel = groupTunnel
                if let groupId = groupTunnel.failoverGroupId {
                    cell.activeConfigName = failoverStateConfigNames[groupId]
                }
                cell.onSwitchToggled = { [weak self] isOn in
                    guard let self = self, let tunnelsManager = self.tunnelsManager else { return }
                    if groupTunnel.hasOnDemandRules {
                        tunnelsManager.setOnDemandEnabled(isOn, on: groupTunnel) { error in
                            if error == nil && !isOn {
                                tunnelsManager.startDeactivation(of: groupTunnel)
                            }
                        }
                    } else {
                        if isOn {
                            tunnelsManager.startActivation(of: groupTunnel)
                        } else {
                            tunnelsManager.startDeactivation(of: groupTunnel)
                        }
                    }
                }
            }
            return cell

        case .titGroups:
            let cell: FailoverGroupCell = tableView.dequeueReusableCell(for: indexPath)
            if let tunnelsManager = tunnelsManager {
                let groupTunnel = tunnelsManager.titGroup(at: indexPath.row)
                cell.tunnel = groupTunnel
                cell.onSwitchToggled = { [weak self] isOn in
                    guard let self = self, let tunnelsManager = self.tunnelsManager else { return }
                    if groupTunnel.hasOnDemandRules {
                        tunnelsManager.setOnDemandEnabled(isOn, on: groupTunnel) { error in
                            if error == nil && !isOn {
                                tunnelsManager.startDeactivation(of: groupTunnel)
                            }
                        }
                    } else {
                        if isOn {
                            tunnelsManager.startActivation(of: groupTunnel)
                        } else {
                            tunnelsManager.startDeactivation(of: groupTunnel)
                        }
                    }
                }
            }
            return cell

        case .tunnels:
            let cell: TunnelListCell = tableView.dequeueReusableCell(for: indexPath)
            if let tunnelsManager = tunnelsManager {
                let tunnel = tunnelsManager.tunnel(at: indexPath.row)
                cell.tunnel = tunnel
                cell.onSwitchToggled = { [weak self] isOn in
                    guard let self = self, let tunnelsManager = self.tunnelsManager else { return }
                    if tunnel.hasOnDemandRules {
                        tunnelsManager.setOnDemandEnabled(isOn, on: tunnel) { error in
                            if error == nil && !isOn {
                                tunnelsManager.startDeactivation(of: tunnel)
                            }
                        }
                    } else {
                        if isOn {
                            tunnelsManager.startActivation(of: tunnel)
                        } else {
                            tunnelsManager.startDeactivation(of: tunnel)
                        }
                    }
                }
            }
            return cell
        }
    }
}

extension TunnelsListTableViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard !tableView.isEditing else {
            tableState = .multiSelect(selectionCount: tableView.indexPathsForSelectedRows?.count ?? 0)
            return
        }
        guard let listSection = ListSection(rawValue: indexPath.section) else { return }

        switch listSection {
        case .failoverGroups:
            guard let tunnelsManager = tunnelsManager else { return }
            let groupTunnel = tunnelsManager.failoverGroup(at: indexPath.row)
            showFailoverGroupDetail(for: groupTunnel, animated: true)

        case .titGroups:
            guard let tunnelsManager = tunnelsManager else { return }
            let groupTunnel = tunnelsManager.titGroup(at: indexPath.row)
            showTiTGroupDetail(for: groupTunnel, animated: true)

        case .tunnels:
            guard let tunnelsManager = tunnelsManager else { return }
            let tunnel = tunnelsManager.tunnel(at: indexPath.row)
            showTunnelDetail(for: tunnel, animated: true)
        }
    }

    func tableView(_ tableView: UITableView, didDeselectRowAt indexPath: IndexPath) {
        guard !tableView.isEditing else {
            tableState = .multiSelect(selectionCount: tableView.indexPathsForSelectedRows?.count ?? 0)
            return
        }
    }

    func tableView(_ tableView: UITableView,
                   trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let listSection = ListSection(rawValue: indexPath.section) else { return nil }

        switch listSection {
        case .failoverGroups:
            let deleteAction = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, completionHandler in
                guard let self = self, let tunnelsManager = self.tunnelsManager else { return }
                let groupTunnel = tunnelsManager.failoverGroup(at: indexPath.row)
                tunnelsManager.removeFailoverGroup(tunnel: groupTunnel) { error in
                    if error != nil {
                        ErrorPresenter.showErrorAlert(error: error!, from: self)
                        completionHandler(false)
                    } else {
                        completionHandler(true)
                    }
                }
            }
            return UISwipeActionsConfiguration(actions: [deleteAction])

        case .titGroups:
            let deleteAction = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, completionHandler in
                guard let self = self, let tunnelsManager = self.tunnelsManager else { return }
                let groupTunnel = tunnelsManager.titGroup(at: indexPath.row)
                tunnelsManager.removeTiTGroup(tunnel: groupTunnel) { error in
                    if error != nil {
                        ErrorPresenter.showErrorAlert(error: error!, from: self)
                        completionHandler(false)
                    } else {
                        completionHandler(true)
                    }
                }
            }
            return UISwipeActionsConfiguration(actions: [deleteAction])

        case .tunnels:
            let deleteAction = UIContextualAction(style: .destructive, title: tr("tunnelsListSwipeDeleteButtonTitle")) { [weak self] _, _, completionHandler in
                guard let tunnelsManager = self?.tunnelsManager else { return }
                let tunnel = tunnelsManager.tunnel(at: indexPath.row)
                tunnelsManager.remove(tunnel: tunnel) { error in
                    if error != nil {
                        ErrorPresenter.showErrorAlert(error: error!, from: self)
                        completionHandler(false)
                    } else {
                        completionHandler(true)
                    }
                }
            }
            return UISwipeActionsConfiguration(actions: [deleteAction])
        }
    }

    func tableView(_ tableView: UITableView, willBeginEditingRowAt indexPath: IndexPath) {
        if tableState == .normal {
            tableState = .rowSwiped
        }
    }

    func tableView(_ tableView: UITableView, didEndEditingRowAt indexPath: IndexPath?) {
        if tableState == .rowSwiped {
            tableState = .normal
        }
    }
}

extension TunnelsListTableViewController: TunnelsManagerListDelegate {
    private var tunnelsSection: Int { ListSection.tunnels.rawValue }

    func tunnelAdded(at index: Int) {
        tableView.insertRows(at: [IndexPath(row: index, section: tunnelsSection)], with: .automatic)
        centeredAddButton.isHidden = (tunnelsManager?.numberOfTunnels() ?? 0 > 0)
    }

    func tunnelModified(at index: Int) {
        tableView.reloadRows(at: [IndexPath(row: index, section: tunnelsSection)], with: .automatic)
    }

    func tunnelMoved(from oldIndex: Int, to newIndex: Int) {
        tableView.moveRow(at: IndexPath(row: oldIndex, section: tunnelsSection), to: IndexPath(row: newIndex, section: tunnelsSection))
    }

    func tunnelRemoved(at index: Int, tunnel: TunnelContainer) {
        tableView.deleteRows(at: [IndexPath(row: index, section: tunnelsSection)], with: .automatic)
        centeredAddButton.isHidden = tunnelsManager?.numberOfTunnels() ?? 0 > 0
        if detailDisplayedTunnel == tunnel, let splitViewController = splitViewController {
            if splitViewController.isCollapsed != false {
                (splitViewController.viewControllers[0] as? UINavigationController)?.popToRootViewController(animated: false)
            } else {
                let detailVC = UIViewController()
                detailVC.view.backgroundColor = .systemBackground
                let detailNC = UINavigationController(rootViewController: detailVC)
                splitViewController.showDetailViewController(detailNC, sender: self)
            }
            detailDisplayedTunnel = nil
            if let presentedNavController = self.presentedViewController as? UINavigationController, presentedNavController.viewControllers.first is TunnelEditTableViewController {
                self.presentedViewController?.dismiss(animated: false, completion: nil)
            }
        }
    }
}

// MARK: - TunnelsManagerGroupListDelegate

extension TunnelsListTableViewController: TunnelsManagerGroupListDelegate {
    private func listSection(for kind: TunnelGroupKind) -> Int {
        switch kind {
        case .failover: return ListSection.failoverGroups.rawValue
        case .tunnelInTunnel: return ListSection.titGroups.rawValue
        }
    }

    func groupAdded(kind: TunnelGroupKind, at index: Int) {
        tableView.insertRows(at: [IndexPath(row: index, section: listSection(for: kind))], with: .automatic)
        centeredAddButton.isHidden = true
    }

    func groupModified(kind: TunnelGroupKind, at index: Int) {
        tableView.reloadRows(at: [IndexPath(row: index, section: listSection(for: kind))], with: .automatic)
    }

    func groupMoved(kind: TunnelGroupKind, from oldIndex: Int, to newIndex: Int) {
        let section = listSection(for: kind)
        tableView.moveRow(at: IndexPath(row: oldIndex, section: section), to: IndexPath(row: newIndex, section: section))
    }

    func groupRemoved(kind: TunnelGroupKind, at index: Int, tunnel: TunnelContainer) {
        tableView.deleteRows(at: [IndexPath(row: index, section: listSection(for: kind))], with: .automatic)
        let hasAnyItems = (tunnelsManager?.numberOfTunnels() ?? 0) > 0
            || (tunnelsManager?.numberOfFailoverGroups() ?? 0) > 0
            || (tunnelsManager?.numberOfTiTGroups() ?? 0) > 0
        centeredAddButton.isHidden = hasAnyItems
        if detailDisplayedTunnel == tunnel, let splitViewController = splitViewController {
            if splitViewController.isCollapsed != false {
                (splitViewController.viewControllers[0] as? UINavigationController)?.popToRootViewController(animated: false)
            } else {
                let detailVC = UIViewController()
                detailVC.view.backgroundColor = .systemBackground
                let detailNC = UINavigationController(rootViewController: detailVC)
                splitViewController.showDetailViewController(detailNC, sender: self)
            }
            detailDisplayedTunnel = nil
            self.presentedViewController?.dismiss(animated: false, completion: nil)
        }
    }
}

// MARK: - TunnelInTunnelEditDelegate

extension TunnelsListTableViewController: TunnelInTunnelEditDelegate {
    func titGroupSaved(_ tunnel: TunnelContainer) {
        // Table updates handled by TunnelsManagerGroupListDelegate
    }

    func titGroupDeleted(_ tunnel: TunnelContainer) {
        // Table updates handled by TunnelsManagerGroupListDelegate
    }
}

// MARK: - Failover State Polling

extension TunnelsListTableViewController {
    func startPollingFailoverState() {
        stopPollingFailoverState()
        failoverStateTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.pollAllFailoverStates()
        }
    }

    func stopPollingFailoverState() {
        failoverStateTimer?.invalidate()
        failoverStateTimer = nil
    }

    private func pollAllFailoverStates() {
        guard let tunnelsManager = tunnelsManager else { return }
        for i in 0..<tunnelsManager.numberOfFailoverGroups() {
            let groupTunnel = tunnelsManager.failoverGroup(at: i)
            guard groupTunnel.status == .active else { continue }
            tunnelsManager.getFailoverState(for: groupTunnel) { [weak self] state in
                guard let self = self, let state = state, let groupId = groupTunnel.failoverGroupId else { return }
                DispatchQueue.main.async {
                    let newActiveConfig = state["activeConfig"] as? String
                    if newActiveConfig != self.failoverStateConfigNames[groupId] {
                        self.failoverStateConfigNames[groupId] = newActiveConfig
                        if let index = tunnelsManager.failoverGroupIndex(of: groupTunnel) {
                            let indexPath = IndexPath(row: index, section: ListSection.failoverGroups.rawValue)
                            if let cell = self.tableView.cellForRow(at: indexPath) as? FailoverGroupCell {
                                cell.activeConfigName = newActiveConfig
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - FailoverGroupEditDelegate

extension TunnelsListTableViewController: FailoverGroupEditDelegate {
    func failoverGroupSaved(_ tunnel: TunnelContainer) {
        // The delegate methods from TunnelsManagerGroupListDelegate handle table updates
    }

    func failoverGroupDeleted(_ tunnel: TunnelContainer) {
        // The delegate methods from TunnelsManagerGroupListDelegate handle table updates
    }
}

extension UISplitViewController {
    func showDetailViewController(_ viewController: UIViewController, sender: Any?, animated: Bool) {
        if animated {
            showDetailViewController(viewController, sender: sender)
        } else {
            UIView.performWithoutAnimation {
                showDetailViewController(viewController, sender: sender)
            }
        }
    }
}
