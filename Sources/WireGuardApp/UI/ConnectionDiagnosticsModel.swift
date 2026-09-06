// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import Foundation
import NetworkExtension

struct DiagnosticsRow {
    let key: String
    let value: String
}

struct DiagnosticsSection {
    let title: String
    let rows: [DiagnosticsRow]
}

/// Builds the rows shown by the connection details ("nerd") view on both platforms.
///
/// The input is the app-side `TunnelContainer` plus the raw dictionary the Network
/// Extension returns for IPC message type 5 (see `PacketTunnelProvider.buildDiagnostics`).
/// Everything here is presentation logic: nothing is fetched, and nothing is cached
/// beyond the previous traffic sample used to derive throughput.
final class ConnectionDiagnosticsModel {

    let tunnel: TunnelContainer

    /// The most recent payload from the extension, or nil when the tunnel is not running.
    private(set) var diagnostics: [String: Any]?

    /// When `diagnostics` was received.
    private(set) var receivedAt: Date?

    /// Throughput per runtime key ("runtime", "innerRuntime", "outerRuntime"), derived
    /// from consecutive samples.
    private var rates: [String: (rx: Double, tx: Double)] = [:]
    private var previousSample: (date: Date, counters: [String: (rx: UInt64, tx: UInt64)])?

    /// Cap on routing-table rows so a busy host does not produce a thousand-row section.
    private let maxRoutingTableRows = 200

    init(tunnel: TunnelContainer) {
        self.tunnel = tunnel
    }

    // MARK: - Updating

    func update(with diagnostics: [String: Any]) {
        let now = Date()
        var counters: [String: (rx: UInt64, tx: UInt64)] = [:]
        for key in ["runtime", "innerRuntime", "outerRuntime"] {
            guard let runtime = Self.dict(diagnostics[key]) else { continue }
            counters[key] = (Self.uint64(runtime["rxBytes"]) ?? 0, Self.uint64(runtime["txBytes"]) ?? 0)
        }
        if let previous = previousSample {
            let elapsed = now.timeIntervalSince(previous.date)
            if elapsed > 0.5 {
                for (key, current) in counters {
                    guard let before = previous.counters[key] else { continue }
                    let rx = current.rx >= before.rx ? Double(current.rx - before.rx) / elapsed : 0
                    let tx = current.tx >= before.tx ? Double(current.tx - before.tx) / elapsed : 0
                    rates[key] = (rx, tx)
                }
                previousSample = (now, counters)
            }
        } else {
            previousSample = (now, counters)
        }
        self.diagnostics = diagnostics
        self.receivedAt = now
    }

    /// Forget runtime state (the tunnel went down).
    func clearRuntime() {
        diagnostics = nil
        receivedAt = nil
        rates = [:]
        previousSample = nil
    }

    // MARK: - Sections

    func sections() -> [DiagnosticsSection] {
        var sections: [DiagnosticsSection] = [overviewSection()]

        if let diagnostics = diagnostics {
            let mode = Self.string(diagnostics["mode"]) ?? "single"
            if mode == "tunnelInTunnel" {
                sections.append(tunnelChainSection(diagnostics))
                sections.append(trafficSection(diagnostics, runtimeKey: "outerRuntime", title: "Outer Tunnel Traffic"))
                sections.append(trafficSection(diagnostics, runtimeKey: "innerRuntime", title: "Inner Tunnel Traffic"))
            } else {
                sections.append(trafficSection(diagnostics, runtimeKey: "runtime", title: "Traffic"))
            }
            sections.append(interfaceSection(diagnostics))
            sections.append(dnsSection(diagnostics))
            sections.append(tunnelRoutesSection(diagnostics))
            if mode == "tunnelInTunnel" {
                sections.append(contentsOf: peerSections(diagnostics, runtimeKey: "outerRuntime", endpointsKey: "outerEndpoints", titlePrefix: "Outer Peer"))
                sections.append(contentsOf: peerSections(diagnostics, runtimeKey: "innerRuntime", endpointsKey: "endpoints", titlePrefix: "Inner Peer"))
            } else {
                sections.append(contentsOf: peerSections(diagnostics, runtimeKey: "runtime", endpointsKey: "endpoints", titlePrefix: "Peer"))
            }
            if mode == "failover" || Self.dict(diagnostics["failover"]) != nil {
                sections.append(contentsOf: failoverSections(diagnostics))
            }
            sections.append(networkPathSection(diagnostics))
            sections.append(localInterfacesSection(diagnostics))
            sections.append(sessionSection(diagnostics))
            sections.append(processSection(diagnostics))
            sections.append(routingTableSection(diagnostics))
        } else {
            sections.append(contentsOf: configuredSections())
        }

        return sections.filter { !$0.rows.isEmpty }
    }

    // MARK: Overview

    private func overviewSection() -> DiagnosticsSection {
        var rows: [DiagnosticsRow] = [
            DiagnosticsRow(key: "Name", value: tunnel.name),
            DiagnosticsRow(key: "Type", value: kindDescription),
            DiagnosticsRow(key: "Status", value: Self.statusDescription(for: tunnel)),
            DiagnosticsRow(key: "On-Demand", value: onDemandDescription)
        ]

        if let diagnostics = diagnostics {
            rows.append(DiagnosticsRow(key: "Extension Mode", value: Self.modeDescription(Self.string(diagnostics["mode"]))))
            if let state = Self.string(diagnostics["adapterState"]) {
                rows.append(DiagnosticsRow(key: "Adapter State", value: Self.adapterStateDescription(state)))
            }
            if let connectedSince = Self.date(diagnostics["connectedSince"]) {
                rows.append(DiagnosticsRow(key: "Connected Since", value: FormattingHelpers.prettyDateTime(connectedSince)))
                rows.append(DiagnosticsRow(key: "Uptime", value: FormattingHelpers.prettyDuration(Date().timeIntervalSince(connectedSince))))
            }
            if let reason = Self.string(diagnostics["activationReason"]) {
                rows.append(DiagnosticsRow(key: "Activated By", value: reason == "onDemand" ? "On-Demand rule" : "App"))
            }
            if let failover = Self.dict(diagnostics["failover"]), let active = Self.string(failover["activeConfig"]) {
                let index = Self.int(failover["activeIndex"]) ?? 0
                rows.append(DiagnosticsRow(key: "Active Config", value: "\(active) (#\(index))"))
            }
            if let version = Self.string(diagnostics["backendVersion"]) {
                rows.append(DiagnosticsRow(key: "Backend", value: "wireguard-go \(version)"))
            }
            if let receivedAt = receivedAt {
                rows.append(DiagnosticsRow(key: "Snapshot", value: FormattingHelpers.prettyTime(receivedAt)))
            }
        } else if tunnel.status == .inactive {
            rows.append(DiagnosticsRow(key: "Live Data", value: "Connect to see runtime details"))
        }

        return DiagnosticsSection(title: "Overview", rows: rows)
    }

