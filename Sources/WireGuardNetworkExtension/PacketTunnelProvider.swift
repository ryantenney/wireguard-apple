// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.
// Copyright © 2026 Ryan Tenney.

import Foundation
import NetworkExtension
import UserNotifications
import os

class PacketTunnelProvider: NEPacketTunnelProvider {

    private lazy var adapter: WireGuardAdapter = {
        return WireGuardAdapter(with: self) { logLevel, message in
            wg_log(logLevel.osLogLevel, message: message)
        }
    }()

    /// TiT outer config (Server A), if tunnel-in-tunnel is configured.
    private var titOuterConfig: TunnelConfiguration?

    /// TiT inner config (Server B), if tunnel-in-tunnel is configured.
    private var titInnerConfig: TunnelConfiguration?

    /// All tunnel configurations for failover (index 0 = primary). Empty if failover is not configured.
    private var failoverConfigs: [TunnelConfiguration] = []

    /// Names corresponding to failoverConfigs, for display/logging.
    private var failoverConfigNames: [String] = []

    /// Index of the currently active configuration within failoverConfigs.
    private var activeConfigIndex: Int = 0

    /// Failover settings decoded from providerConfiguration (defaults if absent).
    private var failoverSettings = FailoverSettings()

    /// The failover health monitor, if this tunnel is a failover group.
    /// The provider owns the lifecycle; the adapter holds a copy (installed
    /// via `setHealthMonitor`) for its network-path callbacks.
    private var healthMonitor: ConnectionHealthMonitor?

    // MARK: - Widget Stats Writer

    /// Timer that periodically writes traffic stats to shared UserDefaults for the widget.
    private var statsTimer: DispatchSourceTimer?

    /// tx_bytes from the previous stats poll (for rate computation).
    private var previousStatsTxBytes: UInt64 = 0

    /// rx_bytes from the previous stats poll (for rate computation).
    private var previousStatsRxBytes: UInt64 = 0

    /// Timestamp of the previous stats poll.
    private var previousStatsTime: Date?

    /// Rolling traffic samples for sparkline.
    private var trafficSamples: [VPNTrafficData.TrafficSample] = []

    /// When this tunnel session connected.
    private var tunnelConnectedSince: Date?

    // MARK: - Session History

    /// In-progress session record for this tunnel run. Mutations must go through `sessionQueue`.
    private var currentSession: SessionRecord?

    /// Whether the `options` parameter to `startTunnel` was nil — Apple's convention indicates
    /// `nil` means started by the OS (on-demand rule fired) and non-nil means started by the app.
    private var startupOptionsWasNil: Bool = true

    /// Serializes mutations of `currentSession` across the stats poll queue, the health monitor's
    /// queue, and the system NE start/stop queues.
    private let sessionQueue = DispatchQueue(label: "PacketTunnelProvider.SessionHistory")

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let activationAttemptId = options?["activationAttemptId"] as? String
        let errorNotifier = ErrorNotifier(activationAttemptId: activationAttemptId)
        startupOptionsWasNil = (options == nil)

        Logger.configureGlobal(tagged: "NET", withFilePath: FileManager.logFileURL?.path)

        wg_log(.info, message: "Starting tunnel from the " + (activationAttemptId == nil ? "OS directly, rather than the app" : "app"))

        guard let tunnelProviderProtocol = self.protocolConfiguration as? NETunnelProviderProtocol else {
            errorNotifier.notify(PacketTunnelProviderError.savedProtocolConfigurationIsInvalid)
            completionHandler(PacketTunnelProviderError.savedProtocolConfigurationIsInvalid)
            return
        }

        // Load failover configurations from providerConfiguration, if present
        let providerConfig = tunnelProviderProtocol.providerConfiguration
        loadFailoverConfigs(from: providerConfig)
        loadTiTConfigs(from: providerConfig)

        // Tunnel-in-Tunnel: start with paired outer+inner configs if present.
        if let outer = titOuterConfig, let inner = titInnerConfig {
            wg_log(.info, message: "TiT: starting tunnel-in-tunnel (outer→inner)")
            adapter.startTunnelInTunnel(
                outerTunnelConfiguration: outer,
                innerTunnelConfiguration: inner
            ) { adapterError in
                guard let adapterError = adapterError else {
                    wg_log(.info, message: "TiT: tunnel interface is \(self.adapter.interfaceName ?? "unknown")")
                    self.startStatsWriter()
                    completionHandler(nil)
                    return
                }
                self.handleStartAdapterError(adapterError, notifier: errorNotifier, completionHandler: completionHandler)
            }
            return
        }

        // Determine the primary tunnel configuration
        let tunnelConfiguration: TunnelConfiguration
        if let primary = failoverConfigs.first {
            tunnelConfiguration = primary
            wg_log(.info, message: "Failover: loaded \(failoverConfigs.count) configs [\(failoverConfigNames.joined(separator: ", "))]")
        } else {
            guard let config = tunnelProviderProtocol.asTunnelConfiguration() else {
                errorNotifier.notify(PacketTunnelProviderError.savedProtocolConfigurationIsInvalid)
                completionHandler(PacketTunnelProviderError.savedProtocolConfigurationIsInvalid)
                return
            }
            tunnelConfiguration = config
        }

        // Collect sibling failover endpoints (every config in the group except the primary)
        // so the adapter installs them as `excludedRoutes` — keeps probe traffic and any
        // direct hits to dormant failover servers off the active utun. See
        // `docs/probe-routing-bypass.md`.
        let excludedEndpoints = Self.failoverSiblingEndpoints(configs: failoverConfigs, activeIndex: 0)

        // Warm spare cellular failover: single-config tunnels only. Failover
        // groups have their own path machinery (ConnectionHealthMonitor) and
        // the warm spare interplay with config switching is not designed yet.
        var warmSpareSettings: WarmSpareSettings?
        if failoverConfigs.count <= 1,
           let settingsData = providerConfig?[ProviderConfigurationKeys.warmSpareSettings] as? Data,
           let decoded = try? JSONDecoder().decode(WarmSpareSettings.self, from: settingsData) {
            if decoded.enabled {
                warmSpareSettings = decoded
                wg_log(.info, message: "Warm spare: enabled (adaptive=\(decoded.adaptiveWarming), probePort=\(decoded.probePort))")
            }
        } else if failoverConfigs.count > 1, providerConfig?[ProviderConfigurationKeys.warmSpareSettings] != nil {
            wg_log(.info, message: "Warm spare: configured but ignored for failover groups")
        }

