// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import UIKit

/// List of past speed test results, newest first.
class SpeedTestResultsViewController: UITableViewController {

    private var results = [SpeedTestResult]()

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    init() {
        super.init(style: .grouped)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = tr("speedTestHistoryViewTitle")

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: tr("speedTestHistoryClearButtonTitle"),
            style: .plain,
            target: self,
            action: #selector(clearTapped)
        )

        tableView.estimatedRowHeight = 44
        tableView.rowHeight = UITableView.automaticDimension
        tableView.register(SpeedTestServerCell.self)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
    }

    private func reload() {
        results = SpeedTestResultsStore.loadResults()
        tableView.reloadData()
        navigationItem.rightBarButtonItem?.isEnabled = !results.isEmpty
        if results.isEmpty {
            let label = UILabel()
            label.text = tr("speedTestHistoryEmptyMessage")
            label.textColor = .secondaryLabel
            label.textAlignment = .center
            label.numberOfLines = 0
            tableView.backgroundView = label
        } else {
            tableView.backgroundView = nil
        }
    }

    @objc private func clearTapped() {
        let alert = UIAlertController(
            title: tr("speedTestHistoryClearConfirmTitle"),
            message: tr("speedTestHistoryClearConfirmMessage"),
            preferredStyle: .actionSheet
        )
        alert.addAction(UIAlertAction(title: tr("speedTestHistoryClearButtonTitle"), style: .destructive) { [weak self] _ in
            SpeedTestResultsStore.clear()
            self?.reload()
        })
        alert.addAction(UIAlertAction(title: tr("actionCancel"), style: .cancel))
        if let popover = alert.popoverPresentationController {
            popover.barButtonItem = navigationItem.rightBarButtonItem
        }
        present(alert, animated: true)
    }

    // MARK: - Table view data source

    override func numberOfSections(in tableView: UITableView) -> Int {
        return results.isEmpty ? 0 : 1
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return results.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell: SpeedTestServerCell = tableView.dequeueReusableCell(for: indexPath)
        let result = results[indexPath.row]
        cell.name = result.summaryLine
        var detailParts = [dateFormatter.string(from: result.date), result.serverName]
        if let networkType = result.networkType {
            detailParts.append(networkType)
        }
        if let tunnelName = result.activeTunnelName {
            detailParts.append(tunnelName)
        }
        cell.detail = detailParts.joined(separator: " · ")
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let detailVC = SpeedTestResultDetailViewController(result: results[indexPath.row])
        navigationController?.pushViewController(detailVC, animated: true)
    }

    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete else { return }
        let result = results[indexPath.row]
        SpeedTestResultsStore.remove(withId: result.id)
        results.remove(at: indexPath.row)
        if results.isEmpty {
            reload()
        } else {
            tableView.deleteRows(at: [indexPath], with: .automatic)
        }
    }
}