    private var kindDescription: String {
        switch tunnel.groupKind {
        case .some(.failover): return "Failover Group"
        case .some(.tunnelInTunnel): return "Tunnel-in-Tunnel"
        case .none: return "Tunnel"
        }
    }

    private var onDemandDescription: String {
        guard tunnel.hasOnDemandRules else { return "Not configured" }
        if tunnel.isOnDemandSuspended { return "Suspended" }
        return tunnel.isActivateOnDemandEnabled ? "Enabled" : "Disabled"
    }

    static func statusDescription(for tunnel: TunnelContainer) -> String {
        switch tunnel.status {
        case .inactive: return tr("tunnelStatusInactive")
        case .activating: return tr("tunnelStatusActivating")
        case .active: return tr("tunnelStatusActive")
        case .deactivating: return tr("tunnelStatusDeactivating")
        case .reasserting: return tr("tunnelStatusReasserting")
        case .restarting: return tr("tunnelStatusRestarting")
        case .waiting: return tr("tunnelStatusWaiting")
        }
    }

    private static func modeDescription(_ mode: String?) -> String {
        switch mode {
        case "failover": return "Failover group"
        case "tunnelInTunnel": return "Tunnel-in-tunnel"
        default: return "Single tunnel"
        }
    }

    private static func adapterStateDescription(_ state: String) -> String {
        switch state {
        case "started": return "Running"
        case "startedTiT": return "Running (tunnel-in-tunnel)"
        case "temporaryShutdown": return "Paused (offline)"
        case "temporaryShutdownTiT": return "Paused (offline, tunnel-in-tunnel)"
        case "stopped": return "Stopped"
        default: return state
        }
    }

    // MARK: Tunnel-in-tunnel chain

    private func tunnelChainSection(_ diagnostics: [String: Any]) -> DiagnosticsSection {
        var rows: [DiagnosticsRow] = []
        let chain = Self.dict(diagnostics["tunnelInTunnel"]) ?? [:]
        if let outer = Self.dict(chain["outer"]) {
            rows.append(DiagnosticsRow(key: "Outer (Server A)", value: Self.string(outer["name"]) ?? "—"))
            let endpoints = Self.dicts(outer["peers"]).compactMap { Self.string($0["endpoint"]) }
            if !endpoints.isEmpty {
                rows.append(DiagnosticsRow(key: "Outer Endpoint", value: endpoints.joined(separator: ", ")))
            }
        }
        if let inner = Self.dict(chain["inner"]) {
            rows.append(DiagnosticsRow(key: "Inner (Server B)", value: Self.string(inner["name"]) ?? "—"))
            let endpoints = Self.dicts(inner["peers"]).compactMap { Self.string($0["endpoint"]) }
            if !endpoints.isEmpty {
                rows.append(DiagnosticsRow(key: "Inner Endpoint", value: endpoints.joined(separator: ", ") + " (via outer)"))
            }
        }
        if let outerIP = Self.string(diagnostics["titOuterInterfaceIP"]) {
            rows.append(DiagnosticsRow(key: "Outer Interface IP", value: outerIP))
        }
        rows.append(DiagnosticsRow(key: "Packet Path", value: "utun → inner → outer → network"))
        return DiagnosticsSection(title: "Tunnel Chain", rows: rows)
    }

    // MARK: Traffic

    private func trafficSection(_ diagnostics: [String: Any], runtimeKey: String, title: String) -> DiagnosticsSection {
        guard let runtime = Self.dict(diagnostics[runtimeKey]) else {
            return DiagnosticsSection(title: title, rows: [DiagnosticsRow(key: "Runtime Stats", value: "Unavailable")])
        }
        var rows: [DiagnosticsRow] = []
        let rx = Self.uint64(runtime["rxBytes"]) ?? 0
        let tx = Self.uint64(runtime["txBytes"]) ?? 0
        rows.append(DiagnosticsRow(key: "Received", value: FormattingHelpers.prettyBytes(rx)))
        rows.append(DiagnosticsRow(key: "Sent", value: FormattingHelpers.prettyBytes(tx)))
        if let rate = rates[runtimeKey] {
            rows.append(DiagnosticsRow(key: "Receive Rate", value: FormattingHelpers.prettyRate(rate.rx)))
            rows.append(DiagnosticsRow(key: "Send Rate", value: FormattingHelpers.prettyRate(rate.tx)))
        } else {
            rows.append(DiagnosticsRow(key: "Throughput", value: "Sampling…"))
        }
        if let handshake = Self.date(runtime["lastHandshakeTime"]) {
            rows.append(DiagnosticsRow(key: "Latest Handshake", value: FormattingHelpers.prettyTimeAgo(since: handshake)))
            rows.append(DiagnosticsRow(key: "Handshake Time", value: FormattingHelpers.prettyDateTime(handshake)))
        } else {
            rows.append(DiagnosticsRow(key: "Latest Handshake", value: "None yet"))
        }
        let peers = Self.dicts(runtime["peers"])
        rows.append(DiagnosticsRow(key: "Peers", value: "\(peers.count)"))
        return DiagnosticsSection(title: title, rows: rows)
    }

    // MARK: Interface

