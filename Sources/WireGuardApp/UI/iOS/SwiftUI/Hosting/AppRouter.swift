// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import UIKit
import SwiftUI
import MobileCoreServices
import NetworkExtension

/// Bridges the SwiftUI screens to UIKit navigation and to the existing UIKit
/// flows that the redesign does not (yet) cover: tunnel/group editors, the QR
/// scanner, file import, the log viewer and session history. SwiftUI views call
/// these methods through `@EnvironmentObject`.
final class AppRouter: NSObject, ObservableObject {
    let theme: AppTheme
    @Published var store: TunnelStore?

    weak var hostController: UIViewController?
    weak var splitViewController: UISplitViewController?
    /// Navigation controller of the Settings tab; Settings-originated pushes
    /// (log, session history) land here so they stay on the Settings tab.
    weak var settingsNavigationController: UINavigationController?

    init(theme: AppTheme) {
        self.theme = theme
        super.init()
    }

    private var manager: TunnelsManager? { store?.manager }
    private var masterNavigationController: UINavigationController? { hostController?.navigationController }

    // MARK: - Hosting helpers

    /// Wrap a SwiftUI screen with the shared environment objects.
    private func wrap<Content: View>(_ view: Content) -> some View {
        view
            .environmentObject(theme)
            .environmentObject(self)
            .modifier(OptionalStoreEnvironment(store: store))
    }

    private func makeDetailHost<Content: View>(_ view: Content, title: String) -> ThemedHostingController {
        let controller = ThemedHostingController(rootView: AnyView(wrap(view)))
        controller.hidesNavigationBar = false
        controller.navigationItem.title = title
        return controller
    }

    // MARK: - Primary navigation

    func showDetail(for node: TunnelNode) {
        if node.isFailoverGroup {
            showFailoverGroup(node)
        } else if node.isTiTGroup {
            showTiTGroup(node)
        } else {
            showTunnelDetail(node)
        }
    }