        // Start the tunnel
        adapter.start(tunnelConfiguration: tunnelConfiguration, excludedEndpoints: excludedEndpoints, warmSpareSettings: warmSpareSettings) { adapterError in
            guard let adapterError = adapterError else {
                wg_log(.info, message: "Tunnel interface is \(self.adapter.interfaceName ?? "unknown")")
                self.startHealthMonitorIfNeeded(providerConfig: providerConfig)
                self.startStatsWriter()
                completionHandler(nil)
                return
            }
            self.handleStartAdapterError(adapterError, notifier: errorNotifier, completionHandler: completionHandler)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        wg_log(.info, staticMessage: "Stopping tunnel")

        let displayName = resolveDisplayName()

        // Post a disconnect notification if the user enabled it and the stop was
        // not triggered by the user themselves (e.g. network lost, server closed).
        #if os(iOS)
        if reason != .none && reason != .userInitiated {
            postDisconnectNotificationIfEnabled(tunnelName: displayName, reason: reason)
        }
        #endif

        finalizeSessionRecord(reason: reason)

        healthMonitor?.stop()
        healthMonitor = nil
        adapter.setHealthMonitor(nil)
        stopStatsWriter()

        adapter.stop { error in
            ErrorNotifier.removeLastErrorFile()

            if let error = error {
                wg_log(.error, message: "Failed to stop WireGuard adapter: \(error.localizedDescription)")
            }
            // Deterministic final teardown (unregisters the Go log callback)
            // instead of relying on deinit timing.
            self.adapter.shutdown()
            completionHandler()

            #if os(macOS)
            // HACK: This is a filthy hack to work around Apple bug 32073323 (dup'd by us as 47526107).
            // Remove it when they finally fix this upstream and the fix has been rolled out to
            // sufficient quantities of users.
            exit(0)
            #endif
        }
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
        guard let completionHandler = completionHandler else { return }
        guard messageData.count >= 1 else {
            completionHandler(nil)
            return
        }

        switch messageData[0] {
        case 0:
            // Existing: get runtime configuration
            adapter.getRuntimeConfiguration { settings in
                var data: Data?
                if let settings = settings {
                    data = settings.data(using: .utf8)!
                }
                completionHandler(data)
            }

        case 1:
            // Failover: get current failover state + runtime stats
            let state: [String: Any] = [
                "activeIndex": activeConfigIndex,
                "activeConfig": failoverConfigNames.indices.contains(activeConfigIndex) ? failoverConfigNames[activeConfigIndex] : "unknown",
                "totalConfigs": failoverConfigs.count,
                "configNames": failoverConfigNames,
                "isFailoverActive": failoverConfigs.count > 1
            ]

            let group = DispatchGroup()

            // The two completions below run on different queues (the monitor's
            // and the adapter's), so each writes only its own variable; the
            // merge happens in group.notify, after both have left the group.
            var monitorSnapshot: [String: Any] = [:]
            var runtimeStats: [String: Any] = [:]

            // Gather health monitor state
            if let monitor = healthMonitor {
                group.enter()
                monitor.getStateSnapshot { snapshot in
                    monitorSnapshot = snapshot
                    group.leave()
                }
            }

            // Gather runtime peer stats (tx/rx bytes, last handshake)
            group.enter()
            adapter.getRuntimeConfiguration { configString in
                if let configString = configString {
                    let (tx, rx) = ConnectionHealthMonitor.parseTxRxBytes(from: configString)
                    runtimeStats["txBytes"] = tx
                    runtimeStats["rxBytes"] = rx
                    let handshakeAge = ConnectionHealthMonitor.parseLastHandshakeAge(from: configString)
                    if handshakeAge != .infinity {
                        runtimeStats["lastHandshakeTime"] = Date().timeIntervalSince1970 - handshakeAge
                    }
                }
                group.leave()
            }

            group.notify(queue: .main) {
                var merged = state
                for (key, value) in monitorSnapshot {
                    merged[key] = value
                }
                for (key, value) in runtimeStats {
                    merged[key] = value
                }
                completionHandler(try? JSONSerialization.data(withJSONObject: merged))
            }

        #if FAILOVER_TESTING
        case 2:
            // Debug: force failover to next config
            guard let monitor = healthMonitor else {
                completionHandler(nil)
                return
            }
            monitor.forceSwitch { success in
                let result: [String: Any] = ["success": success]
                completionHandler(try? JSONSerialization.data(withJSONObject: result))
            }

        case 3:
            // Debug: force failback to primary
            guard let monitor = healthMonitor else {
                completionHandler(nil)
                return
            }
            monitor.forceFailback { success in
                let result: [String: Any] = ["success": success]
                completionHandler(try? JSONSerialization.data(withJSONObject: result))
            }
        #endif

        case 5:
            // Warm spare: get merged status (Go bridge stats + path controller state)
            adapter.getWarmSpareStatus { status in
                guard let status = status else {
                    completionHandler(nil)
                    return
                }
                completionHandler(try? JSONSerialization.data(withJSONObject: status))
            }

        case 6:
            // Warm spare: run the EIM (endpoint-independent mapping) self-test.
            // The verdict lands in the message-5 status within a few seconds.
            adapter.runWarmSpareEimTest { started in
                let result: [String: Any] = ["started": started]
                completionHandler(try? JSONSerialization.data(withJSONObject: result))
            }

        #if FAILOVER_TESTING
        case 7:
            // Debug: force the warm spare active path.
            // Byte 1: 0 = primary, 1 = cellular, 2 = resume automatic control.
            guard messageData.count >= 2 else {
                completionHandler(nil)
                return
            }
            let path: WarmSparePath?
            switch messageData[1] {
            case 0: path = .primary
            case 1: path = .cellular
            default: path = nil
            }
            adapter.debugForceWarmSparePath(path)
            completionHandler(try? JSONSerialization.data(withJSONObject: ["success": true]))
        #endif

        case 4:
            // TiT: get runtime stats for both INNER and OUTER tunnels
            adapter.getTiTRuntimeConfigurations { innerConfig, outerConfig in
                var state: [String: Any] = [:]
                if let innerConfig = innerConfig {
                    let (tx, rx) = ConnectionHealthMonitor.parseTxRxBytes(from: innerConfig)
                    state["innerTxBytes"] = tx
                    state["innerRxBytes"] = rx
                    let handshakeAge = ConnectionHealthMonitor.parseLastHandshakeAge(from: innerConfig)
                    if handshakeAge != .infinity {
                        state["innerLastHandshakeTime"] = Date().timeIntervalSince1970 - handshakeAge
                    }
                }
                if let outerConfig = outerConfig {
                    let (tx, rx) = ConnectionHealthMonitor.parseTxRxBytes(from: outerConfig)
                    state["outerTxBytes"] = tx
                    state["outerRxBytes"] = rx
                    let handshakeAge = ConnectionHealthMonitor.parseLastHandshakeAge(from: outerConfig)
                    if handshakeAge != .infinity {
                        state["outerLastHandshakeTime"] = Date().timeIntervalSince1970 - handshakeAge
                    }
                }
                completionHandler(try? JSONSerialization.data(withJSONObject: state))
            }

        case 5:
            // Connection details: everything the app needs for the stats/debug view
            buildDiagnostics { diagnostics in
                completionHandler(try? JSONSerialization.data(withJSONObject: diagnostics))
            }

        case 6:
            // Live reload of a group's configuration after a member or the group was edited
            guard let payload = try? JSONSerialization.jsonObject(with: messageData.dropFirst()) as? [String: Any] else {
                completionHandler(try? JSONSerialization.data(withJSONObject: ["success": false]))
                return
            }
            reloadGroupConfiguration(payload) { success in
                completionHandler(try? JSONSerialization.data(withJSONObject: ["success": success]))
            }

        default:
            completionHandler(nil)
        }
    }

