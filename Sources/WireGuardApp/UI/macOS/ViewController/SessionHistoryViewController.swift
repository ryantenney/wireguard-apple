// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import Cocoa

class SessionHistoryViewController: NSViewController {

    private enum HistoryColumn: String {
        case started = "Started"
        case tunnel = "Tunnel"
        case duration = "Duration"
        case rxBytes = "RX"
        case txBytes = "TX"
        case reason = "Reason"

        func makeColumn() -> NSTableColumn {
            return NSTableColumn(identifier: NSUserInterfaceItemIdentifier(rawValue))
        }

        func matches(_ tableColumn: NSTableColumn?) -> Bool {
            return tableColumn?.identifier.rawValue == rawValue
        }
    }

    private var records: [SessionRecord] = []

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private let durationFormatter: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.hour, .minute, .second]
        f.unitsStyle = .abbreviated
        f.maximumUnitCount = 2
        return f
    }()

    private let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .binary
        return f
    }()

    private let scrollView: NSScrollView = {
        let sv = NSScrollView()
        sv.hasVerticalScroller = true
        sv.autohidesScrollers = false
        sv.borderType = .bezelBorder
        return sv
    }()

    private let tableView: NSTableView = {
        let tv = NSTableView()
        // swiftlint:disable:next large_tuple
        let cols: [(HistoryColumn, String, CGFloat, NSTableColumn.ResizingOptions)] = [
            (.started, tr("sessionDetailLabelStarted"), 160, []),
            (.tunnel, tr("sessionDetailLabelTunnel"), 140, .autoresizingMask),
            (.duration, tr("sessionDetailLabelDuration"), 90, []),
            (.rxBytes, tr("sessionDetailLabelRxBytes"), 90, []),
            (.txBytes, tr("sessionDetailLabelTxBytes"), 90, []),
            (.reason, tr("sessionDetailLabelDeactivation"), 160, .autoresizingMask)
        ]
        for (col, title, width, mask) in cols {
            let column = col.makeColumn()
            column.title = title
            column.width = width
            column.resizingMask = mask
            tv.addTableColumn(column)
        }
        tv.usesAlternatingRowBackgroundColors = true
        tv.allowsColumnReordering = false
        tv.allowsColumnResizing = true
        tv.allowsMultipleSelection = false
        return tv
    }()

    private let closeButton: NSButton = {
        let button = NSButton()
        button.title = tr("macLogButtonTitleClose")
        button.bezelStyle = .rounded
        return button
    }()

    private let clearButton: NSButton = {
        let button = NSButton()
        button.title = tr("sessionHistoryClearButtonTitle")
        button.bezelStyle = .rounded
        return button
    }()

    private let recordingCheckbox: NSButton = {
        let checkbox = NSButton()
        checkbox.title = tr("settingsSessionHistoryRecording")
        checkbox.setButtonType(.switch)
        checkbox.state = SessionHistoryStore.isRecordingEnabled ? .on : .off
        return checkbox
    }()

    private let emptyLabel: NSTextField = {
        let label = NSTextField(labelWithString: tr("sessionHistoryEmptyMessage"))
        label.alignment = .center
        label.textColor = .secondaryLabelColor
        return label
    }()

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked)

        closeButton.target = self
        closeButton.action = #selector(closeClicked)

        clearButton.target = self
        clearButton.action = #selector(clearClicked)

        recordingCheckbox.target = self
        recordingCheckbox.action = #selector(recordingToggled)

        let clipView = NSClipView()
        clipView.documentView = tableView
        scrollView.contentView = clipView

        let buttonRow = NSStackView()
        buttonRow.addView(closeButton, in: .leading)
        buttonRow.addView(recordingCheckbox, in: .center)
        buttonRow.addView(clearButton, in: .trailing)
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10

        let margin: CGFloat = 20
        let internalSpacing: CGFloat = 10

        let containerView = NSView()
        [scrollView, emptyLabel, buttonRow].forEach { v in
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
            containerView.bottomAnchor.constraint(equalTo: buttonRow.bottomAnchor, constant: margin),
            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor)
        ])

        NSLayoutConstraint.activate([
            containerView.widthAnchor.constraint(greaterThanOrEqualToConstant: 760),
            containerView.heightAnchor.constraint(greaterThanOrEqualToConstant: 360)
        ])

        containerView.frame = NSRect(x: 0, y: 0, width: 760, height: 480)
        view = containerView

        reload()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        reload()
    }

    private func reload() {
        records = SessionHistoryStore.loadAll()
        tableView.reloadData()
        emptyLabel.isHidden = !records.isEmpty
        clearButton.isEnabled = !records.isEmpty
    }

    @objc private func closeClicked() {
        presentingViewController?.dismiss(self)
    }

    @objc private func recordingToggled() {
        SessionHistoryStore.isRecordingEnabled = (recordingCheckbox.state == .on)
    }

    @objc private func clearClicked() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = tr("sessionHistoryClearConfirmTitle")
        alert.informativeText = tr("sessionHistoryClearConfirmMessage")
        alert.addButton(withTitle: tr("sessionHistoryClearButtonTitle"))
        alert.addButton(withTitle: tr("actionCancel"))
        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn {
                SessionHistoryStore.clear()
                self?.reload()
            }
        }
    }

    @objc private func rowDoubleClicked() {
        let row = tableView.clickedRow
        guard records.indices.contains(row) else { return }
        let detail = SessionDetailViewController(record: records[row])
        presentAsSheet(detail)
    }

    private func cellText(for record: SessionRecord, column: HistoryColumn) -> String {
        switch column {
        case .started:
            return dateFormatter.string(from: record.startedAt)
        case .tunnel:
            return record.tunnelName
        case .duration:
            if record.endedAt == nil { return tr("sessionStatusInProgress") }
            return durationFormatter.string(from: record.duration) ?? ""
        case .rxBytes:
            return byteFormatter.string(fromByteCount: Int64(record.rxBytes))
        case .txBytes:
            return byteFormatter.string(fromByteCount: Int64(record.txBytes))
        case .reason:
            return SessionLocalization.deactivation(record.deactivationReason)
        }
    }
}

extension SessionHistoryViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        return records.count
    }
}

extension SessionHistoryViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("SessionHistoryCell")
        let textField: NSTextField
        if let existing = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTextField {
            textField = existing
        } else {
            textField = NSTextField(labelWithString: "")
            textField.identifier = identifier
            textField.lineBreakMode = .byTruncatingTail
        }
        guard records.indices.contains(row) else { return textField }
        let record = records[row]
        for col in [HistoryColumn.started, .tunnel, .duration, .rxBytes, .txBytes, .reason] where col.matches(tableColumn) {
            textField.stringValue = cellText(for: record, column: col)
            return textField
        }
        return textField
    }
}

extension SessionHistoryViewController {
    override func cancelOperation(_ sender: Any?) {
        closeClicked()
    }
}

/// Shared localization helpers for session reasons (used by both list and detail views).
enum SessionLocalization {
    static func activation(_ reason: ActivationReason) -> String {
        switch reason {
        case .manual: return tr("sessionActivationManual")
        case .onDemand: return tr("sessionActivationOnDemand")
        case .unknown: return tr("sessionActivationUnknown")
        }
    }

    static func deactivation(_ reason: DeactivationReason?) -> String {
        guard let reason = reason else { return "" }
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
}