    private func interfaceSection(_ diagnostics: [String: Any]) -> DiagnosticsSection {
        var rows: [DiagnosticsRow] = []
        let settings = Self.dict(diagnostics["networkSettings"]) ?? [:]
        let mode = Self.string(diagnostics["mode"]) ?? "single"
        let runtime = Self.dict(diagnostics[mode == "tunnelInTunnel" ? "innerRuntime" : "runtime"]) ?? [:]
        let interface = Self.dict(runtime["interface"]) ?? [:]

        rows.append(DiagnosticsRow(key: "Interface", value: Self.string(diagnostics["interfaceName"]) ?? "Unknown"))
        if let handle = Self.int(diagnostics["tunnelHandle"]) {
            rows.append(DiagnosticsRow(key: "Backend Handle", value: "\(handle)"))
        }
        if let mtu = Self.int(diagnostics["interfaceMTU"]) {
            rows.append(DiagnosticsRow(key: "Interface MTU", value: "\(mtu)"))
        }
        if let mtu = Self.int(settings["mtu"]) {
            rows.append(DiagnosticsRow(key: "Requested MTU", value: "\(mtu)"))
        } else if let overhead = Self.int(settings["tunnelOverheadBytes"]) {
            rows.append(DiagnosticsRow(key: "Requested MTU", value: "Automatic (overhead \(overhead) bytes)"))
        }
        if let configured = Self.int(diagnostics["configuredMTU"]) {
            rows.append(DiagnosticsRow(key: "Configured MTU", value: configured == 0 ? "Automatic" : "\(configured)"))
        }
        if let publicKey = Self.string(interface["publicKey"]) {
            rows.append(DiagnosticsRow(key: "Public Key", value: publicKey))
        }
        if let listenPort = Self.int(interface["listenPort"]) {
            rows.append(DiagnosticsRow(key: "Listen Port", value: listenPort == 0 ? "Ephemeral" : "\(listenPort)"))
        }
        if let fwmark = Self.int(interface["fwmark"]), fwmark != 0 {
            rows.append(DiagnosticsRow(key: "Fwmark", value: "\(fwmark)"))
        }
        let ipv4 = Self.strings(settings["ipv4Addresses"])
        if !ipv4.isEmpty {
            rows.append(DiagnosticsRow(key: "IPv4 Addresses", value: ipv4.joined(separator: ", ")))
        }
        let ipv6 = Self.strings(settings["ipv6Addresses"])
        if !ipv6.isEmpty {
            rows.append(DiagnosticsRow(key: "IPv6 Addresses", value: ipv6.joined(separator: ", ")))
        }
        // Addresses the kernel actually has on the utun, which can differ from what was requested.
        if let name = Self.string(diagnostics["interfaceName"]) {
            let kernelAddresses = Self.dicts(diagnostics["interfaces"])
                .filter { Self.string($0["name"]) == name }
                .compactMap { Self.describeInterfaceAddress($0) }
            if !kernelAddresses.isEmpty {
                rows.append(DiagnosticsRow(key: "Kernel Addresses", value: kernelAddresses.joined(separator: ", ")))
            }
        }
        if let remote = Self.string(settings["tunnelRemoteAddress"]) {
            rows.append(DiagnosticsRow(key: "Tunnel Remote Address", value: remote + (remote == "127.0.0.1" ? " (placeholder)" : "")))
        }
        return DiagnosticsSection(title: "Tunnel Interface", rows: rows)
    }

    // MARK: DNS

    private func dnsSection(_ diagnostics: [String: Any]) -> DiagnosticsSection {
        let settings = Self.dict(diagnostics["networkSettings"]) ?? [:]
        var rows: [DiagnosticsRow] = []
        let servers = Self.strings(settings["dnsServers"])
        if servers.isEmpty {
            rows.append(DiagnosticsRow(key: "Servers", value: "System default (tunnel sets none)"))
        } else {
            rows.append(DiagnosticsRow(key: "Servers", value: servers.joined(separator: ", ")))
            let search = Self.strings(settings["dnsSearchDomains"])
            rows.append(DiagnosticsRow(key: "Search Domains", value: search.isEmpty ? "None" : search.joined(separator: ", ")))
            let match = Self.strings(settings["dnsMatchDomains"])
            if match == [""] {
                rows.append(DiagnosticsRow(key: "Match Domains", value: "All queries"))
            } else if !match.isEmpty {
                rows.append(DiagnosticsRow(key: "Match Domains", value: match.joined(separator: ", ")))
            }
            if let noSearch = Self.bool(settings["dnsMatchDomainsNoSearch"]) {
                rows.append(DiagnosticsRow(key: "Match Without Search", value: noSearch ? "Yes" : "No"))
            }
        }
        if let path = Self.dict(diagnostics["networkPath"]), let supportsDNS = Self.bool(path["supportsDNS"]) {
            rows.append(DiagnosticsRow(key: "Path Supports DNS", value: supportsDNS ? "Yes" : "No"))
        }
        return DiagnosticsSection(title: "DNS", rows: rows)
    }

    // MARK: Tunnel routes

    private func tunnelRoutesSection(_ diagnostics: [String: Any]) -> DiagnosticsSection {
        let settings = Self.dict(diagnostics["networkSettings"]) ?? [:]
        var rows: [DiagnosticsRow] = []

        let included4 = Self.strings(settings["ipv4IncludedRoutes"])
        let included6 = Self.strings(settings["ipv6IncludedRoutes"])
        let excluded4 = Self.strings(settings["ipv4ExcludedRoutes"])
        let excluded6 = Self.strings(settings["ipv6ExcludedRoutes"])

        rows.append(DiagnosticsRow(key: "Included Routes", value: "\(included4.count) IPv4, \(included6.count) IPv6"))
        rows.append(DiagnosticsRow(key: "Excluded Routes", value: "\(excluded4.count) IPv4, \(excluded6.count) IPv6"))
        for route in included4 {
            rows.append(DiagnosticsRow(key: "Include", value: route))
        }
        for route in included6 {
            rows.append(DiagnosticsRow(key: "Include", value: route))
        }
        for route in excluded4 {
            rows.append(DiagnosticsRow(key: "Exclude", value: route))
        }
        for route in excluded6 {
            rows.append(DiagnosticsRow(key: "Exclude", value: route))
        }

        let excludedIPs = Self.strings(diagnostics["excludedIPs"])
        if !excludedIPs.isEmpty {
            rows.append(DiagnosticsRow(key: "Excluded IPs", value: excludedIPs.joined(separator: ", ")))
        }
        if Self.bool(diagnostics["excludeLocalNetwork"]) == true {
            let localRoutes = Self.strings(diagnostics["localNetworkRoutes"])
            let interface = Self.string(diagnostics["localNetworkInterface"]).map { " via \($0)" } ?? ""
            rows.append(DiagnosticsRow(key: "Local Network Bypass", value: localRoutes.isEmpty ? "On (no local network found)" : localRoutes.joined(separator: ", ") + interface))
        }
        let siblingExclusions = Self.strings(diagnostics["excludedEndpoints"])
        if !siblingExclusions.isEmpty {
            rows.append(DiagnosticsRow(key: "Sibling Bypass", value: siblingExclusions.joined(separator: ", ")))
        }
        let configuredExclusions = Self.strings(diagnostics["configuredExcludedEndpoints"])
        if !configuredExclusions.isEmpty && configuredExclusions != siblingExclusions {
            rows.append(DiagnosticsRow(key: "Sibling Bypass (configured)", value: configuredExclusions.joined(separator: ", ")))
        }
        return DiagnosticsSection(title: "Tunnel Routes", rows: rows)
    }

