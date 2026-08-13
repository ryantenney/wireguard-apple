// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import Foundation

/// User preferences for the Map Home landing page, stored in the shared app
/// group defaults.
struct MapHomeSettings {

    private static let keyShowAtLaunch = "mapHomeShowAtLaunch"
    private static let keySelectedTunnelName = "mapHomeSelectedTunnelName"

    private static var userDefaults: UserDefaults? {
        guard let appGroupId = FileManager.appGroupId else { return nil }
        return UserDefaults(suiteName: appGroupId)
    }

    /// Whether the app opens directly into the Map Home screen at launch.
    /// Defaults to `false`, keeping the classic tunnels list as the landing page.
    static var isShownAtLaunch: Bool {
        get { return userDefaults?.bool(forKey: keyShowAtLaunch) ?? false }
        set { userDefaults?.set(newValue, forKey: keyShowAtLaunch) }
    }

    /// Name of the tunnel or group last selected on the Map Home screen.
    static var selectedTunnelName: String? {
        get { return userDefaults?.string(forKey: keySelectedTunnelName) }
        set { userDefaults?.set(newValue, forKey: keySelectedTunnelName) }
    }
}
