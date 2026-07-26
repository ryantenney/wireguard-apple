// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import Cocoa
import NetworkExtension

protocol TunnelInTunnelEditViewControllerDelegate: AnyObject {
    func titGroupSaved(tunnel: TunnelContainer)
    func titGroupEditingCancelled()
}

class TunnelInTunnelEditViewController: NSViewController {

    let tunnelsManager: TunnelsManager
    let tunnel: TunnelContainer?

    weak var delegate: TunnelInTunnelEditViewControllerDelegate?

    private var outerTunnelName: String
    private var innerTunnelName: String
    private var onDemandViewModel: ActivateOnDemandViewModel

    // UI elements

    let nameRow: EditableKeyValueRow = {
        let row = EditableKeyValueRow()
        row.key = tr(format: "macFieldKey (%@)", tr("tunnelInterfaceName"))
        return row
    }()

    let outerLabel: NSTextField = {
        let label = NSTextField()
        label.stringValue = "Outer Tunnel (Server A):"
        label.isEditable = false
        label.isSelectable = false
        label.isBordered = false
        label.backgroundColor = .clear
        label.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
        return label
    }()

    let outerPopUp: NSPopUpButton = {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        return button
    }()

    let innerLabel: NSTextField = {
        let label = NSTextField()
        label.stringValue = "Inner Tunnel (Server B):"
        label.isEditable = false
        label.isSelectable = false
        label.isBordered = false
        label.backgroundColor = .clear
        label.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
        return label
    }()

    let innerPopUp: NSPopUpButton = {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        return button
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
        button.title = "Delete Tunnel-in-Tunnel Group"
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
            self.outerTunnelName = (providerConfig[ProviderConfigurationKeys.titOuterName] as? String) ?? ""
            self.innerTunnelName = (providerConfig[ProviderConfigurationKeys.titInnerName] as? String) ?? ""
            self.onDemandViewModel = ActivateOnDemandViewModel(tunnel: tunnel)
        } else {
            self.outerTunnelName = ""
            self.innerTunnelName = ""
            self.onDemandViewModel = ActivateOnDemandViewModel(from: OnDemandActivation())
        }

        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let availableNames = tunnelsManager.mapTunnels { $0.name }

        // Populate outer popup
        outerPopUp.removeAllItems()
        outerPopUp.addItem(withTitle: "Select Tunnel...")
        outerPopUp.addItems(withTitles: availableNames)
        if !outerTunnelName.isEmpty {
            outerPopUp.selectItem(withTitle: outerTunnelName)
        }

        // Populate inner popup
        innerPopUp.removeAllItems()
        innerPopUp.addItem(withTitle: "Select Tunnel...")
        innerPopUp.addItems(withTitles: availableNames)
        if !innerTunnelName.isEmpty {
            innerPopUp.selectItem(withTitle: innerTunnelName)
        }

        nameRow.value = tunnel?.name ?? ""

        saveButton.target = self
        saveButton.action = #selector(handleSaveAction)

        discardButton.target = self
        discardButton.action = #selector(handleDiscardAction)

        deleteButton.target = self
        deleteButton.action = #selector(handleDeleteAction)

        onDemandControlsRow.onDemandViewModel = onDemandViewModel

        // Outer tunnel row
        let outerRow = NSStackView(views: [outerLabel, outerPopUp])
        outerRow.orientation = .vertical
        outerRow.alignment = .leading
        outerRow.spacing = 4

        // Inner tunnel row
        let innerRow = NSStackView(views: [innerLabel, innerPopUp])
        innerRow.orientation = .vertical
        innerRow.alignment = .leading
        innerRow.spacing = 4

        // Footer text
        let footerLabel = NSTextField()
        footerLabel.stringValue = "Traffic is encrypted first by the inner tunnel, then by the outer tunnel."
        footerLabel.isEditable = false
        footerLabel.isSelectable = false
        footerLabel.isBordered = false
        footerLabel.backgroundColor = .clear
        footerLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        footerLabel.textColor = .secondaryLabelColor
        footerLabel.lineBreakMode = .byWordWrapping
        footerLabel.preferredMaxLayoutWidth = 360

