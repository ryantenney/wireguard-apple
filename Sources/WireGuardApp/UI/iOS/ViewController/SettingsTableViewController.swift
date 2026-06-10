// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.
// Copyright © 2026 Ryan Tenney.

import UIKit
import NetworkExtension
import UserNotifications
import os.log

class SettingsTableViewController: UITableViewController {

    enum SettingsFields {
        case iosAppVersion
        case goBackendVersion
        case exportZipArchive
        case viewLog
        case sessionHistory
        case notifyOnDisconnect
        case notifyOnFailover
        case ipDiscovery

        var localizedUIString: String {
            switch self {
            case .iosAppVersion: return tr("settingsVersionKeyWireGuardForIOS")
            case .goBackendVersion: return tr("settingsVersionKeyWireGuardGoBackend")
            case .exportZipArchive: return tr("settingsExportZipButtonTitle")
            case .viewLog: return tr("settingsViewLogButtonTitle")
            case .sessionHistory: return tr("settingsSessionHistoryButtonTitle")
            case .notifyOnDisconnect: return tr("settingsNotifyOnDisconnect")
            case .notifyOnFailover: return tr("settingsNotifyOnFailover")
            case .ipDiscovery: return tr("settingsIPDiscovery")
            }
        }
    }

    let settingsFieldsBySection: [[SettingsFields]] = [
        [.iosAppVersion, .goBackendVersion],
        [.notifyOnDisconnect, .notifyOnFailover],
        [.ipDiscovery],
        [.exportZipArchive],
        [.viewLog],
        [.sessionHistory]
    ]

    let tunnelsManager: TunnelsManager?

    init(tunnelsManager: TunnelsManager?) {
        self.tunnelsManager = tunnelsManager
        super.init(style: .grouped)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = tr("settingsViewTitle")
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(doneTapped))

        tableView.estimatedRowHeight = 44
        tableView.rowHeight = UITableView.automaticDimension
        tableView.allowsSelection = false

        tableView.register(KeyValueCell.self)
        tableView.register(ButtonCell.self)
        tableView.register(SwitchCell.self)
    }

    @objc func doneTapped() {
        dismiss(animated: true, completion: nil)
    }

    func exportConfigurationsAsZipFile(sourceView: UIView) {
        PrivateDataConfirmation.confirmAccess(to: tr("iosExportPrivateData")) { [weak self] in
            guard let self = self else { return }
            guard let tunnelsManager = self.tunnelsManager else { return }
            guard let destinationDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }

            let destinationURL = destinationDir.appendingPathComponent("wireguard-export.zip")
            _ = FileManager.deleteFile(at: destinationURL)

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

                let fileExportVC = UIDocumentPickerViewController(url: destinationURL, in: .exportToService)
                self?.present(fileExportVC, animated: true, completion: nil)
            }
        }
    }

    func presentLogView() {
        let logVC = LogViewController()
        navigationController?.pushViewController(logVC, animated: true)

    }

    func presentSessionHistory() {
        let historyVC = SessionHistoryViewController()
        navigationController?.pushViewController(historyVC, animated: true)
    }

    // MARK: - Notification Permission

    private func requestNotificationPermissionIfNeeded(completion: @escaping (Bool) -> Void) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            DispatchQueue.main.async {
                switch settings.authorizationStatus {
                case .authorized, .provisional:
                    completion(true)
                case .notDetermined:
                    center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                        DispatchQueue.main.async { completion(granted) }
                    }
                default:
                    completion(false)
                }
            }
        }
    }

    private func handleNotificationToggle(field: SettingsFields, isOn: Bool, switchCell: SwitchCell) {
        if isOn {
            requestNotificationPermissionIfNeeded { [weak self] granted in
                if granted {
                    switch field {
                    case .notifyOnDisconnect:
                        NotificationSettings.isDisconnectNotificationEnabled = true
                    case .notifyOnFailover:
                        NotificationSettings.isFailoverNotificationEnabled = true
                    default:
                        break
                    }
                } else {
                    switchCell.isOn = false
                    let alert = UIAlertController(
                        title: tr("settingsNotificationPermissionDeniedTitle"),
                        message: tr("settingsNotificationPermissionDeniedMessage"),
                        preferredStyle: .alert
                    )
                    alert.addAction(UIAlertAction(title: tr("actionOK"), style: .default))
                    self?.present(alert, animated: true)
                }
            }
        } else {
            switch field {
            case .notifyOnDisconnect:
                NotificationSettings.isDisconnectNotificationEnabled = false
            case .notifyOnFailover:
                NotificationSettings.isFailoverNotificationEnabled = false
            default:
                break
            }
        }
    }
}

