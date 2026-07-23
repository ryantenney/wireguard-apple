// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import Foundation
import Network

/// Which socket carries WireGuard traffic. Raw values match the Go bridge
/// (`wgWarmSetActivePath`).
public enum WarmSparePath: Int32 {
    case primary = 0
    case cellular = 1
}

/// Adapter operations the path controller needs. `WireGuardAdapter`
/// implements this against the warm-spare Go bridge; all calls are
/// fire-and-forget onto the adapter's work queue.
public protocol WarmSparePathBackend: AnyObject {
    func warmSpareWarmCellular(ifindex: UInt32)
    func warmSpareCoolCellular()
    func warmSpareSetActivePath(_ path: WarmSparePath)
    func warmSpareSetPrimaryProbing(_ enabled: Bool)
    func warmSpareFetchState(completionHandler: @escaping ([String: Any]?) -> Void)
}

/// State machine driving warm spare cellular failover. Owns the warming
/// lifecycle (when the cellular socket exists) and the active path (which
/// socket the bind writes to). Inputs:
///
/// - The adapter's existing `NWPathMonitor` (default path), forwarded via
///   `defaultPathDidUpdate` — the hard-loss backstop.
/// - A cellular-specific `NWPathMonitor` for cellular availability and the
///   interface index needed to bind the warm socket.
/// - Quality probe statistics polled from the Go bridge — soft-degradation
///   flips and adaptive warming triggers.
///
/// Path migration is invisible to the OS: no `NEVPNStatus` transitions, no
/// network settings changes — just which socket the Go bind writes to.
public final class PathController {

    public enum State: String {
        /// Primary (default path) active; cellular socket closed.
        case wifiActiveCellCold
        /// Primary active; cellular socket open, keepalives running.
        case wifiActiveCellWarm
        /// Cellular socket carries traffic (Wi-Fi lost or degraded).
        case cellActive
        /// Cellular still active; Wi-Fi is back and the dwell timer runs.
        case recovering
    }

    private let queue = DispatchQueue(label: "WireGuardPathController")
    private let settings: WarmSpareSettings
    private weak var backend: WarmSparePathBackend?
    private let logHandler: (WireGuardLogLevel, String) -> Void

    private var state: State = .wifiActiveCellCold

    /// Cellular-specific path monitor (availability + interface index).
    private var cellMonitor: NWPathMonitor?
    private var cellAvailable = false
    private var cellIfindex: UInt32?

    /// Latest default-path facts, forwarded from the adapter's monitor.
    private var defaultPathSatisfied = true
    private var defaultPathUsesWifi = false

    private var pollTimer: DispatchSourceTimer?

    /// When `recovering` began (dwell reference point).
    private var recoveringSince: Date?

    /// Start of the current stretch of healthy Wi-Fi (adaptive cool-down).
    private var wifiHealthySince: Date?

    /// Debug override: when set, automatic decisions are suspended.
    private var forcedPath: WarmSparePath?

    private var isRunning = false

    /// How long Wi-Fi must stay healthy before adaptive warming lets the
    /// cellular socket go cold again.
    private let adaptiveQuietPeriod: TimeInterval = 120

    /// Cadence for polling probe statistics from the Go bridge.
    private let pollInterval: TimeInterval = 3

    /// Minimum probe samples before quality-based decisions.
    private let minSamples = 3

    public init(settings: WarmSpareSettings,
                backend: WarmSparePathBackend,
                logHandler: @escaping (WireGuardLogLevel, String) -> Void) {
        self.settings = settings
        self.backend = backend
        self.logHandler = logHandler
    }

    // MARK: - Lifecycle