    // MARK: - Connection Diagnostics

    /// Assemble the connection details payload (IPC message type 5). Gathers adapter
    /// state, live UAPI stats, health monitor internals, failover/TiT configuration,
    /// session history for this run, host interfaces, the routing table, and process
    /// info into a single JSON-serializable dictionary.
    private func buildDiagnostics(completionHandler: @escaping ([String: Any]) -> Void) {
        let isTunnelInTunnel = titOuterConfig != nil && titInnerConfig != nil

        var diagnostics: [String: Any] = [
            "generatedAt": Date().timeIntervalSince1970,
            "mode": isTunnelInTunnel ? "tunnelInTunnel" : (failoverConfigs.count > 1 ? "failover" : "single"),
            "activationReason": startupOptionsWasNil ? "onDemand" : "manual",
            "process": NetworkDiagnostics.processInfo(),
            "interfaces": NetworkDiagnostics.interfaceAddresses()
        ]
        if let connectedSince = tunnelConnectedSince {
            diagnostics["connectedSince"] = connectedSince.timeIntervalSince1970
        }
        if let routes = NetworkDiagnostics.routingTable() {
            diagnostics["routes"] = routes
        }
        if let session = sessionDiagnostics() {
            diagnostics["session"] = session
        }
        if !failoverConfigs.isEmpty {
            diagnostics["failover"] = failoverDiagnostics()
        }
        if isTunnelInTunnel {
            diagnostics["tunnelInTunnel"] = tunnelInTunnelDiagnostics()
        }

        // The remaining pieces are asynchronous; merge them on a private queue.
        let mergeQueue = DispatchQueue(label: "PacketTunnelProvider.Diagnostics")
        let group = DispatchGroup()

        group.enter()
        adapter.getDiagnostics { info in
            mergeQueue.async {
                for (key, value) in info {
                    diagnostics[key] = value
                }
                if let interfaceName = info["interfaceName"] as? String,
                   let mtu = NetworkDiagnostics.interfaceMTU(named: interfaceName) {
                    diagnostics["interfaceMTU"] = mtu
                }
                group.leave()
            }
        }

        if isTunnelInTunnel {
            group.enter()
            adapter.getTiTRuntimeConfigurations { innerConfig, outerConfig in
                mergeQueue.async {
                    if let innerConfig = innerConfig {
                        diagnostics["innerRuntime"] = UapiRuntimeSnapshot.parse(innerConfig)
                        diagnostics["innerUapi"] = ConnectionHealthMonitor.redactSecrets(from: innerConfig)
                    }
                    if let outerConfig = outerConfig {
                        diagnostics["outerRuntime"] = UapiRuntimeSnapshot.parse(outerConfig)
                        diagnostics["outerUapi"] = ConnectionHealthMonitor.redactSecrets(from: outerConfig)
                    }
                    group.leave()
                }
            }
        } else {
            group.enter()
            adapter.getRuntimeConfiguration { configString in
                mergeQueue.async {
                    if let configString = configString {
                        diagnostics["runtime"] = UapiRuntimeSnapshot.parse(configString)
                        diagnostics["uapi"] = ConnectionHealthMonitor.redactSecrets(from: configString)
                    }
                    group.leave()
                }
            }
        }

        if let monitor = healthMonitor {
            group.enter()
            monitor.getStateSnapshot { snapshot in
                mergeQueue.async {
                    diagnostics["healthMonitor"] = snapshot
                    group.leave()
                }
            }
        }

        group.notify(queue: mergeQueue) {
            completionHandler(diagnostics)
        }
    }

    private func sessionDiagnostics() -> [String: Any]? {
        return sessionQueue.sync { () -> [String: Any]? in
            guard let session = self.currentSession else { return nil }
            var info: [String: Any] = [
                "id": session.id.uuidString,
                "tunnelName": session.tunnelName,
                "startedAt": session.startedAt.timeIntervalSince1970,
                "activationReason": session.activationReason.rawValue,
                "rxBytes": session.rxBytes,
                "txBytes": session.txBytes
            ]
            if let initialActiveConfigName = session.initialActiveConfigName {
                info["initialActiveConfigName"] = initialActiveConfigName
            }
            info["failoverEvents"] = session.failoverEvents.map { event -> [String: Any] in
                var entry: [String: Any] = [
                    "kind": event.kind.rawValue,
                    "timestamp": event.timestamp.timeIntervalSince1970
                ]
                if let fromConfigName = event.fromConfigName {
                    entry["from"] = fromConfigName
                }
                if let toConfigName = event.toConfigName {
                    entry["to"] = toConfigName
                }
                if let duration = event.txWithoutRxDuration {
                    entry["txWithoutRxDuration"] = duration
                }
                return entry
            }
            return info
        }
    }

