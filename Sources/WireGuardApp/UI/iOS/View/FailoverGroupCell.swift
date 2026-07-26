// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import UIKit
import NetworkExtension

class FailoverGroupCell: UITableViewCell {

    var tunnel: TunnelContainer? {
        didSet {
            nameLabel.text = tunnel?.name ?? ""
            nameObservationToken = tunnel?.observe(\.name) { [weak self] tunnel, _ in
                self?.nameLabel.text = tunnel.name
            }
            updateDetailLabel()
            update(from: tunnel, animated: false)
            statusObservationToken = tunnel?.observe(\.status) { [weak self] tunnel, _ in
                self?.update(from: tunnel, animated: true)
            }
            isOnDemandEnabledObservationToken = tunnel?.observe(\.isActivateOnDemandEnabled) { [weak self] tunnel, _ in
                self?.update(from: tunnel, animated: true)
            }
            hasOnDemandRulesObservationToken = tunnel?.observe(\.hasOnDemandRules) { [weak self] tunnel, _ in
                self?.update(from: tunnel, animated: true)
            }
            isOnDemandSuspendedObservationToken = tunnel?.observe(\.isOnDemandSuspended) { [weak self] tunnel, _ in
                self?.update(from: tunnel, animated: true)
            }
        }
    }

    var activeConfigName: String? {
        didSet {
            updateActiveConfigLabel()
        }
    }

    var onSwitchToggled: ((Bool) -> Void)?

    let nameLabel: UILabel = {
        let label = UILabel()
        label.font = UIFont.preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 1
        return label
    }()

    let detailLabel: UILabel = {
        let label = UILabel()
        label.font = UIFont.preferredFont(forTextStyle: .caption1)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 1
        label.textColor = .secondaryLabel
        return label
    }()

    let onDemandLabel: UILabel = {
        let label = UILabel()
        label.font = UIFont.preferredFont(forTextStyle: .caption2)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 1
        label.textColor = .secondaryLabel
        return label
    }()

    let activeConfigLabel: UILabel = {
        let label = UILabel()
        label.font = UIFont.preferredFont(forTextStyle: .caption2)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 1
        label.textColor = .systemGreen
        return label
    }()

    let statusSwitch = UISwitch()

    let busyIndicator: UIActivityIndicatorView = {
        let indicator = UIActivityIndicatorView(style: .medium)
        indicator.hidesWhenStopped = true
        return indicator
    }()

    private var nameObservationToken: NSKeyValueObservation?
    private var statusObservationToken: NSKeyValueObservation?
    private var isOnDemandEnabledObservationToken: NSKeyValueObservation?
    private var hasOnDemandRulesObservationToken: NSKeyValueObservation?
    private var isOnDemandSuspendedObservationToken: NSKeyValueObservation?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)

        accessoryType = .disclosureIndicator

        for subview in [nameLabel, detailLabel, onDemandLabel, activeConfigLabel, statusSwitch, busyIndicator] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(subview)
        }

        NSLayoutConstraint.activate([
            nameLabel.topAnchor.constraint(equalToSystemSpacingBelow: contentView.layoutMarginsGuide.topAnchor, multiplier: 0.5),
            nameLabel.leadingAnchor.constraint(equalToSystemSpacingAfter: contentView.layoutMarginsGuide.leadingAnchor, multiplier: 1),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: statusSwitch.leadingAnchor, constant: -8),

            detailLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            detailLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: statusSwitch.leadingAnchor, constant: -8),

            onDemandLabel.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 1),
            onDemandLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            onDemandLabel.trailingAnchor.constraint(lessThanOrEqualTo: statusSwitch.leadingAnchor, constant: -8),

            activeConfigLabel.topAnchor.constraint(equalTo: onDemandLabel.bottomAnchor, constant: 1),
            activeConfigLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            activeConfigLabel.trailingAnchor.constraint(lessThanOrEqualTo: statusSwitch.leadingAnchor, constant: -8),
            contentView.layoutMarginsGuide.bottomAnchor.constraint(equalToSystemSpacingBelow: activeConfigLabel.bottomAnchor, multiplier: 0.5),

            statusSwitch.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            statusSwitch.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),

            busyIndicator.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            busyIndicator.trailingAnchor.constraint(equalTo: statusSwitch.leadingAnchor, constant: -8)
        ])

        statusSwitch.addTarget(self, action: #selector(switchToggled), for: .valueChanged)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        tunnel = nil
        activeConfigName = nil
        nameObservationToken = nil
        statusObservationToken = nil
        isOnDemandEnabledObservationToken = nil
        hasOnDemandRulesObservationToken = nil
        isOnDemandSuspendedObservationToken = nil
    }

    @objc private func switchToggled() {
        onSwitchToggled?(statusSwitch.isOn)
    }

    private func updateDetailLabel() {
        guard let tunnel = tunnel,
              let proto = tunnel.tunnelProvider.protocolConfiguration as? NETunnelProviderProtocol,
              let providerConfig = proto.providerConfiguration else {
            detailLabel.text = ""
            return
        }
        if let configNames = providerConfig[ProviderConfigurationKeys.failoverConfigNames] as? [String] {
            detailLabel.text = configNames.joined(separator: " \u{2192} ")
        } else if let outerName = providerConfig[ProviderConfigurationKeys.titOuterName] as? String,
                  let innerName = providerConfig[ProviderConfigurationKeys.titInnerName] as? String {
            detailLabel.text = "\(outerName) \u{2192} \(innerName)"
        } else {
            detailLabel.text = ""
        }
    }

    private func updateActiveConfigLabel() {
        guard let tunnel = tunnel else {
            activeConfigLabel.isHidden = true
            return
        }
        let status = tunnel.status
        if status == .active || status == .activating, let activeName = activeConfigName {
            activeConfigLabel.text = "Active: \(activeName)"
            activeConfigLabel.isHidden = false
        } else {
            activeConfigLabel.isHidden = true
        }
    }

    private func update(from tunnel: TunnelContainer?, animated: Bool) {
        guard let tunnel = tunnel else {
            statusSwitch.setOn(false, animated: animated)
            statusSwitch.onTintColor = .systemGreen
            onDemandLabel.text = ""
            onDemandLabel.isHidden = true
            activeConfigLabel.isHidden = true
            busyIndicator.stopAnimating()
            return
        }

        let status = tunnel.status
        let isOnDemandEngaged = tunnel.isActivateOnDemandEnabled
        let isSuspended = tunnel.isOnDemandSuspended

        let shouldSwitchBeOn = (status != .deactivating && status != .inactive) || isOnDemandEngaged || isSuspended
        statusSwitch.setOn(shouldSwitchBeOn, animated: animated)

        if isSuspended && !(status == .activating || status == .active) {
            statusSwitch.onTintColor = .systemGray
        } else if isOnDemandEngaged && !(status == .activating || status == .active) {
            statusSwitch.onTintColor = .systemYellow
        } else {
            statusSwitch.onTintColor = .systemGreen
        }

        if isOnDemandEngaged || isSuspended {
            onDemandLabel.text = tr("tunnelListCaptionOnDemand")
            onDemandLabel.isHidden = false
        } else {
            onDemandLabel.text = ""
            onDemandLabel.isHidden = true
        }

        if status == .inactive || status == .active {
            busyIndicator.stopAnimating()
        } else {
            busyIndicator.startAnimating()
        }

        updateActiveConfigLabel()
    }
}
