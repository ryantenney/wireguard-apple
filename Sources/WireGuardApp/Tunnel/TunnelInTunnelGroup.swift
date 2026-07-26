// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import Foundation
import NetworkExtension

/// A tunnel-in-tunnel (TiT) group pairs an OUTER WireGuard config (Server A) with an INNER
/// WireGuard config (Server B).  User traffic travels:
///   device → INNER wg-go (utun) → PipedBind → OUTER wg-go (virtual TUN) → Server A → Server B → Internet
struct TunnelInTunnelGroup: Codable, Equatable, Identifiable {
    var id: UUID
    /// Display name shown in the app.
    var name: String
    /// Name of the tunnel configuration that acts as the OUTER tunnel (Server A).
    var outerTunnelName: String
    /// Name of the tunnel configuration that acts as the INNER tunnel (Server B).
    var innerTunnelName: String
    /// Optional on-demand settings (same model as failover groups).
    var onDemandActivation: OnDemandActivation

    enum CodingKeys: String, CodingKey {
        case id, name, outerTunnelName, innerTunnelName, onDemandActivation
    }

    init(name: String, outerTunnelName: String, innerTunnelName: String,
         onDemandActivation: OnDemandActivation = OnDemandActivation()) {
        self.id = UUID()
        self.name = name
        self.outerTunnelName = outerTunnelName
        self.innerTunnelName = innerTunnelName
        self.onDemandActivation = onDemandActivation
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        outerTunnelName = try c.decode(String.self, forKey: .outerTunnelName)
        innerTunnelName = try c.decode(String.self, forKey: .innerTunnelName)
        onDemandActivation = try c.decodeIfPresent(OnDemandActivation.self, forKey: .onDemandActivation) ?? OnDemandActivation()
    }
}

// MARK: - NETunnelProviderManager helpers

extension TunnelInTunnelGroup {

    /// Builds the providerConfiguration dictionary for an NETunnelProviderManager
    /// from two keychain references to wg-quick configs.
    static func makeProviderConfiguration(
        groupId: String,
        outerConfigRef: Data, outerName: String,
        innerConfigRef: Data, innerName: String
    ) -> [String: Any] {
        return [
            ProviderConfigurationKeys.titGroupId:        groupId,
            ProviderConfigurationKeys.titOuterConfigRef: outerConfigRef,
            ProviderConfigurationKeys.titInnerConfigRef: innerConfigRef,
            ProviderConfigurationKeys.titOuterName:      outerName,
            ProviderConfigurationKeys.titInnerName:      innerName
        ]
    }
}
