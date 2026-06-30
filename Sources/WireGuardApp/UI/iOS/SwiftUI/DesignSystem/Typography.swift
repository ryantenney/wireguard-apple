// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import SwiftUI

/// Centralized typography for the redesigned UI.
///
/// The mockup uses Geist / Geist Mono. We currently render with the system
/// faces (SF Pro / SF Mono) so there are no bundled-font or licensing concerns.
/// To switch to Geist later, drop the font files into the bundle, register them
/// in Info.plist under `UIAppFonts`, and change the two `Font` factories below —
/// every screen picks it up automatically.
enum AppFont {

    /// Set to a bundled family name (e.g. "Geist") to use a custom sans face.
    /// `nil` falls back to the system font.
    static let sansFamily: String? = nil

    /// Set to a bundled family name (e.g. "Geist Mono") to use a custom mono face.
    /// `nil` falls back to the system monospaced font.
    static let monoFamily: String? = nil

    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        if let family = sansFamily {
            return .custom(family, fixedSize: size).weight(weight)
        }
        return .system(size: size, weight: weight)
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        if let family = monoFamily {
            return .custom(family, fixedSize: size).weight(weight)
        }
        return .system(size: size, weight: weight, design: .monospaced)
    }
}

extension Font {
    static func appSans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        AppFont.sans(size, weight)
    }

    static func appMono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        AppFont.mono(size, weight)
    }
}
