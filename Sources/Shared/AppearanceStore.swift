// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import Foundation

/// Shared accent-color preference, persisted in the app group so the main app
/// and the widget render the same accent. Stored as a packed 0xRRGGBB value.
enum AppearanceStore {

    /// Default accent (orange) — the redesign's chosen light-mode hero.
    static let defaultAccentRGB: UInt32 = 0xFF7A47

    private static let accentKey = "wgnext.theme.accentRGB"

    private static var userDefaults: UserDefaults? {
        #if os(iOS)
        let key = "app.wgnext.ios.app_group_id"
        #elseif os(macOS)
        let key = "app.wgnext.macos.app_group_id"
        #else
        #error("Unimplemented")
        #endif
        guard let appGroupId = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        return UserDefaults(suiteName: appGroupId)
    }

    /// The selected accent as a packed 0xRRGGBB value. Defaults to orange.
    static var accentRGB: UInt32 {
        get {
            guard let number = userDefaults?.object(forKey: accentKey) as? NSNumber else {
                return defaultAccentRGB
            }
            return number.uint32Value
        }
        set { userDefaults?.set(NSNumber(value: newValue), forKey: accentKey) }
    }
}
