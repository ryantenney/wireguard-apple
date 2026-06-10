// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import Foundation
import NetworkExtension

// MARK: - TunnelGroupSpec Protocol

/// Protocol that each group type implements to provide its specific configuration building logic.
protocol TunnelGroupSpec {
    var groupKind: TunnelGroupKind { get }
    var name: String { get }
    var onDemandActivation: OnDemandActivation { get }

    /// Validate the spec, returning an error message string if invalid, or nil if valid.
    func validate() -> String?

    /// Build the providerConfiguration dictionary. Returns nil on failure.
    func buildProviderConfiguration(tunnelsManager: TunnelsManager, existing: [String: Any]?) -> [String: Any]?

    /// Get the passwordReference from the appropriate source tunnel.
    func passwordReference(from tunnelsManager: TunnelsManager) -> Data?
}

// MARK: - FailoverGroupSpec

struct FailoverGroupSpec: TunnelGroupSpec {
    let groupKind = TunnelGroupKind.failover
    var name: String
    var tunnelNames: [String]
    var settings: FailoverSettings
    var onDemandActivation: OnDemandActivation

    func validate() -> String? {
        if name.isEmpty { return "Name is empty" }
        if tunnelNames.count < 2 { return "Failover group must have at least 2 tunnels" }
        return nil
    }

    func buildProviderConfiguration(tunnelsManager: TunnelsManager, existing: [String: Any]?) -> [String: Any]? {
        // Build a lookup of existing stored configs for fallback
        var existingConfigByName: [String: String] = [:]
        if let existing = existing {
            let existingNames = (existing["FailoverConfigNames"] as? [String]) ?? []
            let existingConfigs = (existing["FailoverConfigs"] as? [String]) ?? []
            for (n, c) in zip(existingNames, existingConfigs) {
                existingConfigByName[n] = c
            }
        }

        // Resolve all tunnel names to wg-quick configs
        let configs: [(name: String, config: String)] = tunnelNames.compactMap { tunnelName in
            if let t = tunnelsManager.tunnel(named: tunnelName),
               let config = t.tunnelConfiguration?.asWgQuickConfig() {
                return (tunnelName, config)
            }
            if let storedConfig = existingConfigByName[tunnelName] {
                wg_log(.debug, message: "Failover: using stored config for tunnel '\(tunnelName)'")
                return (tunnelName, storedConfig)
            }
            wg_log(.error, message: "Failover: could not load config for tunnel '\(tunnelName)'")
            return nil
        }

        guard configs.count >= 2 else {
            wg_log(.error, staticMessage: "Failover: fewer than 2 valid configs found")
            return nil
        }

        var providerConfig: [String: Any] = existing ?? [:]
        providerConfig["FailoverConfigs"] = configs.map { $0.config }
        providerConfig["FailoverConfigNames"] = configs.map { $0.name }
        if let settingsData = try? JSONEncoder().encode(settings) {
            providerConfig["FailoverSettings"] = settingsData
        }
        return providerConfig
    }

    func passwordReference(from tunnelsManager: TunnelsManager) -> Data? {
        guard let primaryTunnel = tunnelsManager.tunnel(named: tunnelNames[0]),
              let primaryProto = primaryTunnel.tunnelProvider.protocolConfiguration as? NETunnelProviderProtocol else {
            return nil
        }
        return primaryProto.passwordReference
    }
}

// MARK: - TiTGroupSpec

struct TiTGroupSpec: TunnelGroupSpec {
    let groupKind = TunnelGroupKind.tunnelInTunnel
    var name: String
    var outerTunnelName: String
    var innerTunnelName: String
    var onDemandActivation: OnDemandActivation

    func validate() -> String? {
        if name.isEmpty { return "Name is empty" }
        if outerTunnelName == innerTunnelName { return "Outer and inner tunnels must be different" }
        return nil
    }