    private func failoverDiagnostics() -> [String: Any] {
        var info: [String: Any] = [
            "configNames": failoverConfigNames,
            "activeIndex": activeConfigIndex,
            "totalConfigs": failoverConfigs.count,
            "settings": Self.describe(failoverSettings)
        ]
        if failoverConfigNames.indices.contains(activeConfigIndex) {
            info["activeConfig"] = failoverConfigNames[activeConfigIndex]
        }
        info["configs"] = failoverConfigs.enumerated().map { index, config -> [String: Any] in
            var entry: [String: Any] = [
                "index": index,
                "name": config.name ?? (failoverConfigNames.indices.contains(index) ? failoverConfigNames[index] : "config #\(index)"),
                "publicKey": config.interface.privateKey.publicKey.base64Key,
                "addresses": config.interface.addresses.map { $0.stringRepresentation },
                "endpoints": config.peers.compactMap { $0.endpoint?.stringRepresentation },
                "peerCount": config.peers.count
            ]
            if let keepalive = config.peers.compactMap({ $0.persistentKeepAlive }).first {
                entry["persistentKeepalive"] = Int(keepalive)
            }
            if let mtu = config.interface.mtu {
                entry["mtu"] = Int(mtu)
            }
            return entry
        }
        return info
    }

    private func tunnelInTunnelDiagnostics() -> [String: Any] {
        var info: [String: Any] = [:]
        if let outer = titOuterConfig {
            info["outer"] = Self.describe(outer)
        }
        if let inner = titInnerConfig {
            info["inner"] = Self.describe(inner)
        }
        return info
    }

    private static func describe(_ config: TunnelConfiguration) -> [String: Any] {
        var info: [String: Any] = [
            "publicKey": config.interface.privateKey.publicKey.base64Key,
            "addresses": config.interface.addresses.map { $0.stringRepresentation },
            "dns": config.interface.dns.map { $0.stringRepresentation },
            "dnsSearch": config.interface.dnsSearch,
            "peers": config.peers.map { peer -> [String: Any] in
                var entry: [String: Any] = [
                    "publicKey": peer.publicKey.base64Key,
                    "allowedIPs": peer.allowedIPs.map { $0.stringRepresentation },
                    "presharedKey": peer.preSharedKey != nil
                ]
                if let endpoint = peer.endpoint {
                    entry["endpoint"] = endpoint.stringRepresentation
                }
                if let keepalive = peer.persistentKeepAlive {
                    entry["persistentKeepalive"] = Int(keepalive)
                }
                return entry
            }
        ]
        if let name = config.name {
            info["name"] = name
        }
        if let mtu = config.interface.mtu {
            info["mtu"] = Int(mtu)
        }
        if let listenPort = config.interface.listenPort {
            info["listenPort"] = Int(listenPort)
        }
        return info
    }

    private static func describe(_ settings: FailoverSettings) -> [String: Any] {
        var info: [String: Any] = [
            "trafficTimeout": settings.trafficTimeout,
            "healthCheckInterval": settings.healthCheckInterval,
            "failbackProbeInterval": settings.failbackProbeInterval,
            "autoFailback": settings.autoFailback,
            "useBackgroundProbes": settings.useBackgroundProbes,
            "hotSpare": settings.hotSpare,
            "confirmBeforeFailover": settings.confirmBeforeFailover,
            "confirmationTimeout": settings.confirmationTimeout,
            "linkDownHoldTime": settings.linkDownHoldTime,
            "adaptiveSensitivity": settings.adaptiveSensitivity,
            "pathChangeGrace": settings.pathChangeGrace
        ]
        if let override = settings.persistentKeepaliveOverride {
            info["persistentKeepaliveOverride"] = Int(override)
        }
        return info
    }

    // MARK: - Widget Stats Writer

