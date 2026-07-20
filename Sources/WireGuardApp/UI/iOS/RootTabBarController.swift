// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import UIKit

/// Root of the iOS app: a tab bar with the tunnels UI (the previous root
/// split view controller) and the speed test tab.
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

        viewControllers = [mainVC, speedTestNC]
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
