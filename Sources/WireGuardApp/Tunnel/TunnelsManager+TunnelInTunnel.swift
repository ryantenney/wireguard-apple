// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import Foundation
import NetworkExtension

extension TunnelsManager {

    // MARK: - TiT Group Convenience CRUD (delegates to shared GroupCRUD)

    func addTiTGroup(name: String,
                     outerTunnelName: String,
                     innerTunnelName: String,
                     onDemandActivation: OnDemandActivation,
                     completionHandler: @escaping (Result<TunnelContainer, TunnelsManagerError>) -> Void) {
        let spec = TiTGroupSpec(name: name, outerTunnelName: outerTunnelName, innerTunnelName: innerTunnelName, onDemandActivation: onDemandActivation)
        addGroup(spec: spec, completionHandler: completionHandler)
    }

    func modifyTiTGroup(tunnel: TunnelContainer,
                        name: String,
                        outerTunnelName: String,
                        innerTunnelName: String,
                        onDemandActivation: OnDemandActivation,
                        completionHandler: @escaping (TunnelsManagerError?) -> Void) {
        let spec = TiTGroupSpec(name: name, outerTunnelName: outerTunnelName, innerTunnelName: innerTunnelName, onDemandActivation: onDemandActivation)
        modifyGroup(tunnel: tunnel, spec: spec, completionHandler: completionHandler)
    }

    func removeTiTGroup(tunnel: TunnelContainer, completionHandler: @escaping (TunnelsManagerError?) -> Void) {
        removeGroup(kind: .tunnelInTunnel, tunnel: tunnel, completionHandler: completionHandler)
    }

    // MARK: - TiT-Specific: Refresh

    /// Update any TiT groups that reference a tunnel that was modified or renamed.
    func refreshTiTGroupsContaining(tunnelName: String, oldName: String? = nil) {
        forEachGroupNeedingRefresh(kind: .tunnelInTunnel, changedTunnelName: tunnelName) { groupTunnel, providerConfig in
            let matchName = oldName ?? tunnelName
            var outerName = providerConfig[ProviderConfigurationKeys.titOuterName] as? String ?? ""
            var innerName = providerConfig[ProviderConfigurationKeys.titInnerName] as? String ?? ""

            guard outerName == matchName || innerName == matchName else { return nil }

            // Update names if renamed
            if let oldName = oldName {
                if outerName == oldName { outerName = tunnelName }
                if innerName == oldName { innerName = tunnelName }
            }

            return TiTGroupSpec(name: groupTunnel.name, outerTunnelName: outerName,
                                innerTunnelName: innerName, onDemandActivation: OnDemandActivation())
        }
    }

    // MARK: - TiT State Query

    /// Query runtime stats from both INNER and OUTER tunnels in a TiT group.
    func getTiTState(for tunnel: TunnelContainer, completionHandler: @escaping ([String: Any]?) -> Void) {
        getGroupState(kind: .tunnelInTunnel, for: tunnel, completionHandler: completionHandler)
    }
}
