// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import UIKit
import SwiftUI

/// Root of the iOS app: a single bottom tab bar with the tunnels UI (the
/// previous root split view controller), the speed test tab, and settings.
class RootTabBarController: UITabBarController {

    let mainVC = MainViewController()
    let speedTestVC = SpeedTestViewController()

    init() {
        super.init(nibName: nil, bundle: nil)

        restorationIdentifier = "RootTabBarVC"

        mainVC.tabBarItem = UITabBarItem(title: tr("tabTitleTunnels"), image: UIImage(systemName: "network"), tag: 0)

        let speedTestNC = UINavigationController(rootViewController: speedTestVC)
        speedTestNC.restorationIdentifier = "SpeedTestNC"
        speedTestNC.tabBarItem = UITabBarItem(title: tr("tabTitleSpeedTest"), image: UIImage(systemName: "speedometer"), tag: 1)

        // Settings shares the tunnels UI's theme/router so appearance and
        // navigation stay consistent; it used to live in a second, in-content
        // tab bar that has now been folded into this one.
        let settingsNC = RootTabBarController.makeSettingsTab(homeHost: mainVC.homeHost)
        settingsNC.tabBarItem = UITabBarItem(title: tr("tabTitleSettings"), image: UIImage(systemName: "gearshape"), tag: 2)

        speedTestVC.activeTunnelNameProvider = { [weak self] in
            guard let tunnelsManager = self?.mainVC.tunnelsManager else { return nil }
            let activeStatuses: [TunnelStatus] = [.active, .restarting, .reasserting]
            for index in 0 ..< tunnelsManager.numberOfTunnels() {
                let tunnel = tunnelsManager.tunnel(at: index)
                if activeStatuses.contains(tunnel.status) {
                    return tunnel.name
                }
            }
            for index in 0 ..< tunnelsManager.numberOfFailoverGroups() {
                let group = tunnelsManager.failoverGroup(at: index)
                if activeStatuses.contains(group.status) {
                    return group.name
                }
            }
            return nil
        }

        viewControllers = [mainVC, speedTestNC, settingsNC]
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Build the Settings tab: the SwiftUI `SettingsView` hosted in its own
    /// navigation controller, sharing the tunnels UI's theme and router.
    private static func makeSettingsTab(homeHost: TunnelsHomeHostingController?) -> UINavigationController {
        let settingsHost: UIViewController
        if let homeHost = homeHost {
            let root = SettingsView()
                .environmentObject(homeHost.theme)
                .environmentObject(homeHost.router)
            let host = ThemedHostingController(rootView: AnyView(root))
            host.hidesNavigationBar = true
            settingsHost = host
        } else {
            settingsHost = UIViewController()
        }
        let settingsNC = UINavigationController(rootViewController: settingsHost)
        settingsNC.restorationIdentifier = "SettingsNC"
        homeHost?.router.settingsNavigationController = settingsNC
        return settingsNC
    }
}