    private func startStatsWriter() {
        tunnelConnectedSince = Date()
        previousStatsTxBytes = 0
        previousStatsRxBytes = 0
        previousStatsTime = nil
        trafficSamples = []

        // Determine initial active config name for failover groups
        let initialActiveConfig: String?
        if !failoverConfigNames.isEmpty {
            initialActiveConfig = failoverConfigNames.indices.contains(activeConfigIndex) ? failoverConfigNames[activeConfigIndex] : nil
        } else {
            initialActiveConfig = nil
        }

        // Begin a session history record sharing the same start timestamp.
        // All downstream writers (stats poll, failover events, finalize) no-op
        // when currentSession is nil, so the user's off switch gates here.
        if SessionHistoryStore.isRecordingEnabled {
            let activationReason: ActivationReason = startupOptionsWasNil ? .onDemand : .manual
            let session = SessionRecord(
                tunnelName: resolveDisplayName(),
                startedAt: tunnelConnectedSince!,
                activationReason: activationReason,
                initialActiveConfigName: initialActiveConfig
            )
            sessionQueue.sync {
                self.currentSession = session
                SessionHistoryStore.saveCurrent(session)
            }
        }

        // Write initial traffic data immediately so the widget sees it right away
        let initial = VPNTrafficData(
            txBytes: 0,
            rxBytes: 0,
            txRate: 0,
            rxRate: 0,
            connectedSince: tunnelConnectedSince!,
            activeConfigName: initialActiveConfig,
            lastHandshakeTime: nil,
            trafficSamples: [],
            updatedAt: Date()
        )
        VPNTrafficData.save(initial)

        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in
            self?.pollAndWriteStats()
        }
        timer.resume()
        statsTimer = timer
    }

    private func stopStatsWriter() {
        statsTimer?.cancel()
        statsTimer = nil
        VPNTrafficData.clear()
    }

    private func pollAndWriteStats() {
        adapter.getRuntimeConfiguration { [weak self] configString in
            guard let self = self, let configString = configString else { return }

            let now = Date()
            let (currentTx, currentRx) = ConnectionHealthMonitor.parseTxRxBytes(from: configString)

            // Compute rates. Counters reset to zero when the Go device or its
            // peers are replaced (failover config swap, iOS offline/online,
            // probe promotion) — treat a regression as counting from zero so
            // the unsigned subtraction can't trap.
            var txRate: Double = 0
            var rxRate: Double = 0
            if let prevTime = self.previousStatsTime {
                let elapsed = now.timeIntervalSince(prevTime)
                if elapsed > 0 {
                    let txDelta = currentTx >= self.previousStatsTxBytes ? currentTx - self.previousStatsTxBytes : currentTx
                    let rxDelta = currentRx >= self.previousStatsRxBytes ? currentRx - self.previousStatsRxBytes : currentRx
                    txRate = Double(txDelta) / elapsed
                    rxRate = Double(rxDelta) / elapsed
                }
            }

            self.previousStatsTxBytes = currentTx
            self.previousStatsRxBytes = currentRx
            self.previousStatsTime = now

            // Update the in-progress session record with the latest byte totals.
            self.sessionQueue.sync {
                guard var session = self.currentSession else { return }
                session.rxBytes = currentRx
                session.txBytes = currentTx
                self.currentSession = session
                SessionHistoryStore.saveCurrent(session)
            }

            // Parse last handshake
            let handshakeAge = ConnectionHealthMonitor.parseLastHandshakeAge(from: configString)
            let lastHandshake: Date? = handshakeAge != .infinity ? now.addingTimeInterval(-handshakeAge) : nil

            // Append to rolling traffic samples
            let sample = VPNTrafficData.TrafficSample(timestamp: now, rxRate: rxRate, txRate: txRate)
            self.trafficSamples.append(sample)
            if self.trafficSamples.count > VPNTrafficData.maxSamples {
                self.trafficSamples.removeFirst(self.trafficSamples.count - VPNTrafficData.maxSamples)
            }

            // Determine active config name for failover
            let activeConfig: String?
            if !self.failoverConfigNames.isEmpty {
                activeConfig = self.failoverConfigNames.indices.contains(self.activeConfigIndex) ? self.failoverConfigNames[self.activeConfigIndex] : nil
            } else {
                activeConfig = nil
            }

            let trafficData = VPNTrafficData(
                txBytes: currentTx,
                rxBytes: currentRx,
                txRate: txRate,
                rxRate: rxRate,
                connectedSince: self.tunnelConnectedSince ?? now,
                activeConfigName: activeConfig,
                lastHandshakeTime: lastHandshake,
                trafficSamples: self.trafficSamples,
                updatedAt: now
            )
            VPNTrafficData.save(trafficData)
        }
    }

    // MARK: - Session History helpers

    /// Resolve a user-visible display name for the tunnel run, preferring failover group / TiT
    /// group names when applicable.
    private func resolveDisplayName() -> String {
        let proto = self.protocolConfiguration as? NETunnelProviderProtocol
        if let configNames = proto?.providerConfiguration?[ProviderConfigurationKeys.failoverConfigNames] as? [String], let firstName = configNames.first {
            return firstName
        } else if let config = proto?.asTunnelConfiguration() {
            return config.name ?? "WireGuard"
        }
        return "WireGuard"
    }

    /// Append a failover event to the in-progress session and persist it.
    private func appendFailoverEvent(_ event: FailoverEvent) {
        sessionQueue.sync {
            guard var session = self.currentSession else { return }
            session.failoverEvents.append(event)
            self.currentSession = session
            SessionHistoryStore.saveCurrent(session)
        }
    }

    /// Finalize the in-progress session and append it to the history archive. Called from
    /// `stopTunnel` synchronously (before `adapter.stop` and the macOS `exit(0)`), so the file
    /// is durably written before the extension shuts down. Uses the most recent rx/tx values
    /// from the periodic poll (up to ~30 s stale, by design).
    private func finalizeSessionRecord(reason: NEProviderStopReason) {
        sessionQueue.sync {
            guard var session = self.currentSession else { return }
            session.endedAt = Date()
            session.rxBytes = self.previousStatsRxBytes
            session.txBytes = self.previousStatsTxBytes
            session.deactivationReason = DeactivationReason(from: reason)
            SessionHistoryStore.appendCompleted(session)
            SessionHistoryStore.clearCurrent()
            self.currentSession = nil
        }
    }

    // MARK: - Failover Setup

    private func handleStartAdapterError(
        _ adapterError: WireGuardAdapterError,
        notifier errorNotifier: ErrorNotifier,
        completionHandler: @escaping (Error?) -> Void
    ) {
        switch adapterError {
        case .cannotLocateTunnelFileDescriptor:
            wg_log(.error, staticMessage: "Starting tunnel failed: could not determine file descriptor")
            errorNotifier.notify(PacketTunnelProviderError.couldNotDetermineFileDescriptor)
            completionHandler(PacketTunnelProviderError.couldNotDetermineFileDescriptor)
        case .dnsResolution(let dnsErrors):
            let failed = dnsErrors.map { $0.address }.joined(separator: ", ")
            wg_log(.error, message: "DNS resolution failed for the following hostnames: \(failed)")
            errorNotifier.notify(PacketTunnelProviderError.dnsResolutionFailure)
            completionHandler(PacketTunnelProviderError.dnsResolutionFailure)
        case .setNetworkSettings(let error):
            wg_log(.error, message: "Starting tunnel failed with setTunnelNetworkSettings returning \(error.localizedDescription)")
            errorNotifier.notify(PacketTunnelProviderError.couldNotSetNetworkSettings)
            completionHandler(PacketTunnelProviderError.couldNotSetNetworkSettings)
        case .startWireGuardBackend(let errorCode):
            wg_log(.error, message: "Starting tunnel failed with wgTurnOn returning \(errorCode)")
            errorNotifier.notify(PacketTunnelProviderError.couldNotStartBackend)
            completionHandler(PacketTunnelProviderError.couldNotStartBackend)
        case .invalidState:
            fatalError()
        }
    }

    // MARK: - Tunnel-in-Tunnel Setup

    private func loadTiTConfigs(from providerConfig: [String: Any]?) {
        // Member configs are stored as keychain references. The plaintext keys
        // are read only as a legacy fallback for groups created before the
        // keychain migration (the app migrates them on its next launch).
        let outerConfigString: String?
        let innerConfigString: String?
        if let outerRef = providerConfig?[ProviderConfigurationKeys.titOuterConfigRef] as? Data,
           let innerRef = providerConfig?[ProviderConfigurationKeys.titInnerConfigRef] as? Data {
            outerConfigString = Keychain.openReference(called: outerRef)
            innerConfigString = Keychain.openReference(called: innerRef)
            if outerConfigString == nil || innerConfigString == nil {
                wg_log(.error, staticMessage: "TiT: could not open member configs from keychain")
            }
        } else {
            outerConfigString = providerConfig?[ProviderConfigurationKeys.titOuterConfig] as? String
            innerConfigString = providerConfig?[ProviderConfigurationKeys.titInnerConfig] as? String
        }

        guard let outerConfigString = outerConfigString,
              let innerConfigString = innerConfigString else { return }

        let outerName = providerConfig?[ProviderConfigurationKeys.titOuterName] as? String
        let innerName = providerConfig?[ProviderConfigurationKeys.titInnerName] as? String

        do {
            titOuterConfig = try TunnelConfiguration(fromWgQuickConfig: outerConfigString, called: outerName)
            titInnerConfig = try TunnelConfiguration(fromWgQuickConfig: innerConfigString, called: innerName)
        } catch {
            wg_log(.error, message: "TiT: failed to parse configs: \(error)")
            titOuterConfig = nil
            titInnerConfig = nil
        }
    }

    private func loadFailoverConfigs(from providerConfig: [String: Any]?) {
        // Member configs are stored as keychain references. The plaintext
        // FailoverConfigs key is read only as a legacy fallback for groups
        // created before the keychain migration (the app migrates them on its
        // next launch).
        let configStrings: [String?]
        if let refs = providerConfig?[ProviderConfigurationKeys.failoverConfigRefs] as? [Data] {
            configStrings = refs.map { ref in
                let config = Keychain.openReference(called: ref)
                if config == nil {
                    wg_log(.error, staticMessage: "Failover: could not open a member config from keychain")
                }
                return config
            }
        } else if let legacyConfigs = providerConfig?[ProviderConfigurationKeys.failoverConfigs] as? [String] {
            configStrings = legacyConfigs
        } else {
            return
        }

        let names = providerConfig?[ProviderConfigurationKeys.failoverConfigNames] as? [String] ?? []
        if let settingsData = providerConfig?[ProviderConfigurationKeys.failoverSettings] as? Data,
           let settings = try? JSONDecoder().decode(FailoverSettings.self, from: settingsData) {
            failoverSettings = settings
        }

        let parsed = Self.parseFailoverConfigs(configStrings, names: names, settings: failoverSettings)
        failoverConfigs = parsed.map { $0.config }
        failoverConfigNames = parsed.map { $0.name }

        if let override = failoverSettings.persistentKeepaliveOverride {
            wg_log(.info, message: "Failover: persistent keepalive override = \(override)s applied to all peers")
        }
    }

    /// Parse packed wg-quick configs, applying the group's persistent keepalive override.
    /// Configs and names are returned together so a dropped (unreadable/unparseable) member
    /// can't shift the index-to-name alignment used in failover events.
    private static func parseFailoverConfigs(_ configStrings: [String?], names: [String], settings: FailoverSettings) -> [(name: String, config: TunnelConfiguration)] {
        let keepaliveOverride = settings.persistentKeepaliveOverride
        return configStrings.enumerated().compactMap { index, configString in
            let name = names.indices.contains(index) ? names[index] : nil
            guard let configString = configString else { return nil }
            do {
                let config = try TunnelConfiguration(fromWgQuickConfig: configString, called: name)
                // Apply persistent keepalive override if configured
                if let override = keepaliveOverride {
                    let effectiveValue: UInt16? = override > 0 ? override : nil
                    let modifiedPeers = config.peers.map { peer -> PeerConfiguration in
                        var p = peer
                        p.persistentKeepAlive = effectiveValue
                        return p
                    }
                    return (name ?? "config #\(index)", TunnelConfiguration(name: config.name, interface: config.interface, peers: modifiedPeers))
                }
                return (name ?? "config #\(index)", config)
            } catch {
                wg_log(.error, message: "Failover: failed to parse config #\(index) '\(name ?? "unknown")': \(error)")
                return nil
            }
        }
    }

    // MARK: - Live Configuration Reload (IPC type 6)

    /// Apply an updated group configuration to the running tunnel. For failover groups the
    /// active connection is hot-swapped via `adapter.update` only when it actually changed, and
    /// the health monitor is rebuilt around the new config list. For tunnel-in-tunnel both
    /// devices are restarted in place. Never tears the packet tunnel down.
    private func reloadGroupConfiguration(_ payload: [String: Any], completionHandler: @escaping (Bool) -> Void) {
        switch payload["kind"] as? String {
        case "failover":
            reloadFailoverConfiguration(payload, completionHandler: completionHandler)
        case "tunnelInTunnel":
            reloadTunnelInTunnelConfiguration(payload, completionHandler: completionHandler)
        default:
            completionHandler(false)
        }
    }

    private func reloadFailoverConfiguration(_ payload: [String: Any], completionHandler: @escaping (Bool) -> Void) {
        guard titOuterConfig == nil, !failoverConfigs.isEmpty,
              let configStrings = payload["configs"] as? [String],
              let names = payload["names"] as? [String] else {
            completionHandler(false)
            return
        }

        var settings = FailoverSettings()
        if let encoded = payload["settings"] as? String,
           let data = Data(base64Encoded: encoded),
           let decoded = try? JSONDecoder().decode(FailoverSettings.self, from: data) {
            settings = decoded
        }

        let parsed = Self.parseFailoverConfigs(configStrings, names: names, settings: settings)
        guard !parsed.isEmpty else {
            wg_log(.error, staticMessage: "Failover: reload payload contained no valid configs")
            completionHandler(false)
            return
        }
        let newConfigs = parsed.map { $0.config }
        let newNames = parsed.map { $0.name }

        // Stay on the connection that is currently up if it still exists in the new list.
        let activeName = failoverConfigNames.indices.contains(activeConfigIndex) ? failoverConfigNames[activeConfigIndex] : nil
        let newIndex = activeName.flatMap { newNames.firstIndex(of: $0) } ?? 0
        let activeConfigChanged = newConfigs[newIndex] != failoverConfigs[activeConfigIndex]
        let newSiblings = Self.failoverSiblingEndpoints(configs: newConfigs, activeIndex: newIndex)
        let oldSiblings = Self.failoverSiblingEndpoints(configs: failoverConfigs, activeIndex: activeConfigIndex)
        let siblingsChanged = Set(newSiblings) != Set(oldSiblings)

        healthMonitor?.stop()
        healthMonitor = nil
        adapter.setHealthMonitor(nil)

        let finish: (Bool) -> Void = { success in
            guard success else {
                // Keep the old monitor semantics alive on the previous config list.
                self.startHealthMonitor(settings: self.failoverSettings, initialActiveIndex: self.activeConfigIndex)
                completionHandler(false)
                return
            }
            self.failoverConfigs = newConfigs
            self.failoverConfigNames = newNames
            self.failoverSettings = settings
            self.activeConfigIndex = newIndex
            self.startHealthMonitor(settings: settings, initialActiveIndex: newIndex)
            self.appendFailoverEvent(FailoverEvent(kind: .configReloaded, timestamp: Date(), fromConfigName: nil,
                                                   toConfigName: newNames.indices.contains(newIndex) ? newNames[newIndex] : nil,
                                                   txWithoutRxDuration: nil))
            wg_log(.info, message: "Failover: configuration reloaded in place (\(newConfigs.count) configs, active '\(newNames.indices.contains(newIndex) ? newNames[newIndex] : "#\(newIndex)")', \(activeConfigChanged ? "active config updated" : "active config unchanged"))")
            completionHandler(true)
        }

        if activeConfigChanged || siblingsChanged {
            adapter.update(tunnelConfiguration: newConfigs[newIndex], excludedEndpoints: newSiblings) { (error: WireGuardAdapterError?) in
                if let error = error {
                    wg_log(.error, message: "Failover: live update of the active config failed: \(error)")
                }
                finish(error == nil)
            }
        } else {
            finish(true)
        }
    }

    private func reloadTunnelInTunnelConfiguration(_ payload: [String: Any], completionHandler: @escaping (Bool) -> Void) {
        guard let currentOuter = titOuterConfig, let currentInner = titInnerConfig,
              let outerString = payload["outer"] as? String, !outerString.isEmpty,
              let innerString = payload["inner"] as? String, !innerString.isEmpty else {
            completionHandler(false)
            return
        }
        let outerName = payload["outerName"] as? String
        let innerName = payload["innerName"] as? String

        let newOuter: TunnelConfiguration
        let newInner: TunnelConfiguration
        do {
            newOuter = try TunnelConfiguration(fromWgQuickConfig: outerString, called: outerName)
            newInner = try TunnelConfiguration(fromWgQuickConfig: innerString, called: innerName)
        } catch {
            wg_log(.error, message: "TiT: reload payload failed to parse: \(error)")
            completionHandler(false)
            return
        }

        if newOuter == currentOuter && newInner == currentInner {
            wg_log(.info, staticMessage: "TiT: reload requested but configuration is unchanged")
            completionHandler(true)
            return
        }

        adapter.restartTunnelInTunnel(outerTunnelConfiguration: newOuter, innerTunnelConfiguration: newInner) { error in
            if let error = error {
                wg_log(.error, message: "TiT: in-place restart failed (\(error)); stopping the tunnel")
                self.cancelTunnelWithError(PacketTunnelProviderError.couldNotStartBackend)
                completionHandler(false)
                return
            }
            self.titOuterConfig = newOuter
            self.titInnerConfig = newInner
            self.appendFailoverEvent(FailoverEvent(kind: .configReloaded, timestamp: Date(), fromConfigName: nil, toConfigName: nil, txWithoutRxDuration: nil))
            completionHandler(true)
        }
    }

    /// Endpoints from every failover config except the one at `activeIndex`.
    /// Returned as Endpoint values (potentially with hostname `host`); the adapter
    /// re-resolves them to IPs before installing as `excludedRoutes`.
    private static func failoverSiblingEndpoints(configs: [TunnelConfiguration], activeIndex: Int) -> [Endpoint] {
        guard configs.count > 1 else { return [] }
        var endpoints: [Endpoint] = []
        for (idx, config) in configs.enumerated() where idx != activeIndex {
            for peer in config.peers {
                if let endpoint = peer.endpoint {
                    endpoints.append(endpoint)
                }
            }
        }
        return endpoints
    }

    private func startHealthMonitorIfNeeded(providerConfig: [String: Any]?) {
        guard failoverConfigs.count > 1 else { return }
        startHealthMonitor(settings: failoverSettings, initialActiveIndex: activeConfigIndex)
    }

    private func startHealthMonitor(settings: FailoverSettings, initialActiveIndex: Int) {
        guard failoverConfigs.count > 1 else { return }

        let monitor = ConnectionHealthMonitor(
            adapter: adapter,
            configurations: failoverConfigs,
            settings: settings,
            initialActiveIndex: initialActiveIndex
        ) { (logLevel: FailoverLogLevel, message: String) in
            wg_log(logLevel.osLogLevel, message: message)
        }
        monitor.delegate = self
        healthMonitor = monitor
        adapter.setHealthMonitor(monitor)
        monitor.start()
    }
}