    func buildProviderConfiguration(tunnelsManager: TunnelsManager, existing: [String: Any]?) -> [String: Any]? {
        guard let outerTunnel = tunnelsManager.tunnel(named: outerTunnelName),
              let outerConfig = outerTunnel.tunnelConfiguration?.asWgQuickConfig() else {
            wg_log(.error, message: "TiT: could not load config for outer tunnel '\(outerTunnelName)'")
            return nil
        }
        guard let innerTunnel = tunnelsManager.tunnel(named: innerTunnelName),
              let innerConfig = innerTunnel.tunnelConfiguration?.asWgQuickConfig() else {
            wg_log(.error, message: "TiT: could not load config for inner tunnel '\(innerTunnelName)'")
            return nil
        }

        let groupId = (existing?[TunnelInTunnelConfigKeys.groupId] as? String) ?? UUID().uuidString
        var providerConfig = existing ?? [:]
        let newConfig = TunnelInTunnelGroup.makeProviderConfiguration(
            groupId: groupId,
            outerWgQuick: outerConfig, outerName: outerTunnelName,
            innerWgQuick: innerConfig, innerName: innerTunnelName
        )
        for (key, value) in newConfig {
            providerConfig[key] = value
        }
        return providerConfig
    }

    func passwordReference(from tunnelsManager: TunnelsManager) -> Data? {
        guard let outerTunnel = tunnelsManager.tunnel(named: outerTunnelName),
              let outerProto = outerTunnel.tunnelProvider.protocolConfiguration as? NETunnelProviderProtocol else {
            return nil
        }
        return outerProto.passwordReference
    }
}

// MARK: - Shared CRUD

extension TunnelsManager {

    func addGroup(spec: TunnelGroupSpec, completionHandler: @escaping (Result<TunnelContainer, TunnelsManagerError>) -> Void) {
        if let validationError = spec.validate() {
            wg_log(.error, message: "\(spec.groupKind.displayName): \(validationError)")
            completionHandler(.failure(TunnelsManagerError.tunnelNameEmpty))
            return
        }

        // Group names share a namespace with tunnel names: config sync and
        // delete protection are name-based, and zip re-imports would otherwise
        // create duplicate groups on every import.
        guard !tunnels.contains(where: { $0.name == spec.name })
                && !failoverGroupTunnels.contains(where: { $0.name == spec.name })
                && !titGroupTunnels.contains(where: { $0.name == spec.name }) else {
            completionHandler(.failure(TunnelsManagerError.tunnelAlreadyExistsWithThatName))
            return
        }

        guard let passwordRef = spec.passwordReference(from: self) else {
            wg_log(.error, message: "\(spec.groupKind.displayName): source tunnel has no valid keychain reference")
            completionHandler(.failure(TunnelsManagerError.tunnelNameEmpty))
            return
        }

        guard let providerConfig = spec.buildProviderConfiguration(tunnelsManager: self, existing: nil) else {
            completionHandler(.failure(TunnelsManagerError.tunnelNameEmpty))
            return
        }

        let groupId = UUID().uuidString

        let tunnelProviderManager = NETunnelProviderManager()
        tunnelProviderManager.localizedDescription = spec.name
        tunnelProviderManager.isEnabled = true

        let proto = NETunnelProviderProtocol()
        guard let appId = Bundle.main.bundleIdentifier else {
            completionHandler(.failure(TunnelsManagerError.tunnelNameEmpty))
            return
        }
        proto.providerBundleIdentifier = "\(appId).network-extension"
        proto.passwordReference = passwordRef
        proto.serverAddress = spec.groupKind.serverAddress

        var finalConfig = providerConfig
        #if os(macOS)
        finalConfig["UID"] = getuid()
        #endif
        finalConfig[spec.groupKind.groupIdKey] = groupId
        proto.providerConfiguration = finalConfig
        tunnelProviderManager.protocolConfiguration = proto

        let onDemandOption = spec.onDemandActivation.toActivateOnDemandOption()
        onDemandOption.apply(on: tunnelProviderManager)
        tunnelProviderManager.isOnDemandEnabled = spec.onDemandActivation.isEnabled

        let activeTunnel = (tunnels + failoverGroupTunnels + titGroupTunnels).first { $0.status == .active || $0.status == .activating }
        let kind = spec.groupKind

        tunnelProviderManager.saveToPreferences { [weak self] error in
            if let error = error {
                wg_log(.error, message: "\(kind.displayName): failed to save group manager: \(error)")
                completionHandler(.failure(TunnelsManagerError.systemErrorOnAddTunnel(systemError: error)))
                return
            }

            guard let self = self else { return }

            #if os(iOS)
            if let activeTunnel = activeTunnel {
                if activeTunnel.status == .inactive || activeTunnel.status == .deactivating {
                    self.startActivation(of: activeTunnel)
                }
                if activeTunnel.status == .active || activeTunnel.status == .activating {
                    activeTunnel.status = .restarting
                }
            }
            #endif

            let groupTunnel = TunnelContainer(tunnel: tunnelProviderManager)
            switch kind {
            case .failover:
                self.failoverGroupTunnels.append(groupTunnel)
                self.failoverGroupTunnels.sort { TunnelsManager.tunnelNameIsLessThan($0.name, $1.name) }
            case .tunnelInTunnel:
                self.titGroupTunnels.append(groupTunnel)
                self.titGroupTunnels.sort { TunnelsManager.tunnelNameIsLessThan($0.name, $1.name) }
            }
            self.groupListDelegate?.groupAdded(kind: kind, at: self.groupTunnels(kind: kind).firstIndex(of: groupTunnel)!)
            completionHandler(.success(groupTunnel))
        }
    }

