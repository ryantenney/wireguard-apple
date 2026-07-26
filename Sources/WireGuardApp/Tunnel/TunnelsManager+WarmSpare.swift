// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import Foundation
import NetworkExtension

// App-side plumbing for warm spare cellular failover: per-tunnel settings
// persistence (in `providerConfiguration`, preserved across tunnel edits by
// `NETunnelProviderProtocol+Extension`) and IPC to the running extension.
// See `DESIGN-warm-spare-cellular-failover.md`.
extension TunnelsManager {

    // MARK: - Settings persistence

    /// Warm spare settings stored for a tunnel, or `nil` if never configured.
    func warmSpareSettings(for tunnel: TunnelContainer) -> WarmSpareSettings? {
        guard let proto = tunnel.tunnelProvider.protocolConfiguration as? NETunnelProviderProtocol,
              let data = proto.providerConfiguration?[ProviderConfigurationKeys.warmSpareSettings] as? Data else {
            return nil
        }
        return try? JSONDecoder().decode(WarmSpareSettings.self, from: data)
    }

    /// Persist warm spare settings for a tunnel (pass `nil` to remove them).
    /// Takes effect on the next tunnel activation; the running extension is
    /// not reconfigured live.
    func setWarmSpareSettings(_ settings: WarmSpareSettings?, for tunnel: TunnelContainer, completionHandler: @escaping (TunnelsManagerError?) -> Void) {
        guard let proto = tunnel.tunnelProvider.protocolConfiguration as? NETunnelProviderProtocol else {
            completionHandler(.systemErrorOnModifyTunnel(systemError: NEVPNError(.configurationInvalid)))
            return
        }
        var config = proto.providerConfiguration ?? [:]
        if let settings = settings, let data = try? JSONEncoder().encode(settings) {
            config[ProviderConfigurationKeys.warmSpareSettings] = data
        } else {
            config.removeValue(forKey: ProviderConfigurationKeys.warmSpareSettings)
        }
        proto.providerConfiguration = config
        tunnel.tunnelProvider.saveToPreferences { error in
            if let error = error {
                wg_log(.error, message: "Warm spare: failed to save settings: \(error)")
                completionHandler(.systemErrorOnModifyTunnel(systemError: error))
            } else {
                completionHandler(nil)
            }
        }
    }

    // MARK: - Extension IPC

    /// Query warm spare runtime status from the running extension: active
    /// path, warm/cold, per-path RTT/loss, EIM verdict, and controller state.
    /// Returns `nil` if the tunnel is not active or warm spare is not engaged.
    func getWarmSpareStatus(for tunnel: TunnelContainer, completionHandler: @escaping ([String: Any]?) -> Void) {
        sendWarmSpareMessage(Data([5]), to: tunnel, completionHandler: completionHandler)
    }

    /// Ask the running extension to run the EIM (endpoint-independent
    /// mapping) self-test. The verdict appears in `getWarmSpareStatus` within
    /// a few seconds.
    func runWarmSpareEimTest(for tunnel: TunnelContainer, completionHandler: @escaping (Bool) -> Void) {
        sendWarmSpareMessage(Data([6]), to: tunnel) { response in
            completionHandler(response?["started"] as? Bool ?? false)
        }
    }

    #if FAILOVER_TESTING
    /// Debug: force the warm spare path. 0 = primary, 1 = cellular,
    /// `nil` = resume automatic control.
    func debugForceWarmSparePath(_ path: Int?, for tunnel: TunnelContainer, completionHandler: @escaping (Bool) -> Void) {
        let pathByte: UInt8
        switch path {
        case 0: pathByte = 0
        case 1: pathByte = 1
        default: pathByte = 2
        }
        sendWarmSpareMessage(Data([7, pathByte]), to: tunnel) { response in
            completionHandler(response?["success"] as? Bool ?? false)
        }
    }
    #endif

    private func sendWarmSpareMessage(_ message: Data, to tunnel: TunnelContainer, completionHandler: @escaping ([String: Any]?) -> Void) {
        guard tunnel.status == .active,
              let session = tunnel.tunnelProvider.connection as? NETunnelProviderSession else {
            completionHandler(nil)
            return
        }
        do {
            try session.sendProviderMessage(message) { responseData in
                guard let data = responseData,
                      let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    completionHandler(nil)
                    return
                }
                completionHandler(response)
            }
        } catch {
            wg_log(.error, message: "Warm spare: IPC message failed: \(error)")
            completionHandler(nil)
        }
    }
}

extension ActivateOnDemandOption {
    /// Warm spare needs the provider process running while on Wi-Fi, which
    /// requires the always-connected on-demand mode (a single
    /// `NEOnDemandRuleConnect` matching any interface — surfaced in the UI as
    /// "Always On"). The legacy cellular-only mode leaves nothing to warm:
    /// the provider isn't running while Wi-Fi carries traffic.
    var supportsWarmSpare: Bool {
        if case .anyInterface(.anySSID) = self { return true }
        return false
    }
}
