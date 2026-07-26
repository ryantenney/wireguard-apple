// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import Cocoa
import NetworkExtension

class FailoverGroupListRow: NSView {
    var tunnel: TunnelContainer? {
        didSet(value) {
            nameLabel.stringValue = tunnel?.name ?? ""
            nameObservationToken = tunnel?.observe(\TunnelContainer.name) { [weak self] tunnel, _ in
                self?.nameLabel.stringValue = tunnel.name
            }
            updateSubtitleLabel()
            statusImageView.image = TunnelListRow.image(for: tunnel)
            statusObservationToken = tunnel?.observe(\TunnelContainer.status) { [weak self] tunnel, _ in
                self?.statusImageView.image = TunnelListRow.image(for: tunnel)
            }
            isOnDemandEnabledObservationToken = tunnel?.observe(\TunnelContainer.isActivateOnDemandEnabled) { [weak self] tunnel, _ in
                self?.statusImageView.image = TunnelListRow.image(for: tunnel)
            }
        }
    }

    let nameLabel: NSTextField = {
        let nameLabel = NSTextField()
        nameLabel.isEditable = false
        nameLabel.isSelectable = false
        nameLabel.isBordered = false
        nameLabel.maximumNumberOfLines = 1
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
        return nameLabel
    }()

    let subtitleLabel: NSTextField = {
        let label = NSTextField()
        label.isEditable = false
        label.isSelectable = false
        label.isBordered = false
        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        return label
    }()

    let statusImageView = NSImageView()

    private var statusObservationToken: AnyObject?
    private var nameObservationToken: AnyObject?
    private var isOnDemandEnabledObservationToken: AnyObject?

    init() {
        super.init(frame: CGRect.zero)

        addSubview(statusImageView)
        addSubview(nameLabel)
        addSubview(subtitleLabel)
        statusImageView.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.backgroundColor = .clear
        subtitleLabel.backgroundColor = .clear

        NSLayoutConstraint.activate([
            self.leadingAnchor.constraint(equalTo: statusImageView.leadingAnchor),
            statusImageView.trailingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            statusImageView.widthAnchor.constraint(equalToConstant: 20),
            nameLabel.trailingAnchor.constraint(equalTo: self.trailingAnchor),
            statusImageView.centerYAnchor.constraint(equalTo: self.centerYAnchor),
            nameLabel.topAnchor.constraint(equalTo: self.topAnchor, constant: 2),
            subtitleLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 0),
            subtitleLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: self.trailingAnchor),
            subtitleLabel.bottomAnchor.constraint(lessThanOrEqualTo: self.bottomAnchor, constant: -2)
        ])
    }

    required init?(coder decoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func updateSubtitleLabel() {
        guard let tunnel = tunnel,
              let proto = tunnel.tunnelProvider.protocolConfiguration as? NETunnelProviderProtocol,
              let providerConfig = proto.providerConfiguration else {
            subtitleLabel.stringValue = ""
            return
        }
        if let configNames = providerConfig[ProviderConfigurationKeys.failoverConfigNames] as? [String] {
            subtitleLabel.stringValue = configNames.joined(separator: " \u{2192} ")
        } else if let outerName = providerConfig[ProviderConfigurationKeys.titOuterName] as? String,
                  let innerName = providerConfig[ProviderConfigurationKeys.titInnerName] as? String {
            subtitleLabel.stringValue = "\(outerName) \u{2192} \(innerName)"
        } else {
            subtitleLabel.stringValue = ""
        }
    }

    override func prepareForReuse() {
        nameLabel.stringValue = ""
        subtitleLabel.stringValue = ""
        statusImageView.image = nil
    }
}
