// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import SwiftUI

/// The "Add a Tunnel" sheet: every import route the app supports, surfaced as
/// equal options. Each row routes through `AppRouter`, which dismisses the sheet
/// and presents the appropriate existing flow.
struct AddTunnelSheet: View {
    @EnvironmentObject var router: AppRouter
    @EnvironmentObject var theme: AppTheme

    var body: some View {
        ZStack(alignment: .top) {
            Palette.screenBackground.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Capsule()
                        .fill(Palette.faintText.opacity(0.5))
                        .frame(width: 38, height: 5)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 11)
                        .padding(.bottom, 18)

                    Text("Add a Tunnel")
                        .font(.appSans(26, .bold))
                        .foregroundColor(Palette.primaryText)
                    Text("Import an existing config or generate a fresh keypair.")
                        .font(.appSans(14))
                        .foregroundColor(Palette.secondaryText)
                        .padding(.top, 4)
                        .padding(.bottom, 22)

                    VStack(spacing: 12) {
                        primaryOption
                        OptionRow(icon: "doc.text", title: "Import file or archive",
                                  subtitle: ".conf · .zip", mono: true) { router.importFile() }
                        OptionRow(icon: "qrcode.viewfinder", title: "Scan QR code",
                                  subtitle: "Point at a config QR from your server") { router.scanQRCode() }
                        OptionRow(icon: "arrow.triangle.branch", title: "Create failover group",
                                  subtitle: "Ordered tunnels with automatic failover") { router.createFailoverGroup() }
                        OptionRow(icon: "square.stack.3d.up", title: "Create tunnel-in-tunnel",
                                  subtitle: "Route one tunnel through another") { router.createTiTGroup() }
                    }

                    HStack(spacing: 10) {
                        Rectangle().fill(Palette.separator).frame(height: 1)
                        Text("OR").font(.appMono(11)).foregroundColor(Palette.faintText)
                        Rectangle().fill(Palette.separator).frame(height: 1)
                    }
                    .padding(.vertical, 22)

                    Button {
                        router.pasteFromClipboard()
                    } label: {
                        Text("Paste from clipboard")
                            .font(.appSans(14, .medium))
                            .foregroundColor(theme.accent.color)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
    }

    private var primaryOption: some View {
        let accent = theme.accent.color
        return Button {
            router.createTunnelFromScratch()
        } label: {
            HStack(spacing: 15) {
                Image(systemName: "plus")
                    .font(.system(size: 24, weight: .regular))
                    .foregroundColor(.white)
                    .frame(width: 46, height: 46)
                    .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(accent))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Create from scratch")
                        .font(.appSans(16, .semibold))
                        .foregroundColor(Palette.primaryText)
                    Text("Generate a keypair, add peers manually")
                        .font(.appSans(12))
                        .foregroundColor(Palette.secondaryText)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Palette.faintText)
            }
            .padding(17)
            .background(accent.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(accent.opacity(0.28), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

private struct OptionRow: View {
    let icon: String
    let title: String
    var subtitle: String
    var mono: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 15) {
                Image(systemName: icon)
                    .font(.system(size: 19))
                    .foregroundColor(Palette.secondaryText)
                    .frame(width: 46, height: 46)
                    .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Palette.cardSurface))
                    .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Palette.cardBorder, lineWidth: 1))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.appSans(16, .semibold))
                        .foregroundColor(Palette.primaryText)
                    Text(subtitle)
                        .font(mono ? .appMono(11) : .appSans(12))
                        .foregroundColor(Palette.secondaryText)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Palette.faintText)
            }
            .padding(17)
            .cardBackground(cornerRadius: 18)
        }
        .buttonStyle(.plain)
    }
}