    // MARK: Peers

    private func peerSections(_ diagnostics: [String: Any], runtimeKey: String, endpointsKey: String, titlePrefix: String) -> [DiagnosticsSection] {
        let runtime = Self.dict(diagnostics[runtimeKey]) ?? [:]
        let peers = Self.dicts(runtime["peers"])
        let resolutions = Self.dicts(diagnostics[endpointsKey])
        guard !peers.isEmpty else { return [] }

        return peers.enumerated().map { index, peer -> DiagnosticsSection in
            var rows: [DiagnosticsRow] = []
            let publicKey = Self.string(peer["publicKey"]) ?? "?"
            rows.append(DiagnosticsRow(key: "Public Key", value: publicKey))

            let resolution = resolutions.first { Self.string($0["publicKey"]) == publicKey }
            if let configured = Self.string(resolution?["configured"]) {
                rows.append(DiagnosticsRow(key: "Configured Endpoint", value: configured))
            }
            if let resolved = Self.string(resolution?["resolved"]), resolved != Self.string(resolution?["configured"]) {
                rows.append(DiagnosticsRow(key: "Resolved Endpoint", value: resolved))
            }
            if let current = Self.string(peer["endpoint"]) {
                rows.append(DiagnosticsRow(key: "Current Endpoint", value: current))
            } else {
                rows.append(DiagnosticsRow(key: "Current Endpoint", value: "None (waiting for peer)"))
            }
            let allowedIPs = Self.strings(peer["allowedIPs"])
            rows.append(DiagnosticsRow(key: "Allowed IPs", value: allowedIPs.isEmpty ? "None" : allowedIPs.joined(separator: ", ")))
            if let keepalive = Self.int(peer["persistentKeepalive"]) {
                rows.append(DiagnosticsRow(key: "Persistent Keepalive", value: keepalive == 0 ? "Off" : "Every \(keepalive)s"))
            }
            if let psk = Self.bool(peer["presharedKey"]) {
                rows.append(DiagnosticsRow(key: "Preshared Key", value: psk ? "Yes" : "No"))
            }
            if let handshake = Self.date(peer["lastHandshakeTime"]) {
                rows.append(DiagnosticsRow(key: "Latest Handshake", value: FormattingHelpers.prettyTimeAgo(since: handshake)))
            } else {
                rows.append(DiagnosticsRow(key: "Latest Handshake", value: "None yet"))
            }
            rows.append(DiagnosticsRow(key: "Received", value: FormattingHelpers.prettyBytes(Self.uint64(peer["rxBytes"]) ?? 0)))
            rows.append(DiagnosticsRow(key: "Sent", value: FormattingHelpers.prettyBytes(Self.uint64(peer["txBytes"]) ?? 0)))
            if let version = Self.int(peer["protocolVersion"]) {
                rows.append(DiagnosticsRow(key: "Protocol Version", value: "\(version)"))
            }
            let title = peers.count == 1 ? titlePrefix : "\(titlePrefix) \(index + 1)"
            return DiagnosticsSection(title: title, rows: rows)
        }
    }

    // MARK: Failover

