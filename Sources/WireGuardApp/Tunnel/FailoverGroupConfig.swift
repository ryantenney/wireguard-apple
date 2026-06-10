// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import Foundation

/// Lightweight representation of a failover group for import/export.
/// The actual runtime data is stored in NETunnelProviderManager's providerConfiguration;
/// this struct captures just what's needed for the .failovergroup.conf file format.
struct FailoverGroupConfig {

    var name: String
    var tunnelNames: [String]
    var trafficTimeout: TimeInterval?
    var healthCheckInterval: TimeInterval?
    var failbackProbeInterval: TimeInterval?
    var autoFailback: Bool?
    var useBackgroundProbes: Bool?
    var hotSpare: Bool?
    var persistentKeepaliveOverride: UInt16?

    // MARK: - Parsing

    enum ParseError: WireGuardAppError {
        case invalidLine(String)
        case noConnections
        case noGroupSection
        case invalidValue(key: String, value: String)

        var alertText: AlertText {
            switch self {
            case .invalidLine(let line):
                return ("Invalid line", "Could not parse line: \(line)")
            case .noConnections:
                return ("No connections", "Failover group must contain at least two [Connection] sections.")
            case .noGroupSection:
                return ("Missing section", "Failover group config must contain a [FailoverGroup] section.")
            case .invalidValue(let key, let value):
                return ("Invalid value", "Invalid value '\(value)' for key '\(key)'.")
            }
        }
    }

    private enum ParserState {
        case notInASection
        case inGroupSection
        case inConnectionSection
    }

    init(from configString: String, called name: String) throws {
        self.name = name

        var tunnelNames = [String]()
        var parserState = ParserState.notInASection
        var attributes = [String: String]()
        var hadGroupSection = false

        let lines = configString.split(omittingEmptySubsequences: false) { $0.isNewline }

        for (lineIndex, line) in lines.enumerated() {
            var trimmedLine: String
            if let commentRange = line.range(of: "#") {
                trimmedLine = String(line[..<commentRange.lowerBound])
            } else {
                trimmedLine = String(line)
            }

            trimmedLine = trimmedLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowercasedLine = trimmedLine.lowercased()

            if !trimmedLine.isEmpty {
                if let equalsIndex = trimmedLine.firstIndex(of: "=") {
                    let key = trimmedLine[..<equalsIndex].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    let value = trimmedLine[trimmedLine.index(equalsIndex, offsetBy: 1)...].trimmingCharacters(in: .whitespacesAndNewlines)
                    attributes[key] = value
                } else if lowercasedLine != "[failovergroup]" && lowercasedLine != "[connection]" {
                    throw ParseError.invalidLine(trimmedLine)
                }
            }

            let isLastLine = lineIndex == lines.count - 1

            if isLastLine || lowercasedLine == "[failovergroup]" || lowercasedLine == "[connection]" {
                // Process previous section
                switch parserState {
                case .inGroupSection:
                    hadGroupSection = true
                    if let val = attributes["traffictimeout"] {
                        guard let t = TimeInterval(val) else { throw ParseError.invalidValue(key: "TrafficTimeout", value: val) }
                        self.trafficTimeout = t
                    }
                    if let val = attributes["healthcheckinterval"] {
                        guard let t = TimeInterval(val) else { throw ParseError.invalidValue(key: "HealthCheckInterval", value: val) }
                        self.healthCheckInterval = t
                    }
                    if let val = attributes["failbackprobeinterval"] {
                        guard let t = TimeInterval(val) else { throw ParseError.invalidValue(key: "FailbackProbeInterval", value: val) }
                        self.failbackProbeInterval = t
                    }
                    if let val = attributes["autofailback"] {
                        self.autoFailback = val.lowercased() == "true"
                    }
                    if let val = attributes["usebackgroundprobes"] {
                        self.useBackgroundProbes = val.lowercased() == "true"
                    }
                    if let val = attributes["hotspare"] {
                        self.hotSpare = val.lowercased() == "true"
                    }
                    if let val = attributes["persistentkeepaliveoverride"] {
                        guard let v = UInt16(val) else { throw ParseError.invalidValue(key: "PersistentKeepaliveOverride", value: val) }
                        self.persistentKeepaliveOverride = v
                    }

                case .inConnectionSection:
                    if let tunnelName = attributes["tunnel"]?.trimmingCharacters(in: .whitespacesAndNewlines), !tunnelName.isEmpty {
                        tunnelNames.append(tunnelName)
                    }

                case .notInASection:
                    break
                }
            }

            if lowercasedLine == "[failovergroup]" {
                parserState = .inGroupSection
                attributes.removeAll()
                // Mark the section as present at the header, not only when its
                // body is processed — a trailing "[FailoverGroup]" with no body
                // would otherwise be reported as missing.
                hadGroupSection = true
            } else if lowercasedLine == "[connection]" {
                parserState = .inConnectionSection
                attributes.removeAll()
            }
        }

        guard hadGroupSection else { throw ParseError.noGroupSection }

        // Drop duplicate [Connection] entries (keeping first occurrence) — a
        // group with the same member twice would fail over to itself.
        var seenNames = Set<String>()
        let uniqueNames = tunnelNames.filter { seenNames.insert($0).inserted }

        guard uniqueNames.count >= 2 else { throw ParseError.noConnections }
        self.tunnelNames = uniqueNames
    }

