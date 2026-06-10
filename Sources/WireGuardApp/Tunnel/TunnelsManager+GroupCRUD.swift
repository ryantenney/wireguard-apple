// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import Foundation
import NetworkExtension

// MARK: - TunnelGroupSpec Protocol

/// Result of building a group's providerConfiguration. Member configs are
/// stored as individual keychain items (never plaintext in the NE preferences),
/// so the build also reports which keychain references it created (to delete if
/// the subsequent save fails) and which previous references it superseded (to
/// delete once the save succeeds).
struct GroupProviderConfigResult {
    var providerConfiguration: [String: Any]
    var createdReferences: [Data] = []
    var obsoleteReferences: [Data] = []

    /// Roll back keychain items created for a build whose save never happened.
    func discardCreatedReferences() {
        for ref in createdReferences {
            Keychain.deleteReference(called: ref)
        }
    }

    /// Delete keychain items superseded by a successfully saved build.
    func deleteObsoleteReferences() {
        for ref in obsoleteReferences {
            Keychain.deleteReference(called: ref)
        }
    }
}

/// Protocol that each group type implements to provide its specific configuration building logic.
protocol TunnelGroupSpec {
    var groupKind: TunnelGroupKind { get }
    var name: String { get }
    var onDemandActivation: OnDemandActivation { get }

    /// Validate the spec, returning an error message string if invalid, or nil if valid.
    func validate() -> String?

    /// Build the providerConfiguration dictionary, storing member configs in the
    /// keychain. Returns nil on failure (any keychain items created during a
    /// failed build are already rolled back).
    func buildProviderConfiguration(tunnelsManager: TunnelsManager, existing: [String: Any]?) -> GroupProviderConfigResult?

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

