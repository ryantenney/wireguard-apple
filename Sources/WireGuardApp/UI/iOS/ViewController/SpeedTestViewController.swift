// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import UIKit

/// The Speed Test tab: pick a server, direction and duration, run the test
/// with a live readout, and browse past results.
class SpeedTestViewController: UITableViewController {

    /// Injected by RootTabBarController; returns the name of the currently
    /// active VPN tunnel or failover group, if any.
    var activeTunnelNameProvider: (() -> String?)?

    private enum Row {
        case server
        case direction
        case duration
        case liveStatus
        case startStop
        case history
    }

    private let rowsBySection: [[Row]] = [
        [.server, .direction, .duration],
        [.liveStatus, .startStop],
        [.history]
    ]

    static let durationChoices = [5, 10, 15, 30, 60]

    private static let selectedServerIdKey = "speedTestSelectedServerId"
    private static let directionKey = "speedTestDirection"
    private static let durationKey = "speedTestDuration"

    private var selectedServer: SpeedTestServer?
    private var direction: SpeedTestDirection = .download
    private var durationSeconds = 10

    private let engine = SpeedTestEngine.shared
    private var lastProgress: SpeedTestProgress?
    private var lastResult: SpeedTestResult?
    private var statusText = ""

    init() {
        super.init(style: .grouped)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = tr("speedTestViewTitle")
        statusText = tr("speedTestStatusIdle")

        tableView.estimatedRowHeight = 44
        tableView.rowHeight = UITableView.automaticDimension
        tableView.register(ChevronCell.self)
        tableView.register(ButtonCell.self)
        tableView.register(SpeedTestRunCell.self)

        loadPreferences()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // The selected server may have been edited or deleted elsewhere.
        if let selectedServer = selectedServer {
            self.selectedServer = SpeedTestServerStore.server(withId: selectedServer.id)
        }
        if selectedServer == nil {
            selectedServer = SpeedTestServerStore.loadServers().first
        }
        tableView.reloadData()
    }

    private func loadPreferences() {
        let defaults = UserDefaults.standard
        if let idString = defaults.string(forKey: SpeedTestViewController.selectedServerIdKey),
           let id = UUID(uuidString: idString) {
            selectedServer = SpeedTestServerStore.server(withId: id)
        }
        if selectedServer == nil {
            selectedServer = SpeedTestServerStore.loadServers().first
        }
        if let directionString = defaults.string(forKey: SpeedTestViewController.directionKey),
           let savedDirection = SpeedTestDirection(rawValue: directionString) {
            direction = savedDirection
        }
        let savedDuration = defaults.integer(forKey: SpeedTestViewController.durationKey)
        if SpeedTestViewController.durationChoices.contains(savedDuration) {
            durationSeconds = savedDuration
        }
    }

    private func savePreferences() {
        let defaults = UserDefaults.standard
        defaults.set(selectedServer?.id.uuidString, forKey: SpeedTestViewController.selectedServerIdKey)
        defaults.set(direction.rawValue, forKey: SpeedTestViewController.directionKey)
        defaults.set(durationSeconds, forKey: SpeedTestViewController.durationKey)
    }

    // MARK: - Running the test

    private func startTest() {
        guard !engine.isRunning else { return }
        guard let server = selectedServer else {
            let alert = UIAlertController(title: tr("speedTestAlertNoServerTitle"), message: tr("speedTestAlertNoServerMessage"), preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: tr("actionOK"), style: .default))
            present(alert, animated: true)
            return
        }

        lastProgress = nil
        lastResult = nil
        statusText = tr("speedTestStatusConnecting")
        UIApplication.shared.isIdleTimerDisabled = true
        reloadTestSection()