    func showTunnelDetail(_ node: TunnelNode) {
        let host = makeDetailHost(TunnelDetailView(node: node), title: node.name)
        host.navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .edit,
            primaryAction: UIAction { [weak self] _ in self?.editTunnel(node) }, menu: nil)
        push(host)
    }

    func showFailoverGroup(_ node: TunnelNode) {
        let host = makeDetailHost(FailoverGroupView(node: node), title: node.name)
        host.navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .edit,
            primaryAction: UIAction { [weak self] _ in self?.editFailoverGroup(node) }, menu: nil)
        push(host)
    }

    func showTiTGroup(_ node: TunnelNode) {
        let host = makeDetailHost(TunnelInTunnelDetailView(node: node), title: node.name)
        host.navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .edit,
            primaryAction: UIAction { [weak self] _ in self?.editTiTGroup(node) }, menu: nil)
        push(host)
    }

    func dismissDetail() {
        if let split = splitViewController, !split.isCollapsed {
            let empty = UIViewController()
            empty.view.backgroundColor = .systemBackground
            split.showDetailViewController(UINavigationController(rootViewController: empty), sender: nil)
        } else {
            masterNavigationController?.popViewController(animated: true)
        }
    }

    private func push(_ viewController: UIViewController) {
        if let split = splitViewController, !split.isCollapsed {
            let navigation = UINavigationController(rootViewController: viewController)
            navigation.restorationIdentifier = "DetailNC"
            split.showDetailViewController(navigation, sender: nil)
        } else {
            masterNavigationController?.pushViewController(viewController, animated: true)
        }
    }

    private func present(_ viewController: UIViewController) {
        let presenter = visibleTopViewController ?? masterNavigationController?.topViewController ?? hostController
        presenter?.present(viewController, animated: true)
    }

    /// The view controller currently on screen, regardless of which tab is
    /// selected, so modals present from the visible tab (e.g. exporting from
    /// the Settings tab) rather than an off-screen one.
    private var visibleTopViewController: UIViewController? {
        let window = hostController?.view.window ?? settingsNavigationController?.view.window
        guard let root = window?.rootViewController else { return nil }
        return AppRouter.topMost(of: root)
    }

    private static func topMost(of viewController: UIViewController) -> UIViewController {
        if let presented = viewController.presentedViewController {
            return topMost(of: presented)
        }
        switch viewController {
        case let tab as UITabBarController:
            if let selected = tab.selectedViewController { return topMost(of: selected) }
        case let navigation as UINavigationController:
            if let top = navigation.topViewController { return topMost(of: top) }
        case let split as UISplitViewController:
            if let last = split.viewControllers.last { return topMost(of: last) }
        default:
            break
        }
        return viewController
    }

    // MARK: - Add tunnel routes

    func presentAddTunnel() {
        let sheet = AddTunnelSheet()
        let host = ThemedHostingController(rootView: AnyView(wrap(sheet)))
        host.hidesNavigationBar = true
        host.modalPresentationStyle = .formSheet
        present(host)
    }

    func createTunnelFromScratch() {
        guard let manager = manager else { return }
        dismissPresented {
            let editVC = TunnelEditTableViewController(tunnelsManager: manager)
            let editNC = UINavigationController(rootViewController: editVC)
            editNC.modalPresentationStyle = .fullScreen
            self.present(editNC)
        }
    }

    func importFile() {
        dismissPresented {
            let documentTypes = ["com.wireguard.config.quick", String(kUTTypeText), String(kUTTypeZipArchive)]
            let picker = UIDocumentPickerViewController(documentTypes: documentTypes, in: .import)
            picker.delegate = self
            self.present(picker)
        }
    }

    func scanQRCode() {
        dismissPresented {
            let scanVC = QRScanViewController()
            scanVC.delegate = self
            let scanNC = UINavigationController(rootViewController: scanVC)
            scanNC.modalPresentationStyle = .fullScreen
            self.present(scanNC)
        }
    }

    func pasteFromClipboard() {
        guard let manager = manager else { return }
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
        do {
            let config = try TunnelConfiguration(fromWgQuickConfig: text, called: "Imported")
            dismissPresented {
                manager.add(tunnelConfiguration: config) { [weak self] result in
                    if case .failure(let error) = result {
                        self?.showError(error)
                    }
                }
            }
        } catch {
            showSimpleError(title: tr("alertBadConfigImportTitle"),
                            message: tr("addTunnelClipboardInvalidMessage"))
        }
    }

    func createFailoverGroup() {
        guard let manager = manager else { return }
        dismissPresented {
            let editVC = FailoverGroupEditTableViewController(tunnelsManager: manager, groupTunnel: nil)
            editVC.delegate = self
            let editNC = UINavigationController(rootViewController: editVC)
            editNC.modalPresentationStyle = .formSheet
            self.present(editNC)
        }
    }

    func createTiTGroup() {
        guard let manager = manager else { return }
        dismissPresented {
            let editVC = TunnelInTunnelEditTableViewController(tunnelsManager: manager, groupTunnel: nil)
            editVC.delegate = self
            let editNC = UINavigationController(rootViewController: editVC)
            editNC.modalPresentationStyle = .formSheet
            self.present(editNC)
        }
    }

    // MARK: - Detail actions

    func editTunnel(_ node: TunnelNode) {
        guard let manager = manager else { return }
        let editVC = TunnelEditTableViewController(tunnelsManager: manager, tunnel: node.container)
        let editNC = UINavigationController(rootViewController: editVC)
        editNC.modalPresentationStyle = .fullScreen
        present(editNC)
    }

    func editFailoverGroup(_ node: TunnelNode) {
        guard let manager = manager else { return }
        let editVC = FailoverGroupEditTableViewController(tunnelsManager: manager, groupTunnel: node.container)
        editVC.delegate = self
        let editNC = UINavigationController(rootViewController: editVC)
        editNC.modalPresentationStyle = .formSheet
        present(editNC)
    }

    func editTiTGroup(_ node: TunnelNode) {
        guard let manager = manager else { return }
        let editVC = TunnelInTunnelEditTableViewController(tunnelsManager: manager, groupTunnel: node.container)
        editVC.delegate = self
        let editNC = UINavigationController(rootViewController: editVC)
        editNC.modalPresentationStyle = .formSheet
        present(editNC)
    }

    func exportConfig(for node: TunnelNode) {
        guard let configuration = node.container.tunnelConfiguration else { return }
        PrivateDataConfirmation.confirmAccess(to: tr("iosExportPrivateData")) { [weak self] in
            let contents = configuration.asWgQuickConfig()
            let fileName = "\(node.name).conf"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
            do {
                try contents.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                return
            }
            let exportVC = UIDocumentPickerViewController(forExporting: [url])
            self?.present(exportVC)
        }
    }

    func copyToPasteboard(_ string: String) {
        UIPasteboard.general.string = string
    }

    /// Delete a tunnel or group, then clear the detail if it was showing.
    func delete(_ node: TunnelNode) {
        store?.remove(node) { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                self.showError(error)
                return
            }
            self.dismissDetail()
        }
    }

    // MARK: - Settings actions

    func exportAllConfigurations() {
        guard let manager = manager else { return }
        PrivateDataConfirmation.confirmAccess(to: tr("iosExportPrivateData")) { [weak self] in
            guard let self = self else { return }
            guard let destinationDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
            let destinationURL = destinationDir.appendingPathComponent("wireguard-export.zip")
            _ = FileManager.deleteFile(at: destinationURL)

            let count = manager.numberOfTunnels()
            let tunnelConfigurations = (0 ..< count).compactMap { manager.tunnel(at: $0).tunnelConfiguration }

            var failoverGroups = [(name: String, config: String)]()
            for index in 0 ..< manager.numberOfFailoverGroups() {
                let groupTunnel = manager.failoverGroup(at: index)
                if let proto = groupTunnel.tunnelProvider.protocolConfiguration as? NETunnelProviderProtocol,
                   let providerConfig = proto.providerConfiguration,
                   let configString = FailoverGroupConfig.configString(from: providerConfig) {
                    failoverGroups.append((name: groupTunnel.name, config: configString))
                }
            }
            let tunnelInTunnelGroups = titGroupPersistence.loadGroups().map {
                (name: $0.name, config: TunnelInTunnelGroupConfig.configString(from: $0))
            }

            ZipExporter.exportConfigFiles(tunnelConfigurations: tunnelConfigurations,
                                          failoverGroups: failoverGroups,
                                          tunnelInTunnelGroups: tunnelInTunnelGroups,
                                          to: destinationURL) { [weak self] error in
                if let error = error {
                    self?.showError(error)
                    return
                }
                let exportVC = UIDocumentPickerViewController(url: destinationURL, in: .exportToService)
                self?.present(exportVC)
            }
        }
    }

    func viewLog() {
        pushOnSettings(LogViewController())
    }

    func showSessionHistory() {
        pushOnSettings(SessionHistoryViewController())
    }

    /// Push a UIKit screen onto the Settings tab, restoring its navigation bar
    /// (the Settings root hides it to draw its own large title).
    private func pushOnSettings(_ viewController: UIViewController) {
        let navigation = settingsNavigationController ?? masterNavigationController
        navigation?.setNavigationBarHidden(false, animated: false)
        navigation?.pushViewController(viewController, animated: true)
    }

    // MARK: - Helpers

    private func dismissPresented(_ completion: @escaping () -> Void) {
        if let presented = hostController?.presentedViewController {
            presented.dismiss(animated: true, completion: completion)
        } else {
            completion()
        }
    }

    private func showError(_ error: Error) {
        guard let presenter = hostController else { return }
        if let appError = error as? WireGuardAppError {
            ErrorPresenter.showErrorAlert(error: appError, from: presenter)
        } else {
            showSimpleError(title: tr("alertBadConfigImportTitle"), message: error.localizedDescription)
        }
    }

    private func showSimpleError(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: tr("actionOK"), style: .default))
        present(alert)
    }
}