    func buildProviderConfiguration(tunnelsManager: TunnelsManager, existing: [String: Any]?) -> GroupProviderConfigResult? {
        // Build lookups of the group's existing member keychain refs (and any
        // legacy plaintext configs from before the keychain migration) for
        // fallback when a member tunnel can no longer be resolved.
        var existingRefByName: [String: Data] = [:]
        var legacyConfigByName: [String: String] = [:]
        let existingNames = (existing?["FailoverConfigNames"] as? [String]) ?? []
        if let existingRefs = existing?["FailoverConfigRefs"] as? [Data] {
            for (n, r) in zip(existingNames, existingRefs) {
                existingRefByName[n] = r
            }
        }
        if let legacyConfigs = existing?["FailoverConfigs"] as? [String] {
            for (n, c) in zip(existingNames, legacyConfigs) {
                legacyConfigByName[n] = c
            }
        }

        var created: [Data] = []
        var kept = Set<Data>()

        // Resolve each member to a keychain reference holding its wg-quick config
        let members: [(name: String, ref: Data)] = tunnelNames.compactMap { tunnelName in
            if let t = tunnelsManager.tunnel(named: tunnelName),
               let config = t.tunnelConfiguration?.asWgQuickConfig() {
                if let ref = Keychain.makeReference(containing: config, called: "\(name): \(tunnelName)") {
                    created.append(ref)
                    return (tunnelName, ref)
                }
                wg_log(.error, message: "Failover: could not store config for tunnel '\(tunnelName)' in keychain")
                return nil
            }
            if let existingRef = existingRefByName[tunnelName], Keychain.verifyReference(called: existingRef) {
                wg_log(.debug, message: "Failover: keeping stored config for tunnel '\(tunnelName)'")
                kept.insert(existingRef)
                return (tunnelName, existingRef)
            }
            if let legacyConfig = legacyConfigByName[tunnelName],
               let ref = Keychain.makeReference(containing: legacyConfig, called: "\(name): \(tunnelName)") {
                wg_log(.debug, message: "Failover: migrated stored config for tunnel '\(tunnelName)' to keychain")
                created.append(ref)
                return (tunnelName, ref)
            }
            wg_log(.error, message: "Failover: could not load config for tunnel '\(tunnelName)'")
            return nil
        }

        guard members.count >= 2 else {
            wg_log(.error, staticMessage: "Failover: fewer than 2 valid configs found")
            for ref in created {
                Keychain.deleteReference(called: ref)
            }
            return nil
        }

        var providerConfig: [String: Any] = existing ?? [:]
        providerConfig["FailoverConfigRefs"] = members.map { $0.ref }
        providerConfig["FailoverConfigNames"] = members.map { $0.name }
        providerConfig.removeValue(forKey: "FailoverConfigs") // legacy plaintext storage
        if let settingsData = try? JSONEncoder().encode(settings) {
            providerConfig["FailoverSettings"] = settingsData
        }

        let obsolete = existingRefByName.values.filter { !kept.contains($0) }
        return GroupProviderConfigResult(providerConfiguration: providerConfig,
                                         createdReferences: created,
                                         obsoleteReferences: Array(obsolete))
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

    func buildProviderConfiguration(tunnelsManager: TunnelsManager, existing: [String: Any]?) -> GroupProviderConfigResult? {
        var created: [Data] = []
        var kept = Set<Data>()

        /// Resolve a member to a keychain reference: prefer the live tunnel's
        /// current config; fall back to the group's existing keychain ref (or a
        /// pre-migration legacy plaintext config) if the tunnel is unresolvable
        /// and the member name is unchanged.
        func resolveMember(tunnelName: String, existingNameKey: String, refKey: String, legacyConfigKey: String) -> Data? {
            if let t = tunnelsManager.tunnel(named: tunnelName),
               let config = t.tunnelConfiguration?.asWgQuickConfig() {
                if let ref = Keychain.makeReference(containing: config, called: "\(name): \(tunnelName)") {
                    created.append(ref)
                    return ref
                }
                wg_log(.error, message: "TiT: could not store config for tunnel '\(tunnelName)' in keychain")
                return nil
            }
            guard (existing?[existingNameKey] as? String) == tunnelName else {
                wg_log(.error, message: "TiT: could not load config for tunnel '\(tunnelName)'")
                return nil
            }
            if let existingRef = existing?[refKey] as? Data, Keychain.verifyReference(called: existingRef) {
                wg_log(.debug, message: "TiT: keeping stored config for tunnel '\(tunnelName)'")
                kept.insert(existingRef)
                return existingRef
            }
            if let legacyConfig = existing?[legacyConfigKey] as? String,
               let ref = Keychain.makeReference(containing: legacyConfig, called: "\(name): \(tunnelName)") {
                wg_log(.debug, message: "TiT: migrated stored config for tunnel '\(tunnelName)' to keychain")
                created.append(ref)
                return ref
            }
            wg_log(.error, message: "TiT: could not load config for tunnel '\(tunnelName)'")
            return nil
        }

        guard let outerRef = resolveMember(tunnelName: outerTunnelName,
                                           existingNameKey: TunnelInTunnelConfigKeys.outerName,
                                           refKey: TunnelInTunnelConfigKeys.outerConfigRef,
                                           legacyConfigKey: TunnelInTunnelConfigKeys.outerConfig),
              let innerRef = resolveMember(tunnelName: innerTunnelName,
                                           existingNameKey: TunnelInTunnelConfigKeys.innerName,
                                           refKey: TunnelInTunnelConfigKeys.innerConfigRef,
                                           legacyConfigKey: TunnelInTunnelConfigKeys.innerConfig) else {
            for ref in created {
                Keychain.deleteReference(called: ref)
            }
            return nil
        }

        let groupId = (existing?[TunnelInTunnelConfigKeys.groupId] as? String) ?? UUID().uuidString
        var providerConfig = existing ?? [:]
        let newConfig = TunnelInTunnelGroup.makeProviderConfiguration(
            groupId: groupId,
            outerConfigRef: outerRef, outerName: outerTunnelName,
            innerConfigRef: innerRef, innerName: innerTunnelName
        )
        for (key, value) in newConfig {
            providerConfig[key] = value
        }
        // Legacy plaintext storage
        providerConfig.removeValue(forKey: TunnelInTunnelConfigKeys.outerConfig)
        providerConfig.removeValue(forKey: TunnelInTunnelConfigKeys.innerConfig)

        var obsolete: [Data] = []
        for refKey in [TunnelInTunnelConfigKeys.outerConfigRef, TunnelInTunnelConfigKeys.innerConfigRef] {
            if let oldRef = existing?[refKey] as? Data, !kept.contains(oldRef) {
                obsolete.append(oldRef)
            }
        }
        return GroupProviderConfigResult(providerConfiguration: providerConfig,
                                         createdReferences: created,
                                         obsoleteReferences: obsolete)
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
            let error: TunnelsManagerError = spec.name.isEmpty ? .tunnelNameEmpty : .groupConfigurationInvalid(groupName: spec.name)
            completionHandler(.failure(error))
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
            completionHandler(.failure(TunnelsManagerError.groupConfigurationInvalid(groupName: spec.name)))
            return
        }

        guard let buildResult = spec.buildProviderConfiguration(tunnelsManager: self, existing: nil) else {
            completionHandler(.failure(TunnelsManagerError.groupConfigurationInvalid(groupName: spec.name)))
            return
        }

        let groupId = UUID().uuidString

        let tunnelProviderManager = NETunnelProviderManager()
        tunnelProviderManager.localizedDescription = spec.name
        tunnelProviderManager.isEnabled = true

        let proto = NETunnelProviderProtocol()
        guard let appId = Bundle.main.bundleIdentifier else {
            buildResult.discardCreatedReferences()
            completionHandler(.failure(TunnelsManagerError.groupConfigurationInvalid(groupName: spec.name)))
            return
        }
        proto.providerBundleIdentifier = "\(appId).network-extension"
        proto.passwordReference = passwordRef
        proto.serverAddress = spec.groupKind.serverAddress

        var finalConfig = buildResult.providerConfiguration
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
                buildResult.discardCreatedReferences()
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
            let error: TunnelsManagerError = spec.name.isEmpty ? .tunnelNameEmpty : .groupConfigurationInvalid(groupName: spec.name)
            completionHandler(error)
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
        guard let buildResult = spec.buildProviderConfiguration(tunnelsManager: self, existing: existingConfig) else {
            completionHandler(TunnelsManagerError.groupConfigurationInvalid(groupName: spec.name))
            return
        }

        if isNameChanged {
            guard !tunnels.contains(where: { $0.name == spec.name })
                    && !failoverGroupTunnels.contains(where: { $0.name == spec.name })
                    && !titGroupTunnels.contains(where: { $0.name == spec.name }) else {
                buildResult.discardCreatedReferences()
                completionHandler(TunnelsManagerError.tunnelAlreadyExistsWithThatName)
                return
            }
            tunnel.name = spec.name
            tunnelProviderManager.localizedDescription = spec.name
        }

        // Whether the running tunnel's effective configuration changed.
        // Member keychain refs rotate on every save, so compare the stable
        // facts: membership and (for failover) the encoded settings. Member
        // *content* changes arrive via the refresh paths, not modifyGroup.
        let isRunningConfigChanged: Bool
        switch kind {
        case .failover:
            isRunningConfigChanged =
                (existingConfig?["FailoverConfigNames"] as? [String]) != (buildResult.providerConfiguration["FailoverConfigNames"] as? [String])
                || (existingConfig?["FailoverSettings"] as? Data) != (buildResult.providerConfiguration["FailoverSettings"] as? Data)
        case .tunnelInTunnel:
            isRunningConfigChanged =
                (existingConfig?[TunnelInTunnelConfigKeys.outerName] as? String) != (buildResult.providerConfiguration[TunnelInTunnelConfigKeys.outerName] as? String)
                || (existingConfig?[TunnelInTunnelConfigKeys.innerName] as? String) != (buildResult.providerConfiguration[TunnelInTunnelConfigKeys.innerName] as? String)
        }

        // Update passwordReference from spec
        if let passwordRef = spec.passwordReference(from: self) {
            proto.passwordReference = passwordRef
        }

        proto.providerConfiguration = buildResult.providerConfiguration

        let isActivatingOnDemand = !tunnelProviderManager.isOnDemandEnabled && spec.onDemandActivation.isEnabled
        let onDemandOption = spec.onDemandActivation.toActivateOnDemandOption()
        onDemandOption.apply(on: tunnelProviderManager)
        tunnelProviderManager.isOnDemandEnabled = spec.onDemandActivation.isEnabled
        tunnelProviderManager.isEnabled = true

        let activeTunnel = (tunnels + failoverGroupTunnels + titGroupTunnels).first { $0.status == .active || $0.status == .activating }

        tunnelProviderManager.saveToPreferences { [weak self] error in
            if let error = error {
                wg_log(.error, message: "\(kind.displayName): failed to save group modification: \(error)")
                buildResult.discardCreatedReferences()
                completionHandler(TunnelsManagerError.systemErrorOnModifyTunnel(systemError: error))
                return
            }
            buildResult.deleteObsoleteReferences()
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

            // Only drop the live VPN when the change actually affects it —
            // saving an unmodified edit screen shouldn't restart the tunnel.
            if isRunningConfigChanged,
               tunnel.status == .active || tunnel.status == .activating || tunnel.status == .reasserting {
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
        // The group owns its members' keychain config items; destroy them with the
        // group. We do NOT destroy the passwordReference — that belongs to the
        // source tunnel.
        let proto = tunnelProviderManager.protocolConfiguration as? NETunnelProviderProtocol
        let memberRefs = TunnelsManager.groupMemberConfigReferences(in: proto?.providerConfiguration)
        tunnelProviderManager.removeFromPreferences { [weak self] error in
            if let error = error {
                wg_log(.error, message: "\(kind.displayName): failed to remove group manager: \(error)")
                completionHandler(TunnelsManagerError.systemErrorOnRemoveTunnel(systemError: error))
                return
            }
            for ref in memberRefs {
                Keychain.deleteReference(called: ref)
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
        // .reasserting/.restarting still have a live session — a failover swap
        // reasserts, and refusing to poll then makes the UI go stale exactly
        // when the state is most interesting.
        guard tunnel.status == .active || tunnel.status == .reasserting || tunnel.status == .restarting,
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

    /// All keychain references owned by a group manager (its members' stored
    /// configs). Does not include the borrowed passwordReference.
    static func groupMemberConfigReferences(in providerConfiguration: [String: Any]?) -> [Data] {
        var refs: [Data] = []
        if let failoverRefs = providerConfiguration?["FailoverConfigRefs"] as? [Data] {
            refs.append(contentsOf: failoverRefs)
        }
        if let outerRef = providerConfiguration?[TunnelInTunnelConfigKeys.outerConfigRef] as? Data {
            refs.append(outerRef)
        }
        if let innerRef = providerConfiguration?[TunnelInTunnelConfigKeys.innerConfigRef] as? Data {
            refs.append(innerRef)
        }
        return refs
    }
}

// MARK: - Legacy plaintext migration

extension NETunnelProviderProtocol {
    /// Older versions stored group members' full wg-quick configs (private keys
    /// included) as plaintext in providerConfiguration, which is persisted in
    /// the system NE preferences rather than the keychain. Move them into
    /// keychain items and store persistent references instead.
    /// Returns true if a migration happened and the manager needs saving.
    func migrateGroupConfigsToKeychainIfNeeded(called name: String) -> Bool {
        guard var config = providerConfiguration else { return false }
        var changed = false

        if let legacyConfigs = config["FailoverConfigs"] as? [String] {
            if config["FailoverConfigRefs"] == nil {
                let memberNames = config["FailoverConfigNames"] as? [String] ?? []
                var refs: [Data] = []
                for (index, legacyConfig) in legacyConfigs.enumerated() {
                    let memberName = memberNames.indices.contains(index) ? memberNames[index] : "#\(index)"
                    guard let ref = Keychain.makeReference(containing: legacyConfig, called: "\(name): \(memberName)") else {
                        // Keychain unavailable — keep the plaintext configs so the
                        // group still works; migration retries on next launch.
                        wg_log(.error, message: "Failover: keychain migration failed for group '\(name)', will retry")
                        for r in refs {
                            Keychain.deleteReference(called: r)
                        }
                        return changed
                    }
                    refs.append(ref)
                }
                config["FailoverConfigRefs"] = refs
                wg_log(.info, message: "Failover: migrated \(refs.count) member configs of group '\(name)' to keychain")
            }
            config.removeValue(forKey: "FailoverConfigs")
            changed = true
        }

        let hasLegacyTiT = config[TunnelInTunnelConfigKeys.outerConfig] != nil
            || config[TunnelInTunnelConfigKeys.innerConfig] != nil
        if hasLegacyTiT {
            let hasRefs = config[TunnelInTunnelConfigKeys.outerConfigRef] != nil
                && config[TunnelInTunnelConfigKeys.innerConfigRef] != nil
            if !hasRefs {
                guard let legacyOuter = config[TunnelInTunnelConfigKeys.outerConfig] as? String,
                      let legacyInner = config[TunnelInTunnelConfigKeys.innerConfig] as? String else {
                    return changed
                }
                let outerName = config[TunnelInTunnelConfigKeys.outerName] as? String ?? "outer"
                let innerName = config[TunnelInTunnelConfigKeys.innerName] as? String ?? "inner"
                guard let outerRef = Keychain.makeReference(containing: legacyOuter, called: "\(name): \(outerName)") else {
                    wg_log(.error, message: "TiT: keychain migration failed for group '\(name)', will retry")
                    return changed
                }
                guard let innerRef = Keychain.makeReference(containing: legacyInner, called: "\(name): \(innerName)") else {
                    wg_log(.error, message: "TiT: keychain migration failed for group '\(name)', will retry")
                    Keychain.deleteReference(called: outerRef)
                    return changed
                }
                config[TunnelInTunnelConfigKeys.outerConfigRef] = outerRef
                config[TunnelInTunnelConfigKeys.innerConfigRef] = innerRef
                wg_log(.info, message: "TiT: migrated member configs of group '\(name)' to keychain")
            }
            config.removeValue(forKey: TunnelInTunnelConfigKeys.outerConfig)
            config.removeValue(forKey: TunnelInTunnelConfigKeys.innerConfig)
            changed = true
        }

        if changed {
            providerConfiguration = config
        }
        return changed
    }
}