    // MARK: - Serialization

    func asConfigString() -> String {
        var output = "[FailoverGroup]\n"
        if let trafficTimeout = trafficTimeout {
            output += "TrafficTimeout = \(Int(trafficTimeout))\n"
        }
        if let healthCheckInterval = healthCheckInterval {
            output += "HealthCheckInterval = \(Int(healthCheckInterval))\n"
        }
        if let failbackProbeInterval = failbackProbeInterval {
            output += "FailbackProbeInterval = \(Int(failbackProbeInterval))\n"
        }
        if let autoFailback = autoFailback {
            output += "AutoFailback = \(autoFailback)\n"
        }
        if let useBackgroundProbes = useBackgroundProbes {
            output += "UseBackgroundProbes = \(useBackgroundProbes)\n"
        }
        if let hotSpare = hotSpare {
            output += "HotSpare = \(hotSpare)\n"
        }
        if let persistentKeepaliveOverride = persistentKeepaliveOverride {
            output += "PersistentKeepaliveOverride = \(persistentKeepaliveOverride)\n"
        }
        for tunnelName in tunnelNames {
            output += "\n[Connection]\nTunnel = \(tunnelName)\n"
        }
        return output
    }

    /// Serialize a failover group from its NETunnelProviderManager provider config.
    static func configString(from providerConfig: [String: Any]) -> String? {
        guard let configNames = providerConfig["FailoverConfigNames"] as? [String],
              configNames.count >= 2 else { return nil }

        var settings = FailoverSettings()
        if let settingsData = providerConfig["FailoverSettings"] as? Data,
           let decoded = try? JSONDecoder().decode(FailoverSettings.self, from: settingsData) {
            settings = decoded
        }

        var output = "[FailoverGroup]\n"
        output += "TrafficTimeout = \(Int(settings.trafficTimeout))\n"
        output += "HealthCheckInterval = \(Int(settings.healthCheckInterval))\n"
        output += "FailbackProbeInterval = \(Int(settings.failbackProbeInterval))\n"
        output += "AutoFailback = \(settings.autoFailback)\n"
        output += "UseBackgroundProbes = \(settings.useBackgroundProbes)\n"
        output += "HotSpare = \(settings.hotSpare)\n"
        if let persistentKeepaliveOverride = settings.persistentKeepaliveOverride {
            output += "PersistentKeepaliveOverride = \(persistentKeepaliveOverride)\n"
        }
        for name in configNames {
            output += "\n[Connection]\nTunnel = \(name)\n"
        }
        return output
    }
}
