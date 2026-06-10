// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import Foundation
import NetworkExtension

extension TunnelsManager {

    // MARK: - Failover Group Convenience CRUD (delegates to shared GroupCRUD)

    func addFailoverGroup(name: String,
                          tunnelNames: [String],
                          settings: FailoverSettings,
                          onDemandActivation: OnDemandActivation,
                          completionHandler: @escaping (Result<TunnelContainer, TunnelsManagerError>) -> Void) {
        let spec = FailoverGroupSpec(name: name, tunnelNames: tunnelNames, settings: settings, onDemandActivation: onDemandActivation)
        addGroup(spec: spec, completionHandler: completionHandler)
    }

    func modifyFailoverGroup(tunnel: TunnelContainer,
                             name: String,
                             tunnelNames: [String],
                             settings: FailoverSettings,
                             onDemandActivation: OnDemandActivation,
                             completionHandler: @escaping (TunnelsManagerError?) -> Void) {
        let spec = FailoverGroupSpec(name: name, tunnelNames: tunnelNames, settings: settings, onDemandActivation: onDemandActivation)
        modifyGroup(tunnel: tunnel, spec: spec, completionHandler: completionHandler)
    }

    func removeFailoverGroup(tunnel: TunnelContainer, completionHandler: @escaping (TunnelsManagerError?) -> Void) {
        removeGroup(kind: .failover, tunnel: tunnel, completionHandler: completionHandler)
    }

    // MARK: - Failover-Specific: Refresh

    /// Update any failover groups that reference a tunnel that was modified or renamed.
    func refreshFailoverGroupsContaining(tunnelName: String, oldName: String? = nil) {
        for groupTunnel in failoverGroupTunnels {
            guard let proto = groupTunnel.tunnelProvider.protocolConfiguration as? NETunnelProviderProtocol,
                  var configNames = proto.providerConfiguration?["FailoverConfigNames"] as? [String] else {
                continue
            }

            let matchName = oldName ?? tunnelName
            guard configNames.contains(matchName) else { continue }

            // Update the name if it was renamed
            if let oldName = oldName, let idx = configNames.firstIndex(of: oldName) {
                configNames[idx] = tunnelName
            }

            // Rebuild member keychain refs through the spec so unresolvable
            // members fall back to their stored configs instead of being dropped.
            let existingConfig = proto.providerConfiguration
            let settings = (existingConfig?["FailoverSettings"] as? Data)
                .flatMap { try? JSONDecoder().decode(FailoverSettings.self, from: $0) } ?? FailoverSettings()
            let spec = FailoverGroupSpec(name: groupTunnel.name, tunnelNames: configNames,
                                         settings: settings, onDemandActivation: OnDemandActivation())
            guard let buildResult = spec.buildProviderConfiguration(tunnelsManager: self, existing: existingConfig) else {
                wg_log(.error, message: "Failover: could not refresh group '\(groupTunnel.name)' after change to '\(tunnelName)'")
                continue
            }

            // Update passwordReference if primary changed
            if let primaryName = configNames.first,
               let primaryTunnel = self.tunnel(named: primaryName),
               let primaryProto = primaryTunnel.tunnelProvider.protocolConfiguration as? NETunnelProviderProtocol,
               let passwordRef = primaryProto.passwordReference {
                proto.passwordReference = passwordRef
            }

            proto.providerConfiguration = buildResult.providerConfiguration
            groupTunnel.tunnelProvider.saveToPreferences { [weak self] error in
                if let error = error {
                    wg_log(.error, message: "Failover: failed to save refreshed group '\(groupTunnel.name)': \(error)")
                    buildResult.discardCreatedReferences()
                    return
                }
                buildResult.deleteObsoleteReferences()
                if let self = self, let index = self.failoverGroupTunnels.firstIndex(of: groupTunnel) {
                    self.groupListDelegate?.groupModified(kind: .failover, at: index)
                }
            }
        }
    }

    // MARK: - Failover State Query

    /// Query the failover state from the active tunnel's network extension.
    func getFailoverState(for tunnel: TunnelContainer, completionHandler: @escaping ([String: Any]?) -> Void) {
        getGroupState(kind: .failover, for: tunnel, completionHandler: completionHandler)
    }

    /// Check if the given tunnel is currently running as part of a failover group.
    func activeFailoverGroupId(for tunnel: TunnelContainer) -> String? {
        return tunnel.groupId(for: .failover)
    }

    #if FAILOVER_TESTING
    /// Debug: send a force-failover command to the network extension.
    func debugForceFailover(for tunnel: TunnelContainer, completionHandler: @escaping (Bool) -> Void) {
        debugSendCommand(messageType: 2, for: tunnel, completionHandler: completionHandler)
    }

    /// Debug: send a force-failback command to the network extension.
    func debugForceFailback(for tunnel: TunnelContainer, completionHandler: @escaping (Bool) -> Void) {
        debugSendCommand(messageType: 3, for: tunnel, completionHandler: completionHandler)
    }

    private func debugSendCommand(messageType: UInt8, for tunnel: TunnelContainer, completionHandler: @escaping (Bool) -> Void) {
        guard tunnel.status == .active,
              let session = tunnel.tunnelProvider.connection as? NETunnelProviderSession else {
            completionHandler(false)
            return
        }
        do {
            try session.sendProviderMessage(Data([messageType])) { responseData in
                guard let data = responseData,
                      let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let success = result["success"] as? Bool else {
                    completionHandler(false)
                    return
                }
                completionHandler(success)
            }
        } catch {
            wg_log(.error, message: "Failover: debug command \(messageType) failed: \(error)")
            completionHandler(false)
        }
    }
    #endif
}
