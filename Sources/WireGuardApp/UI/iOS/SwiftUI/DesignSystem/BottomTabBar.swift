// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import SwiftUI

/// The redesign's two-item bottom bar (Tunnels / Settings). It is drawn by the
/// Home and Settings screens; switching between them is a UIKit push/pop driven
/// by the supplied callbacks.
struct BottomTabBar: View {
    enum Tab {
        case tunnels
        case settings
    }

    let selected: Tab
    var accent: Color
    var onSelectTunnels: () -> Void
    var onSelectSettings: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            item(.tunnels, label: "Tunnels", systemImage: "rectangle.stack", action: onSelectTunnels)
            item(.settings, label: "Settings", systemImage: "gearshape", action: onSelectSettings)
        }
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(.ultraThinMaterial)
        .overlay(
            Rectangle().fill(Palette.cardBorder).frame(height: 1),
            alignment: .top
        )
    }

    private func item(_ tab: Tab, label: String, systemImage: String, action: @escaping () -> Void) -> some View {
        let isSelected = tab == selected
        return Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .regular))
                Text(label)
                    .font(.appSans(10, isSelected ? .semibold : .medium))
            }
            .foregroundColor(isSelected ? accent : Palette.mutedText)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