// MARK: - Import / QR delegates

extension AppRouter: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let manager = manager, let presenter = hostController else { return }
        TunnelImporter.importFromFile(urls: urls, into: manager, sourceVC: presenter, errorPresenterType: ErrorPresenter.self)
    }
}

extension AppRouter: QRScanViewControllerDelegate {
    func addScannedQRCode(tunnelConfiguration: TunnelConfiguration, qrScanViewController: QRScanViewController, completionHandler: (() -> Void)?) {
        manager?.add(tunnelConfiguration: tunnelConfiguration) { result in
            switch result {
            case .failure(let error):
                ErrorPresenter.showErrorAlert(error: error, from: qrScanViewController, onDismissal: completionHandler)
            case .success:
                completionHandler?()
            }
        }
    }
}

// MARK: - Edit delegates (table updates flow through the group list delegate → store)

extension AppRouter: FailoverGroupEditDelegate {
    func failoverGroupSaved(_ tunnel: TunnelContainer) {}
    func failoverGroupDeleted(_ tunnel: TunnelContainer) {}
}

extension AppRouter: TunnelInTunnelEditDelegate {
    func titGroupSaved(_ tunnel: TunnelContainer) {}
    func titGroupDeleted(_ tunnel: TunnelContainer) {}
}

// MARK: - Hosting controller

/// `UIHostingController` that can hide the navigation bar (used for full-screen
/// SwiftUI screens that draw their own header) and resists status-bar surprises.
final class ThemedHostingController: UIHostingController<AnyView> {
    var hidesNavigationBar = false

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(hidesNavigationBar, animated: animated)
    }
}

/// Injects the store into the SwiftUI environment only once it exists.
private struct OptionalStoreEnvironment: ViewModifier {
    let store: TunnelStore?

    func body(content: Content) -> some View {
        if let store = store {
            content.environmentObject(store)
        } else {
            content
        }
    }
}