        let margin: CGFloat = 20
        let internalSpacing: CGFloat = 10

        let editorViews: [NSView] = [nameRow, outerRow, innerRow, footerLabel, onDemandControlsRow]

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
            containerView.heightAnchor.constraint(greaterThanOrEqualToConstant: 300)
        ])
        containerView.frame = NSRect(x: 0, y: 0, width: 500, height: 400)

        self.view = containerView
    }

    @objc func handleSaveAction() {
        let name = nameRow.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            ErrorPresenter.showErrorAlert(title: tr("macAlertNameIsEmpty"), message: "", from: self)
            return
        }

        let selectedOuter = outerPopUp.titleOfSelectedItem ?? ""
        let selectedInner = innerPopUp.titleOfSelectedItem ?? ""

        guard selectedOuter != "Select Tunnel..." && !selectedOuter.isEmpty else {
            ErrorPresenter.showErrorAlert(title: "Please select an outer tunnel.", message: "", from: self)
            return
        }
        guard selectedInner != "Select Tunnel..." && !selectedInner.isEmpty else {
            ErrorPresenter.showErrorAlert(title: "Please select an inner tunnel.", message: "", from: self)
            return
        }
        guard selectedOuter != selectedInner else {
            ErrorPresenter.showErrorAlert(title: "Outer and inner tunnels must be different.", message: "", from: self)
            return
        }

        onDemandControlsRow.saveToViewModel()
        let onDemandActivation = onDemandViewModel.toOnDemandActivation()

        setUserInteractionEnabled(false)

        if let tunnel = tunnel {
            tunnelsManager.modifyTiTGroup(
                tunnel: tunnel,
                name: name,
                outerTunnelName: selectedOuter,
                innerTunnelName: selectedInner,
                onDemandActivation: onDemandActivation
            ) { [weak self] error in
                guard let self = self else { return }
                self.setUserInteractionEnabled(true)
                if let error = error {
                    ErrorPresenter.showErrorAlert(error: error, from: self)
                    return
                }
                self.delegate?.titGroupSaved(tunnel: tunnel)
                self.presentingViewController?.dismiss(self)
            }
        } else {
            tunnelsManager.addTiTGroup(
                name: name,
                outerTunnelName: selectedOuter,
                innerTunnelName: selectedInner,
                onDemandActivation: onDemandActivation
            ) { [weak self] result in
                guard let self = self else { return }
                self.setUserInteractionEnabled(true)
                switch result {
                case .failure(let error):
                    ErrorPresenter.showErrorAlert(error: error, from: self)
                case .success(let tunnel):
                    self.delegate?.titGroupSaved(tunnel: tunnel)
                    self.presentingViewController?.dismiss(self)
                }
            }
        }
    }

    @objc func handleDiscardAction() {
        delegate?.titGroupEditingCancelled()
        presentingViewController?.dismiss(self)
    }

    @objc func handleDeleteAction() {
        guard let tunnel = tunnel, let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Delete Tunnel-in-Tunnel Group"
        alert.informativeText = "Are you sure you want to delete '\(tunnel.name)'? This won't delete the individual tunnels."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self = self, response == .alertFirstButtonReturn else { return }
            self.tunnelsManager.removeTiTGroup(tunnel: tunnel) { [weak self] error in
                guard let self = self else { return }
                if let error = error {
                    ErrorPresenter.showErrorAlert(error: error, from: self)
                    return
                }
                self.presentingViewController?.dismiss(self)
            }
        }
    }

    func setUserInteractionEnabled(_ enabled: Bool) {
        view.window?.ignoresMouseEvents = !enabled
    }
}

// MARK: - Cancel shortcut

extension TunnelInTunnelEditViewController {
    override func cancelOperation(_ sender: Any?) {
        handleDiscardAction()
    }
}
