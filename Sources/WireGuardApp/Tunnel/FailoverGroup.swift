// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import Foundation

/// Codable representation of on-demand activation settings for a failover group.
struct OnDemandActivation: Codable, Equatable {
    var isWiFiInterfaceEnabled: Bool = false
    var isNonWiFiInterfaceEnabled: Bool = false
    var ssidOption: SSIDOption = .anySSID
    var selectedSSIDs: [String] = []

    enum SSIDOption: String, Codable {
        case anySSID
        case onlySpecificSSIDs
        case exceptSpecificSSIDs
    }

    var isEnabled: Bool { isWiFiInterfaceEnabled || isNonWiFiInterfaceEnabled }

    func toActivateOnDemandOption() -> ActivateOnDemandOption {
        switch (isWiFiInterfaceEnabled, isNonWiFiInterfaceEnabled) {
        case (false, false):
            return .off
        case (false, true):
            return .nonWiFiInterfaceOnly
        case (true, false):
            return .wiFiInterfaceOnly(toSSIDOption())
        case (true, true):
            return .anyInterface(toSSIDOption())
        }
    }

    private func toSSIDOption() -> ActivateOnDemandSSIDOption {
        switch ssidOption {
        case .anySSID:
            return .anySSID
        case .onlySpecificSSIDs:
            let ssids = selectedSSIDs.filter { !$0.isEmpty }
            return ssids.isEmpty ? .anySSID : .onlySpecificSSIDs(ssids)
        case .exceptSpecificSSIDs:
            let ssids = selectedSSIDs.filter { !$0.isEmpty }
            return ssids.isEmpty ? .anySSID : .exceptSpecificSSIDs(ssids)
        }
    }
}

/// A group of tunnel configurations with automatic failover between them.
/// The first tunnel is primary; subsequent tunnels are fallbacks in priority order.
struct FailoverGroup: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var tunnelNames: [String]
    var settings: FailoverSettings
    var onDemandActivation: OnDemandActivation

    enum CodingKeys: String, CodingKey {
        case id, name, tunnelNames, settings, onDemandActivation
    }

    init(name: String, tunnelNames: [String], settings: FailoverSettings = FailoverSettings(), onDemandActivation: OnDemandActivation = OnDemandActivation()) {
        self.id = UUID()
        self.name = name
        self.tunnelNames = tunnelNames
        self.settings = settings
        self.onDemandActivation = onDemandActivation
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        tunnelNames = try container.decode([String].self, forKey: .tunnelNames)
        settings = try container.decode(FailoverSettings.self, forKey: .settings)
        onDemandActivation = try container.decodeIfPresent(OnDemandActivation.self, forKey: .onDemandActivation) ?? OnDemandActivation()
    }
}
