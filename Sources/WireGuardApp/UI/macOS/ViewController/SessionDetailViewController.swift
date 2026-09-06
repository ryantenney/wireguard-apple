// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import Cocoa

class SessionDetailViewController: NSViewController {

    private struct Row {
        let key: String
        let value: String
        let isHeader: Bool
    }

    private let record: SessionRecord
    private var rows: [Row] = []

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

    private enum DetailColumn: String {
        case key = "Key"
        case value = "Value"

        func matches(_ tableColumn: NSTableColumn?) -> Bool {
            tableColumn?.identifier.rawValue == rawValue
        }
    }

    private let tableView: NSTableView = {
        let tv = NSTableView()
        let keyColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(DetailColumn.key.rawValue))
        keyColumn.title = ""
        keyColumn.width = 160
        keyColumn.resizingMask = []
        tv.addTableColumn(keyColumn)
        let valueColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(DetailColumn.value.rawValue))
        valueColumn.title = ""
        valueColumn.minWidth = 240
        valueColumn.resizingMask = .autoresizingMask
        tv.addTableColumn(valueColumn)
        tv.headerView = nil
        tv.usesAlternatingRowBackgroundColors = false
        tv.allowsColumnReordering = false
        tv.allowsColumnResizing = true
        tv.usesAutomaticRowHeights = true
        return tv
    }()

    private let scrollView: NSScrollView = {
        let sv = NSScrollView()
        sv.hasVerticalScroller = true
        sv.borderType = .bezelBorder
        return sv
    }()

    private let closeButton: NSButton = {
        let b = NSButton()
        b.title = tr("macLogButtonTitleClose")
        b.bezelStyle = .rounded
        return b
    }()

    init(record: SessionRecord) {
        self.record = record
        super.init(nibName: nil, bundle: nil)
        rows = buildRows()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        tableView.dataSource = self
        tableView.delegate = self

        closeButton.target = self
        closeButton.action = #selector(closeClicked)

        let clipView = NSClipView()
        clipView.documentView = tableView
        scrollView.contentView = clipView

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.addView(closeButton, in: .trailing)

        let margin: CGFloat = 20
        let internalSpacing: CGFloat = 10

        let containerView = NSView()
        [scrollView, buttonRow].forEach { v in
            containerView.addSubview(v)
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: containerView.topAnchor, constant: margin),
            scrollView.leftAnchor.constraint(equalTo: containerView.leftAnchor, constant: margin),
            containerView.rightAnchor.constraint(equalTo: scrollView.rightAnchor, constant: margin),
            buttonRow.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: internalSpacing),
            buttonRow.leftAnchor.constraint(equalTo: containerView.leftAnchor, constant: margin),
            containerView.rightAnchor.constraint(equalTo: buttonRow.rightAnchor, constant: margin),
            containerView.bottomAnchor.constraint(equalTo: buttonRow.bottomAnchor, constant: margin)
        ])
        NSLayoutConstraint.activate([
            containerView.widthAnchor.constraint(greaterThanOrEqualToConstant: 520),
            containerView.heightAnchor.constraint(greaterThanOrEqualToConstant: 360)
        ])
        containerView.frame = NSRect(x: 0, y: 0, width: 520, height: 420)
        view = containerView
    }

    private func buildRows() -> [Row] {
        var rows: [Row] = []

        rows.append(Row(key: tr("sessionDetailSectionSummary"), value: "", isHeader: true))
        rows.append(Row(key: tr("sessionDetailLabelTunnel"), value: record.tunnelName, isHeader: false))
        rows.append(Row(key: tr("sessionDetailLabelStarted"), value: dateFormatter.string(from: record.startedAt), isHeader: false))
        let endedText = record.endedAt.map { dateFormatter.string(from: $0) } ?? tr("sessionStatusInProgress")
        rows.append(Row(key: tr("sessionDetailLabelEnded"), value: endedText, isHeader: false))
        rows.append(Row(key: tr("sessionDetailLabelDuration"), value: durationFormatter.string(from: record.duration) ?? "", isHeader: false))
        rows.append(Row(key: tr("sessionDetailLabelActivation"), value: SessionLocalization.activation(record.activationReason), isHeader: false))
        if record.deactivationReason != nil {
            rows.append(Row(key: tr("sessionDetailLabelDeactivation"), value: SessionLocalization.deactivation(record.deactivationReason), isHeader: false))
        }
        if let initial = record.initialActiveConfigName {
            rows.append(Row(key: tr("sessionDetailLabelInitialConfig"), value: initial, isHeader: false))
        }

        rows.append(Row(key: tr("sessionDetailSectionTraffic"), value: "", isHeader: true))
        rows.append(Row(key: tr("sessionDetailLabelRxBytes"), value: byteFormatter.string(fromByteCount: Int64(record.rxBytes)), isHeader: false))
        rows.append(Row(key: tr("sessionDetailLabelTxBytes"), value: byteFormatter.string(fromByteCount: Int64(record.txBytes)), isHeader: false))

        if !record.failoverEvents.isEmpty {
            rows.append(Row(key: tr("sessionDetailSectionFailoverEvents"), value: "", isHeader: true))
            let timeFormatter = DateFormatter()
            timeFormatter.dateStyle = .none
            timeFormatter.timeStyle = .medium
            for event in record.failoverEvents {
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
                rows.append(Row(key: timeFormatter.string(from: event.timestamp), value: detail, isHeader: false))
            }
        }
        return rows
    }

    @objc private func closeClicked() {
        presentingViewController?.dismiss(self)
    }
}

extension SessionDetailViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        return rows.count
    }
}

extension SessionDetailViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let entry = rows[row]
        let identifier = NSUserInterfaceItemIdentifier("SessionDetailCell")
        let textField: NSTextField
        if let existing = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTextField {
            textField = existing
        } else {
            textField = NSTextField(labelWithString: "")
            textField.identifier = identifier
            textField.lineBreakMode = .byWordWrapping
            textField.maximumNumberOfLines = 0
        }
        if DetailColumn.key.matches(tableColumn) {
            textField.stringValue = entry.key
            textField.font = entry.isHeader ? .boldSystemFont(ofSize: NSFont.systemFontSize) : .systemFont(ofSize: NSFont.systemFontSize)
        } else {
            textField.stringValue = entry.value
            textField.font = .systemFont(ofSize: NSFont.systemFontSize)
        }
        return textField
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        return false
    }
}

extension SessionDetailViewController {
    override func cancelOperation(_ sender: Any?) {
        closeClicked()
    }
}