    private func failoverSections(_ diagnostics: [String: Any]) -> [DiagnosticsSection] {
        guard let failover = Self.dict(diagnostics["failover"]) else { return [] }
        let monitor = Self.dict(diagnostics["healthMonitor"]) ?? [:]
        let names = Self.strings(failover["configNames"])
        let activeIndex = Self.int(failover["activeIndex"]) ?? 0
        var sections: [DiagnosticsSection] = []

        // State
        var stateRows: [DiagnosticsRow] = []
        if let active = Self.string(failover["activeConfig"]) {
            stateRows.append(DiagnosticsRow(key: "Active Config", value: "\(active) (#\(activeIndex))"))
        }
        if let since = Self.date(monitor["txWithoutRxSince"]) {
            let seconds = Int(Date().timeIntervalSince(since))
            stateRows.append(DiagnosticsRow(key: "Health", value: "Unhealthy (tx without rx for \(seconds)s)"))
        } else {
            stateRows.append(DiagnosticsRow(key: "Health", value: "Healthy"))
        }
        if let running = Self.bool(monitor["monitorRunning"]) {
            stateRows.append(DiagnosticsRow(key: "Health Monitor", value: running ? "Running" : "Stopped"))
        } else {
            stateRows.append(DiagnosticsRow(key: "Health Monitor", value: "Not started"))
        }
        if let rx = Self.uint64(monitor["monitorLastRxBytes"]), let tx = Self.uint64(monitor["monitorLastTxBytes"]) {
            stateRows.append(DiagnosticsRow(key: "Last Poll Counters", value: "rx \(FormattingHelpers.prettyBytes(rx)), tx \(FormattingHelpers.prettyBytes(tx))"))
        }
        if let effective = Self.double(monitor["effectiveTrafficTimeout"]) {
            let base = Self.double(Self.dict(failover["settings"])?["trafficTimeout"]) ?? effective
            let note = effective > base + 0.5 ? " (base \(Int(base))s, raised after false alarms)" : ""
            stateRows.append(DiagnosticsRow(key: "Effective Timeout", value: "\(Int(effective))s" + note))
        }
        if let falseAlarms = Self.int(monitor["falseAlarmCount"]) {
            stateRows.append(DiagnosticsRow(key: "False Alarms", value: "\(falseAlarms)"))
        }
        switch Self.string(monitor["confirmationState"]) {
        case "suppressed":
            let held = Self.date(monitor["suppressedSince"]).map { FormattingHelpers.prettyTimeAgo(since: $0) } ?? "?"
            stateRows.append(DiagnosticsRow(key: "Confirmation", value: "Holding failover, no server reachable (since \(held))"))
        case "probing":
            let index = Self.int(monitor["confirmationProbeIndex"]) ?? -1
            let target = names.indices.contains(index) ? names[index] : "next config"
            stateRows.append(DiagnosticsRow(key: "Confirmation", value: "Probing \(target)"))
        case "idle":
            stateRows.append(DiagnosticsRow(key: "Confirmation", value: "Idle"))
        default:
            break
        }
        if let pathSatisfied = Self.bool(monitor["pathSatisfied"]) {
            stateRows.append(DiagnosticsRow(key: "Path Usable", value: pathSatisfied ? "Yes" : "No (evaluation paused)"))
        }
        let cycles = Self.int(monitor["consecutiveCycles"]) ?? 0
        stateRows.append(DiagnosticsRow(key: "Failover Cycles", value: "\(cycles)"))
        if let maxCycles = Self.int(monitor["maxCyclesBeforeCooldown"]), let cooldown = Self.double(monitor["cooldownDuration"]) {
            stateRows.append(DiagnosticsRow(key: "Cooldown", value: "After \(maxCycles) cycles, \(Int(cooldown))s"))
        }
        if let lastSwitch = Self.date(monitor["lastSwitchTime"]) {
            stateRows.append(DiagnosticsRow(key: "Last Switch", value: FormattingHelpers.prettyTimeAgo(since: lastSwitch)))
        } else {
            stateRows.append(DiagnosticsRow(key: "Last Switch", value: "Never this session"))
        }
        if let hold = Self.double(monitor["minimumHoldTime"]) {
            stateRows.append(DiagnosticsRow(key: "Minimum Hold", value: "\(Int(hold))s"))
        }
        if let failbackTimer = Self.bool(monitor["failbackTimerActive"]) {
            stateRows.append(DiagnosticsRow(key: "Failback Timer", value: failbackTimer ? "Armed" : "Off"))
        }
        let probing = Self.bool(monitor["isProbing"]) ?? false
        if probing {
            if let handle = Self.int(monitor["failbackProbeHandle"]) {
                stateRows.append(DiagnosticsRow(key: "Failback Probe", value: "Background probe running (handle \(handle))"))
            } else if Self.bool(monitor["backgroundProbeActive"]) == true {
                stateRows.append(DiagnosticsRow(key: "Failback Probe", value: "Background probe running"))
            } else {
                stateRows.append(DiagnosticsRow(key: "Failback Probe", value: "Legacy probe in progress"))
            }
        } else {
            stateRows.append(DiagnosticsRow(key: "Failback Probe", value: "Idle"))
        }
        if let hotSpareIndex = Self.int(monitor["hotSpareConfigIndex"]) {
            let name = names.indices.contains(hotSpareIndex) ? names[hotSpareIndex] : "config #\(hotSpareIndex)"
            var value = name
            if let handle = Self.int(monitor["hotSpareHandle"]) {
                value += " (handle \(handle))"
            }
            if let age = Self.double(monitor["hotSpareHandshakeAge"]) {
                value += age < 180 ? ", handshake \(Int(age))s ago" : ", stale handshake \(Int(age))s ago"
            } else if Self.bool(monitor["hotSpareActive"]) == true {
                value += ", waiting for handshake"
            } else {
                value += ", starting"
            }
            stateRows.append(DiagnosticsRow(key: "Hot Spare", value: value))
        }
        let probeHandles = Self.ints(diagnostics["probeHandles"])
        stateRows.append(DiagnosticsRow(key: "Background Probes", value: probeHandles.isEmpty ? "None" : probeHandles.map(String.init).joined(separator: ", ")))
        sections.append(DiagnosticsSection(title: "Failover", rows: stateRows))

        // Configs
        let configs = Self.dicts(failover["configs"])
        var configRows: [DiagnosticsRow] = []
        for (index, config) in configs.enumerated() {
            let name = Self.string(config["name"]) ?? (names.indices.contains(index) ? names[index] : "config #\(index)")
            let role = index == 0 ? "Primary" : "Failover #\(index)"
            let status = failoverConfigStatus(index: index, activeIndex: activeIndex, monitor: monitor)
            var details = [status]
            let endpoints = Self.strings(config["endpoints"])
            if !endpoints.isEmpty {
                details.append(endpoints.joined(separator: ", "))
            }
            if let keepalive = Self.int(config["persistentKeepalive"]) {
                details.append("keepalive \(keepalive)s")
            }
            configRows.append(DiagnosticsRow(key: "\(role): \(name)", value: details.joined(separator: " · ")))
        }
        sections.append(DiagnosticsSection(title: "Failover Configs", rows: configRows))

        // Settings
        if let settings = Self.dict(failover["settings"]) {
            var settingRows: [DiagnosticsRow] = []
            if let timeout = Self.double(settings["trafficTimeout"]) {
                settingRows.append(DiagnosticsRow(key: "Traffic Timeout", value: "\(Int(timeout))s"))
            }
            if let interval = Self.double(settings["healthCheckInterval"]) {
                settingRows.append(DiagnosticsRow(key: "Health Check Interval", value: "\(Int(interval))s"))
            }
            if let interval = Self.double(settings["failbackProbeInterval"]) {
                settingRows.append(DiagnosticsRow(key: "Failback Probe Interval", value: "\(Int(interval))s"))
            }
            if let autoFailback = Self.bool(settings["autoFailback"]) {
                settingRows.append(DiagnosticsRow(key: "Auto Failback", value: autoFailback ? "Yes" : "No"))
            }
            if let background = Self.bool(settings["useBackgroundProbes"]) {
                settingRows.append(DiagnosticsRow(key: "Background Probes", value: background ? "Yes" : "No (legacy probe)"))
            }
            if let hotSpare = Self.bool(settings["hotSpare"]) {
                settingRows.append(DiagnosticsRow(key: "Hot Spare", value: hotSpare ? "Yes" : "No"))
            }
            if let override = Self.int(settings["persistentKeepaliveOverride"]) {
                settingRows.append(DiagnosticsRow(key: "Keepalive Override", value: override == 0 ? "Disabled on all peers" : "\(override)s on all peers"))
            } else {
                settingRows.append(DiagnosticsRow(key: "Keepalive Override", value: "None"))
            }
            if let confirm = Self.bool(settings["confirmBeforeFailover"]) {
                settingRows.append(DiagnosticsRow(key: "Confirm Before Failover", value: confirm ? "Yes" : "No"))
            }
            if let timeout = Self.double(settings["confirmationTimeout"]) {
                settingRows.append(DiagnosticsRow(key: "Confirmation Timeout", value: "\(Int(timeout))s"))
            }
            if let hold = Self.double(settings["linkDownHoldTime"]) {
                settingRows.append(DiagnosticsRow(key: "Link-Down Hold", value: hold > 0 ? "\(Int(hold))s" : "Forever"))
            }
            if let adaptive = Self.bool(settings["adaptiveSensitivity"]) {
                settingRows.append(DiagnosticsRow(key: "Adaptive Sensitivity", value: adaptive ? "Yes" : "No"))
            }
            if let grace = Self.double(settings["pathChangeGrace"]) {
                settingRows.append(DiagnosticsRow(key: "Path Change Grace", value: "\(Int(grace))s"))
            }
            sections.append(DiagnosticsSection(title: "Failover Settings", rows: settingRows))
        }

        return sections
    }

