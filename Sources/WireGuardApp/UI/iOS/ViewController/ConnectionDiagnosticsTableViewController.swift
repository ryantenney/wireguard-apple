// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import UIKit

/// The "nerd view": every fact the app and the Network Extension know about a
/// tunnel, failover group, or tunnel-in-tunnel group. Polls the extension every
/// two seconds while the tunnel is active.
class ConnectionDiagnosticsTableViewController: UITableViewController {

    private let tunnelsManager: TunnelsManager
    private let tunnel: TunnelContainer
    private let model: ConnectionDiagnosticsModel

    private var sections: [DiagnosticsSection] = []
    private var pollTimer: Timer?
    private var statusObservationToken: AnyObject?
    private var isPollInFlight = false

    init(tunnelsManager: TunnelsManager, tunnel: TunnelContainer) {
        self.tunnelsManager = tunnelsManager
        self.tunnel = tunnel
        self.model = ConnectionDiagnosticsModel(tunnel: tunnel)
        super.init(style: .grouped)

        statusObservationToken = tunnel.observe(\.status) { [weak self] tunnel, _ in
            guard let self = self else { return }
            if tunnel.status == .active {
                self.startPolling()
            } else if tunnel.status == .inactive {
                self.stopPolling()
                self.model.clearRuntime()
                self.rebuild()
            } else {
                self.rebuild()
            }
        }
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Connection Details"
        tableView.estimatedRowHeight = 44
        tableView.rowHeight = UITableView.automaticDimension
        tableView.register(KeyValueCell.self)
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .action, target: self, action: #selector(shareTapped))
        restorationIdentifier = "ConnectionDiagnosticsVC:\(tunnel.name)"
        rebuild()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if tunnel.status == .active {
            startPolling()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        stopPolling()
    }

    // MARK: - Polling

    private func startPolling() {
        stopPolling()
        poll()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func poll() {
        guard !isPollInFlight else { return }
        isPollInFlight = true
        tunnelsManager.getConnectionDiagnostics(for: tunnel) { [weak self] diagnostics in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isPollInFlight = false
                if let diagnostics = diagnostics {
                    self.model.update(with: diagnostics)
                }
                self.rebuild()
            }
        }
    }

    // MARK: - Rendering

    /// Rebuild the sections. When the shape of the table is unchanged, update the
    /// visible cells in place so the list does not flicker or lose scroll position.
    private func rebuild() {
        let newSections = model.sections()
        let sameShape = newSections.count == sections.count && zip(newSections, sections).allSatisfy {
            $0.title == $1.title && $0.rows.count == $1.rows.count
        }
        sections = newSections
        guard isViewLoaded else { return }
        if sameShape {
            for indexPath in tableView.indexPathsForVisibleRows ?? [] {
                guard let cell = tableView.cellForRow(at: indexPath) as? KeyValueCell else { continue }
                let row = sections[indexPath.section].rows[indexPath.row]
                cell.key = row.key
                cell.value = row.value
            }
        } else {
            tableView.reloadData()
        }
    }

    @objc private func shareTapped() {
        let report = model.plainTextReport()
        let activityVC = UIActivityViewController(activityItems: [report], applicationActivities: nil)
        activityVC.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItem
        present(activityVC, animated: true)
    }

    // MARK: - UITableViewDataSource

    override func numberOfSections(in tableView: UITableView) -> Int {
        return sections.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return sections[section].rows.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return sections[section].title
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell: KeyValueCell = tableView.dequeueReusableCell(for: indexPath)
        let row = sections[indexPath.section].rows[indexPath.row]
        cell.key = row.key
        cell.value = row.value
        cell.copyableGesture = true
        return cell
    }

    override func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        return nil
    }
}
