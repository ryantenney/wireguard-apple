// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import UIKit

class SessionDetailViewController: UITableViewController {

    private let record: SessionRecord

    private enum Section {
        case summary
        case traffic
        case failover
    }

    private let sections: [Section]

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .medium
        return f
    }()

    private let durationFormatter: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.hour, .minute, .second]
        f.unitsStyle = .abbreviated
        return f
    }()

    private let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .binary
        return f
    }()

    init(record: SessionRecord) {
        self.record = record
        var sections: [Section] = [.summary, .traffic]
        if !record.failoverEvents.isEmpty {
            sections.append(.failover)
        }
        self.sections = sections
        super.init(style: .grouped)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = dateFormatter.string(from: record.startedAt)
        tableView.estimatedRowHeight = 44
        tableView.rowHeight = UITableView.automaticDimension
        tableView.allowsSelection = false
        tableView.register(KeyValueCell.self)
    }

    // MARK: - Helpers

    private func summaryRows() -> [(String, String)] {
        var rows: [(String, String)] = []
        rows.append((tr("sessionDetailLabelTunnel"), record.tunnelName))
        rows.append((tr("sessionDetailLabelStarted"), dateFormatter.string(from: record.startedAt)))
        if let endedAt = record.endedAt {
            rows.append((tr("sessionDetailLabelEnded"), dateFormatter.string(from: endedAt)))
        } else {
            rows.append((tr("sessionDetailLabelEnded"), tr("sessionStatusInProgress")))
        }
        rows.append((tr("sessionDetailLabelDuration"), durationFormatter.string(from: record.duration) ?? ""))
        rows.append((tr("sessionDetailLabelActivation"), localizedActivation(record.activationReason)))
        if let reason = record.deactivationReason {
            rows.append((tr("sessionDetailLabelDeactivation"), localizedDeactivation(reason)))
        }
        if let initial = record.initialActiveConfigName {
            rows.append((tr("sessionDetailLabelInitialConfig"), initial))
        }
        return rows
    }

    private func trafficRows() -> [(String, String)] {
        return [
            (tr("sessionDetailLabelRxBytes"), byteFormatter.string(fromByteCount: Int64(record.rxBytes))),
            (tr("sessionDetailLabelTxBytes"), byteFormatter.string(fromByteCount: Int64(record.txBytes)))
        ]
    }

    private func eventRow(_ event: FailoverEvent) -> (String, String) {
        let timeFormatter = DateFormatter()
        timeFormatter.dateStyle = .none
        timeFormatter.timeStyle = .medium
        let timestamp = timeFormatter.string(from: event.timestamp)
        let detail: String
        switch event.kind {
        case .switched:
            detail = tr(format: "sessionFailoverSwitched (%@: %@)",
                        event.fromConfigName ?? "?",
                        event.toConfigName ?? "?")
        case .unhealthy:
            let secs = event.txWithoutRxDuration.map { "\(Int($0))s" } ?? "?"
            detail = tr(format: "sessionFailoverUnhealthy (%@: %@)",
                        event.fromConfigName ?? "?",
                        secs)
        case .failedBack:
            detail = tr(format: "sessionFailoverFailedBack (%@)", event.toConfigName ?? "?")
        case .suppressed:
            let secs = event.txWithoutRxDuration.map { "\(Int($0))s" } ?? "?"
            detail = tr(format: "sessionFailoverSuppressed (%@: %@)", event.fromConfigName ?? "?", secs)
        case .configReloaded:
            detail = tr("sessionFailoverConfigReloaded")
        }
        return (timestamp, detail)
    }

    private func localizedActivation(_ reason: ActivationReason) -> String {
        switch reason {
        case .manual: return tr("sessionActivationManual")
        case .onDemand: return tr("sessionActivationOnDemand")
        case .unknown: return tr("sessionActivationUnknown")
        }
    }

    private func localizedDeactivation(_ reason: DeactivationReason) -> String {
        switch reason {
        case .userInitiated: return tr("sessionDeactivationUserInitiated")
        case .providerFailed: return tr("sessionDeactivationProviderFailed")
        case .noNetworkAvailable: return tr("sessionDeactivationNoNetwork")
        case .unrecoverableNetworkChange: return tr("sessionDeactivationNetworkChange")
        case .providerDisabled: return tr("sessionDeactivationProviderDisabled")
        case .authenticationCanceled: return tr("sessionDeactivationAuthCanceled")
        case .configurationFailed: return tr("sessionDeactivationConfigFailed")
        case .idleTimeout: return tr("sessionDeactivationIdleTimeout")
        case .configurationDisabled: return tr("sessionDeactivationConfigDisabled")
        case .configurationRemoved: return tr("sessionDeactivationConfigRemoved")
        case .superceded: return tr("sessionDeactivationSuperceded")
        case .userLogout: return tr("sessionDeactivationLogout")
        case .userSwitch: return tr("sessionDeactivationUserSwitch")
        case .connectionFailed: return tr("sessionDeactivationConnectionFailed")
        case .sleep: return tr("sessionDeactivationSleep")
        case .appUpdate: return tr("sessionDeactivationAppUpdate")
        case .internalError: return tr("sessionDeactivationInternalError")
        case .endedUnexpectedly: return tr("sessionDeactivationEndedUnexpectedly")
        }
    }

    // MARK: - UITableViewDataSource

    override func numberOfSections(in tableView: UITableView) -> Int {
        return sections.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch sections[section] {
        case .summary: return summaryRows().count
        case .traffic: return trafficRows().count
        case .failover: return record.failoverEvents.count
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch sections[section] {
        case .summary: return tr("sessionDetailSectionSummary")
        case .traffic: return tr("sessionDetailSectionTraffic")
        case .failover: return tr("sessionDetailSectionFailoverEvents")
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell: KeyValueCell = tableView.dequeueReusableCell(for: indexPath)
        cell.copyableGesture = false
        let pair: (String, String)
        switch sections[indexPath.section] {
        case .summary: pair = summaryRows()[indexPath.row]
        case .traffic: pair = trafficRows()[indexPath.row]
        case .failover: pair = eventRow(record.failoverEvents[indexPath.row])
        }
        cell.key = pair.0
        cell.value = pair.1
        return cell
    }
}