    func modifyGroup(tunnel: TunnelContainer, spec: TunnelGroupSpec, completionHandler: @escaping (TunnelsManagerError?) -> Void) {
        if let validationError = spec.validate() {
            wg_log(.error, message: "\(spec.groupKind.displayName): \(validationError)")
            completionHandler(TunnelsManagerError.tunnelNameEmpty)
            return
        }

        let kind = spec.groupKind
        let tunnelProviderManager = tunnel.tunnelProvider
        let oldName = tunnelProviderManager.localizedDescription ?? ""
        let isNameChanged = spec.name != oldName

        // Validate everything that can fail before mutating any state: bailing
        // out after the rename below would leave the in-memory container
        // diverged from preferences while reporting success to the UI.
        guard let proto = tunnelProviderManager.protocolConfiguration as? NETunnelProviderProtocol else {
            completionHandler(TunnelsManagerError.groupConfigurationInvalid(groupName: spec.name))
            return
        }

        let existingConfig = proto.providerConfiguration
        guard let providerConfig = spec.buildProviderConfiguration(tunnelsManager: self, existing: existingConfig) else {
            completionHandler(TunnelsManagerError.groupConfigurationInvalid(groupName: spec.name))
            return
        }

        if isNameChanged {
            guard !tunnels.contains(where: { $0.name == spec.name })
                    && !failoverGroupTunnels.contains(where: { $0.name == spec.name })
                    && !titGroupTunnels.contains(where: { $0.name == spec.name }) else {
                completionHandler(TunnelsManagerError.tunnelAlreadyExistsWithThatName)
                return
            }
            tunnel.name = spec.name
            tunnelProviderManager.localizedDescription = spec.name
        }

        // Update passwordReference from spec
        if let passwordRef = spec.passwordReference(from: self) {
            proto.passwordReference = passwordRef
        }

        proto.providerConfiguration = providerConfig

        let isActivatingOnDemand = !tunnelProviderManager.isOnDemandEnabled && spec.onDemandActivation.isEnabled
        let onDemandOption = spec.onDemandActivation.toActivateOnDemandOption()
        onDemandOption.apply(on: tunnelProviderManager)
        tunnelProviderManager.isOnDemandEnabled = spec.onDemandActivation.isEnabled
        tunnelProviderManager.isEnabled = true

        let activeTunnel = (tunnels + failoverGroupTunnels + titGroupTunnels).first { $0.status == .active || $0.status == .activating }

        tunnelProviderManager.saveToPreferences { [weak self] error in
            if let error = error {
                wg_log(.error, message: "\(kind.displayName): failed to save group modification: \(error)")
                completionHandler(TunnelsManagerError.systemErrorOnModifyTunnel(systemError: error))
                return
            }
            guard let self = self else { return }

            #if os(iOS)
            if let activeTunnel = activeTunnel, activeTunnel !== tunnel {
                if activeTunnel.status == .inactive || activeTunnel.status == .deactivating {
                    self.startActivation(of: activeTunnel)
                }
                if activeTunnel.status == .active || activeTunnel.status == .activating {
                    activeTunnel.status = .restarting
                }
            }
            #endif

            if isNameChanged {
                let groupList = self.groupTunnels(kind: kind)
                let oldIndex = groupList.firstIndex(of: tunnel)!
                switch kind {
                case .failover:
                    self.failoverGroupTunnels.sort { TunnelsManager.tunnelNameIsLessThan($0.name, $1.name) }
                case .tunnelInTunnel:
                    self.titGroupTunnels.sort { TunnelsManager.tunnelNameIsLessThan($0.name, $1.name) }
                }
                let newIndex = self.groupTunnels(kind: kind).firstIndex(of: tunnel)!
                self.groupListDelegate?.groupMoved(kind: kind, from: oldIndex, to: newIndex)
                OnDemandSuspensionStore.handleTunnelRenamed(from: oldName, to: spec.name)
            }
            self.groupListDelegate?.groupModified(kind: kind, at: self.groupTunnels(kind: kind).firstIndex(of: tunnel)!)

            if tunnel.status == .active || tunnel.status == .activating || tunnel.status == .reasserting {
                tunnel.status = .restarting
                (tunnel.tunnelProvider.connection as? NETunnelProviderSession)?.stopTunnel()
            }

            if isActivatingOnDemand {
                tunnelProviderManager.loadFromPreferences { error in
                    tunnel.isActivateOnDemandEnabled = tunnelProviderManager.isOnDemandEnabled
                    if let error = error {
                        wg_log(.error, message: "\(kind.displayName): Re-loading after saving configuration failed: \(error)")
                        completionHandler(TunnelsManagerError.systemErrorOnModifyTunnel(systemError: error))
                    } else {
                        completionHandler(nil)
                    }
                }
            } else {
                completionHandler(nil)
            }
        }
    }

