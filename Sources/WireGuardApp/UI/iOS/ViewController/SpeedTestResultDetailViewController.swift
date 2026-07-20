// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import UIKit

/// Full detail for one speed test result, including the network conditions
/// it was captured under.
class SpeedTestResultDetailViewController: UITableViewController {

    private let result: SpeedTestResult
    private var rows = [(key: String, value: String)]()

    init(result: SpeedTestResult) {
        self.result = result
        super.init(style: .grouped)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = tr("speedTestResultDetailViewTitle")

        tableView.estimatedRowHeight = 44
        tableView.rowHeight = UITableView.automaticDimension
        tableView.allowsSelection = false
        tableView.register(KeyValueCell.self)
        tableView.register(ButtonCell.self)

        buildRows()
    }

    private func buildRows() {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .medium

        rows.removeAll()
        rows.append((tr("speedTestResultFieldDate"), dateFormatter.string(from: result.date)))
        rows.append((tr("speedTestResultFieldServer"), result.serverName))
        rows.append((tr("speedTestResultFieldEndpoint"), result.serverHost))
        rows.append((tr("speedTestResultFieldKind"), result.serverKind.localizedName))
        rows.append((tr("speedTestResultFieldDirection"), result.direction.localizedName))
        rows.append((tr("speedTestResultFieldDuration"), String(format: "%.1f s", result.actualDurationSeconds)))
        if let downloadMbps = result.downloadMbps {
            rows.append((tr("speedTestResultFieldDownload"), SpeedTestResult.formatMbps(downloadMbps)))
        }
        if let uploadMbps = result.uploadMbps {
            rows.append((tr("speedTestResultFieldUpload"), SpeedTestResult.formatMbps(uploadMbps)))
        }
        if let downloadBytes = result.downloadBytes, downloadBytes > 0 {
            rows.append((tr("speedTestResultFieldDownloadedData"), FormattingHelpers.prettyBytes(UInt64(downloadBytes))))
        }
        if let uploadBytes = result.uploadBytes, uploadBytes > 0 {
            rows.append((tr("speedTestResultFieldUploadedData"), FormattingHelpers.prettyBytes(UInt64(uploadBytes))))
        }
        rows.append((tr("speedTestResultFieldNetworkType"), result.networkType ?? tr("speedTestResultValueUnknown")))
        if let ssid = result.wifiSSID {
            rows.append((tr("speedTestResultFieldWifiSSID"), ssid))
        }
        if let carrierName = result.carrierName {
            rows.append((tr("speedTestResultFieldCarrier"), carrierName))
        }
        if let radioTechnology = result.radioTechnology {
            rows.append((tr("speedTestResultFieldRadio"), radioTechnology))
        }
        if let locationDescription = result.locationDescription {
            rows.append((tr("speedTestResultFieldLocation"), locationDescription))
        } else if let latitude = result.latitude, let longitude = result.longitude {
            rows.append((tr("speedTestResultFieldLocation"), String(format: "%.4f, %.4f", latitude, longitude)))
        }
        rows.append((tr("speedTestResultFieldVPNTunnel"), result.activeTunnelName ?? tr("speedTestResultValueNone")))
    }

    // MARK: - Table view data source

    override func numberOfSections(in tableView: UITableView) -> Int {
        return 2
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return section == 0 ? rows.count : 1
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section == 1 {
            let cell: ButtonCell = tableView.dequeueReusableCell(for: indexPath)
            cell.buttonText = tr("speedTestResultDeleteButtonTitle")
            cell.hasDestructiveAction = true
            cell.onTapped = { [weak self] in
                guard let self = self else { return }
                SpeedTestResultsStore.remove(withId: self.result.id)
                self.navigationController?.popViewController(animated: true)
            }
            return cell
        }
        let cell: KeyValueCell = tableView.dequeueReusableCell(for: indexPath)
        let row = rows[indexPath.row]
        cell.key = row.key
        cell.value = row.value
        return cell
    }
}
