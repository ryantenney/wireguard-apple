// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import Foundation

/// Protocol abstracting the adapter operations needed by the health monitor.
/// `WireGuardAdapter` conforms to this protocol.
public protocol FailoverAdapterProtocol: AnyObject {
    func getRuntimeConfiguration(completionHandler: @escaping (String?) -> Void)
    func update(tunnelConfiguration: TunnelConfiguration, excludedEndpoints: [Endpoint], completionHandler: @escaping (Error?) -> Void)

    /// Start a background probe for the given tunnel configuration.
    /// The probe establishes a WireGuard session (handshake) without routing traffic.
    /// Returns the probe handle (>= 0) on success, or an error.
    func startProbe(tunnelConfiguration: TunnelConfiguration, completionHandler: @escaping (Int32?, Error?) -> Void)

    /// Stop a running background probe.
    func stopProbe(handle: Int32)

    /// Get UAPI runtime configuration from a probe (handshake time, tx/rx stats).
    func getProbeRuntimeConfiguration(handle: Int32, completionHandler: @escaping (String?) -> Void)

    /// Rebind probe sockets after a network change.
    func bumpProbeSockets(handle: Int32)

    /// Promote a probe to become the active tunnel, preserving its WireGuard session.
    /// Swaps the probe's null tun for the real utun fd — no re-handshake.
    func promoteProbe(probeHandle: Int32, tunnelConfiguration: TunnelConfiguration,
                      excludedEndpoints: [Endpoint],
                      completionHandler: @escaping (Error?) -> Void)

    /// Rebind the active tunnel's UDP sockets and retry handshakes. Used to kick the
    /// tunnel immediately after the underlying network recovers (e.g. captive portal
    /// sign-in) without waiting for a timer or a network path change.
    func bumpTunnelSockets()
}

/// Delegate protocol for receiving failover events from the health monitor.
public protocol ConnectionHealthMonitorDelegate: AnyObject {
    /// Called when the monitor switches to a different configuration.
    func healthMonitor(_ monitor: ConnectionHealthMonitor, didSwitchToConfigAt index: Int)

    /// Called when the monitor detects the active connection is unhealthy.
    func healthMonitor(_ monitor: ConnectionHealthMonitor, didDetectUnhealthyConnectionAt index: Int, txWithoutRxDuration: TimeInterval)

    /// Called when a failback probe succeeds and the monitor returns to a higher-priority config.
    func healthMonitor(_ monitor: ConnectionHealthMonitor, didFailbackToConfigAt index: Int)

    /// Called once per outage when failover was warranted by traffic but held back because no
    /// other server could be reached either (the local link is the likely culprit).
    func healthMonitor(_ monitor: ConnectionHealthMonitor, didSuppressFailoverAt index: Int, txWithoutRxDuration: TimeInterval, reason: String)

    /// Called when the monitor detects that the underlying network itself is blocked
    /// (captive portal or offline) and pauses failover instead of cycling configs.
    func healthMonitor(_ monitor: ConnectionHealthMonitor, didDetectBlockedNetwork status: UnderlyingNetworkStatus)

    /// Called when a previously blocked underlying network clears and normal monitoring resumes.
    func healthMonitorDidClearBlockedNetwork(_ monitor: ConnectionHealthMonitor)
}

public extension ConnectionHealthMonitorDelegate {
    func healthMonitor(_ monitor: ConnectionHealthMonitor, didDetectBlockedNetwork status: UnderlyingNetworkStatus) {}
    func healthMonitorDidClearBlockedNetwork(_ monitor: ConnectionHealthMonitor) {}
}

/// Log level for failover messages.
public enum FailoverLogLevel: Int32 {
    case verbose = 0
    case error = 1
}

/// Monitors WireGuard tunnel health by tracking traffic counters (tx_bytes / rx_bytes)
/// across multiple tunnel configurations and triggers failover when the active connection
/// is sending data without receiving any — indicating the tunnel endpoint is unreachable.
/// Runs entirely in the Network Extension process.
public class ConnectionHealthMonitor {

    /// The adapter used to query runtime config and switch configurations.
    private weak var adapter: FailoverAdapterProtocol?

    /// Ordered list of tunnel configurations (index 0 = primary).
    private let configurations: [TunnelConfiguration]

    /// Failover behavior settings.
    private let settings: FailoverSettings

    /// Delegate for failover event notifications.
    public weak var delegate: ConnectionHealthMonitorDelegate?

    /// Log handler closure.
    private let logHandler: (FailoverLogLevel, String) -> Void

    /// Index of the currently active configuration.
    public private(set) var activeIndex: Int = 0

    /// Serial queue for all failover state and timer operations.
    private let workQueue = DispatchQueue(label: "WireGuardFailoverMonitor")

    /// Timer for periodic health checks.
    private var healthCheckTimer: DispatchSourceTimer?

    /// Timer for periodic failback probing.
    private var failbackTimer: DispatchSourceTimer?

    /// When the last config switch occurred (anti-flap). Monotonic
    /// (mach_absolute_time-based), so wall-clock steps (NTP, user changes)
    /// can't fake or freeze the hold-time/cooldown intervals; it pauses during
    /// system sleep, so sleep never counts toward them either. nil = never.
    private var lastSwitchTime: DispatchTime?

    /// Minimum time to stay on a config before switching again.
    private let minimumHoldTime: TimeInterval = 60

    /// Consecutive config *switches* without an intervening healthy period.
    /// (Note: switches, not full rotations through the config list — with
    /// more than 2 configs the cooldown engages before a full cycle.)
    private var consecutiveCycles: Int = 0

    /// After this many consecutive switches, enter cooldown.
    private let maxCyclesBeforeCooldown: Int = 3

    /// Cooldown duration after too many cycles.
    private let cooldownDuration: TimeInterval = 300

    /// Whether the monitor is currently running.
    public private(set) var isRunning: Bool = false

    /// Whether a failback probe is in progress (prevents concurrent probes).
    private var isProbing: Bool = false

    /// Set while a config swap or probe promotion is in flight, so a health tick that lands
    /// during a slow `adapter.update`/`promoteProbe` (DNS can block for seconds) does not
    /// start a second switch or a second confirmation probe.
    private var isSwitching: Bool = false

    // MARK: - Traffic Tracking State

    /// Total tx_bytes from the last health check poll.
    private var lastTxBytes: UInt64 = 0

    /// Total rx_bytes from the last health check poll.
    private var lastRxBytes: UInt64 = 0

    /// When we first noticed tx increasing without rx. `nil` when healthy or
    /// idle. Monotonic (see lastSwitchTime): a sleep period can't inflate the
    /// tx-without-rx duration into a spurious failover on wake.
    private var txWithoutRxSince: DispatchTime?

    /// Whether the current unhealthy episode has been reported to the delegate.
    private var unhealthyReported: Bool = false

    // MARK: - Confirmation & Adaptive Sensitivity State

    /// Whether the underlying network path is currently usable (from the adapter's path monitor).
    private var pathSatisfied = true

    /// When the network path last changed; tx-without-rx is ignored for `pathChangeGrace` after it.
    private var lastPathChange: Date = .distantPast

    /// Outages that turned out to be the link rather than the server, and quick failbacks.
    private var falseAlarmCount = 0

    /// When `falseAlarmCount` last changed; drives the decay.
    private var lastIncidentTime: Date = .distantPast