    private func failoverConfigStatus(index: Int, activeIndex: Int, monitor: [String: Any]) -> String {
        if index == activeIndex {
            return monitor["txWithoutRxSince"] != nil ? "Active, unhealthy" : "Active"
        }
        if let hotSpareIndex = Self.int(monitor["hotSpareConfigIndex"]), hotSpareIndex == index {
            if let age = Self.double(monitor["hotSpareHandshakeAge"]), age < 180 {
                return "Hot spare, standby"
            }
            return Self.bool(monitor["hotSpareActive"]) == true ? "Hot spare, connecting" : "Hot spare, starting"
        }
        if index == 0, Self.bool(monitor["isProbing"]) == true {
            return "Probing"
        }
        return "Idle"
    }

    // MARK: Network path

    private func networkPathSection(_ diagnostics: [String: Any]) -> DiagnosticsSection {
        guard let path = Self.dict(diagnostics["networkPath"]) else {
            return DiagnosticsSection(title: "Network Path", rows: [])
        }
        var rows: [DiagnosticsRow] = []
        let status = Self.string(path["status"]) ?? "unknown"
        var statusText: String
        switch status {
        case "satisfied": statusText = "Satisfied"
        case "unsatisfied": statusText = "Unsatisfied"
        case "requiresConnection": statusText = "Requires connection"
        default: statusText = status
        }
        if let reason = Self.string(path["unsatisfiedReason"]) {
            statusText += " (\(reason))"
        }
        rows.append(DiagnosticsRow(key: "Status", value: statusText))

        let interfaces = Self.dicts(path["interfaces"])
        if let primary = interfaces.first {
            rows.append(DiagnosticsRow(key: "Primary Interface", value: Self.describePathInterface(primary)))
        }
        for interface in interfaces.dropFirst() {
            rows.append(DiagnosticsRow(key: "Fallback Interface", value: Self.describePathInterface(interface)))
        }
        let gateways = Self.strings(path["gateways"])
        rows.append(DiagnosticsRow(key: "Gateways", value: gateways.isEmpty ? "None reported" : gateways.joined(separator: ", ")))
        if let expensive = Self.bool(path["isExpensive"]) {
            rows.append(DiagnosticsRow(key: "Expensive", value: expensive ? "Yes (cellular or hotspot)" : "No"))
        }
        if let constrained = Self.bool(path["isConstrained"]) {
            rows.append(DiagnosticsRow(key: "Constrained", value: constrained ? "Yes (Low Data Mode)" : "No"))
        }
        var families: [String] = []
        if Self.bool(path["supportsIPv4"]) == true { families.append("IPv4") }
        if Self.bool(path["supportsIPv6"]) == true { families.append("IPv6") }
        rows.append(DiagnosticsRow(key: "Address Families", value: families.isEmpty ? "None" : families.joined(separator: ", ")))
        return DiagnosticsSection(title: "Network Path", rows: rows)
    }

    private static func describePathInterface(_ interface: [String: Any]) -> String {
        let name = string(interface["name"]) ?? "?"
        let type: String
        switch string(interface["type"]) {
        case "wifi": type = "Wi-Fi"
        case "cellular": type = "Cellular"
        case "wiredEthernet": type = "Ethernet"
        case "loopback": type = "Loopback"
        default: type = "Other"
        }
        return "\(name) (\(type))"
    }

    // MARK: Local interfaces

    private func localInterfacesSection(_ diagnostics: [String: Any]) -> DiagnosticsSection {
        let entries = Self.dicts(diagnostics["interfaces"])
        let tunnelName = Self.string(diagnostics["interfaceName"])
        let pathOrder = Self.dicts(Self.dict(diagnostics["networkPath"])?["interfaces"]).compactMap { Self.string($0["name"]) }

        var byName: [String: [[String: Any]]] = [:]
        var order: [String] = []
        for entry in entries {
            guard let name = Self.string(entry["name"]) else { continue }
            guard Self.bool(entry["isLoopback"]) != true else { continue }
            guard Self.bool(entry["isUp"]) == true else { continue }
            if byName[name] == nil {
                order.append(name)
            }
            byName[name, default: []].append(entry)
        }

        func rank(_ name: String) -> Int {
            if name == tunnelName { return 0 }
            if let index = pathOrder.firstIndex(of: name) { return 1 + index }
            return 1000
        }
        order.sort { lhs, rhs in
            let lr = rank(lhs)
            let rr = rank(rhs)
            return lr == rr ? lhs < rhs : lr < rr
        }

        let rows = order.map { name -> DiagnosticsRow in
            let addresses = byName[name]?.compactMap { Self.describeInterfaceAddress($0) } ?? []
            var flags: [String] = []
            if let first = byName[name]?.first {
                if Self.bool(first["isRunning"]) != true { flags.append("not running") }
                if Self.bool(first["isPointToPoint"]) == true { flags.append("p2p") }
            }
            var value = addresses.joined(separator: ", ")
            if !flags.isEmpty {
                value += " (" + flags.joined(separator: ", ") + ")"
            }
            let key = name == tunnelName ? "\(name) (tunnel)" : name
            return DiagnosticsRow(key: key, value: value)
        }
        return DiagnosticsSection(title: "Local Interfaces", rows: rows)
    }

    private static func describeInterfaceAddress(_ entry: [String: Any]) -> String? {
        guard let address = string(entry["address"]) else { return nil }
        var text = address
        if let prefix = int(entry["prefixLength"]) {
            text += "/\(prefix)"
        }
        if let destination = string(entry["destination"]) {
            text += " → \(destination)"
        }
        return text
    }