        engine.start(server: server,
                     direction: direction,
                     durationSeconds: durationSeconds,
                     activeTunnelName: activeTunnelNameProvider?(),
                     onProgress: { [weak self] progress in
                         guard let self = self else { return }
                         self.lastProgress = progress
                         self.statusText = tr(format: "speedTestStatusRunning (%d) (%d)", Int(progress.elapsedSeconds.rounded()), Int(progress.totalSeconds))
                         self.updateRunCell()
                     },
                     completion: { [weak self] result in
                         guard let self = self else { return }
                         UIApplication.shared.isIdleTimerDisabled = false
                         self.lastProgress = nil
                         switch result {
                         case .success(let testResult):
                             self.lastResult = testResult
                             self.statusText = tr("speedTestStatusDone")
                         case .failure(let error):
                             self.statusText = tr("speedTestStatusIdle")
                             if !self.engine.lastRunWasCancelled {
                                 ErrorPresenter.showErrorAlert(error: error, from: self)
                             }
                         }
                         self.tableView.reloadData()
                     })
    }

    private func stopTest() {
        engine.cancel()
        statusText = tr("speedTestStatusIdle")
    }

    private func reloadTestSection() {
        tableView.reloadSections(IndexSet(integer: 1), with: .none)
    }

    private func updateRunCell() {
        guard let cell = tableView.cellForRow(at: IndexPath(row: 0, section: 1)) as? SpeedTestRunCell else { return }
        configureRunCell(cell)
    }

    private func configureRunCell(_ cell: SpeedTestRunCell) {
        let downloadText: String
        let uploadText: String
        var progressFraction: Float?

        if let progress = lastProgress {
            downloadText = progress.downloadMbps.map { SpeedTestResult.formatMbps($0) } ?? "—"
            uploadText = progress.uploadMbps.map { SpeedTestResult.formatMbps($0) } ?? "—"
            if progress.totalSeconds > 0 {
                progressFraction = Float(min(progress.elapsedSeconds / progress.totalSeconds, 1))
            }
        } else if let result = lastResult {
            downloadText = result.downloadMbps.map { SpeedTestResult.formatMbps($0) } ?? "—"
            uploadText = result.uploadMbps.map { SpeedTestResult.formatMbps($0) } ?? "—"
        } else {
            downloadText = "—"
            uploadText = "—"
        }
        cell.update(downloadText: downloadText, uploadText: uploadText, statusText: statusText, progress: progressFraction)
    }

    // MARK: - Table view data source

    override func numberOfSections(in tableView: UITableView) -> Int {
        return rowsBySection.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return rowsBySection[section].count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch section {
        case 0:
            return tr("speedTestSectionTitleConfiguration")
        case 1:
            return tr("speedTestSectionTitleTest")
        case 2:
            return tr("speedTestSectionTitleResults")
        default:
            return nil
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let row = rowsBySection[indexPath.section][indexPath.row]
        switch row {
        case .server:
            let cell: ChevronCell = tableView.dequeueReusableCell(for: indexPath)
            cell.message = tr("speedTestFieldServer")
            cell.detailMessage = selectedServer?.name ?? tr("speedTestNoServerSelected")
            return cell
        case .direction:
            let cell: ChevronCell = tableView.dequeueReusableCell(for: indexPath)
            cell.message = tr("speedTestFieldDirection")
            cell.detailMessage = direction.localizedName
            return cell
        case .duration:
            let cell: ChevronCell = tableView.dequeueReusableCell(for: indexPath)
            cell.message = tr("speedTestFieldDuration")
            cell.detailMessage = tr(format: "speedTestDurationValue (%d)", durationSeconds)
            return cell
        case .liveStatus:
            let cell: SpeedTestRunCell = tableView.dequeueReusableCell(for: indexPath)
            configureRunCell(cell)
            return cell
        case .startStop:
            let cell: ButtonCell = tableView.dequeueReusableCell(for: indexPath)
            cell.buttonText = engine.isRunning ? tr("speedTestStopButtonTitle") : tr("speedTestStartButtonTitle")
            cell.hasDestructiveAction = engine.isRunning
            cell.onTapped = { [weak self] in
                guard let self = self else { return }
                if self.engine.isRunning {
                    self.stopTest()
                } else {
                    self.startTest()
                }
                self.reloadTestSection()
            }
            return cell
        case .history:
            let cell: ChevronCell = tableView.dequeueReusableCell(for: indexPath)
            cell.message = tr("speedTestHistoryButtonTitle")
            let count = SpeedTestResultsStore.loadResults().count
            cell.detailMessage = count > 0 ? "\(count)" : ""
            return cell
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let row = rowsBySection[indexPath.section][indexPath.row]
        switch row {
        case .server:
            guard !engine.isRunning else { return }
            let serverListVC = SpeedTestServerListViewController(selectedServerId: selectedServer?.id)
            serverListVC.onSelectionChanged = { [weak self] server in
                guard let self = self else { return }
                self.selectedServer = server
                self.savePreferences()
                self.tableView.reloadData()
            }
            navigationController?.pushViewController(serverListVC, animated: true)
        case .direction:
            guard !engine.isRunning else { return }
            let options = SpeedTestDirection.allCases
            let picker = SpeedTestPickerViewController(
                title: tr("speedTestFieldDirection"),
                options: options.map { $0.localizedName },
                selectedIndex: options.firstIndex(of: direction) ?? 0
            )
            picker.onSelect = { [weak self] index in
                guard let self = self else { return }
                self.direction = options[index]
                self.savePreferences()
                self.tableView.reloadData()
            }
            navigationController?.pushViewController(picker, animated: true)
        case .duration:
            guard !engine.isRunning else { return }
            let choices = SpeedTestViewController.durationChoices
            let picker = SpeedTestPickerViewController(
                title: tr("speedTestFieldDuration"),
                options: choices.map { tr(format: "speedTestDurationValue (%d)", $0) },
                selectedIndex: choices.firstIndex(of: durationSeconds) ?? 1
            )
            picker.onSelect = { [weak self] index in
                guard let self = self else { return }
                self.durationSeconds = choices[index]
                self.savePreferences()
                self.tableView.reloadData()
            }
            navigationController?.pushViewController(picker, animated: true)
        case .history:
            navigationController?.pushViewController(SpeedTestResultsViewController(), animated: true)
        case .liveStatus, .startStop:
            break
        }
    }
}