    /// Set while failover is warranted by traffic but held back because no server is reachable.
    private var suppressedSince: Date?

    /// Temporary probe used to confirm the next config is reachable when no hot spare is running.
    private var confirmationProbeHandle: Int32?
    private var confirmationProbeIndex: Int?
    private var confirmationProbeStartedAt: Date?

    /// Hot spare handshakes at least every ~2 min while its server answers; older than this
    /// means the spare cannot reach its server either.
    private let hotSpareFreshness: TimeInterval = 150

    /// Quiet time after which one false alarm is forgiven.
    private let adaptiveDecayInterval: TimeInterval = 1800

    /// Largest adaptive multiplier applied to `trafficTimeout`.
    private let maxAdaptiveMultiplier: Double = 4

    /// Traffic timeout after adaptive scaling.
    private var effectiveTrafficTimeout: TimeInterval {
        guard settings.adaptiveSensitivity, falseAlarmCount > 0 else { return settings.trafficTimeout }
        let multiplier = min(pow(1.5, Double(falseAlarmCount)), maxAdaptiveMultiplier)
        return settings.trafficTimeout * multiplier
    }

    // MARK: - Background Probe State

    /// Handle for an active failback probe (non-nil while a background probe is running).
    private var failbackProbeHandle: Int32?

    /// Handle for an active hot spare probe (non-nil while a hot spare is running).
    private var hotSpareHandle: Int32?

    /// Config index being probed by the hot spare.
    private var hotSpareConfigIndex: Int?

    // MARK: - Blocked Network State

    /// Detector for captive-portal / offline underlying networks.
    /// See DESIGN-captive-portal-handling.md.
    private lazy var captivePortalDetector = CaptivePortalDetector()

    /// When the underlying network was detected as blocked (captive or offline).
    /// Non-nil means the monitor is holding: no config switching, no probes, no
    /// flap-cycle counting — every failover target is equally unreachable.
    private var networkBlockedSince: Date?

    /// Most recent blocked-network verdict (meaningful while `networkBlockedSince != nil`).
    private var networkBlockedStatus: UnderlyingNetworkStatus = .clear

    /// Timer polling the detector while the network is blocked.
    private var networkRecheckTimer: DispatchSourceTimer?

    /// Whether a detector check is in flight (prevents overlapping checks).
    private var isCheckingNetwork = false

    /// How often to re-probe the underlying network while blocked.
    private let networkRecheckInterval: TimeInterval = 15

    // MARK: - Initialization

    /// - Parameter initialActiveIndex: the configuration the adapter is already running. Used
    ///   when the monitor is rebuilt after a live configuration reload so it continues from the
    ///   connection that is actually up instead of assuming the primary.
    public init(
        adapter: FailoverAdapterProtocol,
        configurations: [TunnelConfiguration],
        settings: FailoverSettings,
        initialActiveIndex: Int = 0,
        logHandler: @escaping (FailoverLogLevel, String) -> Void
    ) {
        self.adapter = adapter
        self.configurations = configurations
        self.settings = settings
        self.activeIndex = configurations.indices.contains(initialActiveIndex) ? initialActiveIndex : 0
        self.logHandler = logHandler
    }

    deinit {
        // Must not call stop() here: it async-captures self on workQueue, which
        // would retain an object whose refcount already reached zero and run the
        // block against freed memory. Cancel the timers directly (DispatchSource
        // is thread-safe); probe devices are cleaned up by the adapter when the
        // tunnel stops (stopAllProbes), and the owner is expected to call stop()
        // before releasing the monitor.
        healthCheckTimer?.cancel()
        failbackTimer?.cancel()
    }

    // MARK: - Start / Stop

    public func start() {
        workQueue.async {
            guard !self.isRunning else { return }
            guard self.configurations.count > 1 else {
                self.logHandler(.verbose, "Failover: only one config, health monitor not needed")
                return
            }

            self.isRunning = true
            self.logHandler(.verbose, "Failover: health monitor started with \(self.configurations.count) configs, check interval \(self.settings.healthCheckInterval)s, traffic timeout \(self.settings.trafficTimeout)s")

            self.startHealthCheckTimer()
            if self.settings.autoFailback {
                self.startFailbackTimer()
            }
            self.startHotSpareIfNeeded()
        }
    }

    public func stop() {
        workQueue.async {
            self.isRunning = false
            self.healthCheckTimer?.cancel()
            self.healthCheckTimer = nil
            self.failbackTimer?.cancel()
            self.failbackTimer = nil
            self.networkRecheckTimer?.cancel()
            self.networkRecheckTimer = nil
            self.networkBlockedSince = nil
            self.stopFailbackProbe()
            self.stopHotSpare()
            self.stopConfirmationProbe()
            self.logHandler(.verbose, "Failover: health monitor stopped")
        }
    }