    public func start() {
        queue.async {
            guard !self.isRunning else { return }
            self.isRunning = true

            let monitor = NWPathMonitor(requiredInterfaceType: .cellular)
            monitor.pathUpdateHandler = { [weak self] path in
                self?.cellularPathDidUpdate(path)
            }
            monitor.start(queue: self.queue)
            self.cellMonitor = monitor

            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + self.pollInterval, repeating: self.pollInterval)
            timer.setEventHandler { [weak self] in
                self?.poll()
            }
            timer.resume()
            self.pollTimer = timer

            self.logHandler(.verbose, "Warm spare: path controller started (adaptive=\(self.settings.adaptiveWarming), rtt>\(self.settings.switchRttMs)ms, loss>\(self.settings.switchLossPct)%, dwell=\(Int(self.settings.dwellSeconds))s)")
        }
    }

    public func stop() {
        queue.async {
            guard self.isRunning else { return }
            self.isRunning = false
            self.cellMonitor?.cancel()
            self.cellMonitor = nil
            self.pollTimer?.cancel()
            self.pollTimer = nil
        }
    }

    /// Thread-safe snapshot of the controller state, for IPC reporting.
    public func snapshot(completionHandler: @escaping ([String: Any]) -> Void) {
        queue.async {
            var snap: [String: Any] = [
                "controllerState": self.state.rawValue,
                "cellularAvailable": self.cellAvailable,
                "defaultPathUsesWifi": self.defaultPathUsesWifi
            ]
            if let since = self.recoveringSince {
                snap["recoveringForSec"] = Date().timeIntervalSince(since)
            }
            if let forced = self.forcedPath {
                snap["forcedPath"] = forced == .cellular ? "cellular" : "primary"
            }
            completionHandler(snap)
        }
    }

    // MARK: - Inputs

    /// Forwarded from the adapter's default-path `NWPathMonitor`. This is the
    /// hard-loss backstop: quality probes usually flip first, but this always
    /// fires eventually.
    public func defaultPathDidUpdate(isSatisfied: Bool, usesWifi: Bool) {
        queue.async {
            guard self.isRunning else { return }
            self.defaultPathSatisfied = isSatisfied
            self.defaultPathUsesWifi = usesWifi

            // Default-path quality probes only inform decisions while Wi-Fi
            // is the default path; keep the radio quiet otherwise. (Re-sent
            // on every update: the Go-side gate is also how a resumed
            // backend, which defaults to probing on, learns the truth.)
            self.backend?.warmSpareSetPrimaryProbing(usesWifi)

            guard self.forcedPath == nil else { return }

            if !isSatisfied {
                // Total loss (airplane mode, no network at all): the adapter
                // tears the backend down, taking the Go-side warm state with
                // it. Reset bookkeeping; on resume we re-warm from cold.
                self.state = .wifiActiveCellCold
                self.recoveringSince = nil
                self.wifiHealthySince = nil
                return
            }

            if !usesWifi {
                // Default path no longer Wi-Fi: either Wi-Fi is gone (path
                // now cellular) or was never there. Hard flip.
                switch self.state {
                case .wifiActiveCellCold, .wifiActiveCellWarm:
                    self.flipToCellular(reason: "default path lost Wi-Fi")
                case .recovering:
                    // Wi-Fi bounced during dwell — stay on cellular.
                    self.logHandler(.verbose, "Warm spare: Wi-Fi lost during dwell, staying on cellular")
                    self.state = .cellActive
                    self.recoveringSince = nil
                case .cellActive:
                    break
                }
            } else {
                // Default path is Wi-Fi again.
                if self.state == .cellActive {
                    self.state = .recovering
                    self.recoveringSince = Date()
                    self.logHandler(.verbose, "Warm spare: Wi-Fi back, dwelling \(Int(self.settings.dwellSeconds))s before flip-back")
                }
            }
        }
    }

    private func cellularPathDidUpdate(_ path: Network.NWPath) {
        // Already on our queue (monitor started on it).
        let available = path.status == .satisfied
        let ifindex = path.availableInterfaces.first { $0.type == .cellular }.map { UInt32($0.index) }
        let becameAvailable = available && !cellAvailable
        cellAvailable = available
        cellIfindex = ifindex

        guard isRunning, forcedPath == nil else { return }

        if !available {
            // Airplane mode, SIM out, data off: cold is a normal state, not
            // an error. If cellular was carrying traffic, fall back to the
            // primary socket (it follows whatever default path remains).
            switch state {
            case .cellActive, .recovering:
                logHandler(.verbose, "Warm spare: cellular gone while active, reverting to primary socket")
                backend?.warmSpareSetActivePath(.primary)
                backend?.warmSpareCoolCellular()
                state = .wifiActiveCellCold
                recoveringSince = nil
            case .wifiActiveCellWarm:
                backend?.warmSpareCoolCellular()
                state = .wifiActiveCellCold
            case .wifiActiveCellCold:
                break
            }
        } else if becameAvailable {
            // Continuous warming wants the socket up as soon as cellular
            // exists; adaptive waits for a quality trigger in poll().
            if state == .wifiActiveCellCold && !settings.adaptiveWarming && defaultPathUsesWifi {
                warmNow(reason: "cellular available (continuous warming)")
            }
        }
    }

    // MARK: - Quality polling

    private func poll() {
        guard isRunning else { return }
        // Keep the Go-side probing gate converged: a backend rebuilt after a
        // temporary shutdown defaults to probing on, and the path update that
        // triggered the resume may have raced the restart.
        backend?.warmSpareSetPrimaryProbing(defaultPathUsesWifi)
        backend?.warmSpareFetchState { [weak self] stateDict in
            guard let self = self else { return }
            self.queue.async {
                self.evaluate(stateDict: stateDict)
            }
        }
    }

    private struct PathQuality {
        let rttMs: Double
        let lossPct: Int
        let samples: Int

        init?(_ dict: [String: Any]?) {
            guard let dict = dict else { return nil }
            self.rttMs = (dict["rttMs"] as? NSNumber)?.doubleValue ?? -1
            self.lossPct = (dict["lossPct"] as? NSNumber)?.intValue ?? -1
            self.samples = (dict["samples"] as? NSNumber)?.intValue ?? 0
        }
    }

    private func evaluate(stateDict: [String: Any]?) {
        guard isRunning, forcedPath == nil else { return }
        let primary = PathQuality(stateDict?["primaryPath"] as? [String: Any])

        switch state {
        case .wifiActiveCellCold:
            guard defaultPathUsesWifi, cellAvailable else { return }
            if !settings.adaptiveWarming {
                warmNow(reason: "continuous warming")
            } else if let q = primary, isDegrading(q) {
                warmNow(reason: "Wi-Fi degrading (rtt \(Int(q.rttMs))ms, loss \(q.lossPct)%)")
            }

        case .wifiActiveCellWarm:
            guard defaultPathUsesWifi else { return }
            if let q = primary, isBreaching(q) {
                flipToCellular(reason: "Wi-Fi breached thresholds (rtt \(Int(q.rttMs))ms, loss \(q.lossPct)%)")
                return
            }
            trackWifiHealth(primary)
            if settings.adaptiveWarming,
               let healthySince = wifiHealthySince,
               Date().timeIntervalSince(healthySince) > adaptiveQuietPeriod {
                logHandler(.verbose, "Warm spare: Wi-Fi healthy for \(Int(adaptiveQuietPeriod))s, cooling cellular")
                backend?.warmSpareCoolCellular()
                state = .wifiActiveCellCold
                wifiHealthySince = nil
            }

        case .cellActive:
            break

        case .recovering:
            guard let since = recoveringSince else {
                state = .cellActive
                return
            }
            // Flip back only after the dwell elapses with Wi-Fi still the
            // default path and default-path probes not breaching.
            guard defaultPathUsesWifi else { return }
            if let q = primary, q.samples >= minSamples, isBreaching(q) {
                // Wi-Fi is back but bad — restart the dwell.
                recoveringSince = Date()
                return
            }
            if Date().timeIntervalSince(since) >= settings.dwellSeconds {
                flipToPrimary(reason: "Wi-Fi healthy through dwell")
            }
        }
    }

    private func trackWifiHealth(_ quality: PathQuality?) {
        if let q = quality, q.samples >= minSamples, !isDegrading(q) {
            if wifiHealthySince == nil {
                wifiHealthySince = Date()
            }
        } else {
            wifiHealthySince = nil
        }
    }

    /// Hard thresholds: flip when breached.
    private func isBreaching(_ q: PathQuality) -> Bool {
        guard q.samples >= minSamples else { return false }
        if q.rttMs >= 0 && q.rttMs >= Double(settings.switchRttMs) { return true }
        if q.lossPct >= 0 && q.lossPct >= settings.switchLossPct { return true }
        // All probes lost is the strongest breach signal of all.
        if q.rttMs < 0 && q.lossPct >= 100 { return true }
        return false
    }

    /// Soft thresholds (two-thirds of the switch thresholds): warm the spare.
    private func isDegrading(_ q: PathQuality) -> Bool {
        guard q.samples >= minSamples else { return false }
        if q.rttMs >= 0 && q.rttMs >= Double(settings.switchRttMs) * 2 / 3 { return true }
        if q.lossPct >= 0 && q.lossPct >= settings.switchLossPct / 2 { return true }
        return false
    }

    // MARK: - Actions

    private func warmNow(reason: String) {
        guard let ifindex = cellIfindex else {
            logHandler(.verbose, "Warm spare: want to warm (\(reason)) but no cellular interface index")
            return
        }
        logHandler(.verbose, "Warm spare: warming cellular — \(reason)")
        backend?.warmSpareWarmCellular(ifindex: ifindex)
        state = .wifiActiveCellWarm
        wifiHealthySince = nil
    }

    private func flipToCellular(reason: String) {
        guard cellAvailable else {
            logHandler(.verbose, "Warm spare: would flip to cellular (\(reason)) but cellular unavailable")
            return
        }
        if state == .wifiActiveCellCold {
            // Cold flip: open the socket on the way. No pre-warmed NAT
            // mapping, but still faster than waiting for the default path
            // socket to rebind.
            if let ifindex = cellIfindex {
                backend?.warmSpareWarmCellular(ifindex: ifindex)
            }
        }
        logHandler(.verbose, "Warm spare: flipping to cellular — \(reason)")
        backend?.warmSpareSetActivePath(.cellular)
        state = .cellActive
        recoveringSince = nil
        wifiHealthySince = nil
    }

    private func flipToPrimary(reason: String) {
        logHandler(.verbose, "Warm spare: flipping back to primary — \(reason)")
        backend?.warmSpareSetActivePath(.primary)
        // Keep the spare warm right after a flip-back — Wi-Fi was recently in
        // trouble. Adaptive warming cools it after the quiet period.
        state = .wifiActiveCellWarm
        recoveringSince = nil
        wifiHealthySince = nil
    }

    /// Warm the cellular spare on explicit request (e.g. before running the
    /// EIM self-test). No-op unless currently cold with cellular available.
    /// Adaptive warming may cool it again after the quiet period.
    public func requestWarm() {
        queue.async {
            guard self.isRunning, self.state == .wifiActiveCellCold, self.cellAvailable else { return }
            self.warmNow(reason: "explicit request")
        }
    }

    // MARK: - Debug

    /// Force the active path (suspending automatic decisions), or pass `nil`
    /// to resume automatic control. Used by the FAILOVER_TESTING debug UI.
    public func forcePath(_ path: WarmSparePath?) {
        queue.async {
            self.forcedPath = path
            guard let path = path else {
                self.logHandler(.verbose, "Warm spare: DEBUG resumed automatic path control")
                self.state = self.defaultPathUsesWifi ? .wifiActiveCellWarm : .cellActive
                return
            }
            if path == .cellular, self.state == .wifiActiveCellCold, let ifindex = self.cellIfindex {
                self.backend?.warmSpareWarmCellular(ifindex: ifindex)
            }
            self.logHandler(.verbose, "Warm spare: DEBUG forcing path \(path == .cellular ? "cellular" : "primary")")
            self.backend?.warmSpareSetActivePath(path)
            self.state = path == .cellular ? .cellActive : .wifiActiveCellWarm
        }
    }
}
