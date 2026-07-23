// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import UIKit

/// Warm spare cellular failover settings and live status for a single tunnel.
/// Pushed from the tunnel detail view. Settings changes save immediately and
/// take effect on the next tunnel activation; the status section reflects the
/// running extension via IPC (message 5). See
/// `DESIGN-warm-spare-cellular-failover.md`.
class WarmSpareViewController: UITableViewController {

    private enum Section {
        case enable
        case policy
        case thresholds
        case status
        case natTest
        #if FAILOVER_TESTING
        case debug
        #endif
    }

    private enum ThresholdRow: Int, CaseIterable {
        case keepaliveInterval
        case probePort
        case switchRtt
        case switchLoss
        case dwell
    }

    private enum StatusRow: Int, CaseIterable {
        case controllerState
        case activePath
        case wifiQuality
        case cellularQuality
    }

    private let tunnelsManager: TunnelsManager
    private let tunnel: TunnelContainer

    private var settings: WarmSpareSettings
    private var sections = [Section]()

    /// Latest IPC status snapshot, or nil if the tunnel isn't running warm spare.
    private var status: [String: Any]?
    private var statusTimer: Timer?
    private var statusObservationToken: AnyObject?

    /// Whether the tunnel's on-demand mode keeps the provider running on
    /// every interface type ("Always On") — the warm spare prerequisite.
    private var supportsWarmSpare: Bool {
        return tunnel.onDemandOption.supportsWarmSpare
    }

