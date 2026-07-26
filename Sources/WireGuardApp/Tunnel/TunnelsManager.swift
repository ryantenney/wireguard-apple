// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.
// Copyright © 2026 Ryan Tenney.

import Foundation
import NetworkExtension
import os.log

protocol TunnelsManagerListDelegate: AnyObject {
    func tunnelAdded(at index: Int)
    func tunnelModified(at index: Int)
    func tunnelMoved(from oldIndex: Int, to newIndex: Int)
    func tunnelRemoved(at index: Int, tunnel: TunnelContainer)
}

// TunnelsManagerGroupListDelegate is defined in TunnelGroupKind.swift

protocol TunnelsManagerActivationDelegate: AnyObject {
    func tunnelActivationAttemptFailed(tunnel: TunnelContainer, error: TunnelsManagerActivationAttemptError) // startTunnel wasn't called or failed
    func tunnelActivationAttemptSucceeded(tunnel: TunnelContainer) // startTunnel succeeded
    func tunnelActivationFailed(tunnel: TunnelContainer, error: TunnelsManagerActivationError) // status didn't change to connected
    func tunnelActivationSucceeded(tunnel: TunnelContainer) // status changed to connected
}

class TunnelsManager {
    var tunnels: [TunnelContainer]
    var failoverGroupTunnels: [TunnelContainer]
    var titGroupTunnels: [TunnelContainer]
    weak var tunnelsListDelegate: TunnelsManagerListDelegate?
    weak var groupListDelegate: TunnelsManagerGroupListDelegate?
    weak var activationDelegate: TunnelsManagerActivationDelegate?
    private var statusObservationToken: NotificationToken?
    private var waiteeObservationToken: NSKeyValueObservation?
    private var configurationsObservationToken: NotificationToken?
    #if os(iOS)
    private let widgetStatusWriter = WidgetStatusWriter()
    #endif

    init(tunnelProviders: [NETunnelProviderManager]) {
        let allContainers = tunnelProviders.map { TunnelContainer(tunnel: $0) }
        tunnels = allContainers.filter { !$0.isFailoverGroup && !$0.isTiTGroup }.sorted { TunnelsManager.tunnelNameIsLessThan($0.name, $1.name) }
        failoverGroupTunnels = allContainers.filter { $0.isFailoverGroup }.sorted { TunnelsManager.tunnelNameIsLessThan($0.name, $1.name) }
        titGroupTunnels = allContainers.filter { $0.isTiTGroup }.sorted { TunnelsManager.tunnelNameIsLessThan($0.name, $1.name) }
        startObservingTunnelStatuses()
        startObservingTunnelConfigurations()
        OnDemandSuspensionStore.cleanup(except: Set(allContainers.map { $0.name }))
        restoreSuspendedOnDemandIfQuiescent()
    }

    static func create(completionHandler: @escaping (Result<TunnelsManager, TunnelsManagerError>) -> Void) {
        #if targetEnvironment(simulator)
        completionHandler(.success(TunnelsManager(tunnelProviders: MockTunnels.createMockTunnels())))
        #else
        NETunnelProviderManager.loadAllFromPreferences { managers, error in
            if let error = error {
                wg_log(.error, message: "Failed to load tunnel provider managers: \(error)")
                completionHandler(.failure(TunnelsManagerError.systemErrorOnListingTunnels(systemError: error)))
                return
            }

            var tunnelManagers = managers ?? []
            var refs: Set<Data> = []
            var regularRefs: Set<Data> = []
            var tunnelNames: Set<String> = []

            // Names of every tunnel referenced by a failover or TiT group. A member whose keychain
            // entry fails to verify is kept (and logged) rather than removed, so a group never
            // silently loses a connection.
            let groupMemberNames = TunnelsManager.groupMemberNames(in: tunnelManagers)

            // Pass 1: regular tunnels (migration, verification, orphan removal).
            for (index, tunnelManager) in tunnelManagers.enumerated().reversed() {
                if let tunnelName = tunnelManager.localizedDescription {
                    tunnelNames.insert(tunnelName)
                }
                guard let proto = tunnelManager.protocolConfiguration as? NETunnelProviderProtocol else { continue }
                // Failover group and TiT group managers keep their own copy of the primary/outer
                // config in the Keychain (pass 2 below) — skip the regular migration and orphan
                // removal for them. They additionally own one keychain item per member config,
                // all of which must be whitelisted.
                let isFailoverGroup = proto.providerConfiguration?[ProviderConfigurationKeys.failoverGroupId] != nil
                let isTiTGroup = proto.providerConfiguration?[ProviderConfigurationKeys.titGroupId] != nil
                if isFailoverGroup || isTiTGroup {
                    if let ref = proto.passwordReference {
                        refs.insert(ref)
                    }
                    // Move any legacy plaintext member configs into the keychain.
                    // Only for groups we own (macOS keychains are per-user).
                    #if os(macOS)
                    let ownsGroup = proto.providerConfiguration?["UID"] as? uid_t == getuid()
                    #else
                    let ownsGroup = true
                    #endif
                    if ownsGroup && proto.migrateGroupConfigsToKeychainIfNeeded(called: tunnelManager.localizedDescription ?? "unknown") {
                        tunnelManager.saveToPreferences { _ in }
                    }
                    for ref in TunnelsManager.groupMemberConfigReferences(in: proto.providerConfiguration) {
                        refs.insert(ref)
                    }
                    continue
                }
                if proto.migrateConfigurationIfNeeded(called: tunnelManager.localizedDescription ?? "unknown") {
                    tunnelManager.saveToPreferences { _ in }
                }
                #if os(iOS)
                let passwordRef = proto.verifyConfigurationReference() ? proto.passwordReference : nil
                #elseif os(macOS)
                let passwordRef: Data?
                if proto.providerConfiguration?[ProviderConfigurationKeys.uid] as? uid_t == getuid() {
                    passwordRef = proto.verifyConfigurationReference() ? proto.passwordReference : nil
                } else {
                    passwordRef = proto.passwordReference // To handle multiple users in macOS, we skip verifying
                }
                #else
                #error("Unimplemented")
                #endif
                let name = tunnelManager.localizedDescription ?? "<unknown>"
                if let ref = passwordRef {
                    refs.insert(ref)
                    regularRefs.insert(ref)
                } else if groupMemberNames.contains(name) {
                    wg_log(.error, message: "Tunnel '\(name)' has a non-verifying keychain entry but belongs to a group; keeping it so the group stays intact")
                } else {
                    wg_log(.info, message: "Removing orphaned tunnel with non-verifying keychain entry: \(name)")
                    tunnelManager.removeFromPreferences { _ in }
                    tunnelManagers.remove(at: index)
                }
            }

            // Pass 2: group managers own a private keychain copy of their primary/outer config.
            // Older builds borrowed the member's reference; migrate those (and repair dangling
            // ones) so editing or deleting a member can never invalidate the group.
            for tunnelManager in tunnelManagers {
                guard let proto = tunnelManager.protocolConfiguration as? NETunnelProviderProtocol else { continue }
                let providerConfig = proto.providerConfiguration ?? [:]
                let isFailoverGroup = providerConfig[ProviderConfigurationKeys.failoverGroupId] != nil
                let isTiTGroup = providerConfig[ProviderConfigurationKeys.titGroupId] != nil
                guard isFailoverGroup || isTiTGroup else { continue }
                let name = tunnelManager.localizedDescription ?? "<unknown>"
                #if os(macOS)
                // Another user's group: its keychain items are not visible to us, so never "repair" it.
                if providerConfig["UID"] as? uid_t != getuid() {
                    if let ref = proto.passwordReference { refs.insert(ref) }
                    continue
                }
                #endif
                let isShared = proto.passwordReference.map { regularRefs.contains($0) } ?? false
                if let ref = proto.passwordReference, !isShared, proto.verifyConfigurationReference() {
                    refs.insert(ref)
                    continue
                }
                // Rebuild from the member config pass 1 just moved into the keychain, falling
                // back to any plaintext left by a group whose migration has not run yet.
                let sourceConfig: String?
                if isFailoverGroup {
                    sourceConfig = (providerConfig[ProviderConfigurationKeys.failoverConfigRefs] as? [Data])?.first.flatMap { Keychain.openReference(called: $0) }
                        ?? (providerConfig[ProviderConfigurationKeys.failoverConfigs] as? [String])?.first
                } else {
                    sourceConfig = (providerConfig[ProviderConfigurationKeys.titOuterConfigRef] as? Data).flatMap { Keychain.openReference(called: $0) }
                        ?? providerConfig[ProviderConfigurationKeys.titOuterConfig] as? String
                }
                guard let config = sourceConfig,
                      let newRef = Keychain.makeReference(containing: config, called: name) else {
                    wg_log(.error, message: "Group '\(name)' has no usable keychain entry and no stored config to rebuild one from")
                    if let ref = proto.passwordReference { refs.insert(ref) }
                    continue
                }
                wg_log(.info, message: "Group '\(name)': \(isShared ? "migrating shared" : "repairing") keychain reference to a group-owned entry")
                proto.passwordReference = newRef
                refs.insert(newRef)
                tunnelManager.saveToPreferences { error in
                    if let error = error {
                        wg_log(.error, message: "Group '\(name)': failed to save migrated keychain reference: \(error)")
                    }
                }
            }
            Keychain.deleteReferences(except: refs)
            #if os(iOS)
            RecentTunnelsTracker.cleanupTunnels(except: tunnelNames)
            EndpointLocationStore.cleanupTunnels(except: tunnelNames)
            #endif

            // Finalize any session-history record left orphaned by an unclean extension exit.
            // Only safe when no tunnel is currently connecting/connected; otherwise the file is
            // owned by the running extension and will be rewritten momentarily.
            let anyActive = tunnelManagers.contains { manager in
                let status = manager.connection.status
                return status == .connected || status == .connecting || status == .reasserting
            }
            if !anyActive {
                DispatchQueue.global(qos: .utility).async {
                    SessionHistoryStore.recoverOrphanedCurrent()
                }
            }

            completionHandler(.success(TunnelsManager(tunnelProviders: tunnelManagers)))
        }
        #endif
    }

