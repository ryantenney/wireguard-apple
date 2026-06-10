// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.
// Copyright © 2026 Ryan Tenney.

import Foundation

class TunnelImporter {
    static func importFromFile(urls: [URL], into tunnelsManager: TunnelsManager, sourceVC: AnyObject?, errorPresenterType: ErrorPresenterProtocol.Type, completionHandler: (() -> Void)? = nil) {
        guard !urls.isEmpty else {
            completionHandler?()
            return
        }
        let dispatchGroup = DispatchGroup()
        var configs = [TunnelConfiguration?]()
        var failoverGroups = [FailoverGroupConfig]()
        var tunnelInTunnelGroups = [TunnelInTunnelGroupConfig]()
        var lastFileImportErrorText: (title: String, message: String)?
        for url in urls {
            if url.pathExtension.lowercased() == "zip" {
                dispatchGroup.enter()
                ZipImporter.importConfigFiles(from: url) { result in
                    switch result {
                    case .failure(let error):
                        lastFileImportErrorText = error.alertText
                    case .success(let importResult):
                        configs.append(contentsOf: importResult.tunnelConfigurations)
                        failoverGroups.append(contentsOf: importResult.failoverGroups)
                        tunnelInTunnelGroups.append(contentsOf: importResult.tunnelInTunnelGroups)
                    }
                    dispatchGroup.leave()
                }
            } else { /* if it is not a zip, we assume it is a conf */
                let fileName = url.lastPathComponent
                let fileBaseName = url.deletingPathExtension().lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
                dispatchGroup.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    let fileContents: String
                    do {
                        fileContents = try String(contentsOf: url)
                    } catch let error {
                        DispatchQueue.main.async {
                            if let cocoaError = error as? CocoaError, cocoaError.isFileError {
                                lastFileImportErrorText = (title: tr("alertCantOpenInputConfFileTitle"), message: error.localizedDescription)
                            } else {
                                lastFileImportErrorText = (title: tr("alertCantOpenInputConfFileTitle"), message: tr(format: "alertCantOpenInputConfFileMessage (%@)", fileName))
                            }
                            configs.append(nil)
                            dispatchGroup.leave()
                        }
                        return
                    }
                    var parseError: Error?
                    var tunnelConfiguration: TunnelConfiguration?
                    do {
                        tunnelConfiguration = try TunnelConfiguration(fromWgQuickConfig: fileContents, called: fileBaseName)
                    } catch let error {
                        parseError = error
                    }
                    DispatchQueue.main.async {
                        if parseError != nil {
                            if let parseError = parseError as? WireGuardAppError {
                                lastFileImportErrorText = parseError.alertText
                            } else {
                                lastFileImportErrorText = (title: tr("alertBadConfigImportTitle"), message: tr(format: "alertBadConfigImportMessage (%@)", fileName))
                            }
                        }
                        configs.append(tunnelConfiguration)
                        dispatchGroup.leave()
                    }
                }
            }
        }
        dispatchGroup.notify(queue: .main) {
            tunnelsManager.addMultiple(tunnelConfigurations: configs.compactMap { $0 }) { numberSuccessful, lastAddError in
                // After tunnels are imported, import failover groups, then tunnel-in-tunnel groups
                importFailoverGroups(failoverGroups, into: tunnelsManager) { groupsImported in
                    importTunnelInTunnelGroups(tunnelInTunnelGroups, into: tunnelsManager) { titGroupsImported in
                        let allGroupsOK = (failoverGroups.isEmpty || groupsImported == failoverGroups.count)
                            && (tunnelInTunnelGroups.isEmpty || titGroupsImported == tunnelInTunnelGroups.count)
                        if !configs.isEmpty && numberSuccessful == configs.count && allGroupsOK {
                            completionHandler?()
                            return
                        }
                        let alertText: (title: String, message: String)?
                        if urls.count == 1 {
                            if urls.first!.pathExtension.lowercased() == "zip" && !configs.isEmpty {
                                var message = tr(format: "alertImportedFromZipMessage (%1$d of %2$d)", numberSuccessful, configs.count)
                                if !failoverGroups.isEmpty {
                                    message += "\n" + tr(format: "alertImportedFailoverGroupsMessage (%1$d of %2$d)", groupsImported, failoverGroups.count)
                                }
                                if !tunnelInTunnelGroups.isEmpty {
                                    message += "\n" + tr(format: "alertImportedTunnelInTunnelGroupsMessage (%1$d of %2$d)", titGroupsImported, tunnelInTunnelGroups.count)
                                }
                                alertText = (title: tr(format: "alertImportedFromZipTitle (%d)", numberSuccessful),
                                             message: message)
                            } else {
                                alertText = lastFileImportErrorText ?? lastAddError?.alertText
                            }
                        } else {
                            alertText = (title: tr(format: "alertImportedFromMultipleFilesTitle (%d)", numberSuccessful),
                                         message: tr(format: "alertImportedFromMultipleFilesMessage (%1$d of %2$d)", numberSuccessful, configs.count))
                        }
                        if let alertText = alertText {
                            errorPresenterType.showErrorAlert(title: alertText.title, message: alertText.message, from: sourceVC, onPresented: completionHandler)
                        } else {
                            completionHandler?()
                        }
                    }
                }
            }
        }
    }

    private static func importTunnelInTunnelGroups(_ groups: [TunnelInTunnelGroupConfig], into tunnelsManager: TunnelsManager, completionHandler: @escaping (Int) -> Void) {
        guard !groups.isEmpty else {
            completionHandler(0)
            return
        }
        var successCount = 0
        var remaining = groups.count
        for group in groups {
            tunnelsManager.addTiTGroup(
                name: group.name,
                outerTunnelName: group.outerTunnelName,
                innerTunnelName: group.innerTunnelName,
                onDemandActivation: OnDemandActivation()
            ) { result in
                switch result {
                case .success:
                    successCount += 1
                case .failure(let error):
                    wg_log(.error, message: "Failed to import tunnel-in-tunnel group '\(group.name)': \(error)")
                }
                remaining -= 1
                if remaining == 0 {
                    completionHandler(successCount)
                }
            }
        }
    }

    private static func importFailoverGroups(_ groups: [FailoverGroupConfig], into tunnelsManager: TunnelsManager, completionHandler: @escaping (Int) -> Void) {
        guard !groups.isEmpty else {
            completionHandler(0)
            return
        }
        var successCount = 0
        var remaining = groups.count

        for group in groups {
            let settings = FailoverSettings(
                trafficTimeout: group.trafficTimeout ?? 30,
                healthCheckInterval: group.healthCheckInterval ?? 10,
                failbackProbeInterval: group.failbackProbeInterval ?? 300,
                autoFailback: group.autoFailback ?? true,
                useBackgroundProbes: group.useBackgroundProbes ?? true,
                hotSpare: group.hotSpare ?? false,
                persistentKeepaliveOverride: group.persistentKeepaliveOverride
            )

            tunnelsManager.addFailoverGroup(
                name: group.name,
                tunnelNames: group.tunnelNames,
                settings: settings,
                onDemandActivation: OnDemandActivation()
            ) { result in
                switch result {
                case .success:
                    successCount += 1
                case .failure(let error):
                    wg_log(.error, message: "Failed to import failover group '\(group.name)': \(error)")
                }
                remaining -= 1
                if remaining == 0 {
                    completionHandler(successCount)
                }
            }
        }
    }
}