    init(tunnelsManager: TunnelsManager, tunnel: TunnelContainer) {
        self.tunnelsManager = tunnelsManager
        self.tunnel = tunnel
        self.settings = tunnelsManager.warmSpareSettings(for: tunnel) ?? WarmSpareSettings()
        super.init(style: .grouped)
        loadSections()
        statusObservationToken = tunnel.observe(\.status) { [weak self] _, _ in
            guard let self = self else { return }
            if self.tunnel.status == .active {
                self.startStatusUpdates()
            } else if self.tunnel.status == .inactive {
                self.stopStatusUpdates()
                self.status = nil
                self.reloadSections()
            }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Warm Spare"
        tableView.estimatedRowHeight = 44
        tableView.rowHeight = UITableView.automaticDimension
        tableView.register(SwitchCell.self)
        tableView.register(KeyValueCell.self)
        tableView.register(ButtonCell.self)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if tunnel.status == .active {
            startStatusUpdates()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        stopStatusUpdates()
    }

    private func loadSections() {
        sections.removeAll()
        sections.append(.enable)
        if settings.enabled {
            sections.append(.policy)
            sections.append(.thresholds)
        }
        if status != nil {
            sections.append(.status)
            sections.append(.natTest)
        }
        #if FAILOVER_TESTING
        if settings.enabled && tunnel.status == .active {
            sections.append(.debug)
        }
        #endif
    }

    private func reloadSections() {
        loadSections()
        tableView.reloadData()
    }

    // MARK: - Status polling

    private func startStatusUpdates() {
        refreshStatus()
        statusTimer?.invalidate()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            self?.refreshStatus()
        }
        statusTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopStatusUpdates() {
        statusTimer?.invalidate()
        statusTimer = nil
    }

    private func refreshStatus() {
        tunnelsManager.getWarmSpareStatus(for: tunnel) { [weak self] status in
            DispatchQueue.main.async {
                guard let self = self else { return }
                let hadStatus = self.status != nil
                self.status = status
                if hadStatus != (status != nil) {
                    self.reloadSections()
                } else if status != nil {
                    var sectionsToReload = IndexSet()
                    if let statusSection = self.sections.firstIndex(of: .status) {
                        sectionsToReload.insert(statusSection)
                    }
                    if let natSection = self.sections.firstIndex(of: .natTest) {
                        sectionsToReload.insert(natSection)
                    }
                    if !sectionsToReload.isEmpty {
                        self.tableView.reloadSections(sectionsToReload, with: .none)
                    }
                }
            }
        }
    }

    // MARK: - Settings persistence

    private func saveSettings() {
        tunnelsManager.setWarmSpareSettings(settings, for: tunnel) { [weak self] error in
            if let error = error, let self = self {
                ErrorPresenter.showErrorAlert(error: error, from: self)
            }
        }
    }

    // MARK: - Table view data source

    override func numberOfSections(in tableView: UITableView) -> Int {
        return sections.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch sections[section] {
        case .enable:
            return 1
        case .policy:
            return 1
        case .thresholds:
            return ThresholdRow.allCases.count
        case .status:
            return StatusRow.allCases.count
        case .natTest:
            return 2
        #if FAILOVER_TESTING
        case .debug:
            return 3
        #endif
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch sections[section] {
        case .enable:
            return nil
        case .policy:
            return "Warming Policy"
        case .thresholds:
            return "Probing & Switching"
        case .status:
            return "Status"
        case .natTest:
            return "Carrier NAT"
        #if FAILOVER_TESTING
        case .debug:
            return "Debug"
        #endif
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch sections[section] {
        case .enable:
            if !supportsWarmSpare {
                return "Warm spare requires on-demand activation for any interface (Always On). With other on-demand modes the VPN isn't running while on Wi-Fi, so there is nothing to keep warm."
            }
            return "Keeps a ready-to-use connection on cellular while on Wi-Fi, so losing Wi-Fi switches paths in under a second without reconnecting. Note that Wi-Fi traffic always rides the tunnel in this mode. Changes apply the next time the tunnel starts."
        case .policy:
            return settings.adaptiveWarming
                ? "Cellular is kept warm only when Wi-Fi quality starts degrading. Uses less battery."
                : "Cellular is kept warm whenever the tunnel is on Wi-Fi. Fastest failover, but each keepalive can wake the cellular radio."
        case .thresholds:
            return "The probe port must match the echo responder running on the WireGuard server, and must differ from the WireGuard port."
        case .natTest:
            return natTestFooter()
        default:
            return nil
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch sections[indexPath.section] {
        case .enable:
            let cell: SwitchCell = tableView.dequeueReusableCell(for: indexPath)
            cell.message = "Warm Spare"
            cell.isOn = settings.enabled && supportsWarmSpare
            cell.isEnabled = supportsWarmSpare
            cell.onSwitchToggled = { [weak self] isOn in
                guard let self = self else { return }
                self.settings.enabled = isOn
                self.saveSettings()
                self.reloadSections()
            }
            return cell

        case .policy:
            let cell: SwitchCell = tableView.dequeueReusableCell(for: indexPath)
            cell.message = "Adaptive Warming"
            cell.isOn = settings.adaptiveWarming
            cell.onSwitchToggled = { [weak self] isOn in
                guard let self = self else { return }
                self.settings.adaptiveWarming = isOn
                self.saveSettings()
                if let policySection = self.sections.firstIndex(of: .policy) {
                    self.tableView.reloadSections(IndexSet(integer: policySection), with: .none)
                }
            }
            return cell

        case .thresholds:
            let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
            guard let row = ThresholdRow(rawValue: indexPath.row) else { return cell }
            switch row {
            case .keepaliveInterval:
                cell.textLabel?.text = "Keepalive Interval"
                cell.detailTextLabel?.text = "\(Int(settings.warmKeepaliveInterval))s"
            case .probePort:
                cell.textLabel?.text = "Probe Port"
                cell.detailTextLabel?.text = "\(settings.probePort)"
            case .switchRtt:
                cell.textLabel?.text = "Switch RTT Threshold"
                cell.detailTextLabel?.text = "\(settings.switchRttMs) ms"
            case .switchLoss:
                cell.textLabel?.text = "Switch Loss Threshold"
                cell.detailTextLabel?.text = "\(settings.switchLossPct)%"
            case .dwell:
                cell.textLabel?.text = "Recovery Dwell"
                cell.detailTextLabel?.text = "\(Int(settings.dwellSeconds))s"
            }
            cell.accessoryType = .disclosureIndicator
            return cell

        case .status:
            let cell: KeyValueCell = tableView.dequeueReusableCell(for: indexPath)
            cell.copyableGesture = false
            guard let row = StatusRow(rawValue: indexPath.row) else { return cell }
            switch row {
            case .controllerState:
                cell.key = "State"
                cell.value = controllerStateDescription()
            case .activePath:
                cell.key = "Active Path"
                cell.value = activePathDescription()
            case .wifiQuality:
                cell.key = "Default Path"
                cell.value = qualityDescription(for: "primaryPath")
            case .cellularQuality:
                cell.key = "Cellular"
                cell.value = qualityDescription(for: "cellularPath")
            }
            return cell

        case .natTest:
            if indexPath.row == 0 {
                let cell: KeyValueCell = tableView.dequeueReusableCell(for: indexPath)
                cell.copyableGesture = false
                cell.key = "Mapping"
                cell.value = natVerdictDescription()
                return cell
            } else {
                let cell: ButtonCell = tableView.dequeueReusableCell(for: indexPath)
                cell.buttonText = "Run Carrier NAT Test"
                cell.onTapped = { [weak self] in
                    self?.runNatTest()
                }
                return cell
            }

        #if FAILOVER_TESTING
        case .debug:
            let cell: ButtonCell = tableView.dequeueReusableCell(for: indexPath)
            switch indexPath.row {
            case 0:
                cell.buttonText = "Force Cellular Path"
                cell.onTapped = { [weak self] in self?.debugForcePath(1) }
            case 1:
                cell.buttonText = "Force Primary Path"
                cell.onTapped = { [weak self] in self?.debugForcePath(0) }
            default:
                cell.buttonText = "Resume Automatic Control"
                cell.onTapped = { [weak self] in self?.debugForcePath(nil) }
            }
            return cell
        #endif
        }
    }

    override func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        if case .thresholds = sections[indexPath.section] {
            return indexPath
        }
        return nil
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard case .thresholds = sections[indexPath.section],
              let row = ThresholdRow(rawValue: indexPath.row) else { return }
        presentValueEditor(for: row)
    }

    // MARK: - Value editing

    private func presentValueEditor(for row: ThresholdRow) {
        let title: String
        let currentValue: Int
        switch row {
        case .keepaliveInterval:
            title = "Keepalive Interval (seconds)"
            currentValue = Int(settings.warmKeepaliveInterval)
        case .probePort:
            title = "Probe Port"
            currentValue = Int(settings.probePort)
        case .switchRtt:
            title = "Switch RTT Threshold (ms)"
            currentValue = settings.switchRttMs
        case .switchLoss:
            title = "Switch Loss Threshold (%)"
            currentValue = settings.switchLossPct
        case .dwell:
            title = "Recovery Dwell (seconds)"
            currentValue = Int(settings.dwellSeconds)
        }

        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        alert.addTextField { textField in
            textField.text = "\(currentValue)"
            textField.keyboardType = .numberPad
        }
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self, weak alert] _ in
            guard let self = self,
                  let text = alert?.textFields?.first?.text,
                  let value = Int(text), value > 0 else { return }
            switch row {
            case .keepaliveInterval:
                self.settings.warmKeepaliveInterval = TimeInterval(value)
            case .probePort:
                guard let port = UInt16(exactly: value) else { return }
                self.settings.probePort = port
            case .switchRtt:
                self.settings.switchRttMs = value
            case .switchLoss:
                self.settings.switchLossPct = min(value, 100)
            case .dwell:
                self.settings.dwellSeconds = TimeInterval(value)
            }
            self.saveSettings()
            if let thresholdsSection = self.sections.firstIndex(of: .thresholds) {
                self.tableView.reloadSections(IndexSet(integer: thresholdsSection), with: .none)
            }
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    // MARK: - NAT test

    private func runNatTest() {
        tunnelsManager.runWarmSpareEimTest(for: tunnel) { [weak self] started in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if !started {
                    let alert = UIAlertController(
                        title: "Test Not Started",
                        message: "The tunnel must be active with warm spare engaged and cellular available.",
                        preferredStyle: .alert
                    )
                    alert.addAction(UIAlertAction(title: "OK", style: .default))
                    self.present(alert, animated: true)
                }
                // The verdict arrives via the status poll within a few seconds.
            }
        }
    }

    #if FAILOVER_TESTING
    private func debugForcePath(_ path: Int?) {
        tunnelsManager.debugForceWarmSparePath(path, for: tunnel) { _ in }
    }
    #endif

    // MARK: - Status formatting

    private func controllerStateDescription() -> String {
        switch status?["controllerState"] as? String {
        case "wifiActiveCellCold":
            return "On Wi-Fi, cellular idle"
        case "wifiActiveCellWarm":
            return "On Wi-Fi, cellular warm"
        case "cellActive":
            return "On cellular"
        case "recovering":
            if let dwell = (status?["recoveringForSec"] as? NSNumber)?.doubleValue {
                return "Returning to Wi-Fi (\(Int(dwell))s)"
            }
            return "Returning to Wi-Fi"
        default:
            return "Unknown"
        }
    }

    private func activePathDescription() -> String {
        switch status?["activePath"] as? String {
        case "cellular":
            return "Cellular"
        case "primary":
            return "Default (Wi-Fi)"
        default:
            return "Unknown"
        }
    }

    private func qualityDescription(for key: String) -> String {
        guard let path = status?[key] as? [String: Any] else { return "—" }
        let samples = (path["samples"] as? NSNumber)?.intValue ?? 0
        guard samples > 0 else { return "No samples" }
        let rtt = (path["rttMs"] as? NSNumber)?.doubleValue ?? -1
        let loss = (path["lossPct"] as? NSNumber)?.intValue ?? -1
        var parts = [String]()
        if rtt >= 0 {
            parts.append("\(Int(rtt)) ms")
        }
        if loss >= 0 {
            parts.append("\(loss)% loss")
        }
        return parts.isEmpty ? "No replies" : parts.joined(separator: " · ")
    }

    private func natVerdictDescription() -> String {
        guard let eim = status?["eim"] as? [String: Any],
              let verdict = eim["verdict"] as? String else {
            return "Not tested"
        }
        switch verdict {
        case "eim":
            return "Compatible (endpoint-independent)"
        case "edm":
            return "Endpoint-dependent"
        case "pending":
            return "Testing…"
        case "unreachable":
            return "No reply"
        default:
            return "Not tested"
        }
    }

    private func natTestFooter() -> String {
        guard let eim = status?["eim"] as? [String: Any],
              let verdict = eim["verdict"] as? String else {
            return "Tests whether your carrier's NAT lets the warm connection be reused instantly on failover."
        }
        switch verdict {
        case "eim":
            return "Your carrier's NAT reuses the warm mapping — failover reuses the existing session with no extra delay."
        case "edm":
            return "Your carrier's NAT assigns a new mapping per destination. Warm spare still helps (the radio and connection stay ready), but the first exchange after failover may take slightly longer."
        case "unreachable":
            return "No reply over cellular. Check that the echo responder is running on the server and that cellular data is available."
        default:
            return "Tests whether your carrier's NAT lets the warm connection be reused instantly on failover."
        }
    }
}
