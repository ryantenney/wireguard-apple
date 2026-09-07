// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.
// Copyright © 2026 Ryan Tenney.

import UIKit

class MainViewController: UISplitViewController {

    var tunnelsManager: TunnelsManager?
    var onTunnelsManagerReady: ((TunnelsManager) -> Void)?
    var homeHost: TunnelsHomeHostingController?

    init() {
        let detailVC = UIViewController()
        detailVC.view.backgroundColor = .systemBackground
        let detailNC = UINavigationController(rootViewController: detailVC)

        let masterVC = TunnelsHomeHostingController()
        let masterNC = UINavigationController(rootViewController: masterVC)

        homeHost = masterVC

        super.init(nibName: nil, bundle: nil)

        viewControllers = [ masterNC, detailNC ]

        restorationIdentifier = "MainVC"
        masterNC.restorationIdentifier = "MasterNC"
        detailNC.restorationIdentifier = "DetailNC"
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        delegate = self

        // On iPad, always show both masterVC and detailVC, even in portrait mode, like the Settings app
        preferredDisplayMode = .allVisible

        // Create the tunnels manager, and when it's ready, hand it to the SwiftUI host.
        TunnelsManager.create { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .failure(let error):
                ErrorPresenter.showErrorAlert(error: error, from: self)
            case .success(let tunnelsManager):
                self.tunnelsManager = tunnelsManager
                self.homeHost?.install(manager: tunnelsManager)

                tunnelsManager.activationDelegate = self

                self.onTunnelsManagerReady?(tunnelsManager)
                self.onTunnelsManagerReady = nil

                if MapHomeSettings.isShownAtLaunch {
                    self.homeHost?.presentMapHomeAtLaunch()
                }
            }
        }
    }

    func allTunnelNames() -> [String]? {
        guard let tunnelsManager = self.tunnelsManager else { return nil }
        return tunnelsManager.mapTunnels { $0.name }
    }
}

extension MainViewController: TunnelsManagerActivationDelegate {
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

extension MainViewController {
    func refreshTunnelConnectionStatuses() {
        if let tunnelsManager = tunnelsManager {
            tunnelsManager.refreshStatuses()
        }
    }

    func showTunnelDetailForTunnel(named tunnelName: String, animated: Bool, shouldToggleStatus: Bool) {
        let showTunnelDetailBlock: (TunnelsManager) -> Void = { [weak self] _ in
            guard let self = self else { return }
            self.homeHost?.showTunnelDetail(named: tunnelName, shouldToggle: shouldToggleStatus)
        }
        if let tunnelsManager = tunnelsManager {
            showTunnelDetailBlock(tunnelsManager)
        } else {
            onTunnelsManagerReady = showTunnelDetailBlock
        }
    }

    /// Present the captive-portal sign-in sheet (WKWebView flow). Invoked when the
    /// user taps the extension's "Wi-Fi requires sign-in" notification.
    func presentCaptivePortalSignIn() {
        let presentBlock: (TunnelsManager) -> Void = { [weak self] tunnelsManager in
            guard let self = self else { return }
            // Already showing the sheet (e.g. repeat notification tap) — don't stack another.
            var topVC: UIViewController = self
            while let presented = topVC.presentedViewController {
                if let navVC = presented as? UINavigationController,
                   navVC.viewControllers.first is CaptivePortalSignInViewController {
                    return
                }
                topVC = presented
            }
            let signInVC = CaptivePortalSignInViewController(tunnelsManager: tunnelsManager)
            let signInNC = UINavigationController(rootViewController: signInVC)
            signInNC.modalPresentationStyle = .pageSheet
            topVC.present(signInNC, animated: true)
        }
        if let tunnelsManager = tunnelsManager {
            presentBlock(tunnelsManager)
        } else {
            onTunnelsManagerReady = presentBlock
        }
    }

    func importFromDisposableFile(url: URL) {
        let importFromFileBlock: (TunnelsManager) -> Void = { [weak self] tunnelsManager in
            TunnelImporter.importFromFile(urls: [url], into: tunnelsManager, sourceVC: self, errorPresenterType: ErrorPresenter.self) {
                _ = FileManager.deleteFile(at: url)
            }
        }
        if let tunnelsManager = tunnelsManager {
            importFromFileBlock(tunnelsManager)
        } else {
            onTunnelsManagerReady = importFromFileBlock
        }
    }
}

extension MainViewController: UISplitViewControllerDelegate {
    func splitViewController(_ splitViewController: UISplitViewController,
                             collapseSecondary secondaryViewController: UIViewController,
                             onto primaryViewController: UIViewController) -> Bool {
        // On iPhone, if the secondaryVC (detailVC) is just a UIViewController, it indicates that it's empty,
        // so just show the primaryVC (masterVC).
        let detailVC = (secondaryViewController as? UINavigationController)?.viewControllers.first
        let isDetailVCEmpty: Bool
        if let detailVC = detailVC {
            isDetailVCEmpty = (type(of: detailVC) == UIViewController.self)
        } else {
            isDetailVCEmpty = true
        }
        return isDetailVCEmpty
    }
}