// MARK: - Local Notifications

#if os(iOS)
extension PacketTunnelProvider {
    private func postDisconnectNotificationIfEnabled(tunnelName: String, reason: NEProviderStopReason) {
        guard NotificationSettings.isDisconnectNotificationEnabled else { return }

        let content = UNMutableNotificationContent()
        content.title = "VPN Disconnected"
        content.body = "'\(tunnelName)' has been disconnected."
        content.sound = .default

        let request = UNNotificationRequest(identifier: "vpn-disconnect-\(UUID().uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                wg_log(.error, message: "Failed to post disconnect notification: \(error.localizedDescription)")
            }
        }
    }

    func postFailoverNotificationIfEnabled(from fromName: String, to toName: String) {
        guard NotificationSettings.isFailoverNotificationEnabled else { return }

        let content = UNMutableNotificationContent()
        content.title = "VPN Failover"
        content.body = "Switched from '\(fromName)' to '\(toName)'."
        content.sound = .default

        let request = UNNotificationRequest(identifier: "vpn-failover-\(UUID().uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                wg_log(.error, message: "Failed to post failover notification: \(error.localizedDescription)")
            }
        }
    }

    func postFailbackNotificationIfEnabled(to name: String) {
        guard NotificationSettings.isFailoverNotificationEnabled else { return }

        let content = UNMutableNotificationContent()
        content.title = "VPN Failback"
        content.body = "Returned to primary connection '\(name)'."
        content.sound = .default

        let request = UNNotificationRequest(identifier: "vpn-failback-\(UUID().uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                wg_log(.error, message: "Failed to post failback notification: \(error.localizedDescription)")
            }
        }
    }

    func postCaptivePortalNotificationIfEnabled() {
        guard NotificationSettings.isCaptivePortalNotificationEnabled else { return }

        let content = UNMutableNotificationContent()
        content.title = "Wi-Fi Network Requires Sign-In"
        content.body = "A captive portal is blocking the VPN. Tap to sign in to the network."
        content.sound = .default
        content.categoryIdentifier = NotificationSettings.captivePortalCategoryIdentifier

        // Stable identifier: a repeat detection replaces the pending notification
        // instead of stacking a new one per blocked episode.
        let request = UNNotificationRequest(identifier: "vpn-captive-portal", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                wg_log(.error, message: "Failed to post captive portal notification: \(error.localizedDescription)")
            }
        }
    }
}
#endif

