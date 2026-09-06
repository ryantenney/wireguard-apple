// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import Cocoa
import NetworkExtension

/// Lets a group detail view ask its container to navigate to one of the group's member tunnels.
protocol GroupDetailMemberNavigationDelegate: AnyObject {
    func groupDetailRequestsTunnel(named name: String)
}

/// Base class for macOS group detail view controllers (failover, TiT).
/// Provides shared loadView layout, status helpers, toggle action, and polling lifecycle.
class GroupDetailBaseViewController: NSViewController {

    weak var memberNavigationDelegate: GroupDetailMemberNavigationDelegate?

    let tableView: NSTableView = {
        let tableView = NSTableView()
        tableView.headerView = nil
        tableView.rowSizeStyle = .medium
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        return tableView
    }()

    let editButton: NSButton = {
        let button = NSButton()
        button.title = tr("macButtonEdit")
        button.setButtonType(.momentaryPushIn)
        button.bezelStyle = .rounded
        button.toolTip = tr("macToolTipEditTunnel")
        return button
    }()

    let detailsButton: NSButton = {
        let button = NSButton()
        button.title = tr("macButtonConnectionDetails")
        button.setButtonType(.momentaryPushIn)
        button.bezelStyle = .rounded
        button.toolTip = tr("macToolTipConnectionDetails")
        return button
    }()

    let box: NSBox = {
        let box = NSBox()
        box.titlePosition = .noTitle
        box.fillColor = .unemphasizedSelectedContentBackgroundColor
        return box
    }()

    let tunnelsManager: TunnelsManager
    let tunnel: TunnelContainer
    var onDemandViewModel: ActivateOnDemandViewModel

    var statusObservationToken: AnyObject?
    private var diagnosticsVC: ConnectionDiagnosticsViewController?

    init(tunnelsManager: TunnelsManager, tunnel: TunnelContainer) {
        self.tunnelsManager = tunnelsManager
        self.tunnel = tunnel
        self.onDemandViewModel = ActivateOnDemandViewModel(tunnel: tunnel)
        super.init(nibName: nil, bundle: nil)

        loadGroupData()
        rebuildTableViewModelRows()
        setupStatusObservation()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Subclass Hooks

    /// Subclasses must add a table column with a unique identifier before calling super.
    var tableColumnIdentifier: String { "GroupDetail" }

    func loadGroupData() {
        // Override in subclass
    }

    func rebuildTableViewModelRows() {
        // Override in subclass
    }

    func startPolling() {
        // Override in subclass
    }

    func stopPolling() {
        // Override in subclass
    }

    @objc func handleEditAction() {
        // Override in subclass
    }

    func onStatusBecameInactive() {
        rebuildTableViewModelRows()
        tableView.reloadData()
    }

    /// The member tunnel shown on the given table row, if that row is a member row.
    func memberTunnelName(forRow row: Int) -> String? {
        return nil
    }

    @objc private func handleRowDoubleClick() {
        let row = tableView.clickedRow
        guard row >= 0, let name = memberTunnelName(forRow: row) else { return }
        memberNavigationDelegate?.groupDetailRequestsTunnel(named: name)
    }

    // MARK: - Layout

    override func loadView() {
        tableView.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier(tableColumnIdentifier)))
        tableView.target = self
        tableView.doubleAction = #selector(handleRowDoubleClick)

        editButton.target = self
        editButton.action = #selector(handleEditAction)

        detailsButton.target = self
        detailsButton.action = #selector(handleShowDiagnosticsAction)

        let clipView = NSClipView()
        clipView.documentView = tableView

