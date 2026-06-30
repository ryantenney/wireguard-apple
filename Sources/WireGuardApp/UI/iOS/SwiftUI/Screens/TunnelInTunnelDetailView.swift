// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import SwiftUI

/// Tunnel-in-tunnel detail: the nested tunnels read as a layered traffic path —
/// a carrier (L1, reached over the network) and the exit (L2, reached inside the
/// carrier) — with per-layer live stats.
struct TunnelInTunnelDetailView: View {
    @ObservedObject var node: TunnelNode
    @EnvironmentObject var store: TunnelStore
    @EnvironmentObject var theme: AppTheme

    private let stackedColor = Color(rgb: 0xC084FC)

    var body: some View {
        ZStack {
            Palette.screenBackground.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    pathSection
                    layerCardsSection
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 24)
            }
        }
        .onAppear { store.startPolling(node) }
        .onDisappear { store.stopPolling(node) }
    }

    // MARK: - Header

    private var header: some View {
        let accent = theme.accent.color
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(node.name)
                        .font(.appSans(26, .bold))
                        .foregroundColor(Palette.primaryText)
                    HStack(spacing: 6) {
                        SolidDot(color: node.isActive ? accent : Palette.idle, size: 7)
                        Text(statusText)
                            .font(.appMono(11))
                            .foregroundColor(node.isActive ? accent : Palette.mutedText)
                    }
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { node.switchIsOn },
                    set: { store.setActive($0, node: node) }))
                    .labelsHidden()
                    .tint(accent)
            }
            .padding(.top, 8)

            Badge(text: "STACKED · 2 LAYERS", color: stackedColor)
                .padding(.top, 12)
                .padding(.bottom, 20)
        }
    }

    private var statusText: String {
        switch node.status {
        case .active:
            if let since = node.connectedSince {
                return "CONNECTED · \(WGFormat.duration(Date().timeIntervalSince(since)))"
            }
            return "CONNECTED"
        case .activating, .reasserting, .restarting, .waiting: return "CONNECTING"
        case .deactivating: return "DISCONNECTING"
        case .inactive: return "INACTIVE"
        }
    }

    // MARK: - Traffic path

    private var pathSection: some View {
        let accent = theme.accent.color
        return VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Traffic Path")
            VStack(spacing: 0) {
                pathRow(isLast: false) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Palette.idle)
                        .frame(width: 14, height: 14)
                } content: {
                    Text("Your device")
                        .font(.appSans(14, .medium))
                        .foregroundColor(Palette.secondaryText)
                }

                pathRow(isLast: false) {
                    Circle()
                        .fill(Palette.cardSurface)
                        .overlay(Circle().strokeBorder(accent, lineWidth: 2))
                        .frame(width: 16, height: 16)
                } content: {
                    layerCard(name: node.titOuterName,
                              badgeText: "CARRIER · L1",
                              badgeFilled: false,
                              subtitle: node.titOuterEndpoint,
                              tinted: false)
                }

                pathRow(isLast: false) {
                    Circle()
                        .fill(accent)
                        .frame(width: 16, height: 16)
                        .overlay(Circle().strokeBorder(accent.opacity(0.35), lineWidth: 3).padding(-3))
                } content: {
                    layerCard(name: node.titInnerName,
                              badgeText: "EXIT · L2",
                              badgeFilled: true,
                              subtitle: exitSubtitle,
                              tinted: true)
                }

                pathRow(isLast: true) {
                    Circle()
                        .fill(Palette.idle)
                        .frame(width: 14, height: 14)
                } content: {
                    HStack {
                        Text("Internet")
                            .font(.appSans(14, .medium))
                            .foregroundColor(Palette.secondaryText)
                        Spacer()
                        if let ip = IPDiscoverySettings.discoveredIP, node.isActive {
                            Text("apparent IP · \(ip)")
                                .font(.appMono(11))
                                .foregroundColor(Palette.mutedText)
                        }
                    }
                }
            }
        }
        .padding(.bottom, 20)
    }

    private var exitSubtitle: String {
        let inside = node.titOuterName.isEmpty ? "carrier" : node.titOuterName
        if let endpoint = node.titInnerEndpoint {
            return "\(endpoint) · reached inside \(inside)"
        }
        return "reached inside \(inside)"
    }

    @ViewBuilder
    private func pathRow<Dot: View, Content: View>(
        isLast: Bool,
        @ViewBuilder dot: () -> Dot,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                dot()
                    .padding(.top, 2)
                if !isLast {
                    Rectangle()
                        .fill(theme.accent.color.opacity(0.35))
                        .frame(width: 2)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 18)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, isLast ? 0 : 18)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func layerCard(name: String, badgeText: String, badgeFilled: Bool, subtitle: String?, tinted: Bool) -> some View {
        let accent = theme.accent.color
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(name)
                    .font(.appSans(15, .semibold))
                    .foregroundColor(Palette.primaryText)
                Spacer()
                Badge(text: badgeText, color: accent, filled: badgeFilled)
            }
            if let subtitle = subtitle {
                Text(subtitle)
                    .font(.appMono(11))
                    .foregroundColor(Palette.mutedText)
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
        .background(tinted ? accent.opacity(0.12) : Palette.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(accent.opacity(tinted ? 0.34 : 0.26), lineWidth: 1)
        )
    }

    // MARK: - Layer stat cards

    private var layerCardsSection: some View {
        HStack(spacing: 10) {
            layerStatCard(title: "Carrier", stats: node.titState?.outer)
            layerStatCard(title: "Exit", stats: node.titState?.inner)
        }
    }

    private func layerStatCard(title: String, stats: TiTRuntimeState.LayerStats?) -> some View {
        let accent = theme.accent.color
        return VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.appMono(10))
                .foregroundColor(Palette.secondaryText)
            if let stats = stats, stats.hasTraffic {
                HStack(spacing: 8) {
                    Text("↓\(WGFormat.compactBytes(stats.rxBytes ?? 0))")
                        .foregroundColor(Palette.healthy)
                    Text("↑\(WGFormat.compactBytes(stats.txBytes ?? 0))")
                        .foregroundColor(accent)
                }
                .font(.appMono(14))
                if let handshake = stats.lastHandshakeTime {
                    Text("handshake \(WGFormat.handshakeAgo(handshake))")
                        .font(.appMono(10))
                        .foregroundColor(Palette.mutedText)
                }
            } else {
                Text("—")
                    .font(.appMono(14))
                    .foregroundColor(Palette.mutedText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .cardBackground(cornerRadius: 14)
    }
}