// MARK: - ConnectionHealthMonitorDelegate

extension PacketTunnelProvider: ConnectionHealthMonitorDelegate {
    func healthMonitor(_ monitor: ConnectionHealthMonitor, didSwitchToConfigAt index: Int) {
        // Compared against the provider's own reference, not the adapter's: the adapter's
        // copy is installed asynchronously, so it can still be the pre-reload monitor here.
        guard monitor === healthMonitor else { return } // stale monitor from before a reload
        let previousName = failoverConfigNames.indices.contains(activeConfigIndex) ? failoverConfigNames[activeConfigIndex] : "config #\(activeConfigIndex)"
        activeConfigIndex = index
        let name = failoverConfigNames.indices.contains(index) ? failoverConfigNames[index] : "config #\(index)"
        wg_log(.info, message: "Failover: now active on '\(name)'")
        appendFailoverEvent(FailoverEvent(
            kind: .switched,
            timestamp: Date(),
            fromConfigName: previousName,
            toConfigName: name,
            txWithoutRxDuration: nil
        ))
        #if os(iOS)
        postFailoverNotificationIfEnabled(from: previousName, to: name)
        #endif
    }

    func healthMonitor(_ monitor: ConnectionHealthMonitor, didDetectUnhealthyConnectionAt index: Int, txWithoutRxDuration: TimeInterval) {
        guard monitor === healthMonitor else { return }
        let name = failoverConfigNames.indices.contains(index) ? failoverConfigNames[index] : "config #\(index)"
        wg_log(.info, message: "Failover: '\(name)' unhealthy (tx without rx for \(Int(txWithoutRxDuration))s)")
        appendFailoverEvent(FailoverEvent(
            kind: .unhealthy,
            timestamp: Date(),
            fromConfigName: name,
            toConfigName: nil,
            txWithoutRxDuration: txWithoutRxDuration
        ))
    }

