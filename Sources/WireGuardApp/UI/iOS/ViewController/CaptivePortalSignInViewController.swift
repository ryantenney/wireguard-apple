// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import UIKit
import WebKit

/// In-app browser for signing in to a captive portal Wi-Fi network.
///
/// Unlike the Network Extension's traffic, the app's traffic routes through the
/// tunnel, so the sheet pauses the active tunnel before loading the portal page.
/// It then loads the captive-check URL — the portal redirects to its sign-in
/// page — and re-probes with `CaptivePortalDetector` until the network clears,
/// at which point it reactivates the tunnel and dismisses itself. While the
/// portal is intercepting, on-demand's `probeURL` check fails, so on-demand
/// cannot fight the user by reconnecting mid-sign-in.
/// See DESIGN-captive-portal-handling.md (Phase 5).
class CaptivePortalSignInViewController: UIViewController {

    private let tunnelsManager: TunnelsManager
    private let detector = CaptivePortalDetector()

    /// The tunnel this sheet deactivated, to be reactivated on success or dismissal.
    private var pausedTunnel: TunnelContainer?

    /// Guards against reactivating more than once (success path + dismissal path).
    private var hasResumedTunnel = false

    private var pauseWaitTimer: Timer?
    private var probeTimer: Timer?

    /// How long to wait for the paused tunnel to reach `.inactive` before loading
    /// the portal page anyway.
    private var pauseWaitRemaining: TimeInterval = 8

    private lazy var webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        // Portal credentials shouldn't outlive the sheet.
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        return webView
    }()

    init(tunnelsManager: TunnelsManager) {
        self.tunnelsManager = tunnelsManager
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Wi-Fi Sign-In"
        view.backgroundColor = .systemBackground

        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(doneTapped))
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .refresh, target: self, action: #selector(reloadTapped))

        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        pauseActiveTunnelThenLoadPortal()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Covers swipe-to-dismiss as well as button dismissal.
        stopTimers()
        resumeTunnelIfNeeded()
    }

    // MARK: - Tunnel pause / resume

    private func pauseActiveTunnelThenLoadPortal() {
        let activeTunnel = findActiveTunnel()
        guard let tunnel = activeTunnel else {
            loadPortalPage()
            return
        }

        title = "Pausing VPN…"
        pausedTunnel = tunnel
        tunnelsManager.startDeactivation(of: tunnel)

        pauseWaitTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            self.pauseWaitRemaining -= 0.5
            if self.pausedTunnel?.status == .inactive || self.pauseWaitRemaining <= 0 {
                timer.invalidate()
                self.pauseWaitTimer = nil
                self.loadPortalPage()
            }
        }
    }

    private func findActiveTunnel() -> TunnelContainer? {
        for index in 0 ..< tunnelsManager.numberOfTunnels() {
            let tunnel = tunnelsManager.tunnel(at: index)
            if tunnel.status == .active || tunnel.status == .activating {
                return tunnel
            }
        }
        for index in 0 ..< tunnelsManager.numberOfFailoverGroups() {
            let tunnel = tunnelsManager.failoverGroup(at: index)
            if tunnel.status == .active || tunnel.status == .activating {
                return tunnel
            }
        }
        return nil
    }

    private func resumeTunnelIfNeeded() {
        guard !hasResumedTunnel, let tunnel = pausedTunnel else { return }
        hasResumedTunnel = true
        tunnelsManager.startActivation(of: tunnel)
    }

    // MARK: - Portal page & probing

    private func loadPortalPage() {
        title = "Wi-Fi Sign-In"
        webView.load(URLRequest(url: CaptivePortalDetector.defaultProbeURL))
        startProbing()
    }

    private func startProbing() {
        guard probeTimer == nil else { return }
        probeTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.probeNetwork()
        }
    }

    private func probeNetwork() {
        detector.check { [weak self] status in
            DispatchQueue.main.async {
                guard let self = self, status == .clear else { return }
                self.handleNetworkCleared()
            }
        }
    }

    private func handleNetworkCleared() {
        stopTimers()
        title = "Signed In"
        resumeTunnelIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.dismiss(animated: true)
        }
    }

    private func stopTimers() {
        pauseWaitTimer?.invalidate()
        pauseWaitTimer = nil
        probeTimer?.invalidate()
        probeTimer = nil
    }

    // MARK: - Actions

    @objc private func doneTapped() {
        stopTimers()
        resumeTunnelIfNeeded()
        dismiss(animated: true)
    }

    @objc private func reloadTapped() {
        webView.load(URLRequest(url: CaptivePortalDetector.defaultProbeURL))
    }
}

// MARK: - WKNavigationDelegate

extension CaptivePortalSignInViewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // A finished navigation often means the user just completed a sign-in step;
        // don't wait for the next timer tick to find out.
        probeNetwork()
    }
}
