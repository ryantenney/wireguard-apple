// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import Foundation

/// Lightweight representation of a tunnel-in-tunnel group for import/export.
/// The actual runtime data is stored in NETunnelProviderManager's providerConfiguration
/// and tit-groups.json; this struct captures just what's needed for the
/// .tunnelintunnel.conf file format.
struct TunnelInTunnelGroupConfig {

    var name: String
    var outerTunnelName: String
    var innerTunnelName: String

    // MARK: - Parsing

    enum ParseError: WireGuardAppError {
        case invalidLine(String)
        case noGroupSection
        case missingOuterTunnel
        case missingInnerTunnel

        var alertText: AlertText {
            switch self {
            case .invalidLine(let line):
                return ("Invalid line", "Could not parse line: \(line)")
            case .noGroupSection:
                return ("Missing section", "Tunnel-in-tunnel config must contain a [TunnelInTunnel] section.")
            case .missingOuterTunnel:
                return ("Missing outer tunnel", "Tunnel-in-tunnel config must specify an OuterTunnel.")
            case .missingInnerTunnel:
                return ("Missing inner tunnel", "Tunnel-in-tunnel config must specify an InnerTunnel.")
            }
        }
    }

    init(from configString: String, called name: String) throws {
        self.name = name

        var outerTunnel: String?
        var innerTunnel: String?
        var hadGroupSection = false
        var inSection = false

        let lines = configString.split(omittingEmptySubsequences: false) { $0.isNewline }

        for line in lines {
            var trimmedLine: String
            if let commentRange = line.range(of: "#") {
                trimmedLine = String(line[..<commentRange.lowerBound])
            } else {
                trimmedLine = String(line)
            }

            trimmedLine = trimmedLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowercasedLine = trimmedLine.lowercased()

            guard !trimmedLine.isEmpty else { continue }

            if lowercasedLine == "[tunnelintunnel]" {
                hadGroupSection = true
                inSection = true
                continue
            }

            // Any other section header ends our section
            if trimmedLine.hasPrefix("[") && trimmedLine.hasSuffix("]") {
                inSection = false
                continue
            }

            if inSection {
                guard let equalsIndex = trimmedLine.firstIndex(of: "=") else {
                    throw ParseError.invalidLine(trimmedLine)
                }
                let key = trimmedLine[..<equalsIndex].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let value = trimmedLine[trimmedLine.index(equalsIndex, offsetBy: 1)...].trimmingCharacters(in: .whitespacesAndNewlines)

                switch key {
                case "outertunnel":
                    outerTunnel = value
                case "innertunnel":
                    innerTunnel = value
                default:
                    break // Ignore unknown keys for forward compatibility
                }
            }
        }

        guard hadGroupSection else { throw ParseError.noGroupSection }
        guard let outer = outerTunnel, !outer.isEmpty else { throw ParseError.missingOuterTunnel }
        guard let inner = innerTunnel, !inner.isEmpty else { throw ParseError.missingInnerTunnel }
        self.outerTunnelName = outer
        self.innerTunnelName = inner
    }

    // MARK: - Serialization

    func asConfigString() -> String {
        var output = "[TunnelInTunnel]\n"
        output += "OuterTunnel = \(outerTunnelName)\n"
        output += "InnerTunnel = \(innerTunnelName)\n"
        return output
    }

    /// Serialize a tunnel-in-tunnel group from its TunnelInTunnelGroup model.
    static func configString(from group: TunnelInTunnelGroup) -> String {
        var output = "[TunnelInTunnel]\n"
        output += "OuterTunnel = \(group.outerTunnelName)\n"
        output += "InnerTunnel = \(group.innerTunnelName)\n"
        return output
    }

    /// Serialize a tunnel-in-tunnel group from a NETunnelProviderManager's
    /// providerConfiguration — the authoritative store for UI-created groups.
    static func configString(from providerConfiguration: [String: Any]) -> String? {
        guard let outerName = providerConfiguration[TunnelInTunnelConfigKeys.outerName] as? String,
              let innerName = providerConfiguration[TunnelInTunnelConfigKeys.innerName] as? String,
              !outerName.isEmpty, !innerName.isEmpty else {
            return nil
        }
        var output = "[TunnelInTunnel]\n"
        output += "OuterTunnel = \(outerName)\n"
        output += "InnerTunnel = \(innerName)\n"
        return output
    }
}