    // MARK: Session

    private func sessionSection(_ diagnostics: [String: Any]) -> DiagnosticsSection {
        guard let session = Self.dict(diagnostics["session"]) else {
            return DiagnosticsSection(title: "Session", rows: [])
        }
        var rows: [DiagnosticsRow] = []
        if let started = Self.date(session["startedAt"]) {
            rows.append(DiagnosticsRow(key: "Started", value: FormattingHelpers.prettyDateTime(started)))
        }
        if let reason = Self.string(session["activationReason"]) {
            rows.append(DiagnosticsRow(key: "Activated By", value: reason == "onDemand" ? "On-Demand rule" : (reason == "manual" ? "App" : reason)))
        }
        if let initial = Self.string(session["initialActiveConfigName"]) {
            rows.append(DiagnosticsRow(key: "Initial Config", value: initial))
        }
        let rx = Self.uint64(session["rxBytes"]) ?? 0
        let tx = Self.uint64(session["txBytes"]) ?? 0
        rows.append(DiagnosticsRow(key: "Recorded Traffic", value: "rx \(FormattingHelpers.prettyBytes(rx)), tx \(FormattingHelpers.prettyBytes(tx)) (30s resolution)"))
        let events = Self.dicts(session["failoverEvents"])
        rows.append(DiagnosticsRow(key: "Failover Events", value: "\(events.count)"))
        for event in events {
            let time = Self.date(event["timestamp"]).map { FormattingHelpers.prettyTime($0) } ?? "?"
            rows.append(DiagnosticsRow(key: time, value: Self.describeFailoverEvent(event)))
        }
        return DiagnosticsSection(title: "Session", rows: rows)
    }

    private static func describeFailoverEvent(_ event: [String: Any]) -> String {
        let from = string(event["from"]) ?? "?"
        let to = string(event["to"]) ?? "?"
        switch string(event["kind"]) {
        case "switched":
            return "Switched \(from) → \(to)"
        case "unhealthy":
            let seconds = double(event["txWithoutRxDuration"]).map { "\(Int($0))s" } ?? "?"
            return "\(from) unhealthy (tx without rx for \(seconds))"
        case "failedBack":
            return "Failed back to \(to)"
        case "suppressed":
            let seconds = double(event["txWithoutRxDuration"]).map { "\(Int($0))s" } ?? "?"
            return "Held on \(from): no server reachable (\(seconds) tx without rx)"
        case "configReloaded":
            return "Configuration reloaded in place"
        default:
            return string(event["kind"]) ?? "Event"
        }
    }

    // MARK: Process

    private func processSection(_ diagnostics: [String: Any]) -> DiagnosticsSection {
        guard let process = Self.dict(diagnostics["process"]) else {
            return DiagnosticsSection(title: "Extension Process", rows: [])
        }
        var rows: [DiagnosticsRow] = []
        if let version = Self.string(process["version"]) {
            let build = Self.string(process["build"]).map { " (\($0))" } ?? ""
            rows.append(DiagnosticsRow(key: "Version", value: version + build))
        }
        if let bundle = Self.string(process["bundleIdentifier"]) {
            rows.append(DiagnosticsRow(key: "Bundle", value: bundle))
        }
        if let pid = Self.int(process["pid"]) {
            rows.append(DiagnosticsRow(key: "PID", value: "\(pid)"))
        }
        if let uptime = Self.double(process["uptime"]) {
            rows.append(DiagnosticsRow(key: "Process Uptime", value: FormattingHelpers.prettyDuration(uptime)))
        }
        if let footprint = Self.uint64(process["memoryFootprint"]) {
            rows.append(DiagnosticsRow(key: "Memory Footprint", value: FormattingHelpers.prettyBytes(footprint)))
        }
        if let os = Self.string(process["osVersion"]) {
            rows.append(DiagnosticsRow(key: "OS", value: os))
        }
        if let thermal = Self.string(process["thermalState"]) {
            rows.append(DiagnosticsRow(key: "Thermal State", value: thermal.capitalized))
        }
        if let lowPower = Self.bool(process["isLowPowerModeEnabled"]) {
            rows.append(DiagnosticsRow(key: "Low Power Mode", value: lowPower ? "On" : "Off"))
        }
        if let cores = Self.int(process["activeProcessorCount"]) {
            rows.append(DiagnosticsRow(key: "Active CPUs", value: "\(cores)"))
        }
        return DiagnosticsSection(title: "Extension Process", rows: rows)
    }

    // MARK: Routing table

    private func routingTableSection(_ diagnostics: [String: Any]) -> DiagnosticsSection {
        guard let routes = diagnostics["routes"] as? [[String: Any]] else {
            return DiagnosticsSection(title: "System Routing Table", rows: [DiagnosticsRow(key: "Routing Table", value: "Unavailable")])
        }
        let tunnelName = Self.string(diagnostics["interfaceName"])
        var rows: [DiagnosticsRow] = []
        var shown = 0
        var hidden = 0
        for route in routes {
            guard let destination = Self.string(route["destination"]) else { continue }
            // Multicast and link-local IPv6 entries exist per interface and add little.
            if destination.hasPrefix("ff") || destination.hasPrefix("224.0.0") || destination.hasPrefix("fe80:") {
                continue
            }
            if shown >= maxRoutingTableRows {
                hidden += 1
                continue
            }
            var parts: [String] = []
            let gateway = Self.string(route["gateway"]) ?? ""
            parts.append(gateway.isEmpty ? "direct" : "via \(gateway)")
            if let flags = Self.string(route["flags"]), !flags.isEmpty {
                parts.append(flags)
            }
            if let interface = Self.string(route["interface"]), !interface.isEmpty {
                parts.append(interface == tunnelName ? "\(interface) ★" : interface)
            }
            if let mtu = Self.int(route["mtu"]) {
                parts.append("mtu \(mtu)")
            }
            rows.append(DiagnosticsRow(key: destination, value: parts.joined(separator: " · ")))
            shown += 1
        }
        if hidden > 0 {
            rows.append(DiagnosticsRow(key: "…", value: "\(hidden) more routes not shown"))
        }
        if rows.isEmpty {
            rows.append(DiagnosticsRow(key: "Routing Table", value: "Empty"))
        }
        return DiagnosticsSection(title: "System Routing Table (★ = tunnel)", rows: rows)
    }

    // MARK: Static configuration (tunnel not running)

