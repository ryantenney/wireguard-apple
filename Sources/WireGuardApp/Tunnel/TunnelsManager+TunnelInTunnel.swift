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
        for groupTunnel in titGroupTunnels {
            guard let proto = groupTunnel.tunnelProvider.protocolConfiguration as? NETunnelProviderProtocol,
                  let providerConfig = proto.providerConfiguration else {
                continue
            }

            let matchName = oldName ?? tunnelName
            var outerName = providerConfig[TunnelInTunnelConfigKeys.outerName] as? String ?? ""
            var innerName = providerConfig[TunnelInTunnelConfigKeys.innerName] as? String ?? ""

            guard outerName == matchName || innerName == matchName else { continue }

            // Update names if renamed
            if let oldName = oldName {
                if outerName == oldName { outerName = tunnelName }
                if innerName == oldName { innerName = tunnelName }
            }

            // Rebuild member keychain refs through the spec so unresolvable
            // members keep their stored configs instead of going stale silently.
            let spec = TiTGroupSpec(name: groupTunnel.name, outerTunnelName: outerName,
                                    innerTunnelName: innerName, onDemandActivation: OnDemandActivation())
            guard let buildResult = spec.buildProviderConfiguration(tunnelsManager: self, existing: providerConfig) else {
                wg_log(.error, message: "TiT: could not refresh group '\(groupTunnel.name)' after change to '\(tunnelName)'")
                continue
            }

            // Update passwordReference from outer tunnel
            if let outerTunnel = self.tunnel(named: outerName),
               let outerProto = outerTunnel.tunnelProvider.protocolConfiguration as? NETunnelProviderProtocol,
               let passwordRef = outerProto.passwordReference {
                proto.passwordReference = passwordRef
            }

            proto.providerConfiguration = buildResult.providerConfiguration

            // On iOS, saving any NE configuration can deactivate the currently
            // active tunnel — same workaround as in modify()/modifyGroup().
            #if os(iOS)
            let activeTunnel = (tunnels + failoverGroupTunnels + titGroupTunnels).first { $0.status == .active || $0.status == .activating }
            #endif

            groupTunnel.tunnelProvider.saveToPreferences { [weak self] error in
                if let error = error {
                    wg_log(.error, message: "TiT: failed to save refreshed group '\(groupTunnel.name)': \(error)")
                    buildResult.discardCreatedReferences()
                    return
                }
                buildResult.deleteObsoleteReferences()
                guard let self = self else { return }

                #if os(iOS)
                if let activeTunnel = activeTunnel, activeTunnel !== groupTunnel {
                    if activeTunnel.status == .inactive || activeTunnel.status == .deactivating {
                        self.startActivation(of: activeTunnel)
                    }
                    if activeTunnel.status == .active || activeTunnel.status == .activating {
                        activeTunnel.status = .restarting
                    }
                }
                #endif

                if let index = self.titGroupTunnels.firstIndex(of: groupTunnel) {
                    self.groupListDelegate?.groupModified(kind: .tunnelInTunnel, at: index)
                }
            }
        }
    }

    // MARK: - TiT State Query

    /// Query runtime stats from both INNER and OUTER tunnels in a TiT group.
    func getTiTState(for tunnel: TunnelContainer, completionHandler: @escaping ([String: Any]?) -> Void) {
        getGroupState(kind: .tunnelInTunnel, for: tunnel, completionHandler: completionHandler)
    }
}