    func removeGroup(kind: TunnelGroupKind, tunnel: TunnelContainer, completionHandler: @escaping (TunnelsManagerError?) -> Void) {
        let tunnelProviderManager = tunnel.tunnelProvider
        // Note: we do NOT destroy the passwordReference because it belongs to the source tunnel
        tunnelProviderManager.removeFromPreferences { [weak self] error in
            if let error = error {
                wg_log(.error, message: "\(kind.displayName): failed to remove group manager: \(error)")
                completionHandler(TunnelsManagerError.systemErrorOnRemoveTunnel(systemError: error))
                return
            }
            if let self = self {
                switch kind {
                case .failover:
                    if let index = self.failoverGroupTunnels.firstIndex(of: tunnel) {
                        self.failoverGroupTunnels.remove(at: index)
                        self.groupListDelegate?.groupRemoved(kind: kind, at: index, tunnel: tunnel)
                    }
                case .tunnelInTunnel:
                    if let index = self.titGroupTunnels.firstIndex(of: tunnel) {
                        self.titGroupTunnels.remove(at: index)
                        self.groupListDelegate?.groupRemoved(kind: kind, at: index, tunnel: tunnel)
                    }
                }
            }
            OnDemandSuspensionStore.remove(tunnel.name)
            completionHandler(nil)
        }
    }

    func getGroupState(kind: TunnelGroupKind, for tunnel: TunnelContainer, completionHandler: @escaping ([String: Any]?) -> Void) {
        guard tunnel.status == .active,
              let session = tunnel.tunnelProvider.connection as? NETunnelProviderSession else {
            completionHandler(nil)
            return
        }

        do {
            try session.sendProviderMessage(Data([kind.ipcMessageType])) { responseData in
                guard let data = responseData,
                      let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    completionHandler(nil)
                    return
                }
                completionHandler(state)
            }
        } catch {
            wg_log(.error, message: "\(kind.displayName): failed to query state: \(error)")
            completionHandler(nil)
        }
    }

    func refreshGroupsContaining(kind: TunnelGroupKind, tunnelName: String, oldName: String? = nil) {
        switch kind {
        case .failover:
            refreshFailoverGroupsContaining(tunnelName: tunnelName, oldName: oldName)
        case .tunnelInTunnel:
            refreshTiTGroupsContaining(tunnelName: tunnelName, oldName: oldName)
        }
    }
}
