// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import Foundation

/// User preferences for VPN-related notifications. Persisted in the shared app group
/// UserDefaults so both the main app and the Network Extension can read them.
struct NotificationSettings {

    private static let keyDisconnectNotifications = "notifyOnDisconnect"
    private static let keyFailoverNotifications = "notifyOnFailover"
    private static let keyCaptivePortalNotifications = "notifyOnCaptivePortal"

    /// Notification category identifier for captive-portal notifications. The app's
    /// notification delegate routes taps on this category to the sign-in sheet.
    static let captivePortalCategoryIdentifier = "CAPTIVE_PORTAL"

    private static var userDefaults: UserDefaults? {
        guard let appGroupId = FileManager.appGroupId else { return nil }
        return UserDefaults(suiteName: appGroupId)
    }

    static var isDisconnectNotificationEnabled: Bool {
        get { return userDefaults?.bool(forKey: keyDisconnectNotifications) ?? false }
        set { userDefaults?.set(newValue, forKey: keyDisconnectNotifications) }
    }

    static var isFailoverNotificationEnabled: Bool {
        get { return userDefaults?.bool(forKey: keyFailoverNotifications) ?? false }
        set { userDefaults?.set(newValue, forKey: keyFailoverNotifications) }
    }

    static var isCaptivePortalNotificationEnabled: Bool {
        get { return userDefaults?.bool(forKey: keyCaptivePortalNotifications) ?? false }
        set { userDefaults?.set(newValue, forKey: keyCaptivePortalNotifications) }
    }
}
