// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import SwiftUI
import UIKit
import WidgetKit

// MARK: - Color helpers

extension UIColor {
    fileprivate convenience init(rgb: UInt32, alpha: CGFloat = 1) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: alpha
        )
    }
}

extension Color {
    /// Solid color from a 0xRRGGBB literal.
    init(rgb: UInt32) {
        self = Color(uiColor: UIColor(rgb: rgb))
    }

    /// Dynamic color that resolves differently in light and dark appearance.
    init(light: UInt32, lightAlpha: CGFloat = 1, dark: UInt32, darkAlpha: CGFloat = 1) {
        self = Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(rgb: dark, alpha: darkAlpha)
                : UIColor(rgb: light, alpha: lightAlpha)
        })
    }
}

// MARK: - Accent

/// The four user-selectable accent colors from the redesign.
enum AppAccent: String, CaseIterable, Identifiable {
    case purple
    case blue
    case green
    case orange

    var id: String { rawValue }

    var rgb: UInt32 {
        switch self {
        case .purple: return 0xA875FB
        case .blue: return 0x5B8DFF
        case .green: return 0x3DDC97
        case .orange: return 0xFF7A47
        }
    }

    var color: Color { Color(rgb: rgb) }
    var uiColor: UIColor { UIColor(rgb: rgb) }

    /// Nearest accent for a packed 0xRRGGBB value (defaults to orange).
    static func matching(rgb: UInt32) -> AppAccent {
        AppAccent.allCases.first { $0.rgb == rgb } ?? .orange
    }

    var displayName: String {
        switch self {
        case .purple: return "Purple"
        case .blue: return "Blue"
        case .green: return "Green"
        case .orange: return "Orange"
        }
    }
}

// MARK: - Appearance

/// Light / Dark / follow-system, mirroring the redesign's Theme setting.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var userInterfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system: return .unspecified
        case .light: return .light
        case .dark: return .dark
        }
    }

    var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

// MARK: - AppTheme

/// Observable, persisted theme state. Injected into the SwiftUI hierarchy and
/// observed by the host so UIKit chrome (nav bars, modals) tracks the accent and
/// appearance too.
final class AppTheme: ObservableObject {
    static let shared = AppTheme()

    private enum Keys {
        static let appearance = "wgnext.theme.appearance"
    }

    /// Accent persists to the shared app group (`AppearanceStore`) so the widget
    /// renders the same accent; changing it refreshes the widget timelines.
    @Published var accent: AppAccent {
        didSet {
            AppearanceStore.accentRGB = accent.rgb
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    @Published var appearance: AppAppearance {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: Keys.appearance) }
    }

    init() {
        // Default accent is orange — the chosen light-mode hero in the redesign.
        accent = AppAccent.matching(rgb: AppearanceStore.accentRGB)
        appearance = AppAppearance(rawValue: UserDefaults.standard.string(forKey: Keys.appearance) ?? "") ?? .system
    }
}

// MARK: - Palette

/// Semantic colors for the redesign, each adapting to light/dark. Accent is not
/// here — it comes from `AppTheme` so it can change at runtime.
enum Palette {
    // Surfaces
    static let screenBackground = Color(light: 0xF4F5F7, dark: 0x0B0E12)
    static let cardSurface = Color(light: 0xFFFFFF, dark: 0x11141B)
    static let cardSurfaceElevated = Color(light: 0xFFFFFF, dark: 0x0D1016)
    static let cardBorder = Color(light: 0x000000, lightAlpha: 0.06, dark: 0xFFFFFF, darkAlpha: 0.07)
    static let separator = Color(light: 0xF0F1F4, dark: 0xFFFFFF, darkAlpha: 0.06)
    static let segmentTrack = Color(light: 0xEEF0F3, dark: 0x15191F)
    static let toggleOff = Color(light: 0xE2E4E9, dark: 0x2A3039)

    // Text
    static let primaryText = Color(light: 0x11151B, dark: 0xE7EAF0)
    static let secondaryText = Color(light: 0x6B7480, dark: 0x9AA3B2)
    static let mutedText = Color(light: 0x9AA3B0, dark: 0x6B7280)
    static let faintText = Color(light: 0xB3BAC4, dark: 0x5B6472)

    // Status / semantics
    static let healthy = Color(light: 0x1FA971, dark: 0x46D39A)
    static let warning = Color(light: 0xC98A14, dark: 0xF0B13B)
    static let danger = Color(light: 0xD9534A, dark: 0xF4685E)
    static let manualAmber = Color(rgb: 0xF0B13B)
    static let idle = Color(light: 0xB3BAC4, dark: 0x3A4150)
}
