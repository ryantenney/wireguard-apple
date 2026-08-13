// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import UIKit

/// A pill-shaped button that pads its intrinsic size, replacing the
/// deprecated contentEdgeInsets.
private class ChipButton: UIButton {
    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + 28, height: size.height + 12)
    }
}

/// The map-based landing page: a stylized world map showing the user's
/// approximate position, the selected tunnel's endpoints, and animated arcs
/// for the traffic path — including both legs of a tunnel-in-tunnel chain and
/// the standby/hot-spare connections of a failover group.
///
/// This screen is additive: the classic tunnels list remains the default
/// landing page unless "Open at launch" is enabled here.
class MapHomeViewController: UIViewController {

    private let tunnelsManager: TunnelsManager

    private var selectedTunnel: TunnelContainer?
    private var lastGroupState: [String: Any]?
    private var lastScene: MapScene?
    private var runtimeStatsText: String?
    private var statusObservation: NSKeyValueObservation?
    private var pollTimer: Timer?
    private weak var previousActivationDelegate: TunnelsManagerActivationDelegate?

    // MARK: - Views

    private let mapView = ConnectionMapView()

    private let gradientView = UIView()
    private let gradientLayer = CAGradientLayer()
    private var statusStackView: UIStackView?

    private let closeButton: UIButton = {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "xmark"), for: .normal)
        button.tintColor = UIColor(white: 1, alpha: 0.8)
        button.backgroundColor = UIColor(white: 1, alpha: 0.12)
        button.layer.cornerRadius = 17
        return button
    }()

    private let menuButton: UIButton = {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "ellipsis"), for: .normal)
        button.tintColor = UIColor(white: 1, alpha: 0.8)
        button.backgroundColor = UIColor(white: 1, alpha: 0.12)
        button.layer.cornerRadius = 17
        button.showsMenuAsPrimaryAction = true
        return button
    }()

    private let statusIconContainer: UIView = {
        let view = UIView()
        view.layer.cornerRadius = 27
        return view
    }()

    private let statusIconView: UIImageView = {
        let imageView = UIImageView()
        imageView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
        imageView.contentMode = .center
        return imageView
    }()

    private let statusTitleLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 22, weight: .bold)
        label.textColor = .white
        label.textAlignment = .center
        return label
    }()

    private let statusPillLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = UIColor(white: 1, alpha: 0.75)
        label.textAlignment = .center
        return label
    }()

    private let statusPillContainer: UIView = {
        let view = UIView()
        view.backgroundColor = UIColor(white: 0.1, alpha: 0.72)
        view.layer.cornerRadius = 14
        return view
    }()

    private let cardView: UIView = {
        let view = UIView()
        view.backgroundColor = MapPalette.backgroundElevated.withAlphaComponent(0.96)
        view.layer.cornerRadius = 20
        view.layer.borderWidth = 1
        view.layer.borderColor = UIColor(white: 1, alpha: 0.07).cgColor
        return view
    }()

    private let kindIconContainer: UIView = {
        let view = UIView()
        view.backgroundColor = MapPalette.accent.withAlphaComponent(0.16)
        view.layer.cornerRadius = 10
        return view
    }()

    private let kindIconView: UIImageView = {
        let imageView = UIImageView()
        imageView.tintColor = MapPalette.accent
        imageView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        imageView.contentMode = .center
        return imageView
    }()

    private let selectionNameLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 17, weight: .semibold)
        label.textColor = .white
        return label
    }()

    private let selectionDetailLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 13, weight: .regular)
        label.textColor = UIColor(white: 1, alpha: 0.55)
        return label
    }()

    private let selectorChevronView: UIImageView = {
        let imageView = UIImageView(image: UIImage(systemName: "chevron.up.chevron.down"))
        imageView.tintColor = UIColor(white: 1, alpha: 0.45)
        imageView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        imageView.contentMode = .center
        return imageView
    }()

    private let selectorButton: UIButton = {
        let button = UIButton(type: .custom)
        button.showsMenuAsPrimaryAction = true
        return button
    }()

    private let connectButton: UIButton = {
        let button = UIButton(type: .system)
        button.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        button.layer.cornerRadius = 14
        return button
    }()

    private let unlocatedChipButton: UIButton = {
        let button = ChipButton(type: .system)
        button.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
        button.setTitleColor(.white, for: .normal)
        button.backgroundColor = UIColor(white: 0.1, alpha: 0.85)
        button.layer.cornerRadius = 15
        button.layer.borderWidth = 1
        button.layer.borderColor = MapPalette.accent.withAlphaComponent(0.5).cgColor
        button.isHidden = true
        return button
    }()

    // MARK: - Lifecycle

    init(tunnelsManager: TunnelsManager) {
        self.tunnelsManager = tunnelsManager
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        pollTimer?.invalidate()
        if tunnelsManager.activationDelegate === self {
            tunnelsManager.activationDelegate = previousActivationDelegate
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = MapPalette.background

        buildViewHierarchy()

        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        connectButton.addTarget(self, action: #selector(connectTapped), for: .touchUpInside)
        unlocatedChipButton.addTarget(self, action: #selector(unlocatedChipTapped), for: .touchUpInside)
        menuButton.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                completion(self?.buildOptionsMenuItems() ?? [])
            }
        ])
        selectorButton.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                completion(self?.buildSelectionMenuItems() ?? [])
            }
        ])

        NotificationCenter.default.addObserver(self, selector: #selector(locationsDidChange),
                                               name: EndpointLocationStore.locationsDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(applicationDidBecomeActive),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)

        selectTunnel(initialSelection(), animated: false)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        gradientLayer.frame = gradientView.bounds

        let topInset = (statusStackView?.frame.maxY ?? 130) + 28
        let bottomInset = view.bounds.height - cardView.frame.minY + 36
        let insets = UIEdgeInsets(top: topInset, left: 44, bottom: bottomInset, right: 44)
        if mapView.cameraInsets != insets {
            mapView.cameraInsets = insets
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if tunnelsManager.activationDelegate !== self {
            previousActivationDelegate = tunnelsManager.activationDelegate
            tunnelsManager.activationDelegate = self
        }
        startPolling()
        refreshUI(animated: false)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isBeingDismissed {
            stopPolling()
            if tunnelsManager.activationDelegate === self {
                tunnelsManager.activationDelegate = previousActivationDelegate
            }
        }
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        return .lightContent
    }

    // MARK: - View hierarchy

    private func buildViewHierarchy() {
        view.addSubview(mapView)
        mapView.translatesAutoresizingMaskIntoConstraints = false

        gradientLayer.colors = [MapPalette.unprotectedTint.withAlphaComponent(0.3).cgColor, UIColor.clear.cgColor]
        gradientLayer.locations = [0, 0.45]
        gradientView.layer.addSublayer(gradientLayer)
        gradientView.isUserInteractionEnabled = false
        view.addSubview(gradientView)
        gradientView.translatesAutoresizingMaskIntoConstraints = false

        statusIconContainer.addSubview(statusIconView)
        statusIconView.translatesAutoresizingMaskIntoConstraints = false
        statusPillContainer.addSubview(statusPillLabel)
        statusPillLabel.translatesAutoresizingMaskIntoConstraints = false

        let statusStack = UIStackView(arrangedSubviews: [statusIconContainer, statusTitleLabel, statusPillContainer])
        statusStack.axis = .vertical
        statusStack.alignment = .center
        statusStack.spacing = 10
        view.addSubview(statusStack)
        statusStack.translatesAutoresizingMaskIntoConstraints = false
        statusStackView = statusStack

        view.addSubview(closeButton)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(menuButton)
        menuButton.translatesAutoresizingMaskIntoConstraints = false

        let selectionTextStack = UIStackView(arrangedSubviews: [selectionNameLabel, selectionDetailLabel])
        selectionTextStack.axis = .vertical
        selectionTextStack.alignment = .leading
        selectionTextStack.spacing = 2

        kindIconContainer.addSubview(kindIconView)
        kindIconView.translatesAutoresizingMaskIntoConstraints = false

        let selectorRow = UIView()
        selectorRow.addSubview(kindIconContainer)
        kindIconContainer.translatesAutoresizingMaskIntoConstraints = false
        selectorRow.addSubview(selectionTextStack)
        selectionTextStack.translatesAutoresizingMaskIntoConstraints = false
        selectorRow.addSubview(selectorChevronView)
        selectorChevronView.translatesAutoresizingMaskIntoConstraints = false
        selectorRow.addSubview(selectorButton)
        selectorButton.translatesAutoresizingMaskIntoConstraints = false

        let cardStack = UIStackView(arrangedSubviews: [selectorRow, connectButton])
        cardStack.axis = .vertical
        cardStack.spacing = 14
        cardView.addSubview(cardStack)
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(cardView)
        cardView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(unlocatedChipButton)
        unlocatedChipButton.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            mapView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            mapView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            mapView.topAnchor.constraint(equalTo: view.topAnchor),
            mapView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            gradientView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            gradientView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            gradientView.topAnchor.constraint(equalTo: view.topAnchor),
            gradientView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            closeButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            closeButton.widthAnchor.constraint(equalToConstant: 34),
            closeButton.heightAnchor.constraint(equalToConstant: 34),

            menuButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            menuButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            menuButton.widthAnchor.constraint(equalToConstant: 34),
            menuButton.heightAnchor.constraint(equalToConstant: 34),

            statusStack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            statusStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusStack.leadingAnchor.constraint(greaterThanOrEqualTo: closeButton.trailingAnchor, constant: 8),
            statusStack.trailingAnchor.constraint(lessThanOrEqualTo: menuButton.leadingAnchor, constant: -8),

            statusIconContainer.widthAnchor.constraint(equalToConstant: 54),
            statusIconContainer.heightAnchor.constraint(equalToConstant: 54),
            statusIconView.centerXAnchor.constraint(equalTo: statusIconContainer.centerXAnchor),
            statusIconView.centerYAnchor.constraint(equalTo: statusIconContainer.centerYAnchor),

            statusPillLabel.leadingAnchor.constraint(equalTo: statusPillContainer.leadingAnchor, constant: 14),
            statusPillLabel.trailingAnchor.constraint(equalTo: statusPillContainer.trailingAnchor, constant: -14),
            statusPillLabel.topAnchor.constraint(equalTo: statusPillContainer.topAnchor, constant: 6),
            statusPillLabel.bottomAnchor.constraint(equalTo: statusPillContainer.bottomAnchor, constant: -6),

            kindIconContainer.leadingAnchor.constraint(equalTo: selectorRow.leadingAnchor),
            kindIconContainer.centerYAnchor.constraint(equalTo: selectorRow.centerYAnchor),
            kindIconContainer.widthAnchor.constraint(equalToConstant: 36),
            kindIconContainer.heightAnchor.constraint(equalToConstant: 36),
            kindIconView.centerXAnchor.constraint(equalTo: kindIconContainer.centerXAnchor),
            kindIconView.centerYAnchor.constraint(equalTo: kindIconContainer.centerYAnchor),

            selectionTextStack.leadingAnchor.constraint(equalTo: kindIconContainer.trailingAnchor, constant: 12),
            selectionTextStack.centerYAnchor.constraint(equalTo: selectorRow.centerYAnchor),
            selectionTextStack.trailingAnchor.constraint(lessThanOrEqualTo: selectorChevronView.leadingAnchor, constant: -8),

            selectorChevronView.trailingAnchor.constraint(equalTo: selectorRow.trailingAnchor, constant: -4),
            selectorChevronView.centerYAnchor.constraint(equalTo: selectorRow.centerYAnchor),

            selectorButton.leadingAnchor.constraint(equalTo: selectorRow.leadingAnchor),
            selectorButton.trailingAnchor.constraint(equalTo: selectorRow.trailingAnchor),
            selectorButton.topAnchor.constraint(equalTo: selectorRow.topAnchor),
            selectorButton.bottomAnchor.constraint(equalTo: selectorRow.bottomAnchor),

            selectorRow.heightAnchor.constraint(equalToConstant: 48),
            connectButton.heightAnchor.constraint(equalToConstant: 52),

            cardStack.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 16),
            cardStack.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -16),
            cardStack.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 14),
            cardStack.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -14),

            cardView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            cardView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            cardView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),

            unlocatedChipButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            unlocatedChipButton.bottomAnchor.constraint(equalTo: cardView.topAnchor, constant: -12)
        ])
    }

    // MARK: - Selection

    private func initialSelection() -> TunnelContainer? {
        let allSelectable = tunnelsManager.failoverGroupTunnels + tunnelsManager.titGroupTunnels + tunnelsManager.tunnels
        if let persistedName = MapHomeSettings.selectedTunnelName,
           let persisted = allSelectable.first(where: { $0.name == persistedName }) {
            return persisted
        }
        if let operating = tunnelsManager.tunnelInOperation() {
            return operating
        }
        return allSelectable.first
    }

    private func selectTunnel(_ tunnel: TunnelContainer?, animated: Bool) {
        selectedTunnel = tunnel
        MapHomeSettings.selectedTunnelName = tunnel?.name
        lastGroupState = nil
        runtimeStatsText = nil
        statusObservation = tunnel?.observe(\.status) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.runtimeStatsText = nil
                self?.refreshUI(animated: true)
            }
        }
        refreshUI(animated: animated)
        pollLiveState()
    }

    private func buildSelectionMenuItems() -> [UIMenuElement] {
        var sections = [UIMenuElement]()

        func actions(for tunnels: [TunnelContainer], image: UIImage?) -> [UIAction] {
            return tunnels.map { tunnel in
                UIAction(title: tunnel.name, image: image,
                         state: tunnel === selectedTunnel ? .on : .off) { [weak self] _ in
                    self?.selectTunnel(tunnel, animated: true)
                }
            }
        }

        let failoverActions = actions(for: tunnelsManager.failoverGroupTunnels,
                                      image: UIImage(systemName: "arrow.triangle.2.circlepath"))
        if !failoverActions.isEmpty {
            sections.append(UIMenu(title: "Failover Groups", options: .displayInline, children: failoverActions))
        }

        let titActions = actions(for: tunnelsManager.titGroupTunnels,
                                 image: UIImage(systemName: "smallcircle.filled.circle"))
        if !titActions.isEmpty {
            sections.append(UIMenu(title: "Tunnel-in-Tunnel", options: .displayInline, children: titActions))
        }

        let tunnelActions = actions(for: tunnelsManager.tunnels, image: UIImage(systemName: "lock.shield"))
        if !tunnelActions.isEmpty {
            sections.append(UIMenu(title: "Tunnels", options: .displayInline, children: tunnelActions))
        }

        if sections.isEmpty {
            sections.append(UIAction(title: "No tunnels configured", attributes: .disabled) { _ in })
        }
        return sections
    }

    private func buildOptionsMenuItems() -> [UIMenuElement] {
        let myLocation = UIAction(title: "Set My Location…",
                                  image: UIImage(systemName: "location")) { [weak self] _ in
            self?.presentMyLocationPicker()
        }
        let endpointLocations = UIAction(title: "Endpoint Locations…",
                                         image: UIImage(systemName: "mappin.and.ellipse")) { [weak self] _ in
            self?.presentEndpointLocationsList()
        }
        let showAtLaunch = UIAction(title: "Open at Launch",
                                    image: UIImage(systemName: "house"),
                                    state: MapHomeSettings.isShownAtLaunch ? .on : .off) { _ in
            MapHomeSettings.isShownAtLaunch.toggle()
        }
        return [myLocation, endpointLocations, UIMenu(options: .displayInline, children: [showAtLaunch])]
    }

    // MARK: - Live state polling

    private func startPolling() {
        stopPolling()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            self?.pollLiveState()
        }
        pollLiveState()
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func pollLiveState() {
        guard let tunnel = selectedTunnel, tunnel.status == .active else { return }

        if let kind = tunnel.groupKind {
            tunnelsManager.getGroupState(kind: kind, for: tunnel) { [weak self] state in
                DispatchQueue.main.async {
                    guard let self = self, let state = state, self.selectedTunnel === tunnel else { return }
                    self.lastGroupState = state
                    self.refreshUI(animated: true)
                }
            }
        } else {
            tunnel.getRuntimeTunnelConfiguration { [weak self] runtimeConfig in
                DispatchQueue.main.async {
                    guard let self = self, self.selectedTunnel === tunnel else { return }
                    if let peers = runtimeConfig?.peers, !peers.isEmpty {
                        let rxTotal = peers.reduce(UInt64(0)) { $0 + ($1.rxBytes ?? 0) }
                        let txTotal = peers.reduce(UInt64(0)) { $0 + ($1.txBytes ?? 0) }
                        self.runtimeStatsText = MapHomeViewController.statsText(rxBytes: rxTotal, txBytes: txTotal)
                    }
                    self.updateCard()
                }
            }
        }
    }

    private static func statsText(rxBytes: UInt64, txBytes: UInt64) -> String? {
        guard rxBytes > 0 || txBytes > 0 else { return nil }
        return "↓ \(FormattingHelpers.prettyBytes(rxBytes))  ↑ \(FormattingHelpers.prettyBytes(txBytes))"
    }

    // MARK: - UI refresh

    private func refreshUI(animated: Bool) {
        updateHeader(animated: animated)
        updateCard()
        refreshScene(animated: animated)
    }

    private func refreshScene(animated: Bool) {
        let scene = MapSceneBuilder.scene(for: selectedTunnel,
                                          groupState: lastGroupState,
                                          userLocation: UserLocationProvider.current())
        if scene != lastScene {
            mapView.setScene(scene, animated: animated && lastScene != nil)
            lastScene = scene
        }
        updateUnlocatedChip(unlocatedNames: scene.unlocatedTunnelNames)
    }

    private enum ProtectionState {
        case protected
        case connecting
        case unprotected
    }

    private var protectionState: ProtectionState {
        guard let status = selectedTunnel?.status else { return .unprotected }
        switch status {
        case .active, .reasserting, .restarting:
            return .protected
        case .activating, .waiting:
            return .connecting
        case .inactive, .deactivating:
            return .unprotected
        }
    }

    private func updateHeader(animated: Bool) {
        let tint: UIColor
        switch protectionState {
        case .protected:
            tint = MapPalette.protectedTint
            statusIconView.image = UIImage(systemName: "lock.fill")
            statusTitleLabel.text = "You are protected"
        case .connecting:
            tint = MapPalette.connectingTint
            statusIconView.image = UIImage(systemName: "lock.rotation")
            statusTitleLabel.text = selectedTunnel?.status == .waiting ? "Waiting…" : "Connecting…"
        case .unprotected:
            tint = MapPalette.unprotectedTint
            statusIconView.image = UIImage(systemName: "lock.open.fill")
            statusTitleLabel.text = "You are unprotected"
        }
        statusIconView.tintColor = tint
        statusIconContainer.backgroundColor = tint.withAlphaComponent(0.16)
        statusPillLabel.text = pillText()

        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.4 : 0)
        gradientLayer.colors = [tint.withAlphaComponent(0.28).cgColor, UIColor.clear.cgColor]
        CATransaction.commit()
    }

    private func pillText() -> String {
        if let tunnel = selectedTunnel, tunnel.status == .active {
            var parts = [String]()
            if let exitLocation = currentExitLocation() {
                parts.append(exitLocation.flaggedDisplayName)
            }
            if IPDiscoverySettings.isEnabled, let discoveredIP = IPDiscoverySettings.discoveredIP {
                parts.append(discoveredIP)
            }
            if parts.isEmpty {
                parts.append(tunnel.name)
            }
            return parts.joined(separator: " · ")
        }
        let userLocation = UserLocationProvider.current()
        return userLocation.isManualOverride ? userLocation.label : "\(userLocation.label) · approximate"
    }

    /// The location traffic exits from: the active failover member, the inner
    /// (exit) hop of a tunnel-in-tunnel chain, or the tunnel's own endpoint.
    private func currentExitLocation() -> EndpointLocation? {
        guard let tunnel = selectedTunnel else { return nil }
        let locations = EndpointLocationStore.locationsByTunnelName()
        switch tunnel.groupKind {
        case .failover:
            let members = tunnel.mapHomeFailoverMemberNames
            let activeName = (lastGroupState?["activeConfig"] as? String) ?? members.first
            return activeName.flatMap { locations[$0] }
        case .tunnelInTunnel:
            if let innerName = tunnel.mapHomeTiTInnerName, let location = locations[innerName] {
                return location
            }
            return tunnel.mapHomeTiTOuterName.flatMap { locations[$0] }
        case nil:
            return locations[tunnel.name]
        }
    }

    private func updateCard() {
        guard let tunnel = selectedTunnel else {
            kindIconView.image = UIImage(systemName: "lock.shield")
            selectionNameLabel.text = "No tunnels"
            selectionDetailLabel.text = "Add a tunnel from the tunnels list first"
            connectButton.setTitle("Connect", for: .normal)
            connectButton.isEnabled = false
            connectButton.backgroundColor = UIColor(white: 1, alpha: 0.1)
            connectButton.setTitleColor(UIColor(white: 1, alpha: 0.4), for: .normal)
            return
        }

        selectionNameLabel.text = tunnel.name
        switch tunnel.groupKind {
        case .failover:
            kindIconView.image = UIImage(systemName: "arrow.triangle.2.circlepath")
        case .tunnelInTunnel:
            kindIconView.image = UIImage(systemName: "smallcircle.filled.circle")
        case nil:
            kindIconView.image = UIImage(systemName: "lock.shield")
        }
        selectionDetailLabel.text = selectionDetailText(for: tunnel)

        switch tunnel.status {
        case .inactive:
            connectButton.setTitle("Connect", for: .normal)
            connectButton.isEnabled = true
            connectButton.backgroundColor = MapPalette.accent
            connectButton.setTitleColor(.white, for: .normal)
        case .activating, .waiting:
            connectButton.setTitle("Cancel", for: .normal)
            connectButton.isEnabled = true
            connectButton.backgroundColor = MapPalette.accent.withAlphaComponent(0.5)
            connectButton.setTitleColor(.white, for: .normal)
        case .active, .restarting, .reasserting:
            connectButton.setTitle("Disconnect", for: .normal)
            connectButton.isEnabled = true
            connectButton.backgroundColor = UIColor(white: 1, alpha: 0.14)
            connectButton.setTitleColor(.white, for: .normal)
        case .deactivating:
            connectButton.setTitle("Disconnecting…", for: .normal)
            connectButton.isEnabled = false
            connectButton.backgroundColor = UIColor(white: 1, alpha: 0.1)
            connectButton.setTitleColor(UIColor(white: 1, alpha: 0.5), for: .normal)
        }
    }

    private func selectionDetailText(for tunnel: TunnelContainer) -> String {
        let locations = EndpointLocationStore.locationsByTunnelName()
        var parts = [String]()

        switch tunnel.groupKind {
        case .failover:
            let members = tunnel.mapHomeFailoverMemberNames
            if tunnel.status == .active {
                let activeName = (lastGroupState?["activeConfig"] as? String) ?? members.first ?? "?"
                let display = locations[activeName]?.flaggedDisplayName ?? activeName
                parts.append("via \(display)")
                if let spareIndex = lastGroupState?["hotSpareConfigIndex"] as? Int,
                   let spareAge = lastGroupState?["hotSpareHandshakeAge"] as? Double,
                   spareAge < 180, spareIndex < members.count {
                    parts.append("spare ready")
                }
                if let rxBytes = lastGroupState?["rxBytes"] as? UInt64,
                   let txBytes = lastGroupState?["txBytes"] as? UInt64,
                   let stats = MapHomeViewController.statsText(rxBytes: rxBytes, txBytes: txBytes) {
                    parts.append(stats)
                }
            } else {
                parts.append("Failover · \(members.count) connections")
            }
        case .tunnelInTunnel:
            let outerName = tunnel.mapHomeTiTOuterName ?? "?"
            let innerName = tunnel.mapHomeTiTInnerName ?? "?"
            let outerDisplay = locations[outerName]?.displayName ?? outerName
            let innerDisplay = locations[innerName]?.displayName ?? innerName
            parts.append("via \(outerDisplay) → \(innerDisplay)")
            if tunnel.status == .active,
               let rxBytes = lastGroupState?["innerRxBytes"] as? UInt64,
               let txBytes = lastGroupState?["innerTxBytes"] as? UInt64,
               let stats = MapHomeViewController.statsText(rxBytes: rxBytes, txBytes: txBytes) {
                parts.append(stats)
            }
        case nil:
            if let location = locations[tunnel.name] {
                parts.append(location.flaggedDisplayName)
            } else {
                parts.append("No location set")
            }
            if tunnel.status == .active, let stats = runtimeStatsText {
                parts.append(stats)
            }
        }
        return parts.joined(separator: " · ")
    }

    private func updateUnlocatedChip(unlocatedNames: [String]) {
        guard let firstName = unlocatedNames.first else {
            unlocatedChipButton.isHidden = true
            return
        }
        var title = "Set location for “\(firstName)”"
        if unlocatedNames.count > 1 {
            title += " (+\(unlocatedNames.count - 1) more)"
        }
        unlocatedChipButton.setTitle(title, for: .normal)
        unlocatedChipButton.isHidden = false
    }

    // MARK: - Actions

    @objc private func closeTapped() {
        dismiss(animated: true)
    }

    @objc private func connectTapped() {
        guard let tunnel = selectedTunnel else { return }
        switch tunnel.status {
        case .inactive:
            tunnelsManager.startActivation(of: tunnel)
        case .active, .activating, .waiting, .restarting, .reasserting:
            if tunnel.isActivateOnDemandEnabled {
                tunnelsManager.setOnDemandEnabled(false, on: tunnel) { [weak self] error in
                    guard error == nil, let self = self else { return }
                    self.tunnelsManager.startDeactivation(of: tunnel)
                }
            } else {
                tunnelsManager.startDeactivation(of: tunnel)
            }
        case .deactivating:
            break
        }
    }

    @objc private func unlocatedChipTapped() {
        guard let firstName = lastScene?.unlocatedTunnelNames.first else { return }
        presentLocationPicker(title: firstName, clearOptionTitle: nil) { city in
            guard let city = city else { return }
            EndpointLocationStore.setLocation(EndpointLocation(city: city), forTunnelNamed: firstName)
        }
    }

    @objc private func locationsDidChange() {
        refreshUI(animated: true)
    }

    @objc private func applicationDidBecomeActive() {
        mapView.restartAnimations()
        refreshUI(animated: false)
    }

    // MARK: - Pickers

    private func presentMyLocationPicker() {
        presentLocationPicker(title: "My Location", clearOptionTitle: "Automatic (Time Zone)") { city in
            EndpointLocationStore.userLocationOverride = city.map { EndpointLocation(city: $0) }
        }
    }

    private func presentEndpointLocationsList() {
        let locationsVC = EndpointLocationsViewController(tunnelsManager: tunnelsManager)
        presentInDarkNavigationController(locationsVC)
    }

    private func presentLocationPicker(title: String, clearOptionTitle: String?, onSelect: @escaping (MapCity?) -> Void) {
        let pickerVC = LocationPickerViewController(clearOptionTitle: clearOptionTitle, onSelect: onSelect)
        pickerVC.title = title
        presentInDarkNavigationController(pickerVC)
    }

    private func presentInDarkNavigationController(_ viewController: UIViewController) {
        let navController = UINavigationController(rootViewController: viewController)
        navController.modalPresentationStyle = .formSheet
        navController.overrideUserInterfaceStyle = .dark
        present(navController, animated: true)
    }
}

// MARK: - TunnelsManagerActivationDelegate

extension MapHomeViewController: TunnelsManagerActivationDelegate {
    func tunnelActivationAttemptFailed(tunnel: TunnelContainer, error: TunnelsManagerActivationAttemptError) {
        ErrorPresenter.showErrorAlert(error: error, from: self)
    }

    func tunnelActivationAttemptSucceeded(tunnel: TunnelContainer) {
        // Nothing to do
    }

    func tunnelActivationFailed(tunnel: TunnelContainer, error: TunnelsManagerActivationError) {
        ErrorPresenter.showErrorAlert(error: error, from: self)
    }

    func tunnelActivationSucceeded(tunnel: TunnelContainer) {
        // Nothing to do
    }
}
