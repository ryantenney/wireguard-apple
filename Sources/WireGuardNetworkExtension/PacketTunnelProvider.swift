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

        // Start the tunnel
        adapter.start(tunnelConfiguration: tunnelConfiguration, excludedEndpoints: excludedEndpoints) { adapterError in
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

        adapter.healthMonitor?.stop()
        adapter.healthMonitor = nil
        stopStatsWriter()

        adapter.stop { error in
            ErrorNotifier.removeLastErrorFile()

            if let error = error {
                wg_log(.error, message: "Failed to stop WireGuard adapter: \(error.localizedDescription)")
            }
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
            if let monitor = adapter.healthMonitor {
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
            guard let monitor = adapter.healthMonitor else {
                completionHandler(nil)
                return
            }
            monitor.forceSwitch { success in
                let result: [String: Any] = ["success": success]
                completionHandler(try? JSONSerialization.data(withJSONObject: result))
            }

        case 3:
            // Debug: force failback to primary
            guard let monitor = adapter.healthMonitor else {
                completionHandler(nil)
                return
            }
            monitor.forceFailback { success in
                let result: [String: Any] = ["success": success]
                completionHandler(try? JSONSerialization.data(withJSONObject: result))
            }
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

        default:
            completionHandler(nil)
        }
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
        if let configNames = proto?.providerConfiguration?["FailoverConfigNames"] as? [String], let firstName = configNames.first {
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
        if let outerRef = providerConfig?["TiTOuterConfigRef"] as? Data,
           let innerRef = providerConfig?["TiTInnerConfigRef"] as? Data {
            outerConfigString = Keychain.openReference(called: outerRef)
            innerConfigString = Keychain.openReference(called: innerRef)
            if outerConfigString == nil || innerConfigString == nil {
                wg_log(.error, staticMessage: "TiT: could not open member configs from keychain")
            }
        } else {
            outerConfigString = providerConfig?["TiTOuterConfig"] as? String
            innerConfigString = providerConfig?["TiTInnerConfig"] as? String
        }

        guard let outerConfigString = outerConfigString,
              let innerConfigString = innerConfigString else { return }

        let outerName = providerConfig?["TiTOuterName"] as? String
        let innerName = providerConfig?["TiTInnerName"] as? String

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
        if let refs = providerConfig?["FailoverConfigRefs"] as? [Data] {
            configStrings = refs.map { ref in
                let config = Keychain.openReference(called: ref)
                if config == nil {
                    wg_log(.error, staticMessage: "Failover: could not open a member config from keychain")
                }
                return config
            }
        } else if let legacyConfigs = providerConfig?["FailoverConfigs"] as? [String] {
            configStrings = legacyConfigs
        } else {
            return
        }

        let names = providerConfig?["FailoverConfigNames"] as? [String] ?? []

        // Decode settings to check for persistent keepalive override
        var keepaliveOverride: UInt16?
        if let settingsData = providerConfig?["FailoverSettings"] as? Data,
           let settings = try? JSONDecoder().decode(FailoverSettings.self, from: settingsData) {
            keepaliveOverride = settings.persistentKeepaliveOverride
        }

        // Parse configs and names together so a dropped (unreadable/unparseable)
        // member can't shift the index-to-name alignment used in failover events.
        let parsed: [(name: String, config: TunnelConfiguration)] = configStrings.enumerated().compactMap { index, configString in
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
        failoverConfigs = parsed.map { $0.config }
        failoverConfigNames = parsed.map { $0.name }

        if let override = keepaliveOverride {
            wg_log(.info, message: "Failover: persistent keepalive override = \(override)s applied to all peers")
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

        var settings = FailoverSettings()
        if let settingsData = providerConfig?["FailoverSettings"] as? Data {
            if let decoded = try? JSONDecoder().decode(FailoverSettings.self, from: settingsData) {
                settings = decoded
            }
        }

        let monitor = ConnectionHealthMonitor(
            adapter: adapter,
            configurations: failoverConfigs,
            settings: settings
        ) { (logLevel: FailoverLogLevel, message: String) in
            wg_log(logLevel.osLogLevel, message: message)
        }
        monitor.delegate = self
        adapter.healthMonitor = monitor
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