    func healthMonitor(_ monitor: ConnectionHealthMonitor, didSuppressFailoverAt index: Int, txWithoutRxDuration: TimeInterval, reason: String) {
        guard monitor === healthMonitor else { return }
        let name = failoverConfigNames.indices.contains(index) ? failoverConfigNames[index] : "config #\(index)"
        wg_log(.info, message: "Failover: holding on '\(name)' (\(reason))")
        appendFailoverEvent(FailoverEvent(
            kind: .suppressed,
            timestamp: Date(),
            fromConfigName: name,
            toConfigName: nil,
            txWithoutRxDuration: txWithoutRxDuration
        ))
    }

    func healthMonitor(_ monitor: ConnectionHealthMonitor, didDetectBlockedNetwork status: UnderlyingNetworkStatus) {
        let reason = (status == .captive) ? "captive portal" : "offline"
        wg_log(.info, message: "Failover: underlying network blocked (\(reason)) — failover paused")
        #if os(iOS)
        if status == .captive {
            postCaptivePortalNotificationIfEnabled()
        }
        #endif
    }

    func healthMonitorDidClearBlockedNetwork(_ monitor: ConnectionHealthMonitor) {
        wg_log(.info, message: "Failover: underlying network cleared — failover resumed")
    }

    func healthMonitor(_ monitor: ConnectionHealthMonitor, didFailbackToConfigAt index: Int) {
        guard monitor === healthMonitor else { return }
        activeConfigIndex = index
        let name = failoverConfigNames.indices.contains(index) ? failoverConfigNames[index] : "config #\(index)"
        wg_log(.info, message: "Failover: successfully failed back to '\(name)'")
        appendFailoverEvent(FailoverEvent(
            kind: .failedBack,
            timestamp: Date(),
            fromConfigName: nil,
            toConfigName: name,
            txWithoutRxDuration: nil
        ))
        #if os(iOS)
        postFailbackNotificationIfEnabled(to: name)
        #endif
    }
}

extension FailoverLogLevel {
    var osLogLevel: OSLogType {
        switch self {
        case .verbose:
            return .debug
        case .error:
            return .error
        }
    }
}

extension WireGuardLogLevel {
    var osLogLevel: OSLogType {
        switch self {
        case .verbose:
            return .debug
        case .error:
            return .error
        }
    }
}

extension WireGuardAdapter: FailoverAdapterProtocol {
    public func update(tunnelConfiguration: TunnelConfiguration, excludedEndpoints: [Endpoint], completionHandler: @escaping (Error?) -> Void) {
        update(tunnelConfiguration: tunnelConfiguration, excludedEndpoints: excludedEndpoints) { (error: WireGuardAdapterError?) in
            completionHandler(error)
        }
    }
}
