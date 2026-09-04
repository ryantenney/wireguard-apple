// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import Cocoa

/// The "nerd view" sheet: every fact the app and the Network Extension know about a
/// tunnel, failover group, or tunnel-in-tunnel group. Polls the extension every two
/// seconds while the tunnel is active.
class ConnectionDiagnosticsViewController: NSViewController {

    private struct Row {
        let key: String
        let value: String
        let isHeader: Bool
    }

    private enum DetailColumn: String {
        case key = "Key"
        case value = "Value"

        func matches(_ tableColumn: NSTableColumn?) -> Bool {
            tableColumn?.identifier.rawValue == rawValue
        }
    }

    private let tunnelsManager: TunnelsManager
    private let tunnel: TunnelContainer
    private let model: ConnectionDiagnosticsModel

    private var rows: [Row] = []
    private var pollTimer: Timer?
    private var statusObservationToken: AnyObject?
    private var isPollInFlight = false

    private let tableView: NSTableView = {
        let tableView = NSTableView()
        let keyColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(DetailColumn.key.rawValue))
        keyColumn.title = ""
        keyColumn.width = 190
        keyColumn.resizingMask = []
        tableView.addTableColumn(keyColumn)
        let valueColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(DetailColumn.value.rawValue))
        valueColumn.title = ""
        valueColumn.minWidth = 300
        valueColumn.resizingMask = .autoresizingMask
        tableView.addTableColumn(valueColumn)
        tableView.headerView = nil
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsColumnReordering = false
        tableView.allowsColumnResizing = true
        tableView.usesAutomaticRowHeights = true
        tableView.selectionHighlightStyle = .none
        return tableView
    }()

    private let scrollView: NSScrollView = {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        return scrollView
    }()

    private let titleLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 2)
        return label
    }()

    private let statusLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        return label
    }()

    private let copyButton: NSButton = {
        let button = NSButton()
        button.title = "Copy"
        button.bezelStyle = .rounded
        button.toolTip = "Copy all connection details as text"
        return button
    }()

    private let closeButton: NSButton = {
        let button = NSButton()
        button.title = tr("macLogButtonTitleClose")
        button.bezelStyle = .rounded
        button.keyEquivalent = "\r"
        return button
    }()

    init(tunnelsManager: TunnelsManager, tunnel: TunnelContainer) {
        self.tunnelsManager = tunnelsManager
        self.tunnel = tunnel
        self.model = ConnectionDiagnosticsModel(tunnel: tunnel)
        super.init(nibName: nil, bundle: nil)

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

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        tableView.dataSource = self
        tableView.delegate = self

        copyButton.target = self
        copyButton.action = #selector(copyClicked)
        closeButton.target = self
        closeButton.action = #selector(closeClicked)

        let clipView = NSClipView()
        clipView.documentView = tableView
        scrollView.contentView = clipView

        titleLabel.stringValue = "\(tunnel.name) — Connection Details"

        let headerRow = NSStackView(views: [titleLabel, statusLabel])
        headerRow.orientation = .vertical
        headerRow.alignment = .leading
        headerRow.spacing = 2

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.addView(copyButton, in: .leading)
        buttonRow.addView(closeButton, in: .trailing)

        let margin: CGFloat = 20
        let internalSpacing: CGFloat = 10

        let containerView = NSView()
        [headerRow, scrollView, buttonRow].forEach { subview in
            containerView.addSubview(subview)
            subview.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            headerRow.topAnchor.constraint(equalTo: containerView.topAnchor, constant: margin),
            headerRow.leftAnchor.constraint(equalTo: containerView.leftAnchor, constant: margin),
            containerView.rightAnchor.constraint(equalTo: headerRow.rightAnchor, constant: margin),
            scrollView.topAnchor.constraint(equalTo: headerRow.bottomAnchor, constant: internalSpacing),
            scrollView.leftAnchor.constraint(equalTo: containerView.leftAnchor, constant: margin),
            containerView.rightAnchor.constraint(equalTo: scrollView.rightAnchor, constant: margin),
            buttonRow.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: internalSpacing),
            buttonRow.leftAnchor.constraint(equalTo: containerView.leftAnchor, constant: margin),
            containerView.rightAnchor.constraint(equalTo: buttonRow.rightAnchor, constant: margin),
            containerView.bottomAnchor.constraint(equalTo: buttonRow.bottomAnchor, constant: margin)
        ])
        NSLayoutConstraint.activate([
            containerView.widthAnchor.constraint(greaterThanOrEqualToConstant: 600),
            containerView.heightAnchor.constraint(greaterThanOrEqualToConstant: 420)
        ])
        containerView.frame = NSRect(x: 0, y: 0, width: 640, height: 560)
        view = containerView

        rebuild()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        if tunnel.status == .active {
            startPolling()
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
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

    private func rebuild() {
        var newRows: [Row] = []
        for section in model.sections() {
            newRows.append(Row(key: section.title, value: "", isHeader: true))
            for row in section.rows {
                newRows.append(Row(key: row.key, value: row.value, isHeader: false))
            }
        }
        let sameShape = newRows.count == rows.count && zip(newRows, rows).allSatisfy { $0.isHeader == $1.isHeader }
        rows = newRows

        guard isViewLoaded else { return }
        if let receivedAt = model.receivedAt {
            statusLabel.stringValue = "\(ConnectionDiagnosticsModel.statusDescription(for: tunnel)) · updated \(FormattingHelpers.prettyTime(receivedAt))"
        } else {
            statusLabel.stringValue = ConnectionDiagnosticsModel.statusDescription(for: tunnel)
        }

        if sameShape {
            // Update cell contents in place; reloading the whole table resets text selection.
            let visibleRows = tableView.rows(in: tableView.visibleRect)
            guard visibleRows.length > 0 else { return }
            tableView.reloadData(forRowIndexes: IndexSet(integersIn: visibleRows.location ..< visibleRows.location + visibleRows.length),
                                 columnIndexes: IndexSet(integersIn: 0 ..< tableView.numberOfColumns))
        } else {
            tableView.reloadData()
        }
    }

    @objc private func copyClicked() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(model.plainTextReport(), forType: .string)
    }

    @objc private func closeClicked() {
        presentingViewController?.dismiss(self)
    }
}

extension ConnectionDiagnosticsViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        return rows.count
    }
}

extension ConnectionDiagnosticsViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let entry = rows[row]
        let identifier = NSUserInterfaceItemIdentifier("ConnectionDiagnosticsCell")
        let textField: NSTextField
        if let existing = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTextField {
            textField = existing
        } else {
            textField = NSTextField(labelWithString: "")
            textField.identifier = identifier
            textField.lineBreakMode = .byWordWrapping
            textField.maximumNumberOfLines = 0
            textField.isSelectable = true
        }
        if DetailColumn.key.matches(tableColumn) {
            textField.stringValue = entry.key
            textField.font = entry.isHeader ? .boldSystemFont(ofSize: NSFont.systemFontSize) : .systemFont(ofSize: NSFont.systemFontSize)
            textField.textColor = .labelColor
        } else {
            textField.stringValue = entry.value
            textField.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .regular)
            textField.textColor = entry.isHeader ? .labelColor : .secondaryLabelColor
        }
        return textField
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        return false
    }
}

extension ConnectionDiagnosticsViewController {
    override func cancelOperation(_ sender: Any?) {
        closeClicked()
    }
}
