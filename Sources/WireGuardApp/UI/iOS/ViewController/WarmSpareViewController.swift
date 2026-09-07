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
        title = tr("warmSpareTitle")
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
            return tr("warmSpareSectionPolicy")
        case .thresholds:
            return tr("warmSpareSectionThresholds")
        case .status:
            return tr("warmSpareSectionStatus")
        case .natTest:
            return tr("warmSpareSectionNatTest")
        #if FAILOVER_TESTING
        case .debug:
            return tr("warmSpareSectionDebug")
        #endif
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch sections[section] {
        case .enable:
            if !supportsWarmSpare {
                return tr("warmSpareFooterUnsupported")
            }
            return tr("warmSpareFooterEnable")
        case .policy:
            return settings.adaptiveWarming
                ? tr("warmSpareFooterAdaptiveOn")
                : tr("warmSpareFooterAdaptiveOff")
        case .thresholds:
            return tr("warmSpareFooterThresholds")
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
            cell.message = tr("warmSpareToggleEnable")
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
            cell.message = tr("warmSpareToggleAdaptive")
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
                cell.textLabel?.text = tr("warmSpareFieldKeepaliveInterval")
                cell.detailTextLabel?.text = tr(format: "warmSpareValueSeconds (%d)", Int(settings.warmKeepaliveInterval))
            case .probePort:
                cell.textLabel?.text = tr("warmSpareFieldProbePort")
                cell.detailTextLabel?.text = "\(settings.probePort)"
            case .switchRtt:
                cell.textLabel?.text = tr("warmSpareFieldSwitchRtt")
                cell.detailTextLabel?.text = tr(format: "warmSpareValueMilliseconds (%d)", settings.switchRttMs)
            case .switchLoss:
                cell.textLabel?.text = tr("warmSpareFieldSwitchLoss")
                cell.detailTextLabel?.text = tr(format: "warmSpareValuePercent (%d)", settings.switchLossPct)
            case .dwell:
                cell.textLabel?.text = tr("warmSpareFieldRecoveryDwell")
                cell.detailTextLabel?.text = tr(format: "warmSpareValueSeconds (%d)", Int(settings.dwellSeconds))
            }
            cell.accessoryType = .disclosureIndicator
            return cell

        case .status:
            let cell: KeyValueCell = tableView.dequeueReusableCell(for: indexPath)
            cell.copyableGesture = false
            guard let row = StatusRow(rawValue: indexPath.row) else { return cell }
            switch row {
            case .controllerState:
                cell.key = tr("warmSpareKeyState")
                cell.value = controllerStateDescription()
            case .activePath:
                cell.key = tr("warmSpareKeyActivePath")
                cell.value = activePathDescription()
            case .wifiQuality:
                cell.key = tr("warmSpareKeyDefaultPath")
                cell.value = qualityDescription(for: "primaryPath")
            case .cellularQuality:
                cell.key = tr("warmSpareKeyCellular")
                cell.value = qualityDescription(for: "cellularPath")
            }
            return cell

        case .natTest:
            if indexPath.row == 0 {
                let cell: KeyValueCell = tableView.dequeueReusableCell(for: indexPath)
                cell.copyableGesture = false
                cell.key = tr("warmSpareKeyMapping")
                cell.value = natVerdictDescription()
                return cell
            } else {
                let cell: ButtonCell = tableView.dequeueReusableCell(for: indexPath)
                cell.buttonText = tr("warmSpareRunNatTestButtonTitle")
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
                cell.buttonText = tr("warmSpareForceCellularButtonTitle")
                cell.onTapped = { [weak self] in self?.debugForcePath(1) }
            case 1:
                cell.buttonText = tr("warmSpareForcePrimaryButtonTitle")
                cell.onTapped = { [weak self] in self?.debugForcePath(0) }
            default:
                cell.buttonText = tr("warmSpareResumeAutomaticButtonTitle")
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
            title = tr("warmSpareEditorKeepaliveInterval")
            currentValue = Int(settings.warmKeepaliveInterval)
        case .probePort:
            title = tr("warmSpareEditorProbePort")
            currentValue = Int(settings.probePort)
        case .switchRtt:
            title = tr("warmSpareEditorSwitchRtt")
            currentValue = settings.switchRttMs
        case .switchLoss:
            title = tr("warmSpareEditorSwitchLoss")
            currentValue = settings.switchLossPct
        case .dwell:
            title = tr("warmSpareEditorRecoveryDwell")
            currentValue = Int(settings.dwellSeconds)
        }

        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        alert.addTextField { textField in
            textField.text = "\(currentValue)"
            textField.keyboardType = .numberPad
        }
        alert.addAction(UIAlertAction(title: tr("actionOK"), style: .default) { [weak self, weak alert] _ in
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
        alert.addAction(UIAlertAction(title: tr("actionCancel"), style: .cancel))
        present(alert, animated: true)
    }

    // MARK: - NAT test

    private func runNatTest() {
        tunnelsManager.runWarmSpareEimTest(for: tunnel) { [weak self] started in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if !started {
                    let alert = UIAlertController(
                        title: tr("warmSpareTestNotStartedTitle"),
                        message: tr("warmSpareTestNotStartedMessage"),
                        preferredStyle: .alert
                    )
                    alert.addAction(UIAlertAction(title: tr("actionOK"), style: .default))
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
            return tr("warmSpareStateWifiCellCold")
        case "wifiActiveCellWarm":
            return tr("warmSpareStateWifiCellWarm")
        case "cellActive":
            return tr("warmSpareStateCellActive")
        case "recovering":
            if let dwell = (status?["recoveringForSec"] as? NSNumber)?.doubleValue {
                return tr(format: "warmSpareStateRecovering (%d)", Int(dwell))
            }
            return tr("warmSpareStateRecoveringNoDwell")
        default:
            return tr("warmSpareStateUnknown")
        }
    }

    private func activePathDescription() -> String {
        switch status?["activePath"] as? String {
        case "cellular":
            return tr("warmSparePathCellular")
        case "primary":
            return tr("warmSparePathPrimary")
        default:
            return tr("warmSpareStateUnknown")
        }
    }

    private func qualityDescription(for key: String) -> String {
        guard let path = status?[key] as? [String: Any] else { return "—" }
        let samples = (path["samples"] as? NSNumber)?.intValue ?? 0
        guard samples > 0 else { return tr("warmSpareQualityNoSamples") }
        let rtt = (path["rttMs"] as? NSNumber)?.doubleValue ?? -1
        let loss = (path["lossPct"] as? NSNumber)?.intValue ?? -1
        var parts = [String]()
        if rtt >= 0 {
            parts.append(tr(format: "warmSpareQualityRtt (%d)", Int(rtt)))
        }
        if loss >= 0 {
            parts.append(tr(format: "warmSpareQualityLoss (%d)", loss))
        }
        return parts.isEmpty ? tr("warmSpareQualityNoReplies") : parts.joined(separator: " · ")
    }

    private func natVerdictDescription() -> String {
        guard let eim = status?["eim"] as? [String: Any],
              let verdict = eim["verdict"] as? String else {
            return tr("warmSpareNatVerdictUntested")
        }
        switch verdict {
        case "eim":
            return tr("warmSpareNatVerdictEim")
        case "edm":
            return tr("warmSpareNatVerdictEdm")
        case "pending":
            return tr("warmSpareNatVerdictPending")
        case "unreachable":
            return tr("warmSpareNatVerdictUnreachable")
        default:
            return tr("warmSpareNatVerdictUntested")
        }
    }

    private func natTestFooter() -> String {
        guard let eim = status?["eim"] as? [String: Any],
              let verdict = eim["verdict"] as? String else {
            return tr("warmSpareNatFooterUntested")
        }
        switch verdict {
        case "eim":
            return tr("warmSpareNatFooterEim")
        case "edm":
            return tr("warmSpareNatFooterEdm")
        case "unreachable":
            return tr("warmSpareNatFooterUnreachable")
        default:
            return tr("warmSpareNatFooterUntested")
        }
    }
}
