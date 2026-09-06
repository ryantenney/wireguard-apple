// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import Cocoa
import NetworkExtension

protocol FailoverGroupEditViewControllerDelegate: AnyObject {
    func failoverGroupSaved(tunnel: TunnelContainer)
    func failoverGroupEditingCancelled()
}

class FailoverGroupEditViewController: NSViewController {

    let tunnelsManager: TunnelsManager
    let tunnel: TunnelContainer?

    weak var delegate: FailoverGroupEditViewControllerDelegate?

    private var selectedTunnelNames: [String]
    private var trafficTimeout: TimeInterval
    private var healthCheckInterval: TimeInterval
    private var failbackProbeInterval: TimeInterval
    private var autoFailback: Bool
    private var useBackgroundProbes: Bool
    private var hotSpare: Bool
    private var persistentKeepaliveOverride: UInt16?
    private var confirmBeforeFailover: Bool
    private var confirmationTimeout: TimeInterval
    private var linkDownHoldTime: TimeInterval
    private var adaptiveSensitivity: Bool
    private var pathChangeGrace: TimeInterval
    private var onDemandViewModel: ActivateOnDemandViewModel

    // UI elements

    let nameRow: EditableKeyValueRow = {
        let row = EditableKeyValueRow()
        row.key = tr(format: "macFieldKey (%@)", tr("tunnelInterfaceName"))
        return row
    }()

    let connectionsLabel: NSTextField = {
        let label = NSTextField()
        label.stringValue = "Connections (in priority order):"
        label.isEditable = false
        label.isSelectable = false
        label.isBordered = false
        label.backgroundColor = .clear
        label.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
        return label
    }()

    let connectionsTableView: NSTableView = {
        let tableView = NSTableView()
        tableView.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ConnectionName")))
        tableView.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ConnectionRole")))
        tableView.headerView = nil
        tableView.rowSizeStyle = .small
        tableView.allowsMultipleSelection = false
        return tableView
    }()

    let addTunnelButton: NSButton = {
        let button = NSButton(image: NSImage(named: NSImage.addTemplateName)!, target: nil, action: nil)
        button.bezelStyle = .smallSquare
        button.imagePosition = .imageOnly
        return button
    }()

    let removeTunnelButton: NSButton = {
        let button = NSButton(image: NSImage(named: NSImage.removeTemplateName)!, target: nil, action: nil)
        button.bezelStyle = .smallSquare
        button.imagePosition = .imageOnly
        return button
    }()

    let moveUpButton: NSButton = {
        let button = NSButton()
        button.title = "\u{25B2}" // Up arrow
        button.bezelStyle = .smallSquare
        button.font = NSFont.systemFont(ofSize: 10)
        return button
    }()

    let moveDownButton: NSButton = {
        let button = NSButton()
        button.title = "\u{25BC}" // Down arrow
        button.bezelStyle = .smallSquare
        button.font = NSFont.systemFont(ofSize: 10)
        return button
    }()

    let trafficTimeoutRow: EditableKeyValueRow = {
        let row = EditableKeyValueRow()
        row.key = tr(format: "macFieldKey (%@)", "Traffic Timeout (s)")
        return row
    }()

    let healthCheckIntervalRow: EditableKeyValueRow = {
        let row = EditableKeyValueRow()
        row.key = tr(format: "macFieldKey (%@)", "Health Check (s)")
        return row
    }()

    let failbackProbeIntervalRow: EditableKeyValueRow = {
        let row = EditableKeyValueRow()
        row.key = tr(format: "macFieldKey (%@)", "Failback Probe (s)")
        return row
    }()

    let autoFailbackCheckbox: NSButton = {
        let checkbox = NSButton()
        checkbox.title = "Auto Failback"
        checkbox.setButtonType(.switch)
        checkbox.state = .on
        return checkbox
    }()

    let autoFailbackRow: NSView = {
        let view = NSView()
        return view
    }()

    let useBackgroundProbesCheckbox: NSButton = {
        let checkbox = NSButton()
        checkbox.title = "Background Probes"
        checkbox.setButtonType(.switch)
        checkbox.state = .on
        return checkbox
    }()

    let useBackgroundProbesRow: NSView = {
        let view = NSView()
        return view
    }()

    let hotSpareCheckbox: NSButton = {
        let checkbox = NSButton()
        checkbox.title = "Hot Spare"
        checkbox.setButtonType(.switch)
        checkbox.state = .off
        return checkbox
    }()