extension SettingsTableViewController {
    override func numberOfSections(in tableView: UITableView) -> Int {
        return settingsFieldsBySection.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return settingsFieldsBySection[section].count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch section {
        case 0:
            return tr("settingsSectionTitleAbout")
        case 1:
            return tr("settingsSectionTitleNotifications")
        case 2:
            return tr("settingsSectionTitleIPDiscovery")
        case 3:
            return tr("settingsSectionTitleExportConfigurations")
        case 4:
            return tr("settingsSectionTitleTunnelLog")
        case 5:
            return tr("settingsSectionTitleSessionHistory")
        default:
            return nil
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let field = settingsFieldsBySection[indexPath.section][indexPath.row]
        if field == .iosAppVersion || field == .goBackendVersion {
            let cell: KeyValueCell = tableView.dequeueReusableCell(for: indexPath)
            cell.copyableGesture = false
            cell.key = field.localizedUIString
            if field == .iosAppVersion {
                var appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown version"
                if let appBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String {
                    appVersion += " (\(appBuild))"
                }
                appVersion += " \(BUILD_COMMIT_HASH)"
                cell.value = appVersion
            } else if field == .goBackendVersion {
                cell.value = WIREGUARD_GO_VERSION
            }
            return cell
        } else if field == .ipDiscovery {
            let cell: SwitchCell = tableView.dequeueReusableCell(for: indexPath)
            cell.message = field.localizedUIString
            cell.isOn = IPDiscoverySettings.isEnabled
            cell.onSwitchToggled = { isOn in
                IPDiscoverySettings.isEnabled = isOn
            }
            return cell
        } else if field == .notifyOnDisconnect || field == .notifyOnFailover {
            let cell: SwitchCell = tableView.dequeueReusableCell(for: indexPath)
            cell.message = field.localizedUIString
            cell.isOn = (field == .notifyOnDisconnect)
                ? NotificationSettings.isDisconnectNotificationEnabled
                : NotificationSettings.isFailoverNotificationEnabled
            cell.onSwitchToggled = { [weak self, weak cell] isOn in
                guard let cell = cell else { return }
                self?.handleNotificationToggle(field: field, isOn: isOn, switchCell: cell)
            }
            return cell
        } else if field == .exportZipArchive {
            let cell: ButtonCell = tableView.dequeueReusableCell(for: indexPath)
            cell.buttonText = field.localizedUIString
            cell.onTapped = { [weak self] in
                self?.exportConfigurationsAsZipFile(sourceView: cell.button)
            }
            return cell
        } else if field == .viewLog {
            let cell: ButtonCell = tableView.dequeueReusableCell(for: indexPath)
            cell.buttonText = field.localizedUIString
            cell.onTapped = { [weak self] in
                self?.presentLogView()
            }
            return cell
        } else if field == .sessionHistory {
            let cell: ButtonCell = tableView.dequeueReusableCell(for: indexPath)
            cell.buttonText = field.localizedUIString
            cell.onTapped = { [weak self] in
                self?.presentSessionHistory()
            }
            return cell
        }
        fatalError()
    }
}