    func reload() {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, _ in
            guard let self = self else { return }

            let loadedTunnelProviders = managers ?? []
            let loadedRegular = loadedTunnelProviders.filter {
                let config = ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration
                return config?[ProviderConfigurationKeys.failoverGroupId] == nil && config?[ProviderConfigurationKeys.titGroupId] == nil
            }
            let loadedFailoverGroups = loadedTunnelProviders.filter {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration?[ProviderConfigurationKeys.failoverGroupId] != nil
            }
            let loadedTiTGroups = loadedTunnelProviders.filter {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration?[ProviderConfigurationKeys.titGroupId] != nil
            }

            // Reconcile regular tunnels. Tunnels are matched by name (names are unique); a
            // configuration change is adopted in place rather than removing and re-adding the
            // row, so a transient keychain read failure can never make a tunnel disappear.
            for (index, currentTunnel) in self.tunnels.enumerated().reversed() {
                if !loadedRegular.contains(where: { $0.localizedDescription == currentTunnel.name }) {
                    wg_log(.info, message: "Reload: tunnel '\(currentTunnel.name)' is no longer in preferences, removing it from the list")
                    self.tunnels.remove(at: index)
                    self.tunnelsListDelegate?.tunnelRemoved(at: index, tunnel: currentTunnel)
                }
            }
            for loadedTunnelProvider in loadedRegular {
                if let matchingTunnel = self.tunnels.first(where: { $0.name == loadedTunnelProvider.localizedDescription }) {
                    let isConfigurationChanged = !loadedTunnelProvider.isEquivalentTo(matchingTunnel)
                    matchingTunnel.tunnelProvider = loadedTunnelProvider
                    matchingTunnel.refreshStatus()
                    if isConfigurationChanged, let tunnelIndex = self.tunnels.firstIndex(of: matchingTunnel) {
                        wg_log(.debug, message: "Reload: tunnel '\(matchingTunnel.name)' changed outside the app, refreshing it in place")
                        self.tunnelsListDelegate?.tunnelModified(at: tunnelIndex)
                    }
                } else {
                    if let proto = loadedTunnelProvider.protocolConfiguration as? NETunnelProviderProtocol {
                        if proto.migrateConfigurationIfNeeded(called: loadedTunnelProvider.localizedDescription ?? "unknown") {
                            loadedTunnelProvider.saveToPreferences { _ in }
                        }
                    }
                    let tunnel = TunnelContainer(tunnel: loadedTunnelProvider)
                    self.tunnels.append(tunnel)
                    self.tunnels.sort { TunnelsManager.tunnelNameIsLessThan($0.name, $1.name) }
                    self.tunnelsListDelegate?.tunnelAdded(at: self.tunnels.firstIndex(of: tunnel)!)
                }
            }

            // Reconcile group tunnels (same shape per kind)
            self.reconcileGroups(kind: .failover, loaded: loadedFailoverGroups)
            self.reconcileGroups(kind: .tunnelInTunnel, loaded: loadedTiTGroups)
        }
    }

    /// Reconcile one group kind's array against freshly loaded managers:
    /// remove vanished groups, refresh matching ones, add new ones.
    private func reconcileGroups(kind: TunnelGroupKind, loaded: [NETunnelProviderManager]) {
        let keyPath = groupArrayKeyPath(kind)
        for (index, currentGroup) in self[keyPath: keyPath].enumerated().reversed() {
            if !loaded.contains(where: { $0.isEquivalentToGroup(kind: kind, currentGroup) }) {
                self[keyPath: keyPath].remove(at: index)
                groupListDelegate?.groupRemoved(kind: kind, at: index, tunnel: currentGroup)
            }
        }
        for loadedProvider in loaded {
            if let matchingGroup = self[keyPath: keyPath].first(where: { loadedProvider.isEquivalentToGroup(kind: kind, $0) }) {
                matchingGroup.tunnelProvider = loadedProvider
                matchingGroup.refreshStatus()
            } else {
                let groupTunnel = TunnelContainer(tunnel: loadedProvider)
                self[keyPath: keyPath].append(groupTunnel)
                self[keyPath: keyPath].sort { TunnelsManager.tunnelNameIsLessThan($0.name, $1.name) }
                groupListDelegate?.groupAdded(kind: kind, at: self[keyPath: keyPath].firstIndex(of: groupTunnel)!)
            }
        }
    }

    func add(tunnelConfiguration: TunnelConfiguration, onDemandOption: ActivateOnDemandOption = .off, completionHandler: @escaping (Result<TunnelContainer, TunnelsManagerError>) -> Void) {
        let tunnelName = tunnelConfiguration.name ?? ""
        if tunnelName.isEmpty {
            completionHandler(.failure(TunnelsManagerError.tunnelNameEmpty))
            return
        }

        if tunnels.contains(where: { $0.name == tunnelName }) || failoverGroupTunnels.contains(where: { $0.name == tunnelName }) || titGroupTunnels.contains(where: { $0.name == tunnelName }) {
            completionHandler(.failure(TunnelsManagerError.tunnelAlreadyExistsWithThatName))
            return
        }

        let tunnelProviderManager = NETunnelProviderManager()
        tunnelProviderManager.setTunnelConfiguration(tunnelConfiguration)
        tunnelProviderManager.isEnabled = true

        onDemandOption.apply(on: tunnelProviderManager)

        let activeTunnel = allTunnels.first { $0.status == .active || $0.status == .activating }

        tunnelProviderManager.saveToPreferences { [weak self] error in
            if let error = error {
                wg_log(.error, message: "Add: Saving configuration failed: \(error)")
                (tunnelProviderManager.protocolConfiguration as? NETunnelProviderProtocol)?.destroyConfigurationReference()
                completionHandler(.failure(TunnelsManagerError.systemErrorOnAddTunnel(systemError: error)))
                return
            }

            guard let self = self else { return }

            #if os(iOS)
            // HACK: In iOS, adding a tunnel causes deactivation of any currently active tunnel.
            // This is an ugly hack to reactivate the tunnel that has been deactivated like that.
            if let activeTunnel = activeTunnel {
                if activeTunnel.status == .inactive || activeTunnel.status == .deactivating {
                    self.startActivation(of: activeTunnel)
                }
                if activeTunnel.status == .active || activeTunnel.status == .activating {
                    activeTunnel.status = .restarting
                }
            }
            #endif

            let tunnel = TunnelContainer(tunnel: tunnelProviderManager)
            self.tunnels.append(tunnel)
            self.tunnels.sort { TunnelsManager.tunnelNameIsLessThan($0.name, $1.name) }
            self.tunnelsListDelegate?.tunnelAdded(at: self.tunnels.firstIndex(of: tunnel)!)
            completionHandler(.success(tunnel))
        }
    }

    func addMultiple(tunnelConfigurations: [TunnelConfiguration], completionHandler: @escaping (UInt, TunnelsManagerError?) -> Void) {
        // Temporarily pause observation of changes to VPN configurations to prevent the feedback
        // loop that causes `reload()` to be called on each newly added tunnel, which significantly
        // impacts performance.
        configurationsObservationToken = nil

        self.addMultiple(tunnelConfigurations: ArraySlice(tunnelConfigurations), numberSuccessful: 0, lastError: nil) { [weak self] numSucceeded, error in
            completionHandler(numSucceeded, error)

            // Restart observation of changes to VPN configrations.
            self?.startObservingTunnelConfigurations()

            // Force reload all configurations to make sure that all tunnels are up to date.
            self?.reload()
        }
    }

    private func addMultiple(tunnelConfigurations: ArraySlice<TunnelConfiguration>, numberSuccessful: UInt, lastError: TunnelsManagerError?, completionHandler: @escaping (UInt, TunnelsManagerError?) -> Void) {
        guard let head = tunnelConfigurations.first else {
            completionHandler(numberSuccessful, lastError)
            return
        }
        let tail = tunnelConfigurations.dropFirst()
        add(tunnelConfiguration: head) { [weak self, tail] result in
            DispatchQueue.main.async {
                var numberSuccessfulCount = numberSuccessful
                var lastError: TunnelsManagerError?
                switch result {
                case .failure(let error):
                    lastError = error
                case .success:
                    numberSuccessfulCount = numberSuccessful + 1
                }
                self?.addMultiple(tunnelConfigurations: tail, numberSuccessful: numberSuccessfulCount, lastError: lastError, completionHandler: completionHandler)
            }
        }
    }

    func modify(tunnel: TunnelContainer, tunnelConfiguration: TunnelConfiguration,
                onDemandOption: ActivateOnDemandOption,
                shouldEnsureOnDemandEnabled: Bool = false,
                completionHandler: @escaping (TunnelsManagerError?) -> Void) {
        let tunnelName = tunnelConfiguration.name ?? ""
        if tunnelName.isEmpty {
            completionHandler(TunnelsManagerError.tunnelNameEmpty)
            return
        }

        let tunnelProviderManager = tunnel.tunnelProvider

        let isIntroducingOnDemandRules = (tunnelProviderManager.onDemandRules ?? []).isEmpty && onDemandOption != .off
        if isIntroducingOnDemandRules && tunnel.status != .inactive && tunnel.status != .deactivating {
            tunnel.onDeactivated = { [weak self] in
                self?.modify(tunnel: tunnel, tunnelConfiguration: tunnelConfiguration,
                             onDemandOption: onDemandOption, shouldEnsureOnDemandEnabled: true,
                             completionHandler: completionHandler)
            }
            self.startDeactivation(of: tunnel)
            return
        } else {
            tunnel.onDeactivated = nil
        }

        let oldName = tunnelProviderManager.localizedDescription ?? ""
        let isNameChanged = tunnelName != oldName
        if isNameChanged {
            guard !tunnels.contains(where: { $0.name == tunnelName }) && !failoverGroupTunnels.contains(where: { $0.name == tunnelName }) && !titGroupTunnels.contains(where: { $0.name == tunnelName }) else {
                completionHandler(TunnelsManagerError.tunnelAlreadyExistsWithThatName)
                return
            }
            tunnel.name = tunnelName
        }

        var isTunnelConfigurationChanged = false
        if tunnelProviderManager.tunnelConfiguration != tunnelConfiguration {
            tunnelProviderManager.setTunnelConfiguration(tunnelConfiguration)
            isTunnelConfigurationChanged = true
        }
        tunnelProviderManager.isEnabled = true

        let isActivatingOnDemand = !tunnelProviderManager.isOnDemandEnabled && shouldEnsureOnDemandEnabled
        onDemandOption.apply(on: tunnelProviderManager)
        if shouldEnsureOnDemandEnabled {
            tunnelProviderManager.isOnDemandEnabled = true
        }

        // Capture the active tunnel before saving — on iOS, saveToPreferences on any
        // NETunnelProviderManager can cause the system to deactivate the currently active tunnel.
        let activeTunnel = allTunnels.first { $0.status == .active || $0.status == .activating }

        tunnelProviderManager.saveToPreferences { [weak self] error in
            if let error = error {
                // TODO: the passwordReference for the old one has already been removed at this point and we can't easily roll back!
                wg_log(.error, message: "Modify: Saving configuration failed: \(error)")
                completionHandler(TunnelsManagerError.systemErrorOnModifyTunnel(systemError: error))
                return
            }
            guard let self = self else { return }

            #if os(iOS)
            // HACK: On iOS, saving any tunnel config can deactivate the active tunnel.
            // If we're modifying a different tunnel than the active one, reactivate it.
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
                let oldIndex = self.tunnels.firstIndex(of: tunnel)!
                self.tunnels.sort { TunnelsManager.tunnelNameIsLessThan($0.name, $1.name) }
                let newIndex = self.tunnels.firstIndex(of: tunnel)!
                self.tunnelsListDelegate?.tunnelMoved(from: oldIndex, to: newIndex)
                OnDemandSuspensionStore.handleTunnelRenamed(from: oldName, to: tunnelName)
                #if os(iOS)
                RecentTunnelsTracker.handleTunnelRenamed(oldName: oldName, newName: tunnelName)
                EndpointLocationStore.handleTunnelRenamed(oldName: oldName, newName: tunnelName)
                #endif
            }
            self.tunnelsListDelegate?.tunnelModified(at: self.tunnels.firstIndex(of: tunnel)!)

            // Update any failover groups or TiT groups that reference this tunnel
            if isTunnelConfigurationChanged || isNameChanged {
                self.refreshFailoverGroupsContaining(tunnelName: tunnelName, oldName: isNameChanged ? oldName : nil)
                self.refreshTiTGroupsContaining(tunnelName: tunnelName, oldName: isNameChanged ? oldName : nil)
            }

            if isTunnelConfigurationChanged {
                if tunnel.status == .active || tunnel.status == .activating || tunnel.status == .reasserting {
                    // Turn off the tunnel, and then turn it back on, so the changes are made effective
                    tunnel.status = .restarting
                    (tunnel.tunnelProvider.connection as? NETunnelProviderSession)?.stopTunnel()
                }
            }

            if isActivatingOnDemand {
                // Reload tunnel after saving.
                // Without this, the tunnel stopes getting updates on the tunnel status from iOS.
                tunnelProviderManager.loadFromPreferences { error in
                    tunnel.isActivateOnDemandEnabled = tunnelProviderManager.isOnDemandEnabled
                    if let error = error {
                        wg_log(.error, message: "Modify: Re-loading after saving configuration failed: \(error)")
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

    /// Delete protection: returns an error if the tunnel is a member of any
    /// failover or tunnel-in-tunnel group, nil otherwise.
    private func groupMembershipError(for tunnel: TunnelContainer) -> TunnelsManagerError? {
        let referencingGroups = failoverGroupTunnels.filter { group in
            let proto = group.tunnelProvider.protocolConfiguration as? NETunnelProviderProtocol
            let names = proto?.providerConfiguration?[ProviderConfigurationKeys.failoverConfigNames] as? [String] ?? []
            return names.contains(tunnel.name)
        }
        if !referencingGroups.isEmpty {
            let groupNames = referencingGroups.map { $0.name }.joined(separator: ", ")
            return TunnelsManagerError.tunnelIsPartOfFailoverGroup(groupNames: groupNames)
        }

        let referencingTiTGroups = titGroupTunnels.filter { group in
            let proto = group.tunnelProvider.protocolConfiguration as? NETunnelProviderProtocol
            let config = proto?.providerConfiguration
            let outerName = config?[ProviderConfigurationKeys.titOuterName] as? String
            let innerName = config?[ProviderConfigurationKeys.titInnerName] as? String
            return outerName == tunnel.name || innerName == tunnel.name
        }
        if !referencingTiTGroups.isEmpty {
            let groupNames = referencingTiTGroups.map { $0.name }.joined(separator: ", ")
            return TunnelsManagerError.tunnelIsPartOfTiTGroup(groupNames: groupNames)
        }

        return nil
    }

    func remove(tunnel: TunnelContainer, completionHandler: @escaping (TunnelsManagerError?) -> Void) {
        if let error = groupMembershipError(for: tunnel) {
            completionHandler(error)
            return
        }

        let tunnelProviderManager = tunnel.tunnelProvider
        #if os(macOS)
        if tunnel.isTunnelAvailableToUser {
            (tunnelProviderManager.protocolConfiguration as? NETunnelProviderProtocol)?.destroyConfigurationReference()
        }
        #elseif os(iOS)
        (tunnelProviderManager.protocolConfiguration as? NETunnelProviderProtocol)?.destroyConfigurationReference()
        #else
        #error("Unimplemented")
        #endif
        tunnelProviderManager.removeFromPreferences { [weak self] error in
            if let error = error {
                wg_log(.error, message: "Remove: Saving configuration failed: \(error)")
                completionHandler(TunnelsManagerError.systemErrorOnRemoveTunnel(systemError: error))
                return
            }
            if let self = self, let index = self.tunnels.firstIndex(of: tunnel) {
                self.tunnels.remove(at: index)
                self.tunnelsListDelegate?.tunnelRemoved(at: index, tunnel: tunnel)
            }
            OnDemandSuspensionStore.remove(tunnel.name)
            completionHandler(nil)

            #if os(iOS)
            RecentTunnelsTracker.handleTunnelRemoved(tunnelName: tunnel.name)
            EndpointLocationStore.handleTunnelRemoved(tunnelName: tunnel.name)
            #endif
        }
    }

    func removeMultiple(tunnels: [TunnelContainer], completionHandler: @escaping (TunnelsManagerError?) -> Void) {
        // Check if any tunnel is referenced by a failover group or TiT group before deleting anything
        for tunnel in tunnels {
            if let error = groupMembershipError(for: tunnel) {
                completionHandler(error)
                return
            }
        }

        // Temporarily pause observation of changes to VPN configurations to prevent the feedback
        // loop that causes `reload()` to be called for each removed tunnel, which significantly
        // impacts performance.
        configurationsObservationToken = nil

        removeMultiple(tunnels: ArraySlice(tunnels)) { [weak self] error in
            completionHandler(error)

            // Restart observation of changes to VPN configrations.
            self?.startObservingTunnelConfigurations()

            // Force reload all configurations to make sure that all tunnels are up to date.
            self?.reload()
        }
    }

    private func removeMultiple(tunnels: ArraySlice<TunnelContainer>, completionHandler: @escaping (TunnelsManagerError?) -> Void) {
        guard let head = tunnels.first else {
            completionHandler(nil)
            return
        }
        let tail = tunnels.dropFirst()
        remove(tunnel: head) { [weak self, tail] error in
            DispatchQueue.main.async {
                if let error = error {
                    completionHandler(error)
                } else {
                    self?.removeMultiple(tunnels: tail, completionHandler: completionHandler)
                }
            }
        }
    }

    func setOnDemandEnabled(_ isOnDemandEnabled: Bool, on tunnel: TunnelContainer, completionHandler: @escaping (TunnelsManagerError?) -> Void) {
        // A user-initiated on-demand toggle takes explicit control: clear any
        // suspension marker we were holding for this tunnel. Internal callers
        // that intend to re-suspend (e.g. startActivation) re-add to the store
        // after this returns.
        clearSuspension(for: tunnel)
        let tunnelProviderManager = tunnel.tunnelProvider
        let isCurrentlyEnabled = (tunnelProviderManager.isOnDemandEnabled && tunnelProviderManager.isEnabled)
        guard isCurrentlyEnabled != isOnDemandEnabled else {
            completionHandler(nil)
            return
        }
        let isActivatingOnDemand = !tunnelProviderManager.isOnDemandEnabled && isOnDemandEnabled
        tunnelProviderManager.isOnDemandEnabled = isOnDemandEnabled
        tunnelProviderManager.isEnabled = true
        tunnelProviderManager.saveToPreferences { error in
            if let error = error {
                wg_log(.error, message: "Modify On-Demand: Saving configuration failed: \(error)")
                completionHandler(TunnelsManagerError.systemErrorOnModifyTunnel(systemError: error))
                return
            }
            if isActivatingOnDemand {
                // If we're enabling on-demand, we want to make sure the tunnel is enabled.
                // If not enabled, the OS will not turn the tunnel on/off based on our rules.
                tunnelProviderManager.loadFromPreferences { error in
                    // isActivateOnDemandEnabled will get changed in reload(), but no harm in setting it here too
                    tunnel.isActivateOnDemandEnabled = tunnelProviderManager.isOnDemandEnabled
                    if let error = error {
                        wg_log(.error, message: "Modify On-Demand: Re-loading after saving configuration failed: \(error)")
                        completionHandler(TunnelsManagerError.systemErrorOnModifyTunnel(systemError: error))
                        return
                    }
                    completionHandler(nil)
                }
            } else {
                completionHandler(nil)
            }
        }
    }

    func numberOfTunnels() -> Int {
        return tunnels.count
    }

    func tunnel(at index: Int) -> TunnelContainer {
        return tunnels[index]
    }

    func mapTunnels<T>(transform: (TunnelContainer) throws -> T) rethrows -> [T] {
        return try tunnels.map(transform)
    }

    func index(of tunnel: TunnelContainer) -> Int? {
        return tunnels.firstIndex(of: tunnel)
    }

    func tunnel(named tunnelName: String) -> TunnelContainer? {
        return tunnels.first { $0.name == tunnelName }
    }

    // MARK: - Group Membership

    /// Names of the failover / tunnel-in-tunnel groups that reference the given tunnel.
    func groupNames(containing tunnelName: String) -> [String] {
        var names: [String] = []
        for group in failoverGroupTunnels {
            let proto = group.tunnelProvider.protocolConfiguration as? NETunnelProviderProtocol
            let members = proto?.providerConfiguration?[ProviderConfigurationKeys.failoverConfigNames] as? [String] ?? []
            if members.contains(tunnelName) {
                names.append(group.name)
            }
        }
        for group in titGroupTunnels {
            let config = (group.tunnelProvider.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration
            let outerName = config?[ProviderConfigurationKeys.titOuterName] as? String
            let innerName = config?[ProviderConfigurationKeys.titInnerName] as? String
            if outerName == tunnelName || innerName == tunnelName {
                names.append(group.name)
            }
        }
        return names
    }

    /// Every tunnel name referenced by any group manager in `managers`.
    static func groupMemberNames(in managers: [NETunnelProviderManager]) -> Set<String> {
        var names: Set<String> = []
        for manager in managers {
            guard let config = (manager.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration else { continue }
            if let members = config[ProviderConfigurationKeys.failoverConfigNames] as? [String] {
                names.formUnion(members)
            }
            if let outerName = config[ProviderConfigurationKeys.titOuterName] as? String {
                names.insert(outerName)
            }
            if let innerName = config[ProviderConfigurationKeys.titInnerName] as? String {
                names.insert(innerName)
            }
        }
        return names
    }

    // MARK: - Group Accessors (unified)

    /// Writable storage for a group kind's tunnel array — the single place
    /// that maps kind to array, so CRUD/reload code doesn't switch on kind.
    func groupArrayKeyPath(_ kind: TunnelGroupKind) -> ReferenceWritableKeyPath<TunnelsManager, [TunnelContainer]> {
        switch kind {
        case .failover: return \.failoverGroupTunnels
        case .tunnelInTunnel: return \.titGroupTunnels
        }
    }

    func groupTunnels(kind: TunnelGroupKind) -> [TunnelContainer] {
        return self[keyPath: groupArrayKeyPath(kind)]
    }

    func numberOfGroups(kind: TunnelGroupKind) -> Int {
        return groupTunnels(kind: kind).count
    }

    func group(kind: TunnelGroupKind, at index: Int) -> TunnelContainer {
        return groupTunnels(kind: kind)[index]
    }

    func groupIndex(kind: TunnelGroupKind, of tunnel: TunnelContainer) -> Int? {
        return groupTunnels(kind: kind).firstIndex(of: tunnel)
    }

    // MARK: - Legacy Failover Group Accessors

    func numberOfFailoverGroups() -> Int {
        return failoverGroupTunnels.count
    }

    func failoverGroup(at index: Int) -> TunnelContainer {
        return failoverGroupTunnels[index]
    }

    func failoverGroupIndex(of tunnel: TunnelContainer) -> Int? {
        return failoverGroupTunnels.firstIndex(of: tunnel)
    }

    // MARK: - Legacy Tunnel-in-Tunnel Group Accessors

    func numberOfTiTGroups() -> Int {
        return titGroupTunnels.count
    }

    func titGroup(at index: Int) -> TunnelContainer {
        return titGroupTunnels[index]
    }

    func titGroupIndex(of tunnel: TunnelContainer) -> Int? {
        return titGroupTunnels.firstIndex(of: tunnel)
    }

    private var allTunnels: [TunnelContainer] {
        return tunnels + failoverGroupTunnels + titGroupTunnels
    }

    func waitingTunnel() -> TunnelContainer? {
        return allTunnels.first { $0.status == .waiting }
    }

    func tunnelInOperation() -> TunnelContainer? {
        if let waitingTunnelObject = waitingTunnel() {
            return waitingTunnelObject
        }
        return allTunnels.first { $0.status != .inactive }
    }

    func startActivation(of tunnel: TunnelContainer) {
        guard tunnels.contains(tunnel) || failoverGroupTunnels.contains(tunnel) || titGroupTunnels.contains(tunnel) else { return } // Ensure it's not deleted
        guard tunnel.status == .inactive else {
            activationDelegate?.tunnelActivationAttemptFailed(tunnel: tunnel, error: .tunnelIsNotInactive)
            return
        }

        if let alreadyWaitingTunnel = allTunnels.first(where: { $0.status == .waiting }) {
            alreadyWaitingTunnel.status = .inactive
        }

        // Suspend any other tunnel that has on-demand armed but is currently
        // inactive — iOS quietly clears its isOnDemandEnabled when we start a
        // manual tunnel, so we record it here to restore on quiescence.
        for otherTunnel in allTunnels where otherTunnel !== tunnel
            && otherTunnel.status == .inactive
            && otherTunnel.isActivateOnDemandEnabled {
            setOnDemandEnabled(false, on: otherTunnel) { [weak self, weak otherTunnel] error in
                guard error == nil, let otherTunnel = otherTunnel else { return }
                self?.markSuspended(otherTunnel)
            }
        }

        if let tunnelInOperation = allTunnels.first(where: { $0.status != .inactive }) {
            wg_log(.info, message: "Tunnel '\(tunnel.name)' waiting for deactivation of '\(tunnelInOperation.name)'")
            tunnel.status = .waiting
            activateWaitingTunnelOnDeactivation(of: tunnelInOperation)
            if tunnelInOperation.status != .deactivating {
                if tunnelInOperation.isActivateOnDemandEnabled {
                    setOnDemandEnabled(false, on: tunnelInOperation) { [weak self, weak tunnelInOperation] error in
                        guard error == nil, let tunnelInOperation = tunnelInOperation else {
                            wg_log(.error, message: "Unable to activate tunnel '\(tunnel.name)' because on-demand could not be disabled on active tunnel '\(tunnel.name)'")
                            return
                        }
                        self?.markSuspended(tunnelInOperation)
                        self?.startDeactivation(of: tunnelInOperation)
                    }
                } else {
                    startDeactivation(of: tunnelInOperation)
                }
            }
            return
        }

        #if targetEnvironment(simulator)
        tunnel.status = .active
        #else
        tunnel.startActivation(activationDelegate: activationDelegate)
        #endif

        #if os(iOS)
        RecentTunnelsTracker.handleTunnelActivated(tunnelName: tunnel.name)
        #endif
    }

    func startDeactivation(of tunnel: TunnelContainer) {
        tunnel.isAttemptingActivation = false
        guard tunnel.status != .inactive && tunnel.status != .deactivating else { return }
        #if targetEnvironment(simulator)
        tunnel.status = .inactive
        #else
        tunnel.startDeactivation()
        #endif
    }

    func refreshStatuses() {
        allTunnels.forEach { $0.refreshStatus() }
    }

    private func activateWaitingTunnelOnDeactivation(of tunnel: TunnelContainer) {
        waiteeObservationToken = tunnel.observe(\.status) { [weak self] tunnel, _ in
            guard let self = self else { return }
            if tunnel.status == .inactive {
                if let waitingTunnel = self.allTunnels.first(where: { $0.status == .waiting }) {
                    waitingTunnel.startActivation(activationDelegate: self.activationDelegate)
                }
                self.waiteeObservationToken = nil
            }
        }
    }

    /// If no tunnel is currently in any non-inactive state, re-enable on-demand
    /// on every tunnel that was suspended for an override and clear those
    /// suspension markers. Called from `init` and after a tunnel disconnects.
    /// See `DESIGN-multiple-on-demand-tunnels.md` for the full lifecycle.
    private func restoreSuspendedOnDemandIfQuiescent() {
        guard OnDemandSuspensionStore.hasSuspensions else { return }
        let isQuiescent = allTunnels.allSatisfy { $0.status == .inactive }
        guard isQuiescent else { return }

        for name in OnDemandSuspensionStore.suspendedTunnelNames {
            guard let tunnel = allTunnels.first(where: { $0.name == name }) else {
                OnDemandSuspensionStore.remove(name)
                continue
            }
            guard tunnel.hasOnDemandRules else {
                OnDemandSuspensionStore.remove(name)
                tunnel.isOnDemandSuspended = false
                continue
            }
            // setOnDemandEnabled clears the suspension internally.
            setOnDemandEnabled(true, on: tunnel) { error in
                if let error = error {
                    wg_log(.error, message: "Restore on-demand for '\(name)' failed: \(error)")
                }
            }
        }
    }

    private func markSuspended(_ tunnel: TunnelContainer) {
        OnDemandSuspensionStore.add(tunnel.name)
        tunnel.isOnDemandSuspended = true
    }

    private func clearSuspension(for tunnel: TunnelContainer) {
        guard tunnel.isOnDemandSuspended else { return }
        OnDemandSuspensionStore.remove(tunnel.name)
        tunnel.isOnDemandSuspended = false
    }

    private func startObservingTunnelStatuses() {
        statusObservationToken = NotificationCenter.default.observe(name: .NEVPNStatusDidChange, object: nil, queue: OperationQueue.main) { [weak self] statusChangeNotification in
            guard let self = self,
                let session = statusChangeNotification.object as? NETunnelProviderSession,
                let tunnelProvider = session.manager as? NETunnelProviderManager,
                let tunnel = self.allTunnels.first(where: { $0.tunnelProvider == tunnelProvider }) else { return }

            wg_log(.debug, message: "Tunnel '\(tunnel.name)' connection status changed to '\(tunnel.tunnelProvider.connection.status)'")

            if tunnel.isAttemptingActivation {
                if session.status == .connected {
                    tunnel.isAttemptingActivation = false
                    self.activationDelegate?.tunnelActivationSucceeded(tunnel: tunnel)
                } else if session.status == .disconnected {
                    tunnel.isAttemptingActivation = false
                    if let (title, message) = lastErrorTextFromNetworkExtension(for: tunnel) {
                        self.activationDelegate?.tunnelActivationFailed(tunnel: tunnel, error: .activationFailedWithExtensionError(title: title, message: message, wasOnDemandEnabled: tunnelProvider.isOnDemandEnabled))
                    } else {
                        self.activationDelegate?.tunnelActivationFailed(tunnel: tunnel, error: .activationFailed(wasOnDemandEnabled: tunnelProvider.isOnDemandEnabled))
                    }
                }
            }

            if session.status == .disconnected {
                tunnel.onDeactivated?()
                tunnel.onDeactivated = nil
            }

            if tunnel.status == .restarting && session.status == .disconnected {
                tunnel.startActivation(activationDelegate: self.activationDelegate)
                return
            }

            tunnel.refreshStatus()

            // IP discovery: fetch when connected, clear when disconnected
            if session.status == .connected {
                PublicIPFetcher.fetchIfEnabled { [weak self] in self?.tunnelInOperation()?.status == .active }
            } else if session.status == .disconnected {
                PublicIPFetcher.clearDiscoveredIP()
                self.restoreSuspendedOnDemandIfQuiescent()
            }

            #if os(iOS)
            self.updateWidgetStatus()
            #endif
        }
    }

    #if os(iOS)
    func updateWidgetStatus() {
        widgetStatusWriter.update(tunnels: allTunnels)
    }
    #endif

    func startObservingTunnelConfigurations() {
        configurationsObservationToken = NotificationCenter.default.observe(name: .NEVPNConfigurationChange, object: nil, queue: OperationQueue.main) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                // We schedule reload() in a subsequent runloop to ensure that the completion handler of loadAllFromPreferences
                // (reload() calls loadAllFromPreferences) is called after the completion handler of the saveToPreferences or
                // removeFromPreferences call, if any, that caused this notification to fire. This notification can also fire
                // as a result of a tunnel getting added or removed outside of the app.
                self?.reload()
            }
        }
    }

    static func tunnelNameIsLessThan(_ lhs: String, _ rhs: String) -> Bool {
        return lhs.compare(rhs, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive, .numeric]) == .orderedAscending
    }
}

private func lastErrorTextFromNetworkExtension(for tunnel: TunnelContainer) -> (title: String, message: String)? {
    guard let lastErrorFileURL = FileManager.networkExtensionLastErrorFileURL else { return nil }
    guard let lastErrorData = try? Data(contentsOf: lastErrorFileURL) else { return nil }
    guard let lastErrorStrings = String(data: lastErrorData, encoding: .utf8)?.splitToArray(separator: "\n") else { return nil }
    guard lastErrorStrings.count == 2 && tunnel.activationAttemptId == lastErrorStrings[0] else { return nil }

    if let extensionError = PacketTunnelProviderError(rawValue: lastErrorStrings[1]) {
        return extensionError.alertText
    }

    return (tr("alertTunnelActivationFailureTitle"), tr("alertTunnelActivationFailureMessage"))
}

class TunnelContainer: NSObject {
    @objc dynamic var name: String
    @objc dynamic var status: TunnelStatus

    @objc dynamic var isActivateOnDemandEnabled: Bool
    @objc dynamic var hasOnDemandRules: Bool
    @objc dynamic var isOnDemandSuspended: Bool

    var isAttemptingActivation = false {
        didSet {
            if isAttemptingActivation {
                self.activationTimer?.invalidate()
                let activationTimer = Timer(timeInterval: 5 /* seconds */, repeats: true) { [weak self] _ in
                    guard let self = self else { return }
                    wg_log(.debug, message: "Status update notification timeout for tunnel '\(self.name)'. Tunnel status is now '\(self.tunnelProvider.connection.status)'.")
                    switch self.tunnelProvider.connection.status {
                    case .connected, .disconnected, .invalid:
                        self.activationTimer?.invalidate()
                        self.activationTimer = nil
                    default:
                        break
                    }
                    self.refreshStatus()
                }
                self.activationTimer = activationTimer
                RunLoop.main.add(activationTimer, forMode: .common)
            }
        }
    }
    var activationAttemptId: String?
    var activationTimer: Timer?
    var deactivationTimer: Timer?
    var onDeactivated: (() -> Void)?

    var tunnelProvider: NETunnelProviderManager {
        didSet {
            isActivateOnDemandEnabled = tunnelProvider.isOnDemandEnabled && tunnelProvider.isEnabled
            hasOnDemandRules = !(tunnelProvider.onDemandRules ?? []).isEmpty
            // Suspension state may have changed out-of-process (or via
            // reload()); refresh it like the other observables above.
            isOnDemandSuspended = OnDemandSuspensionStore.suspendedTunnelNames.contains(tunnelProvider.localizedDescription ?? name)
        }
    }

    var groupKind: TunnelGroupKind? {
        guard let config = (tunnelProvider.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration else {
            return nil
        }
        if config[ProviderConfigurationKeys.failoverGroupId] != nil { return .failover }
        if config[ProviderConfigurationKeys.titGroupId] != nil { return .tunnelInTunnel }
        return nil
    }

    func groupId(for kind: TunnelGroupKind) -> String? {
        return (tunnelProvider.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration?[kind.groupIdKey] as? String
    }

    var isFailoverGroup: Bool {
        return groupKind == .failover
    }

    var failoverGroupId: String? {
        return groupId(for: .failover)
    }

    var isTiTGroup: Bool {
        return groupKind == .tunnelInTunnel
    }

    var titGroupId: String? {
        return groupId(for: .tunnelInTunnel)
    }

    var tunnelConfiguration: TunnelConfiguration? {
        return tunnelProvider.tunnelConfiguration
    }

    var onDemandOption: ActivateOnDemandOption {
        return ActivateOnDemandOption(from: tunnelProvider)
    }

    #if os(macOS)
    var isTunnelAvailableToUser: Bool {
        return (tunnelProvider.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration?[ProviderConfigurationKeys.uid] as? uid_t == getuid()
    }
    #endif

    init(tunnel: NETunnelProviderManager) {
        let resolvedName = tunnel.localizedDescription ?? "Unnamed"
        name = resolvedName
        let status = TunnelStatus(from: tunnel.connection.status)
        self.status = status
        isActivateOnDemandEnabled = tunnel.isOnDemandEnabled && tunnel.isEnabled
        hasOnDemandRules = !(tunnel.onDemandRules ?? []).isEmpty
        isOnDemandSuspended = OnDemandSuspensionStore.suspendedTunnelNames.contains(resolvedName)
        tunnelProvider = tunnel
        super.init()
    }

    func getRuntimeTunnelConfiguration(completionHandler: @escaping ((TunnelConfiguration?) -> Void)) {
        guard status != .inactive, let session = tunnelProvider.connection as? NETunnelProviderSession else {
            completionHandler(tunnelConfiguration)
            return
        }
        guard nil != (try? session.sendProviderMessage(ProviderMessage.runtimeConfiguration.data, responseHandler: {
            guard self.status != .inactive, let data = $0, let base = self.tunnelConfiguration, let settings = String(data: data, encoding: .utf8) else {
                completionHandler(self.tunnelConfiguration)
                return
            }
            completionHandler((try? TunnelConfiguration(fromUapiConfig: settings, basedOn: base)) ?? self.tunnelConfiguration)
        })) else {
            completionHandler(tunnelConfiguration)
            return
        }
    }

    func refreshStatus() {
        if (status == .restarting) || (status == .waiting && tunnelProvider.connection.status == .disconnected) {
            return
        }
        status = TunnelStatus(from: tunnelProvider.connection.status)
    }

    fileprivate func startActivation(recursionCount: UInt = 0, lastError: Error? = nil, activationDelegate: TunnelsManagerActivationDelegate?) {
        if recursionCount >= 8 {
            wg_log(.error, message: "startActivation: Failed after 8 attempts. Giving up with \(lastError!)")
            activationDelegate?.tunnelActivationAttemptFailed(tunnel: self, error: .failedBecauseOfTooManyErrors(lastSystemError: lastError!))
            return
        }

        wg_log(.debug, message: "startActivation: Entering (tunnel: \(name))")

        status = .activating // Ensure that no other tunnel can attempt activation until this tunnel is done trying

        guard tunnelProvider.isEnabled else {
            // In case the tunnel had gotten disabled, re-enable and save it,
            // then call this function again.
            wg_log(.debug, staticMessage: "startActivation: Tunnel is disabled. Re-enabling and saving")
            tunnelProvider.isEnabled = true
            tunnelProvider.saveToPreferences { [weak self] error in
                guard let self = self else { return }
                if error != nil {
                    wg_log(.error, message: "Error saving tunnel after re-enabling: \(error!)")
                    activationDelegate?.tunnelActivationAttemptFailed(tunnel: self, error: .failedWhileSaving(systemError: error!))
                    return
                }
                wg_log(.debug, staticMessage: "startActivation: Tunnel saved after re-enabling, invoking startActivation")
                self.startActivation(recursionCount: recursionCount + 1, lastError: NEVPNError(NEVPNError.configurationUnknown), activationDelegate: activationDelegate)
            }
            return
        }

        // Start the tunnel
        do {
            wg_log(.debug, staticMessage: "startActivation: Starting tunnel")
            isAttemptingActivation = true
            let activationAttemptId = UUID().uuidString
            self.activationAttemptId = activationAttemptId
            try (tunnelProvider.connection as? NETunnelProviderSession)?.startTunnel(options: ["activationAttemptId": activationAttemptId])
            wg_log(.debug, staticMessage: "startActivation: Success")
            activationDelegate?.tunnelActivationAttemptSucceeded(tunnel: self)
        } catch let error {
            isAttemptingActivation = false
            guard let systemError = error as? NEVPNError else {
                wg_log(.error, message: "Failed to activate tunnel: Error: \(error)")
                status = .inactive
                activationDelegate?.tunnelActivationAttemptFailed(tunnel: self, error: .failedWhileStarting(systemError: error))
                return
            }
            guard systemError.code == NEVPNError.configurationInvalid || systemError.code == NEVPNError.configurationStale else {
                wg_log(.error, message: "Failed to activate tunnel: VPN Error: \(error)")
                status = .inactive
                activationDelegate?.tunnelActivationAttemptFailed(tunnel: self, error: .failedWhileStarting(systemError: systemError))
                return
            }
            wg_log(.debug, staticMessage: "startActivation: Will reload tunnel and then try to start it.")
            tunnelProvider.loadFromPreferences { [weak self] error in
                guard let self = self else { return }
                if error != nil {
                    wg_log(.error, message: "startActivation: Error reloading tunnel: \(error!)")
                    self.status = .inactive
                    activationDelegate?.tunnelActivationAttemptFailed(tunnel: self, error: .failedWhileLoading(systemError: systemError))
                    return
                }
                wg_log(.debug, staticMessage: "startActivation: Tunnel reloaded, invoking startActivation")
                self.startActivation(recursionCount: recursionCount + 1, lastError: systemError, activationDelegate: activationDelegate)
            }
        }
    }

    fileprivate func startDeactivation() {
        wg_log(.debug, message: "startDeactivation: Tunnel: \(name)")
        (tunnelProvider.connection as? NETunnelProviderSession)?.stopTunnel()
    }
}

extension NETunnelProviderManager {
    private static var cachedConfigKey: UInt8 = 0

    var tunnelConfiguration: TunnelConfiguration? {
        if let cached = objc_getAssociatedObject(self, &NETunnelProviderManager.cachedConfigKey) as? TunnelConfiguration {
            return cached
        }
        let config = (protocolConfiguration as? NETunnelProviderProtocol)?.asTunnelConfiguration(called: localizedDescription)
        if config != nil {
            objc_setAssociatedObject(self, &NETunnelProviderManager.cachedConfigKey, config, objc_AssociationPolicy.OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        return config
    }

    func setTunnelConfiguration(_ tunnelConfiguration: TunnelConfiguration) {
        protocolConfiguration = NETunnelProviderProtocol(tunnelConfiguration: tunnelConfiguration, previouslyFrom: protocolConfiguration)
        localizedDescription = tunnelConfiguration.name
        objc_setAssociatedObject(self, &NETunnelProviderManager.cachedConfigKey, tunnelConfiguration, objc_AssociationPolicy.OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    func isEquivalentTo(_ tunnel: TunnelContainer) -> Bool {
        return localizedDescription == tunnel.name && tunnelConfiguration == tunnel.tunnelConfiguration
    }

    func isEquivalentToGroup(kind: TunnelGroupKind, _ tunnel: TunnelContainer) -> Bool {
        let myGroupId = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration?[kind.groupIdKey] as? String
        return myGroupId != nil && myGroupId == tunnel.groupId(for: kind)
    }
}