    let hotSpareRow: NSView = {
        let view = NSView()
        return view
    }()

    let persistentKeepaliveCheckbox: NSButton = {
        let checkbox = NSButton()
        checkbox.title = "Override Persistent Keepalive"
        checkbox.setButtonType(.switch)
        checkbox.state = .off
        return checkbox
    }()

    let confirmBeforeFailoverCheckbox: NSButton = {
        let checkbox = NSButton()
        checkbox.title = "Confirm Before Failover"
        checkbox.setButtonType(.switch)
        checkbox.state = .on
        checkbox.toolTip = "Require the next server to handshake before switching; hold if no server answers (likely a link outage)."
        return checkbox
    }()

    let confirmBeforeFailoverRow: NSView = {
        let view = NSView()
        return view
    }()

    let confirmationTimeoutRow: EditableKeyValueRow = {
        let row = EditableKeyValueRow()
        row.key = tr(format: "macFieldKey (%@)", "Confirm Timeout (s)")
        return row
    }()

    let linkDownHoldTimeRow: EditableKeyValueRow = {
        let row = EditableKeyValueRow()
        row.key = tr(format: "macFieldKey (%@)", "Link-Down Hold (s)")
        row.valueLabel.toolTip = "How long to hold failover while no server is reachable. 0 = forever."
        return row
    }()

    let adaptiveSensitivityCheckbox: NSButton = {
        let checkbox = NSButton()
        checkbox.title = "Adaptive Sensitivity"
        checkbox.setButtonType(.switch)
        checkbox.state = .on
        checkbox.toolTip = "Lengthen the traffic timeout after outages that turned out to be the link, relaxing again after a quiet half hour."
        return checkbox
    }()

    let adaptiveSensitivityRow: NSView = {
        let view = NSView()
        return view
    }()

    let pathChangeGraceRow: EditableKeyValueRow = {
        let row = EditableKeyValueRow()
        row.key = tr(format: "macFieldKey (%@)", "Path Change Grace (s)")
        return row
    }()

    let persistentKeepaliveRow: NSView = {
        let view = NSView()
        return view
    }()

    let persistentKeepaliveValueRow: EditableKeyValueRow = {
        let row = EditableKeyValueRow()
        row.key = tr(format: "macFieldKey (%@)", "Keepalive (s)")
        return row
    }()

    let onDemandControlsRow = OnDemandControlsRow()

    let discardButton: NSButton = {
        let button = NSButton()
        button.title = tr("macEditDiscard")
        button.setButtonType(.momentaryPushIn)
        button.bezelStyle = .rounded
        return button
    }()

    let saveButton: NSButton = {
        let button = NSButton()
        button.title = tr("macEditSave")
        button.setButtonType(.momentaryPushIn)
        button.bezelStyle = .rounded
        button.keyEquivalent = "s"
        button.keyEquivalentModifierMask = [.command]
        return button
    }()

    let deleteButton: NSButton = {
        let button = NSButton()
        button.title = "Delete Failover Group"
        button.setButtonType(.momentaryPushIn)
        button.bezelStyle = .rounded
        button.contentTintColor = .systemRed
        return button
    }()