    private func configuredSections() -> [DiagnosticsSection] {
        var sections: [DiagnosticsSection] = []
        guard let proto = tunnel.tunnelProvider.protocolConfiguration as? NETunnelProviderProtocol else { return sections }
        let providerConfig = proto.providerConfiguration ?? [:]

        switch tunnel.groupKind {
        case .some(.failover):
            let names = providerConfig["FailoverConfigNames"] as? [String] ?? []
            var rows = names.enumerated().map { index, name in
                DiagnosticsRow(key: index == 0 ? "Primary" : "Failover #\(index)", value: name)
            }
            if let data = providerConfig["FailoverSettings"] as? Data,
               let settings = try? JSONDecoder().decode(FailoverSettings.self, from: data) {
                rows.append(DiagnosticsRow(key: "Traffic Timeout", value: "\(Int(settings.trafficTimeout))s"))
                rows.append(DiagnosticsRow(key: "Health Check Interval", value: "\(Int(settings.healthCheckInterval))s"))
                rows.append(DiagnosticsRow(key: "Failback Probe Interval", value: "\(Int(settings.failbackProbeInterval))s"))
                rows.append(DiagnosticsRow(key: "Auto Failback", value: settings.autoFailback ? "Yes" : "No"))
                rows.append(DiagnosticsRow(key: "Background Probes", value: settings.useBackgroundProbes ? "Yes" : "No"))
                rows.append(DiagnosticsRow(key: "Hot Spare", value: settings.hotSpare ? "Yes" : "No"))
            }
            sections.append(DiagnosticsSection(title: "Failover Configuration", rows: rows))
        case .some(.tunnelInTunnel):
            let rows = [
                DiagnosticsRow(key: "Outer (Server A)", value: providerConfig[TunnelInTunnelConfigKeys.outerName] as? String ?? "—"),
                DiagnosticsRow(key: "Inner (Server B)", value: providerConfig[TunnelInTunnelConfigKeys.innerName] as? String ?? "—")
            ]
            sections.append(DiagnosticsSection(title: "Tunnel Chain", rows: rows))
        case .none:
            break
        }

        guard let config = tunnel.tunnelConfiguration else { return sections }
        let interface = config.interface
        var interfaceRows: [DiagnosticsRow] = [
            DiagnosticsRow(key: "Public Key", value: interface.privateKey.publicKey.base64Key)
        ]
        if !interface.addresses.isEmpty {
            interfaceRows.append(DiagnosticsRow(key: "Addresses", value: interface.addresses.map { $0.stringRepresentation }.joined(separator: ", ")))
        }
        interfaceRows.append(DiagnosticsRow(key: "Listen Port", value: interface.listenPort.map { "\($0)" } ?? "Ephemeral"))
        interfaceRows.append(DiagnosticsRow(key: "MTU", value: interface.mtu.map { "\($0)" } ?? "Automatic"))
        if !interface.dns.isEmpty {
            interfaceRows.append(DiagnosticsRow(key: "DNS Servers", value: interface.dns.map { $0.stringRepresentation }.joined(separator: ", ")))
        }
        if !interface.dnsSearch.isEmpty {
            interfaceRows.append(DiagnosticsRow(key: "DNS Search", value: interface.dnsSearch.joined(separator: ", ")))
        }
        sections.append(DiagnosticsSection(title: tunnel.groupKind == .failover ? "Primary Interface (configured)" : "Interface (configured)", rows: interfaceRows))

        for (index, peer) in config.peers.enumerated() {
            var rows: [DiagnosticsRow] = [DiagnosticsRow(key: "Public Key", value: peer.publicKey.base64Key)]
            if let endpoint = peer.endpoint {
                rows.append(DiagnosticsRow(key: "Endpoint", value: endpoint.stringRepresentation))
            }
            rows.append(DiagnosticsRow(key: "Allowed IPs", value: peer.allowedIPs.map { $0.stringRepresentation }.joined(separator: ", ")))
            rows.append(DiagnosticsRow(key: "Persistent Keepalive", value: peer.persistentKeepAlive.map { "Every \($0)s" } ?? "Off"))
            rows.append(DiagnosticsRow(key: "Preshared Key", value: peer.preSharedKey != nil ? "Yes" : "No"))
            let title = config.peers.count == 1 ? "Peer (configured)" : "Peer \(index + 1) (configured)"
            sections.append(DiagnosticsSection(title: title, rows: rows))
        }
        return sections
    }

    // MARK: - Plain-text export

    /// A copy/paste friendly rendering of every section plus the redacted UAPI dumps.
    func plainTextReport() -> String {
        var lines: [String] = []
        lines.append("WGnext Connection Details")
        lines.append("Generated: \(FormattingHelpers.prettyDateTime(Date()))")
        lines.append("")
        for section in sections() {
            lines.append("== \(section.title) ==")
            for row in section.rows {
                lines.append("\(row.key): \(row.value)")
            }
            lines.append("")
        }
        if let diagnostics = diagnostics {
            for (key, title) in [("uapi", "Raw UAPI (redacted)"), ("outerUapi", "Outer Raw UAPI (redacted)"), ("innerUapi", "Inner Raw UAPI (redacted)")] {
                if let dump = Self.string(diagnostics[key]) {
                    lines.append("== \(title) ==")
                    lines.append(dump.trimmingCharacters(in: .whitespacesAndNewlines))
                    lines.append("")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - JSON helpers

    private static func dict(_ value: Any?) -> [String: Any]? {
        return value as? [String: Any]
    }

    private static func dicts(_ value: Any?) -> [[String: Any]] {
        return value as? [[String: Any]] ?? []
    }

    private static func string(_ value: Any?) -> String? {
        return value as? String
    }

    private static func strings(_ value: Any?) -> [String] {
        return value as? [String] ?? []
    }

    private static func ints(_ value: Any?) -> [Int] {
        return (value as? [Any])?.compactMap { int($0) } ?? []
    }

    private static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        return value as? Int
    }

    private static func uint64(_ value: Any?) -> UInt64? {
        if let number = value as? NSNumber { return number.uint64Value }
        return value as? UInt64
    }

    private static func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        return value as? Double
    }

    private static func bool(_ value: Any?) -> Bool? {
        if let number = value as? NSNumber { return number.boolValue }
        return value as? Bool
    }

    private static func date(_ value: Any?) -> Date? {
        guard let seconds = double(value), seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}
