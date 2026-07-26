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
        forEachGroupNeedingRefresh(kind: .failover, changedTunnelName: tunnelName) { groupTunnel, providerConfig in
            guard var configNames = providerConfig[ProviderConfigurationKeys.failoverConfigNames] as? [String] else { return nil }

            let matchName = oldName ?? tunnelName
            guard configNames.contains(matchName) else { return nil }

            // Update the name if it was renamed
            if let oldName = oldName, let idx = configNames.firstIndex(of: oldName) {
                configNames[idx] = tunnelName
            }

            let settings = (providerConfig[ProviderConfigurationKeys.failoverSettings] as? Data)
                .flatMap { try? JSONDecoder().decode(FailoverSettings.self, from: $0) } ?? FailoverSettings()
            return FailoverGroupSpec(name: groupTunnel.name, tunnelNames: configNames,
                                     settings: settings, onDemandActivation: OnDemandActivation())
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
        debugSendCommand(.debugForceFailover, for: tunnel, completionHandler: completionHandler)
    }

    /// Debug: send a force-failback command to the network extension.
    func debugForceFailback(for tunnel: TunnelContainer, completionHandler: @escaping (Bool) -> Void) {
        debugSendCommand(.debugForceFailback, for: tunnel, completionHandler: completionHandler)
    }

    private func debugSendCommand(_ message: ProviderMessage, for tunnel: TunnelContainer, completionHandler: @escaping (Bool) -> Void) {
        guard tunnel.status == .active,
              let session = tunnel.tunnelProvider.connection as? NETunnelProviderSession else {
            completionHandler(false)
            return
        }
        do {
            try session.sendProviderMessage(message.data) { responseData in
                guard let data = responseData,
                      let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let success = result["success"] as? Bool else {
                    completionHandler(false)
                    return
                }
                completionHandler(success)
            }
        } catch {
            wg_log(.error, message: "Failover: debug command \(message) failed: \(error)")
            completionHandler(false)
        }
    }
    #endif
}