    init(tunnelsManager: TunnelsManager, tunnel: TunnelContainer?) {
        self.tunnelsManager = tunnelsManager
        self.tunnel = tunnel

        if let tunnel = tunnel,
           let proto = tunnel.tunnelProvider.protocolConfiguration as? NETunnelProviderProtocol {
            let providerConfig = proto.providerConfiguration ?? [:]
            self.selectedTunnelNames = (providerConfig["FailoverConfigNames"] as? [String]) ?? []
            var settings = FailoverSettings()
            if let settingsData = providerConfig["FailoverSettings"] as? Data {
                settings = (try? JSONDecoder().decode(FailoverSettings.self, from: settingsData)) ?? FailoverSettings()
            }
            self.trafficTimeout = settings.trafficTimeout
            self.healthCheckInterval = settings.healthCheckInterval
            self.failbackProbeInterval = settings.failbackProbeInterval
            self.autoFailback = settings.autoFailback
            self.useBackgroundProbes = settings.useBackgroundProbes
            self.hotSpare = settings.hotSpare
            self.persistentKeepaliveOverride = settings.persistentKeepaliveOverride
            self.confirmBeforeFailover = settings.confirmBeforeFailover
            self.confirmationTimeout = settings.confirmationTimeout
            self.linkDownHoldTime = settings.linkDownHoldTime
            self.adaptiveSensitivity = settings.adaptiveSensitivity
            self.pathChangeGrace = settings.pathChangeGrace
            self.onDemandViewModel = ActivateOnDemandViewModel(tunnel: tunnel)
        } else {
            let defaults = FailoverSettings()
            self.selectedTunnelNames = []
            self.trafficTimeout = defaults.trafficTimeout
            self.healthCheckInterval = defaults.healthCheckInterval
            self.failbackProbeInterval = defaults.failbackProbeInterval
            self.autoFailback = defaults.autoFailback
            self.useBackgroundProbes = defaults.useBackgroundProbes
            self.hotSpare = defaults.hotSpare
            self.persistentKeepaliveOverride = defaults.persistentKeepaliveOverride
            self.confirmBeforeFailover = defaults.confirmBeforeFailover
            self.confirmationTimeout = defaults.confirmationTimeout
            self.linkDownHoldTime = defaults.linkDownHoldTime
            self.adaptiveSensitivity = defaults.adaptiveSensitivity
            self.pathChangeGrace = defaults.pathChangeGrace
            self.onDemandViewModel = ActivateOnDemandViewModel(from: OnDemandActivation())
        }

        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        populateFields()

        connectionsTableView.dataSource = self
        connectionsTableView.delegate = self

        saveButton.target = self
        saveButton.action = #selector(handleSaveAction)

        discardButton.target = self
        discardButton.action = #selector(handleDiscardAction)

        deleteButton.target = self
        deleteButton.action = #selector(handleDeleteAction)

        addTunnelButton.target = self
        addTunnelButton.action = #selector(handleAddTunnelAction)

        removeTunnelButton.target = self
        removeTunnelButton.action = #selector(handleRemoveTunnelAction)

        moveUpButton.target = self
        moveUpButton.action = #selector(handleMoveUpAction)

        moveDownButton.target = self
        moveDownButton.action = #selector(handleMoveDownAction)

        onDemandControlsRow.onDemandViewModel = onDemandViewModel

        // Auto failback row layout
        let autoFailbackKeyLabel = NSTextField()
        autoFailbackKeyLabel.stringValue = ""
        autoFailbackKeyLabel.isEditable = false
        autoFailbackKeyLabel.isSelectable = false
        autoFailbackKeyLabel.isBordered = false
        autoFailbackKeyLabel.backgroundColor = .clear

        autoFailbackRow.addSubview(autoFailbackKeyLabel)
        autoFailbackRow.addSubview(autoFailbackCheckbox)
        autoFailbackKeyLabel.translatesAutoresizingMaskIntoConstraints = false
        autoFailbackCheckbox.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            autoFailbackKeyLabel.leadingAnchor.constraint(equalTo: autoFailbackRow.leadingAnchor),
            autoFailbackKeyLabel.widthAnchor.constraint(equalToConstant: 155),
            autoFailbackCheckbox.leadingAnchor.constraint(equalTo: autoFailbackKeyLabel.trailingAnchor),
            autoFailbackCheckbox.centerYAnchor.constraint(equalTo: autoFailbackRow.centerYAnchor),
            autoFailbackRow.topAnchor.constraint(equalTo: autoFailbackCheckbox.topAnchor),
            autoFailbackRow.bottomAnchor.constraint(equalTo: autoFailbackCheckbox.bottomAnchor)
        ])

        layoutCheckboxRow(confirmBeforeFailoverCheckbox, in: confirmBeforeFailoverRow)
        layoutCheckboxRow(adaptiveSensitivityCheckbox, in: adaptiveSensitivityRow)

        // Background probes row layout
        let bgProbesKeyLabel = NSTextField()
        bgProbesKeyLabel.stringValue = ""
        bgProbesKeyLabel.isEditable = false
        bgProbesKeyLabel.isSelectable = false
        bgProbesKeyLabel.isBordered = false
        bgProbesKeyLabel.backgroundColor = .clear

        useBackgroundProbesRow.addSubview(bgProbesKeyLabel)
        useBackgroundProbesRow.addSubview(useBackgroundProbesCheckbox)
        bgProbesKeyLabel.translatesAutoresizingMaskIntoConstraints = false
        useBackgroundProbesCheckbox.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            bgProbesKeyLabel.leadingAnchor.constraint(equalTo: useBackgroundProbesRow.leadingAnchor),
            bgProbesKeyLabel.widthAnchor.constraint(equalToConstant: 155),
            useBackgroundProbesCheckbox.leadingAnchor.constraint(equalTo: bgProbesKeyLabel.trailingAnchor),
            useBackgroundProbesCheckbox.centerYAnchor.constraint(equalTo: useBackgroundProbesRow.centerYAnchor),
            useBackgroundProbesRow.topAnchor.constraint(equalTo: useBackgroundProbesCheckbox.topAnchor),
            useBackgroundProbesRow.bottomAnchor.constraint(equalTo: useBackgroundProbesCheckbox.bottomAnchor)
        ])

        // Hot spare row layout
        let hotSpareKeyLabel = NSTextField()
        hotSpareKeyLabel.stringValue = ""
        hotSpareKeyLabel.isEditable = false
        hotSpareKeyLabel.isSelectable = false
        hotSpareKeyLabel.isBordered = false
        hotSpareKeyLabel.backgroundColor = .clear

        hotSpareRow.addSubview(hotSpareKeyLabel)
        hotSpareRow.addSubview(hotSpareCheckbox)
        hotSpareKeyLabel.translatesAutoresizingMaskIntoConstraints = false
        hotSpareCheckbox.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hotSpareKeyLabel.leadingAnchor.constraint(equalTo: hotSpareRow.leadingAnchor),
            hotSpareKeyLabel.widthAnchor.constraint(equalToConstant: 155),
            hotSpareCheckbox.leadingAnchor.constraint(equalTo: hotSpareKeyLabel.trailingAnchor),
            hotSpareCheckbox.centerYAnchor.constraint(equalTo: hotSpareRow.centerYAnchor),
            hotSpareRow.topAnchor.constraint(equalTo: hotSpareCheckbox.topAnchor),
            hotSpareRow.bottomAnchor.constraint(equalTo: hotSpareCheckbox.bottomAnchor)
        ])

        // Persistent keepalive override row layout
        let keepaliveKeyLabel = NSTextField()
        keepaliveKeyLabel.stringValue = ""
        keepaliveKeyLabel.isEditable = false
        keepaliveKeyLabel.isSelectable = false
        keepaliveKeyLabel.isBordered = false
        keepaliveKeyLabel.backgroundColor = .clear

        persistentKeepaliveRow.addSubview(keepaliveKeyLabel)
        persistentKeepaliveRow.addSubview(persistentKeepaliveCheckbox)
        keepaliveKeyLabel.translatesAutoresizingMaskIntoConstraints = false
        persistentKeepaliveCheckbox.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            keepaliveKeyLabel.leadingAnchor.constraint(equalTo: persistentKeepaliveRow.leadingAnchor),
            keepaliveKeyLabel.widthAnchor.constraint(equalToConstant: 155),
            persistentKeepaliveCheckbox.leadingAnchor.constraint(equalTo: keepaliveKeyLabel.trailingAnchor),
            persistentKeepaliveCheckbox.centerYAnchor.constraint(equalTo: persistentKeepaliveRow.centerYAnchor),
            persistentKeepaliveRow.topAnchor.constraint(equalTo: persistentKeepaliveCheckbox.topAnchor),
            persistentKeepaliveRow.bottomAnchor.constraint(equalTo: persistentKeepaliveCheckbox.bottomAnchor)
        ])

        persistentKeepaliveCheckbox.target = self
        persistentKeepaliveCheckbox.action = #selector(handleKeepaliveToggle)

        // Connections area
        let connectionsScrollView = NSScrollView()
        connectionsScrollView.hasVerticalScroller = true
        connectionsScrollView.autohidesScrollers = true
        connectionsScrollView.borderType = .bezelBorder
        let clipView = NSClipView()
        clipView.documentView = connectionsTableView
        connectionsScrollView.contentView = clipView

        NSLayoutConstraint.activate([
            connectionsScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 80),
            connectionsScrollView.heightAnchor.constraint(lessThanOrEqualToConstant: 160)
        ])

        let connectionButtonBar = NSStackView(views: [addTunnelButton, removeTunnelButton, moveUpButton, moveDownButton])
        connectionButtonBar.orientation = .horizontal
        connectionButtonBar.spacing = 2

        let connectionsArea = NSStackView(views: [connectionsLabel, connectionsScrollView, connectionButtonBar])
        connectionsArea.orientation = .vertical
        connectionsArea.spacing = 4
        connectionsArea.alignment = .leading
        NSLayoutConstraint.activate([
            connectionsScrollView.leadingAnchor.constraint(equalTo: connectionsArea.leadingAnchor),
            connectionsScrollView.trailingAnchor.constraint(equalTo: connectionsArea.trailingAnchor)
        ])

        // Settings label
        let settingsLabel = NSTextField()
        settingsLabel.stringValue = "Failover Settings:"
        settingsLabel.isEditable = false
        settingsLabel.isSelectable = false
        settingsLabel.isBordered = false
        settingsLabel.backgroundColor = .clear
        settingsLabel.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)

        let margin: CGFloat = 20
        let internalSpacing: CGFloat = 10

        var editorViews: [NSView] = [nameRow, connectionsArea, settingsLabel, trafficTimeoutRow, healthCheckIntervalRow, failbackProbeIntervalRow, autoFailbackRow, useBackgroundProbesRow, hotSpareRow,
                                     confirmBeforeFailoverRow, confirmationTimeoutRow, linkDownHoldTimeRow, adaptiveSensitivityRow, pathChangeGraceRow,
                                     persistentKeepaliveRow, persistentKeepaliveValueRow, onDemandControlsRow]

        let editorStackView = NSStackView(views: editorViews)
        editorStackView.orientation = .vertical
        editorStackView.setHuggingPriority(.defaultHigh, for: .horizontal)
        editorStackView.spacing = internalSpacing

        let buttonRowStackView = NSStackView()
        if tunnel != nil {
            buttonRowStackView.addView(deleteButton, in: .leading)
        }
        buttonRowStackView.setViews([discardButton, saveButton], in: .trailing)
        buttonRowStackView.orientation = .horizontal
        buttonRowStackView.spacing = internalSpacing

        let containerView = NSStackView(views: [editorStackView, buttonRowStackView])
        containerView.orientation = .vertical
        containerView.edgeInsets = NSEdgeInsets(top: margin, left: margin, bottom: margin, right: margin)
        containerView.setHuggingPriority(.defaultHigh, for: .horizontal)
        containerView.spacing = internalSpacing

        NSLayoutConstraint.activate([
            containerView.widthAnchor.constraint(greaterThanOrEqualToConstant: 400),
            containerView.heightAnchor.constraint(greaterThanOrEqualToConstant: 400)
        ])
        containerView.frame = NSRect(x: 0, y: 0, width: 600, height: 520)

        self.view = containerView
    }

    /// Lays out a checkbox in a row view, aligned with the value column of the key/value rows.
    private func layoutCheckboxRow(_ checkbox: NSButton, in row: NSView) {
        let keyLabel = NSTextField()
        keyLabel.stringValue = ""
        keyLabel.isEditable = false
        keyLabel.isSelectable = false
        keyLabel.isBordered = false
        keyLabel.backgroundColor = .clear

        row.addSubview(keyLabel)
        row.addSubview(checkbox)
        keyLabel.translatesAutoresizingMaskIntoConstraints = false
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            keyLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            keyLabel.widthAnchor.constraint(equalToConstant: 155),
            checkbox.leadingAnchor.constraint(equalTo: keyLabel.trailingAnchor),
            checkbox.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            row.topAnchor.constraint(equalTo: checkbox.topAnchor),
            row.bottomAnchor.constraint(equalTo: checkbox.bottomAnchor)
        ])
    }

    func populateFields() {
        nameRow.value = tunnel?.name ?? ""
        trafficTimeoutRow.value = "\(Int(trafficTimeout))"
        healthCheckIntervalRow.value = "\(Int(healthCheckInterval))"
        failbackProbeIntervalRow.value = "\(Int(failbackProbeInterval))"
        autoFailbackCheckbox.state = autoFailback ? .on : .off
        useBackgroundProbesCheckbox.state = useBackgroundProbes ? .on : .off
        hotSpareCheckbox.state = hotSpare ? .on : .off
        confirmBeforeFailoverCheckbox.state = confirmBeforeFailover ? .on : .off
        confirmationTimeoutRow.value = "\(Int(confirmationTimeout))"
        linkDownHoldTimeRow.value = "\(Int(linkDownHoldTime))"
        adaptiveSensitivityCheckbox.state = adaptiveSensitivity ? .on : .off
        pathChangeGraceRow.value = "\(Int(pathChangeGrace))"
        persistentKeepaliveCheckbox.state = persistentKeepaliveOverride != nil ? .on : .off
        persistentKeepaliveValueRow.value = "\(persistentKeepaliveOverride ?? 25)"
        persistentKeepaliveValueRow.isHidden = persistentKeepaliveOverride == nil
    }

    @objc func handleSaveAction() {
        let name = nameRow.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            ErrorPresenter.showErrorAlert(title: tr("macAlertNameIsEmpty"), message: "", from: self)
            return
        }
        guard selectedTunnelNames.count >= 2 else {
            ErrorPresenter.showErrorAlert(title: "A failover group needs at least 2 tunnels.", message: "", from: self)
            return
        }

        // Parse settings from text fields
        guard let timeout = TimeInterval(trafficTimeoutRow.value), timeout > 0 else {
            ErrorPresenter.showErrorAlert(title: "Invalid traffic timeout value.", message: "", from: self)
            return
        }
        guard let healthCheck = TimeInterval(healthCheckIntervalRow.value), healthCheck > 0 else {
            ErrorPresenter.showErrorAlert(title: "Invalid health check interval value.", message: "", from: self)
            return
        }
        guard let failbackProbe = TimeInterval(failbackProbeIntervalRow.value), failbackProbe > 0 else {
            ErrorPresenter.showErrorAlert(title: "Invalid failback probe interval value.", message: "", from: self)
            return
        }

        guard let confirmation = TimeInterval(confirmationTimeoutRow.value), confirmation > 0 else {
            ErrorPresenter.showErrorAlert(title: "Invalid confirmation timeout value.", message: "", from: self)
            return
        }
        guard let linkDownHold = TimeInterval(linkDownHoldTimeRow.value), linkDownHold >= 0 else {
            ErrorPresenter.showErrorAlert(title: "Invalid link-down hold value.", message: "", from: self)
            return
        }
        guard let pathGrace = TimeInterval(pathChangeGraceRow.value), pathGrace >= 0 else {
            ErrorPresenter.showErrorAlert(title: "Invalid path change grace value.", message: "", from: self)
            return
        }

        var keepaliveOverride: UInt16?
        if persistentKeepaliveCheckbox.state == .on {
            guard let keepalive = UInt16(persistentKeepaliveValueRow.value), keepalive > 0 else {
                ErrorPresenter.showErrorAlert(title: "Invalid keepalive interval value.", message: "", from: self)
                return
            }
            keepaliveOverride = keepalive
        }

        let settings = FailoverSettings(
            trafficTimeout: timeout,
            healthCheckInterval: healthCheck,
            failbackProbeInterval: failbackProbe,
            autoFailback: autoFailbackCheckbox.state == .on,
            useBackgroundProbes: useBackgroundProbesCheckbox.state == .on,
            hotSpare: hotSpareCheckbox.state == .on,
            persistentKeepaliveOverride: keepaliveOverride,
            confirmBeforeFailover: confirmBeforeFailoverCheckbox.state == .on,
            confirmationTimeout: confirmation,
            linkDownHoldTime: linkDownHold,
            adaptiveSensitivity: adaptiveSensitivityCheckbox.state == .on,
            pathChangeGrace: pathGrace
        )

        onDemandControlsRow.saveToViewModel()
        let onDemandActivation = onDemandViewModel.toOnDemandActivation()

        setUserInteractionEnabled(false)

        if let tunnel = tunnel {
            tunnelsManager.modifyFailoverGroup(
                tunnel: tunnel,
                name: name,
                tunnelNames: selectedTunnelNames,
                settings: settings,
                onDemandActivation: onDemandActivation
            ) { [weak self] error in
                guard let self = self else { return }
                self.setUserInteractionEnabled(true)
                if let error = error {
                    ErrorPresenter.showErrorAlert(error: error, from: self)
                    return
                }
                self.delegate?.failoverGroupSaved(tunnel: tunnel)
                self.presentingViewController?.dismiss(self)
            }
        } else {
            tunnelsManager.addFailoverGroup(
                name: name,
                tunnelNames: selectedTunnelNames,
                settings: settings,
                onDemandActivation: onDemandActivation
            ) { [weak self] result in
                guard let self = self else { return }
                self.setUserInteractionEnabled(true)
                switch result {
                case .failure(let error):
                    ErrorPresenter.showErrorAlert(error: error, from: self)
                case .success(let tunnel):
                    self.delegate?.failoverGroupSaved(tunnel: tunnel)
                    self.presentingViewController?.dismiss(self)
                }
            }
        }
    }

    @objc func handleKeepaliveToggle() {
        let isOn = persistentKeepaliveCheckbox.state == .on
        if isOn {
            persistentKeepaliveOverride = 25
            persistentKeepaliveValueRow.value = "25"
        } else {
            persistentKeepaliveOverride = nil
        }
        persistentKeepaliveValueRow.isHidden = !isOn
    }

    @objc func handleDiscardAction() {
        delegate?.failoverGroupEditingCancelled()
        presentingViewController?.dismiss(self)
    }

    @objc func handleDeleteAction() {
        guard let tunnel = tunnel, let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Delete Failover Group"
        alert.informativeText = "Are you sure you want to delete '\(tunnel.name)'? This won't delete the individual tunnels."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self = self, response == .alertFirstButtonReturn else { return }
            self.tunnelsManager.removeFailoverGroup(tunnel: tunnel) { [weak self] error in
                guard let self = self else { return }
                if let error = error {
                    ErrorPresenter.showErrorAlert(error: error, from: self)
                    return
                }
                self.presentingViewController?.dismiss(self)
            }
        }
    }

    @objc func handleAddTunnelAction() {
        let availableNames = tunnelsManager.mapTunnels { $0.name }.filter { !selectedTunnelNames.contains($0) }
        guard !availableNames.isEmpty else {
            ErrorPresenter.showErrorAlert(title: "All available tunnels are already in this group.", message: "", from: self)
            return
        }

        let menu = NSMenu()
        for name in availableNames {
            let item = NSMenuItem(title: name, action: #selector(tunnelPickerItemClicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = name
            menu.addItem(item)
        }

        let buttonFrame = addTunnelButton.convert(addTunnelButton.bounds, to: nil)
        let windowPoint = NSPoint(x: buttonFrame.origin.x, y: buttonFrame.origin.y)
        menu.popUp(positioning: nil, at: addTunnelButton.convert(NSPoint(x: 0, y: addTunnelButton.bounds.height), to: nil), in: addTunnelButton.window?.contentView)
    }

    @objc func tunnelPickerItemClicked(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        selectedTunnelNames.append(name)
        connectionsTableView.reloadData()
    }

    @objc func handleRemoveTunnelAction() {
        let selectedRow = connectionsTableView.selectedRow
        guard selectedRow >= 0 && selectedRow < selectedTunnelNames.count else { return }
        selectedTunnelNames.remove(at: selectedRow)
        connectionsTableView.reloadData()
    }

    @objc func handleMoveUpAction() {
        let selectedRow = connectionsTableView.selectedRow
        guard selectedRow > 0 else { return }
        selectedTunnelNames.swapAt(selectedRow, selectedRow - 1)
        connectionsTableView.reloadData()
        connectionsTableView.selectRowIndexes(IndexSet(integer: selectedRow - 1), byExtendingSelection: false)
    }

    @objc func handleMoveDownAction() {
        let selectedRow = connectionsTableView.selectedRow
        guard selectedRow >= 0 && selectedRow < selectedTunnelNames.count - 1 else { return }
        selectedTunnelNames.swapAt(selectedRow, selectedRow + 1)
        connectionsTableView.reloadData()
        connectionsTableView.selectRowIndexes(IndexSet(integer: selectedRow + 1), byExtendingSelection: false)
    }

    func setUserInteractionEnabled(_ enabled: Bool) {
        view.window?.ignoresMouseEvents = !enabled
    }
}

// MARK: - Cancel shortcut

extension FailoverGroupEditViewController {
    override func cancelOperation(_ sender: Any?) {
        handleDiscardAction()
    }
}

// MARK: - NSTableViewDataSource

extension FailoverGroupEditViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        return selectedTunnelNames.count
    }
}

// MARK: - NSTableViewDelegate

extension FailoverGroupEditViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn else { return nil }
        let label = NSTextField()
        label.isEditable = false
        label.isSelectable = false
        label.isBordered = false
        label.backgroundColor = .clear

        if column.identifier.rawValue == "ConnectionName" {
            label.stringValue = selectedTunnelNames[row]
        } else {
            label.stringValue = row == 0 ? "Primary" : "Fallback #\(row)"
            label.textColor = .secondaryLabelColor
        }
        return label
    }
}