    /// Called by the adapter when the network path changes. Records path state so outages
    /// with no usable path are never blamed on the server, and gives roaming a grace period.
    /// If we're on a fallback and the network just came back online, probe the primary.
    public func networkPathDidChange(isSatisfied: Bool) {
        workQueue.async {
            self.pathSatisfied = isSatisfied
            self.lastPathChange = Date()
            if !isSatisfied {
                self.logHandler(.verbose, "Failover: network path unsatisfied, pausing health evaluation")
                self.txWithoutRxSince = nil
                // The adapter tears probes down while offline (iOS), and a probe cannot
                // handshake without a path anyway. Forget every handle now so a dead one
                // is never mistaken for a witness that "never handshaked".
                self.clearIncident(recovered: false)
                self.stopFailbackProbe()
                self.isProbing = false
                self.stopHotSpare()
                return
            }

            guard self.isRunning else { return }

            if self.networkBlockedSince != nil {
                // The user may have switched to a different network; find out right away
                // instead of waiting for the next recheck tick.
                self.logHandler(.verbose, "Failover: network change while blocked, re-probing underlying network")
                self.recheckBlockedNetwork()
                return
            }

            // Restart the hot spare if it was force-stopped (iOS offline kills
            // all probe devices via stopAllProbes). The adapter rejects probe
            // starts while it isn't running, so this is safe to attempt on
            // every path change.
            self.startHotSpareIfNeeded()

            guard self.activeIndex != 0, self.settings.autoFailback else { return }
            self.logHandler(.verbose, "Failover: network change detected while on fallback, scheduling immediate probe")
            self.workQueue.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.probeFailback()
            }
        }
    }

    /// Called by the adapter after it force-stops all probe devices (e.g. when
    /// iOS goes offline). The Go side recycles handle IDs, so holding on to the
    /// stale handles could later alias a different probe — clear them so the
    /// failback/hot-spare machinery can start fresh probes when back online.
    public func probesWereStopped() {
        workQueue.async {
            self.failbackProbeHandle = nil
            self.hotSpareHandle = nil
            self.hotSpareConfigIndex = nil
            self.isProbing = false
        }
    }

    // MARK: - Health Check Timer

    private func startHealthCheckTimer() {
        let timer = DispatchSource.makeTimerSource(queue: workQueue)
        timer.schedule(
            deadline: .now() + settings.healthCheckInterval,
            repeating: settings.healthCheckInterval
        )
        timer.setEventHandler { [weak self] in
            self?.checkHealth()
        }
        timer.resume()
        healthCheckTimer = timer
    }

    private func checkHealth() {
        guard isRunning, !isProbing, networkBlockedSince == nil, let adapter = adapter else { return }

        if falseAlarmCount > 0, Date().timeIntervalSince(lastIncidentTime) > adaptiveDecayInterval {
            falseAlarmCount -= 1
            lastIncidentTime = Date()
            logHandler(.verbose, "Failover: quiet for \(Int(adaptiveDecayInterval))s, sensitivity relaxed to \(Int(effectiveTrafficTimeout))s")
        }

        adapter.getRuntimeConfiguration { [weak self] (configString: String?) in
            guard let self = self, let configString = configString else { return }
            self.workQueue.async {
                self.evaluateHealth(runtimeConfig: configString)
            }
        }
    }

    private func evaluateHealth(runtimeConfig: String) {
        // During a legacy failback probe the active device has been temporarily
        // swapped to the primary; evaluating health in that window would race
        // the probe's own config switches and operate on the wrong baseline.
        // (Re-checked here because isProbing can change between checkHealth's
        // async config fetch and this evaluation.)
        if isProbing {
            return
        }

        // A poll callback may have been queued before the blocked state was entered;
        // evaluation (and any switching it leads to) is suspended while blocked.
        guard networkBlockedSince == nil else { return }

        let (currentTx, currentRx) = Self.parseTxRxBytes(from: runtimeConfig)

        // Counters reset to zero whenever the Go device or its peers are
        // replaced outside our control (adapter.update() uses replace_peers=true,
        // iOS recreates the device after an offline period, probe promotion
        // swaps the device). A regression makes the old baseline meaningless —
        // and unsigned subtraction would trap — so re-baseline and skip this poll.
        let isFirstPoll = (lastTxBytes == 0 && lastRxBytes == 0)
        let countersReset = currentTx < lastTxBytes || currentRx < lastRxBytes

        let txDelta = countersReset ? 0 : currentTx - lastTxBytes
        let rxDelta = countersReset ? 0 : currentRx - lastRxBytes

        // Update stored values for next check
        lastTxBytes = currentTx
        lastRxBytes = currentRx

        // Skip evaluation on the first poll or after a counter reset — we need
        // a fresh baseline, and any tx-without-rx observation predates the reset.
        if isFirstPoll || countersReset {
            txWithoutRxSince = nil
            unhealthyReported = false
            return
        }

        if rxDelta > 0 {
            // Receiving data — connection is healthy
            if txWithoutRxSince != nil {
                logHandler(.verbose, "Failover: rx resumed on config #\(activeIndex), connection healthy")
                txWithoutRxSince = nil
                unhealthyReported = false
            }
            if consecutiveCycles > 0 {
                logHandler(.verbose, "Failover: connection stable on config #\(activeIndex), resetting cycle counter")
                consecutiveCycles = 0
            }
            clearIncident(recovered: true)
            return
        }

        if txDelta == 0 {
            // No outgoing traffic — tunnel is idle, not unhealthy
            txWithoutRxSince = nil
            unhealthyReported = false
            clearIncident(recovered: false)
            return
        }

        // No usable path, or one that just changed: not the server's fault yet.
        if !pathSatisfied {
            txWithoutRxSince = nil
            return
        }
        let sincePathChange = Date().timeIntervalSince(lastPathChange)
        if sincePathChange < settings.pathChangeGrace {
            logHandler(.verbose, "Failover: tx without rx \(Int(sincePathChange))s after a path change, within grace")
            txWithoutRxSince = nil
            return
        }

        // tx is increasing but rx is not — potential problem
        if txWithoutRxSince == nil {
            txWithoutRxSince = DispatchTime.now()
            logHandler(.verbose, "Failover: tx without rx detected on config #\(activeIndex) (tx +\(txDelta) bytes)")
            return
        }

        // `txWithoutRxSince` is monotonic (DispatchTime), so the adaptive timeout is
        // compared against an elapsed time that sleep and wall-clock steps can't inflate.
        let duration = Self.secondsSince(txWithoutRxSince!)
        let timeout = effectiveTrafficTimeout
        guard duration > timeout else {
            logHandler(.verbose, "Failover: tx without rx for \(Int(duration))s/\(Int(timeout))s on config #\(activeIndex)")
            return
        }

        if isSwitching {
            logHandler(.verbose, "Failover: unhealthy but a switch is already in progress, waiting")
            return
        }

        // Connection is unhealthy — sending data but receiving nothing.
        // Report once per unhealthy episode: the poll lands here every cycle
        // while hold time/cooldown block the switch, and per-poll delegate
        // events would flood the session history.
        if !unhealthyReported {
            unhealthyReported = true
            delegate?.healthMonitor(self, didDetectUnhealthyConnectionAt: activeIndex, txWithoutRxDuration: duration)
        }

        // Anti-flap: check minimum hold time
        let timeSinceLastSwitch = lastSwitchTime.map(Self.secondsSince) ?? .infinity
        guard timeSinceLastSwitch > minimumHoldTime else {
            logHandler(.verbose, "Failover: unhealthy but within hold time (\(Int(timeSinceLastSwitch))s/\(Int(minimumHoldTime))s), waiting")
            return
        }

        // Anti-flap: check cooldown after too many cycles
        if consecutiveCycles >= maxCyclesBeforeCooldown {
            guard timeSinceLastSwitch > cooldownDuration else {
                logHandler(.verbose, "Failover: in cooldown after \(consecutiveCycles) cycles, \(Int(cooldownDuration - timeSinceLastSwitch))s remaining")
                return
            }
            consecutiveCycles = 0
        }

        // First gate: if the underlying network itself is captive or offline, every
        // failover target is equally unreachable — hold instead of cycling.
        if settings.captivePortalDetection {
            verifyUnderlyingNetworkThenFailover(txWithoutRxDuration: duration)
            return
        }

        beginFailover(duration: duration)
    }

    /// Second gate: require the next config's server to be reachable before switching,
    /// so an outage caused by the local link doesn't cycle through every config.
    private func beginFailover(duration: TimeInterval) {
        if settings.confirmBeforeFailover {
            confirmThenFailover(duration: duration)
        } else {
            failoverNow(duration: duration)
        }
    }

    /// Switch immediately: promote the hot spare if there is one, else swap configs.
    private func failoverNow(duration: TimeInterval) {
        clearIncident(recovered: false)

        // Try hot spare for pre-validated instant failover
        if tryHotSpareFailover() {
            return
        }

        // Switch to next config
        let nextIndex = (activeIndex + 1) % configurations.count
        let nextName = configurations[nextIndex].name ?? "config #\(nextIndex)"
        logHandler(.error, "Failover: tx without rx for \(Int(duration))s (>\(Int(effectiveTrafficTimeout))s), switching to '\(nextName)'")

        switchToConfig(at: nextIndex)
    }

    /// Seconds elapsed since a monotonic timestamp.
    private static func secondsSince(_ time: DispatchTime) -> TimeInterval {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now > time.uptimeNanoseconds else { return 0 }
        return TimeInterval(now - time.uptimeNanoseconds) / 1_000_000_000
    }

    // MARK: - Blocked Network (captive portal / offline)

    /// Probe the underlying network; fail over only if it's clear, otherwise enter the
    /// holding state. Runs the actual switch asynchronously after the probe returns.
    private func verifyUnderlyingNetworkThenFailover(txWithoutRxDuration: TimeInterval) {
        guard !isCheckingNetwork else { return }
        isCheckingNetwork = true
        logHandler(.verbose, "Failover: verifying underlying network before switching configs")
        captivePortalDetector.check { [weak self] status in
            guard let self = self else { return }
            self.workQueue.async {
                self.isCheckingNetwork = false
                guard self.isRunning, self.networkBlockedSince == nil else { return }
                switch status {
                case .clear:
                    self.beginFailover(duration: txWithoutRxDuration)
                case .captive, .offline:
                    self.enterNetworkBlocked(status: status)
                }
            }
        }
    }

    /// Enter the holding state: no failover target can succeed, so stop probes, stop
    /// counting flap cycles, and poll the detector until the network clears.
    private func enterNetworkBlocked(status: UnderlyingNetworkStatus) {
        // Never double-enter: overwriting networkRecheckTimer would leak an active timer.
        guard networkBlockedSince == nil else {
            networkBlockedStatus = status
            return
        }

        networkBlockedSince = Date()
        networkBlockedStatus = status
        txWithoutRxSince = nil
        stopFailbackProbe()
        stopHotSpare()
        isProbing = false
        // The outage is the network's, not a server's: drop the confirmation probe and
        // the suppression bookkeeping rather than leaving them running while we hold.
        clearIncident(recovered: false)

        let reason = (status == .captive) ? "captive portal detected" : "network offline"
        logHandler(.error, "Failover: \(reason) on the underlying network — pausing failover until it clears")
        delegate?.healthMonitor(self, didDetectBlockedNetwork: status)

        let timer = DispatchSource.makeTimerSource(queue: workQueue)
        timer.schedule(deadline: .now() + networkRecheckInterval, repeating: networkRecheckInterval)
        timer.setEventHandler { [weak self] in
            self?.recheckBlockedNetwork()
        }
        timer.resume()
        networkRecheckTimer = timer
    }

    private func recheckBlockedNetwork() {
        guard isRunning, networkBlockedSince != nil, !isCheckingNetwork else { return }
        isCheckingNetwork = true
        captivePortalDetector.check { [weak self] status in
            guard let self = self else { return }
            self.workQueue.async {
                self.isCheckingNetwork = false
                guard self.isRunning, let blockedSince = self.networkBlockedSince else { return }
                if status == .clear {
                    self.exitNetworkBlocked()
                } else {
                    // An offline network turning captive is a fresh, user-actionable event
                    // (e.g. the user just joined portal Wi-Fi) — re-notify the delegate.
                    let becameCaptive = (self.networkBlockedStatus == .offline && status == .captive)
                    self.networkBlockedStatus = status
                    let elapsed = Int(Date().timeIntervalSince(blockedSince))
                    self.logHandler(.verbose, "Failover: underlying network still blocked (\(status == .captive ? "captive" : "offline"), \(elapsed)s)")
                    if becameCaptive {
                        self.delegate?.healthMonitor(self, didDetectBlockedNetwork: status)
                    }
                }
            }
        }
    }

    /// Leave the holding state: kick the active config's sockets so a handshake is
    /// attempted immediately, reset traffic baselines, and resume normal monitoring.
    /// Deliberately stays on the config that was active when the network got blocked —
    /// time spent blocked says nothing about which server is best.
    private func exitNetworkBlocked() {
        networkBlockedSince = nil
        networkBlockedStatus = .clear
        networkRecheckTimer?.cancel()
        networkRecheckTimer = nil
        lastTxBytes = 0
        lastRxBytes = 0
        txWithoutRxSince = nil

        logHandler(.error, "Failover: underlying network cleared — resuming monitoring on config #\(activeIndex)")
        adapter?.bumpTunnelSockets()
        delegate?.healthMonitorDidClearBlockedNetwork(self)
        startHotSpareIfNeeded()
    }

    // MARK: - Failover Confirmation

    /// Decide whether the outage is the server's or the link's before switching. The next
    /// config's server must have handshaked recently — through the hot spare when one runs,
    /// otherwise through a temporary probe started here. No handshake from any server means
    /// the local link is down: hold, count a false alarm, and re-check every tick.
    private func confirmThenFailover(duration: TimeInterval) {
        guard let adapter = adapter else { return }
        let nextIndex = (activeIndex + 1) % configurations.count
        let nextName = configurations[nextIndex].name ?? "config #\(nextIndex)"

        if let since = suppressedSince, settings.linkDownHoldTime > 0, Date().timeIntervalSince(since) > settings.linkDownHoldTime {
            logHandler(.error, "Failover: held for \(Int(Date().timeIntervalSince(since)))s with no reachable server; switching to '\(nextName)' anyway")
            // The hot spare has no session to preserve (that is why we held), and its
            // endpoint resolution is as stale as the hold. Do a full swap instead of promoting it.
            stopHotSpare()
            clearIncident(recovered: false)
            switchToConfig(at: nextIndex)
            return
        }

        // A running hot spare for the next config is the cheapest witness.
        if let handle = hotSpareHandle, hotSpareConfigIndex == nextIndex {
            adapter.getProbeRuntimeConfiguration(handle: handle) { [weak self] (configString: String?) in
                guard let self = self else { return }
                self.workQueue.async {
                    guard let configString = configString else {
                        // The adapter no longer knows this handle (torn down offline). Forget it
                        // and confirm through a fresh probe instead.
                        self.logHandler(.verbose, "Failover: hot spare handle \(handle) is gone; confirming with a temporary probe")
                        self.hotSpareHandle = nil
                        self.hotSpareConfigIndex = nil
                        self.confirmThenFailover(duration: duration)
                        return
                    }
                    let age = Self.parseLastHandshakeAge(from: configString)
                    if age < self.hotSpareFreshness {
                        self.logHandler(.verbose, "Failover: hot spare '\(nextName)' handshaked \(Int(age))s ago; server-side outage confirmed")
                        self.failoverNow(duration: duration)
                    } else {
                        let ageText = age == .infinity ? "never handshaked" : "last handshaked \(Int(age))s ago"
                        self.noteSuppressed(duration: duration, reason: "hot spare '\(nextName)' \(ageText)")
                    }
                }
            }
            return
        }

        // Otherwise use (or start) a temporary confirmation probe.
        if let handle = confirmationProbeHandle, confirmationProbeIndex == nextIndex, let startedAt = confirmationProbeStartedAt {
            adapter.getProbeRuntimeConfiguration(handle: handle) { [weak self] (configString: String?) in
                guard let self = self else { return }
                self.workQueue.async {
                    let age = configString.map(Self.parseLastHandshakeAge) ?? .infinity
                    let probeAge = Date().timeIntervalSince(startedAt)
                    // The probe device was created for this outage, so any handshake it reports
                    // happened after it started. Comparing `age` against `probeAge` would fail
                    // for a handshake that completed within the first second (UAPI reports
                    // whole seconds and `startedAt` is stamped after the device came up).
                    if age < .infinity {
                        self.logHandler(.verbose, "Failover: confirmation probe reached '\(nextName)' (handshake \(Int(age))s ago); promoting it")
                        self.confirmationProbeHandle = nil
                        self.confirmationProbeIndex = nil
                        self.confirmationProbeStartedAt = nil
                        self.clearIncident(recovered: false)
                        self.promoteProbeAsActive(handle: handle, index: nextIndex, label: "confirmation probe")
                    } else if probeAge > self.settings.confirmationTimeout {
                        self.noteSuppressed(duration: duration, reason: "probe to '\(nextName)' has not handshaked in \(Int(probeAge))s")
                    } else {
                        self.logHandler(.verbose, "Failover: waiting for confirmation probe to '\(nextName)' (\(Int(probeAge))s/\(Int(self.settings.confirmationTimeout))s)")
                    }
                }
            }
            return
        }

        stopConfirmationProbe()
        logHandler(.verbose, "Failover: tx without rx for \(Int(duration))s; confirming '\(nextName)' is reachable before switching")
        adapter.startProbe(tunnelConfiguration: configurations[nextIndex]) { [weak self] (handle: Int32?, error: Error?) in
            guard let self = self else { return }
            self.workQueue.async {
                guard let handle = handle else {
                    self.logHandler(.error, "Failover: confirmation probe failed to start (\(String(describing: error))); switching without confirmation")
                    self.failoverNow(duration: duration)
                    return
                }
                self.confirmationProbeHandle = handle
                self.confirmationProbeIndex = nextIndex
                self.confirmationProbeStartedAt = Date()
            }
        }
    }

    /// Record that failover is being held back for this outage (once), and raise sensitivity.
    private func noteSuppressed(duration: TimeInterval, reason: String) {
        if suppressedSince == nil {
            suppressedSince = Date()
            let hold = settings.linkDownHoldTime > 0 ? "forcing failover after \(Int(settings.linkDownHoldTime))s" : "holding indefinitely"
            logHandler(.error, "Failover: holding on config #\(activeIndex): \(reason). The local link is the likely cause; \(hold)")
            delegate?.healthMonitor(self, didSuppressFailoverAt: activeIndex, txWithoutRxDuration: duration, reason: reason)
        } else {
            logHandler(.verbose, "Failover: still holding (\(reason))")
        }
    }

    /// End the current outage bookkeeping. `recovered` means traffic came back on its own,
    /// which is the moment a held outage is known to have been the link: charge it then, not
    /// when the hold starts, so a hold that ends in a forced (and successful) failover is not
    /// counted against sensitivity.
    private func clearIncident(recovered: Bool) {
        if let since = suppressedSince, recovered {
            registerFalseAlarm()
            logHandler(.verbose, "Failover: link recovered after \(Int(Date().timeIntervalSince(since)))s without failing over; counted as a false alarm, traffic timeout now \(Int(effectiveTrafficTimeout))s")
        }
        suppressedSince = nil
        stopConfirmationProbe()
    }

    private func registerFalseAlarm() {
        falseAlarmCount = min(falseAlarmCount + 1, 4)
        lastIncidentTime = Date()
    }

    /// A failback shortly after a failover means the switch was probably unnecessary.
    private func noteFailbackTiming() {
        if (lastSwitchTime.map(Self.secondsSince) ?? .infinity) < 2 * minimumHoldTime {
            registerFalseAlarm()
            logHandler(.verbose, "Failover: quick failback counted as a false alarm; traffic timeout now \(Int(effectiveTrafficTimeout))s")
        }
    }

    private func stopConfirmationProbe() {
        if let handle = confirmationProbeHandle {
            adapter?.stopProbe(handle: handle)
        }
        confirmationProbeHandle = nil
        confirmationProbeIndex = nil
        confirmationProbeStartedAt = nil
    }

    // MARK: - Config Switching

    /// Endpoints belonging to every config in the failover group *except* the one
    /// at `activeIdx`. Threaded through `adapter.update`/`promoteProbe` so the
    /// network-extension layer can install matching `excludedRoutes` and keep
    /// probe traffic off the active utun. See `docs/probe-routing-bypass.md`.
    private func siblingEndpoints(forActiveIndex activeIdx: Int) -> [Endpoint] {
        var endpoints: [Endpoint] = []
        for (idx, config) in configurations.enumerated() where idx != activeIdx {
            for peer in config.peers {
                if let endpoint = peer.endpoint {
                    endpoints.append(endpoint)
                }
            }
        }
        return endpoints
    }

    private func switchToConfig(at index: Int) {
        guard let adapter = adapter else { return }

        let config = configurations[index]
        let siblings = siblingEndpoints(forActiveIndex: index)
        isSwitching = true
        adapter.update(tunnelConfiguration: config, excludedEndpoints: siblings) { [weak self] (error: Error?) in
            guard let self = self else { return }
            self.workQueue.async {
                self.isSwitching = false
                if let error = error {
                    let name = config.name ?? "config #\(index)"
                    self.logHandler(.error, "Failover: failed to switch to '\(name)': \(error.localizedDescription)")
                    // Try the next config in line (skip the one that failed)
                    let nextNext = (index + 1) % self.configurations.count
                    if nextNext != self.activeIndex {
                        self.logHandler(.verbose, "Failover: trying next config #\(nextNext)")
                        self.switchToConfig(at: nextNext)
                    }
                } else {
                    let previousIndex = self.activeIndex
                    self.activeIndex = index
                    self.lastSwitchTime = DispatchTime.now()
                    self.consecutiveCycles += 1

                    // Reset traffic tracking for the new config
                    self.lastTxBytes = 0
                    self.lastRxBytes = 0
                    self.txWithoutRxSince = nil
                    self.unhealthyReported = false
                    self.clearIncident(recovered: false)

                    let name = config.name ?? "config #\(index)"
                    self.logHandler(.verbose, "Failover: switched from config #\(previousIndex) to '\(name)' (cycle \(self.consecutiveCycles))")
                    self.delegate?.healthMonitor(self, didSwitchToConfigAt: index)

                    // Start hot spare for the next potential failover target
                    self.startHotSpareIfNeeded()
                }
            }
        }
    }

    // MARK: - Failback Probing

    private func startFailbackTimer() {
        let timer = DispatchSource.makeTimerSource(queue: workQueue)
        timer.schedule(
            deadline: .now() + settings.failbackProbeInterval,
            repeating: settings.failbackProbeInterval
        )
        timer.setEventHandler { [weak self] in
            self?.probeFailback()
        }
        timer.resume()
        failbackTimer = timer
    }

    private func probeFailback() {
        guard isRunning, networkBlockedSince == nil, activeIndex != 0, !isProbing, let adapter = adapter else { return }

        if settings.useBackgroundProbes {
            probeFailbackBackground()
        } else {
            probeFailbackLegacy()
        }
    }

    // MARK: - Background Probe Failback (non-disruptive)

    /// Start a background WireGuard probe for the primary config. No traffic disruption.
    private func probeFailbackBackground() {
        guard let adapter = adapter else { return }

        isProbing = true
        let primaryName = configurations[0].name ?? "config #0"
        logHandler(.verbose, "Failover: starting background probe for primary '\(primaryName)'")

        adapter.startProbe(tunnelConfiguration: configurations[0]) { [weak self] (handle: Int32?, error: Error?) in
            guard let self = self else { return }
            self.workQueue.async {
                guard let handle = handle else {
                    self.logHandler(.error, "Failover: background probe failed to start: \(String(describing: error)), falling back to legacy probe")
                    self.isProbing = false
                    // Fall back to legacy disruptive probe
                    self.probeFailbackLegacy()
                    return
                }

                // The monitor may have been stopped while the probe was starting;
                // nobody would ever stop a probe stored after that point.
                guard self.isRunning else {
                    self.adapter?.stopProbe(handle: handle)
                    self.isProbing = false
                    return
                }

                self.failbackProbeHandle = handle
                // Wait for handshake to complete
                let probeWait: TimeInterval = min(15, self.settings.trafficTimeout)
                self.workQueue.asyncAfter(deadline: .now() + probeWait) { [weak self] in
                    self?.evaluateFailbackProbeBackground()
                }
            }
        }
    }

    /// Check the background probe's handshake. If primary recovered, promote it to active tunnel.
    private func evaluateFailbackProbeBackground() {
        guard let adapter = adapter, let handle = failbackProbeHandle else {
            isProbing = false
            return
        }

        adapter.getProbeRuntimeConfiguration(handle: handle) { [weak self] (configString: String?) in
            guard let self = self else { return }
            self.workQueue.async {
                guard let configString = configString else {
                    self.logHandler(.error, "Failover: could not read background probe config")
                    self.stopFailbackProbe()
                    self.isProbing = false
                    return
                }

                let handshakeAge = Self.parseLastHandshakeAge(from: configString)

                if handshakeAge < self.settings.trafficTimeout {
                    // Primary recovered! Promote the probe — preserves the existing WireGuard session.
                    let name = self.configurations[0].name ?? "config #0"
                    self.logHandler(.verbose, "Failover: background probe confirmed primary '\(name)' recovered (handshake \(Int(handshakeAge))s ago). Promoting probe to active tunnel.")

                    // Clear the failback handle so stopFailbackProbe doesn't kill it during promotion
                    self.failbackProbeHandle = nil

                    let promotionSiblings = self.siblingEndpoints(forActiveIndex: 0)
                    adapter.promoteProbe(probeHandle: handle, tunnelConfiguration: self.configurations[0], excludedEndpoints: promotionSiblings) { [weak self] (error: Error?) in
                        guard let self = self else { return }
                        self.workQueue.async {
                            if let error = error {
                                self.logHandler(.error, "Failover: failback probe promotion failed: \(error), falling back to config swap")
                                // Fall back to a regular config swap
                                adapter.update(tunnelConfiguration: self.configurations[0], excludedEndpoints: self.siblingEndpoints(forActiveIndex: 0)) { [weak self] (updateError: Error?) in
                                    guard let self = self else { return }
                                    self.workQueue.async {
                                        if let updateError = updateError {
                                            // The swap to primary also failed — the adapter is still
                                            // running the fallback config. Recording activeIndex = 0
                                            // here would disable failback probing forever and make
                                            // the UI report the wrong config. Stay put and let the
                                            // next failback timer tick retry.
                                            self.logHandler(.error, "Failover: fallback config swap to primary also failed: \(updateError.localizedDescription), staying on config #\(self.activeIndex)")
                                            self.isProbing = false
                                            return
                                        }
                                        // Reads lastSwitchTime before it is overwritten below.
                                        self.noteFailbackTiming()
                                        self.activeIndex = 0
                                        self.lastSwitchTime = DispatchTime.now()
                                        self.consecutiveCycles = 0
                                        self.lastTxBytes = 0
                                        self.lastRxBytes = 0
                                        self.txWithoutRxSince = nil
                                        self.unhealthyReported = false
                                        self.isProbing = false
                                        self.delegate?.healthMonitor(self, didFailbackToConfigAt: 0)
                                        self.startHotSpareIfNeeded()
                                    }
                                }
                            } else {
                                self.noteFailbackTiming()
                                self.activeIndex = 0
                                self.lastSwitchTime = DispatchTime.now()
                                self.consecutiveCycles = 0
                                self.lastTxBytes = 0
                                self.lastRxBytes = 0
                                self.txWithoutRxSince = nil
                                self.unhealthyReported = false
                                self.isProbing = false
                                self.delegate?.healthMonitor(self, didFailbackToConfigAt: 0)
                                self.startHotSpareIfNeeded()
                            }
                        }
                    }
                } else {
                    // Primary still unhealthy — stop the probe, no disruption occurred
                    let primaryName = self.configurations[0].name ?? "config #0"
                    self.logHandler(.verbose, "Failover: background probe shows primary '\(primaryName)' still unhealthy (handshake \(Int(handshakeAge))s ago)")
                    self.stopFailbackProbe()
                    self.isProbing = false
                }
            }
        }
    }

    /// Stop the failback probe if one is running.
    private func stopFailbackProbe() {
        if let handle = failbackProbeHandle {
            adapter?.stopProbe(handle: handle)
            failbackProbeHandle = nil
        }
    }

    // MARK: - Legacy Failback (disruptive swap-wait-check-revert)

    private func probeFailbackLegacy() {
        guard let adapter = adapter else { return }

        isProbing = true
        let savedIndex = activeIndex
        let primaryName = configurations[0].name ?? "config #0"
        logHandler(.verbose, "Failover: probing primary '\(primaryName)' for recovery (legacy)")

        // Switch to primary
        adapter.update(tunnelConfiguration: configurations[0], excludedEndpoints: siblingEndpoints(forActiveIndex: 0)) { [weak self] (error: Error?) in
            guard let self = self else { return }
            self.workQueue.async {
                guard error == nil else {
                    self.logHandler(.error, "Failover: failback probe failed to switch: \(error!.localizedDescription)")
                    self.isProbing = false
                    return
                }

                let probeWait: TimeInterval = min(15, self.settings.trafficTimeout)
                self.workQueue.asyncAfter(deadline: .now() + probeWait) { [weak self] in
                    self?.evaluateFailbackProbeLegacy(savedFallbackIndex: savedIndex)
                }
            }
        }
    }

    private func evaluateFailbackProbeLegacy(savedFallbackIndex: Int) {
        guard let adapter = adapter else {
            isProbing = false
            return
        }

        adapter.getRuntimeConfiguration { [weak self] (configString: String?) in
            guard let self = self else { return }
            guard let configString = configString else {
                // isProbing is confined to workQueue — don't write it from the
                // adapter's callback context.
                self.workQueue.async { self.isProbing = false }
                return
            }
            self.workQueue.async {
                let handshakeAge = Self.parseLastHandshakeAge(from: configString)

                if handshakeAge < self.settings.trafficTimeout {
                    // Primary recovered!
                    let name = self.configurations[0].name ?? "config #0"
                    self.logHandler(.verbose, "Failover: primary '\(name)' recovered (handshake \(Int(handshakeAge))s ago). Staying on primary.")
                    self.noteFailbackTiming()
                    self.activeIndex = 0
                    self.lastSwitchTime = DispatchTime.now()
                    self.consecutiveCycles = 0
                    self.lastTxBytes = 0
                    self.lastRxBytes = 0
                    self.txWithoutRxSince = nil
                    self.unhealthyReported = false
                    self.isProbing = false
                    self.delegate?.healthMonitor(self, didFailbackToConfigAt: 0)
                    self.startHotSpareIfNeeded()
                } else {
                    // Primary still unhealthy — revert
                    let fallbackName = self.configurations[savedFallbackIndex].name ?? "config #\(savedFallbackIndex)"
                    self.logHandler(.verbose, "Failover: primary still unhealthy (\(Int(handshakeAge))s), reverting to '\(fallbackName)'")
                    adapter.update(tunnelConfiguration: self.configurations[savedFallbackIndex], excludedEndpoints: self.siblingEndpoints(forActiveIndex: savedFallbackIndex)) { [weak self] (updateError: Error?) in
                        guard let self = self else { return }
                        self.workQueue.async {
                            if let updateError = updateError {
                                // The revert failed — the adapter is still running the
                                // primary config from the probe swap. Record that honestly
                                // so health checks operate on the real state.
                                self.logHandler(.error, "Failover: revert to '\(fallbackName)' failed: \(updateError.localizedDescription), still on primary")
                                self.activeIndex = 0
                            }
                            self.lastTxBytes = 0
                            self.lastRxBytes = 0
                            self.txWithoutRxSince = nil
                            self.unhealthyReported = false
                            self.isProbing = false
                        }
                    }
                }
            }
        }
    }

    // MARK: - Hot Spare

    /// Start a hot spare probe for the next failover target, if hot spare mode is enabled.
    private func startHotSpareIfNeeded() {
        guard settings.hotSpare, isRunning, networkBlockedSince == nil, let adapter = adapter else { return }

        // Probe the next forward failover target — the same config we'd switch to
        // if the active connection went unhealthy ((activeIndex + 1) wrapping at the
        // end of the chain). This keeps the next-in-line connection pre-warmed for
        // instant forward failover. Failback to the primary is handled separately by
        // the periodic failback probe (`probeFailbackBackground`), so the single hot
        // spare slot is reserved for forward protection.
        let targetIndex = (activeIndex + 1) % configurations.count

        // Nothing to pre-warm if the next target is the connection we're already on.
        guard targetIndex != activeIndex else { return }

        // Don't start if already running for this target
        if hotSpareConfigIndex == targetIndex, hotSpareHandle != nil { return }

        // Stop existing hot spare if for a different target
        stopHotSpare()

        let targetName = configurations[targetIndex].name ?? "config #\(targetIndex)"
        logHandler(.verbose, "Failover: starting hot spare probe for '\(targetName)' (index \(targetIndex))")

        adapter.startProbe(tunnelConfiguration: configurations[targetIndex]) { [weak self] (handle: Int32?, error: Error?) in
            guard let self = self else { return }
            self.workQueue.async {
                if let handle = handle {
                    // The monitor may have been stopped while the probe was
                    // starting; nobody would ever stop a probe stored after that.
                    guard self.isRunning else {
                        self.adapter?.stopProbe(handle: handle)
                        return
                    }
                    self.hotSpareHandle = handle
                    self.hotSpareConfigIndex = targetIndex
                    self.logHandler(.verbose, "Failover: hot spare started for index \(targetIndex) (handle \(handle))")
                } else {
                    self.logHandler(.error, "Failover: failed to start hot spare: \(String(describing: error))")
                }
            }
        }
    }

    /// Stop the hot spare probe if one is running.
    private func stopHotSpare() {
        if let handle = hotSpareHandle {
            adapter?.stopProbe(handle: handle)
            hotSpareHandle = nil
            hotSpareConfigIndex = nil
        }
    }

    /// A WireGuard session is rejected by the protocol after 180s without a
    /// re-handshake (REJECT_AFTER_TIME); a spare whose last handshake is older
    /// has no usable session and a promotion would be a blind switch that then
    /// burns the minimum hold time before the monitor can move on.
    private static let hotSpareMaxHandshakeAge: TimeInterval = 180

    /// Promote the hot spare to become the active tunnel, preserving its WireGuard session.
    /// Called from evaluateHealth when the active connection is detected as unhealthy.
    /// Returns true if the monitor has taken responsibility for this failover
    /// (caller must not also switchToConfig): asynchronously, the spare's
    /// session is verified and either promoted or — if it never handshook,
    /// e.g. the fallback endpoint is also down — stopped in favor of a
    /// regular config swap to the same target.
    private func tryHotSpareFailover() -> Bool {
        guard settings.hotSpare, let adapter = adapter,
              let handle = hotSpareHandle, let targetIndex = hotSpareConfigIndex,
              // A failover/failback that landed while the spare was starting can
              // leave it targeting the now-active config — promoting it would
              // "fail over" to the config we're already on.
              targetIndex != activeIndex else {
            return false
        }

        // Take ownership of the spare so stopHotSpare can't kill it mid-promotion
        let config = configurations[targetIndex]
        hotSpareHandle = nil
        hotSpareConfigIndex = nil

        adapter.getProbeRuntimeConfiguration(handle: handle) { [weak self] (configString: String?) in
            guard let self = self else { return }
            self.workQueue.async {
                let handshakeAge = configString.map { Self.parseLastHandshakeAge(from: $0) } ?? .infinity
                guard handshakeAge < Self.hotSpareMaxHandshakeAge else {
                    let name = config.name ?? "config #\(targetIndex)"
                    self.logHandler(.error, "Failover: hot spare for '\(name)' has no live session (handshake \(handshakeAge == .infinity ? "never" : "\(Int(handshakeAge))s ago")), using regular config swap")
                    self.adapter?.stopProbe(handle: handle)
                    self.switchToConfig(at: targetIndex)
                    return
                }

                self.logHandler(.verbose, "Failover: hot spare for index \(targetIndex) has a live session (handshake \(Int(handshakeAge))s ago)")
                self.promoteProbeAsActive(handle: handle, index: targetIndex, label: "hot spare")
            }
        }

        return true
    }

    /// Promote a probe (hot spare or confirmation probe) to become the active tunnel. The
    /// probe's Noise session is preserved, so there is no re-handshake. Falls back to a config
    /// swap if promotion fails.
    private func promoteProbeAsActive(handle: Int32, index targetIndex: Int, label: String) {
        guard let adapter = adapter else { return }
        let config = configurations[targetIndex]
        logHandler(.verbose, "Failover: promoting \(label) for index \(targetIndex) — session preserved, no re-handshake")

        // Promote: swaps null tun → real utun inside the probe's device
        let siblings = siblingEndpoints(forActiveIndex: targetIndex)
        isSwitching = true
        adapter.promoteProbe(probeHandle: handle, tunnelConfiguration: config, excludedEndpoints: siblings) { [weak self] (error: Error?) in
            guard let self = self else { return }
            self.workQueue.async {
                self.isSwitching = false
                if let error = error {
                    self.logHandler(.error, "Failover: \(label) promotion failed: \(error), falling back to config swap")
                    // Fall back to regular config swap
                    self.switchToConfig(at: targetIndex)
                } else {
                    let previousIndex = self.activeIndex
                    self.activeIndex = targetIndex
                    self.lastSwitchTime = DispatchTime.now()
                    self.consecutiveCycles += 1

                    self.lastTxBytes = 0
                    self.lastRxBytes = 0
                    self.txWithoutRxSince = nil
                    self.unhealthyReported = false
                    self.clearIncident(recovered: false)

                    let name = config.name ?? "config #\(targetIndex)"
                    self.logHandler(.verbose, "Failover: \(label) promoted from #\(previousIndex) to '\(name)' (cycle \(self.consecutiveCycles))")
                    self.delegate?.healthMonitor(self, didSwitchToConfigAt: targetIndex)

                    // Start a new hot spare for the next target
                    self.startHotSpareIfNeeded()
                }
            }
        }
    }

    // MARK: - State Snapshot

    /// Returns a snapshot of the health monitor's current state for IPC reporting.
    /// Dispatches to the internal work queue for thread safety.
    public func getStateSnapshot(completionHandler: @escaping ([String: Any]) -> Void) {
        workQueue.async {
            var state = [String: Any]()
            // Monitor internals surfaced for the connection details view. These keys are
            // additive; the failover detail views only read the ones below.
            state["monitorRunning"] = self.isRunning
            state["monitorActiveIndex"] = self.activeIndex
            state["monitorLastTxBytes"] = self.lastTxBytes
            state["monitorLastRxBytes"] = self.lastRxBytes
            state["minimumHoldTime"] = self.minimumHoldTime
            state["maxCyclesBeforeCooldown"] = self.maxCyclesBeforeCooldown
            state["cooldownDuration"] = self.cooldownDuration
            state["failbackTimerActive"] = self.failbackTimer != nil
            state["effectiveTrafficTimeout"] = self.effectiveTrafficTimeout
            state["falseAlarmCount"] = self.falseAlarmCount
            state["pathSatisfied"] = self.pathSatisfied
            if let since = self.suppressedSince {
                state["suppressedSince"] = since.timeIntervalSince1970
            }
            if let handle = self.confirmationProbeHandle {
                state["confirmationProbeHandle"] = Int(handle)
                state["confirmationProbeIndex"] = self.confirmationProbeIndex ?? -1
            }
            let confirmationState: String
            if self.suppressedSince != nil {
                confirmationState = "suppressed"
            } else if self.confirmationProbeHandle != nil {
                confirmationState = "probing"
            } else {
                confirmationState = "idle"
            }
            state["confirmationState"] = confirmationState
            if let handle = self.failbackProbeHandle {
                state["failbackProbeHandle"] = Int(handle)
            }
            if let handle = self.hotSpareHandle {
                state["hotSpareHandle"] = Int(handle)
            }
            if self.consecutiveCycles > 0 {
                state["consecutiveCycles"] = self.consecutiveCycles
            }
            if self.isProbing {
                state["isProbing"] = true
            }
            if self.isSwitching {
                state["isSwitching"] = true
            }
            if self.failbackProbeHandle != nil {
                state["backgroundProbeActive"] = true
            }
            if let lastSwitchTime = self.lastSwitchTime {
                state["lastSwitchTime"] = Date().timeIntervalSince1970 - Self.secondsSince(lastSwitchTime)
            }
            if let txWithoutRxSince = self.txWithoutRxSince {
                state["txWithoutRxSince"] = Date().timeIntervalSince1970 - Self.secondsSince(txWithoutRxSince)
            }
            if let blockedSince = self.networkBlockedSince {
                state["networkBlocked"] = true
                state["captivePortalDetected"] = (self.networkBlockedStatus == .captive)
                state["networkBlockedSince"] = blockedSince.timeIntervalSince1970
            }

            // If hot spare is running, query its probe for handshake status
            if let hotSpareIndex = self.hotSpareConfigIndex {
                state["hotSpareConfigIndex"] = hotSpareIndex
                if let handle = self.hotSpareHandle, let adapter = self.adapter {
                    state["hotSpareActive"] = true
                    adapter.getProbeRuntimeConfiguration(handle: handle) { configString in
                        self.workQueue.async {
                            if let configString = configString {
                                let age = Self.parseLastHandshakeAge(from: configString)
                                if age < .infinity {
                                    state["hotSpareHandshakeAge"] = age
                                } else {
                                    let redacted = Self.redactSecrets(from: configString)
                                    self.logHandler(.verbose, "Failover: hot spare probe (handle \(handle), index \(hotSpareIndex)) has no handshake. UAPI:\n\(redacted)")
                                }
                            } else {
                                self.logHandler(.verbose, "Failover: hot spare probe (handle \(handle), index \(hotSpareIndex)) returned no UAPI config")
                            }
                            completionHandler(state)
                        }
                    }
                    return
                } else {
                    state["hotSpareActive"] = false
                    completionHandler(state)
                    return
                }
            }

            completionHandler(state)
        }
    }

    // MARK: - UAPI Parsing

    /// Parse total tx_bytes and rx_bytes from a UAPI runtime config string.
    /// Sums across all peers.
    static func parseTxRxBytes(from uapiConfig: String) -> (tx: UInt64, rx: UInt64) {
        var totalTx: UInt64 = 0
        var totalRx: UInt64 = 0

        for line in uapiConfig.split(separator: "\n") {
            if line.hasPrefix("tx_bytes=") {
                let value = line.dropFirst("tx_bytes=".count)
                if let bytes = UInt64(value) {
                    totalTx += bytes
                }
            } else if line.hasPrefix("rx_bytes=") {
                let value = line.dropFirst("rx_bytes=".count)
                if let bytes = UInt64(value) {
                    totalRx += bytes
                }
            }
        }

        return (totalTx, totalRx)
    }

    /// Strip private_key / preshared_key values from a UAPI dump for safe logging.
    static func redactSecrets(from uapiConfig: String) -> String {
        return uapiConfig.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            if line.hasPrefix("private_key=") { return "private_key=<redacted>" }
            if line.hasPrefix("preshared_key=") { return "preshared_key=<redacted>" }
            return String(line)
        }.joined(separator: "\n")
    }

    /// Parse the age of the most recent handshake from a UAPI runtime config string.
    /// Used for failback probing. Returns `.infinity` if no handshake has ever occurred.
    static func parseLastHandshakeAge(from uapiConfig: String) -> TimeInterval {
        var latestHandshakeTimestamp: TimeInterval = 0

        for line in uapiConfig.split(separator: "\n") {
            if line.hasPrefix("last_handshake_time_sec=") {
                let value = line.dropFirst("last_handshake_time_sec=".count)
                if let timestamp = TimeInterval(value), timestamp > latestHandshakeTimestamp {
                    latestHandshakeTimestamp = timestamp
                }
            }
        }

        if latestHandshakeTimestamp > 0 {
            return Date().timeIntervalSince1970 - latestHandshakeTimestamp
        }
        return .infinity
    }

    #if FAILOVER_TESTING
    // MARK: - Debug: Force Failover

    /// Force an immediate switch to the next configuration, bypassing health checks.
    public func forceSwitch(completionHandler: @escaping (Bool) -> Void) {
        workQueue.async {
            guard self.isRunning else {
                completionHandler(false)
                return
            }
            let nextIndex = (self.activeIndex + 1) % self.configurations.count
            let name = self.configurations[nextIndex].name ?? "config #\(nextIndex)"
            self.logHandler(.verbose, "Failover: DEBUG force switch to '\(name)'")
            self.switchToConfig(at: nextIndex)
            completionHandler(true)
        }
    }

    /// Force an immediate failback to the primary configuration (index 0).
    public func forceFailback(completionHandler: @escaping (Bool) -> Void) {
        workQueue.async {
            guard self.isRunning, self.activeIndex != 0 else {
                completionHandler(false)
                return
            }
            let name = self.configurations[0].name ?? "config #0"
            self.logHandler(.verbose, "Failover: DEBUG force failback to '\(name)'")
            self.switchToConfig(at: 0)
            completionHandler(true)
        }
    }
    #endif
}