        let scrollView = NSScrollView()
        scrollView.contentView = clipView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let containerView = NSView()
        let bottomControlsContainer = NSLayoutGuide()
        containerView.addLayoutGuide(bottomControlsContainer)
        containerView.addSubview(box)
        containerView.addSubview(scrollView)
        containerView.addSubview(editButton)
        containerView.addSubview(detailsButton)
        box.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        editButton.translatesAutoresizingMaskIntoConstraints = false
        detailsButton.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            containerView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            containerView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            containerView.leadingAnchor.constraint(equalTo: bottomControlsContainer.leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: bottomControlsContainer.trailingAnchor),
            bottomControlsContainer.heightAnchor.constraint(equalToConstant: 32),
            scrollView.bottomAnchor.constraint(equalTo: bottomControlsContainer.topAnchor),
            bottomControlsContainer.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            editButton.trailingAnchor.constraint(equalTo: bottomControlsContainer.trailingAnchor),
            bottomControlsContainer.bottomAnchor.constraint(equalTo: editButton.bottomAnchor, constant: 0),
            detailsButton.leadingAnchor.constraint(equalTo: bottomControlsContainer.leadingAnchor),
            bottomControlsContainer.bottomAnchor.constraint(equalTo: detailsButton.bottomAnchor, constant: 0)
        ])

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: box.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: box.trailingAnchor)
        ])

        NSLayoutConstraint.activate([
            containerView.widthAnchor.constraint(greaterThanOrEqualToConstant: 320),
            containerView.heightAnchor.constraint(greaterThanOrEqualToConstant: 120)
        ])

        view = containerView
    }

    // MARK: - Lifecycle

    override func viewWillAppear() {
        if tunnel.status == .active {
            startPolling()
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        dismissEditSheet()
        if let diagnosticsVC = diagnosticsVC {
            dismiss(diagnosticsVC)
            self.diagnosticsVC = nil
        }
        stopPolling()
    }

    // MARK: - Connection Details

    @objc func handleShowDiagnosticsAction() {
        if let diagnosticsVC = diagnosticsVC {
            dismiss(diagnosticsVC)
        }
        let diagnosticsVC = ConnectionDiagnosticsViewController(tunnelsManager: tunnelsManager, tunnel: tunnel)
        presentAsSheet(diagnosticsVC)
        self.diagnosticsVC = diagnosticsVC
    }

    /// Subclasses override to dismiss their specific edit VC.
    func dismissEditSheet() {
        // Override in subclass
    }

    // MARK: - Observation

    private func setupStatusObservation() {
        statusObservationToken = tunnel.observe(\TunnelContainer.status) { [weak self] tunnel, _ in
            guard let self = self else { return }
            if tunnel.status == .active {
                self.startPolling()
            } else if tunnel.status == .inactive {
                self.stopPolling()
                self.onStatusBecameInactive()
            }
        }
    }

    func handleGroupSaved() {
        loadGroupData()
        onDemandViewModel = ActivateOnDemandViewModel(tunnel: tunnel)
        rebuildTableViewModelRows()
        tableView.reloadData()
    }

    // MARK: - Toggle Action

    @objc func handleToggleActiveStatusAction() {
        if tunnel.hasOnDemandRules {
            let turnOn = !tunnel.isActivateOnDemandEnabled
            tunnelsManager.setOnDemandEnabled(turnOn, on: tunnel) { error in
                if error == nil && !turnOn {
                    self.tunnelsManager.startDeactivation(of: self.tunnel)
                }
            }
        } else {
            if tunnel.status == .inactive {
                tunnelsManager.startActivation(of: tunnel)
            } else if tunnel.status == .active {
                tunnelsManager.startDeactivation(of: tunnel)
            }
        }
    }

    // MARK: - Status Helpers

    static func localizedStatusDescription(for tunnel: TunnelContainer) -> String {
        let status = tunnel.status
        let isOnDemandEngaged = tunnel.isActivateOnDemandEnabled

        var text: String
        switch status {
        case .inactive: text = tr("tunnelStatusInactive")
        case .activating: text = tr("tunnelStatusActivating")
        case .active: text = tr("tunnelStatusActive")
        case .deactivating: text = tr("tunnelStatusDeactivating")
        case .reasserting: text = tr("tunnelStatusReasserting")
        case .restarting: text = tr("tunnelStatusRestarting")
        case .waiting: text = tr("tunnelStatusWaiting")
        }

        if tunnel.hasOnDemandRules {
            text += isOnDemandEngaged ?
                tr("tunnelStatusAddendumOnDemandEnabled") : tr("tunnelStatusAddendumOnDemandDisabled")
        }

        return text
    }

    static func localizedToggleStatusActionText(for tunnel: TunnelContainer) -> String {
        if tunnel.hasOnDemandRules {
            let turnOn = !tunnel.isActivateOnDemandEnabled
            if turnOn {
                return tr("macToggleStatusButtonEnableOnDemand")
            } else {
                if tunnel.status == .active {
                    return tr("macToggleStatusButtonDisableOnDemandDeactivate")
                } else {
                    return tr("macToggleStatusButtonDisableOnDemand")
                }
            }
        } else {
            switch tunnel.status {
            case .waiting: return tr("macToggleStatusButtonWaiting")
            case .inactive: return tr("macToggleStatusButtonActivate")
            case .activating: return tr("macToggleStatusButtonActivating")
            case .active: return tr("macToggleStatusButtonDeactivate")
            case .deactivating: return tr("macToggleStatusButtonDeactivating")
            case .reasserting: return tr("macToggleStatusButtonReasserting")
            case .restarting: return tr("macToggleStatusButtonRestarting")
            }
        }
    }
}
