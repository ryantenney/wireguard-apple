// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import SwiftUI

/// The headline failover screen: live priority order with probe/hot-spare
/// health, the failover-behavior controls, and a recent-event line.
struct FailoverGroupView: View {
    @ObservedObject var node: TunnelNode
    @EnvironmentObject var store: TunnelStore
    @EnvironmentObject var theme: AppTheme

    var body: some View {
        ZStack {
            Palette.screenBackground.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    headerBlock
                    prioritySection
                    behaviorSection
                    recentSection
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 24)
            }
        }
        .onAppear { store.startPolling(node) }
        .onDisappear { store.stopPolling(node) }
    }

    // MARK: - Header

    private var headerBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(node.name)
                .font(.appSans(28, .bold))
                .foregroundColor(Palette.primaryText)
            HStack(spacing: 8) {
                SolidDot(color: healthColor, size: 8)
                healthLine
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 18)
    }

    private var healthLine: some View {
        let accent = theme.accent.color
        return Group {
            if node.isActive {
                let healthy = node.failoverState?.isHealthy ?? true
                let path = node.failoverState?.activeConfig ?? node.failoverMemberNames.first ?? "—"
                (Text(healthy ? "Healthy" : "Unhealthy")
                    + Text(node.isOnDemandEnabled ? " · armed · path " : " · path ")
                    + Text(path).foregroundColor(accent))
                    .font(.appMono(12))
                    .foregroundColor(Palette.secondaryText)
            } else {
                Text(node.switchIsOn ? "Armed · waiting" : "Disconnected")
                    .font(.appMono(12))
                    .foregroundColor(Palette.secondaryText)
            }
        }
    }

    private var healthColor: Color {
        guard node.isActive else { return Palette.idle }
        return (node.failoverState?.isHealthy ?? true) ? Palette.healthy : Palette.warning
    }

    // MARK: - Priority order

    private var prioritySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Priority Order")
            VStack(spacing: 10) {
                let names = node.failoverMemberNames
                ForEach(Array(names.enumerated()), id: \.offset) { index, name in
                    PriorityCard(node: node, index: index, name: name, accent: theme.accent.color)
                }
            }
        }
        .padding(.bottom, 20)
    }

    // MARK: - Behavior

    private var behaviorSection: some View {
        let accent = theme.accent.color
        return VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Failover Behavior")
            GroupedCard {
                ToggleRow(title: "Background probes",
                          subtitle: "Test failback without disrupting traffic",
                          isOn: backgroundProbesBinding,
                          accent: accent)
                RowDivider()
                ToggleRow(title: "Hot spare",
                          subtitle: "Keep next target warm · zero-handshake switch",
                          isOn: hotSpareBinding,
                          accent: accent)
                RowDivider()
                VStack(alignment: .leading, spacing: 11) {
                    Text("Sensitivity")
                        .font(.appSans(14))
                        .foregroundColor(Palette.primaryText)
                    SensitivityPicker(selection: sensitivityBinding, accent: accent)
                }
                .padding(.horizontal, 15)
                .padding(.vertical, 13)
            }
        }
        .padding(.bottom, 20)
    }

    private var backgroundProbesBinding: Binding<Bool> {
        Binding(
            get: { node.failoverSettings.useBackgroundProbes },
            set: { newValue in
                var settings = node.failoverSettings
                settings.useBackgroundProbes = newValue
                store.updateFailoverSettings(settings, for: node)
            })
    }

    private var hotSpareBinding: Binding<Bool> {
        Binding(
            get: { node.failoverSettings.hotSpare },
            set: { newValue in
                var settings = node.failoverSettings
                settings.hotSpare = newValue
                store.updateFailoverSettings(settings, for: node)
            })
    }

    private var sensitivityBinding: Binding<FailoverSensitivity> {
        Binding(
            get: { FailoverSensitivity(from: node.failoverSettings) },
            set: { newValue in
                let settings = newValue.applied(to: node.failoverSettings)
                store.updateFailoverSettings(settings, for: node)
            })
    }

    // MARK: - Recent

    @ViewBuilder private var recentSection: some View {
        if let lastSwitch = node.failoverState?.lastSwitchTime {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeader(title: "Recent")
                HStack(spacing: 8) {
                    Text("●").foregroundColor(Palette.warning)
                    Text("\(WGFormat.clockTime(lastSwitch))  last failover event")
                        .foregroundColor(Palette.secondaryText)
                }
                .font(.appMono(11))
            }
        }
    }
}

// MARK: - Priority card

private struct PriorityCard: View {
    @ObservedObject var node: TunnelNode
    let index: Int
    let name: String
    let accent: Color

    var body: some View {
        let health = node.failoverState?.health(forMemberAt: index, name: name, groupIsActive: node.isActive) ?? .standby
        let isActive = health == .carrying
        HStack(spacing: 13) {
            Text("\(index + 1)")
                .font(.appMono(13))
                .foregroundColor(isActive ? accent : Palette.mutedText)
                .frame(width: 14)
            dot(for: health)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(name)
                        .font(.appSans(15, isActive ? .semibold : .medium))
                        .foregroundColor(Palette.primaryText)
                    if showsHotSpareBadge {
                        Badge(text: "HOT SPARE", color: Palette.warning)
                    }
                }
                Text(descriptor(for: health))
                    .font(.appMono(11))
                    .foregroundColor(isActive ? accent : Palette.mutedText)
            }
            Spacer(minLength: 8)
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 15))
                .foregroundColor(Palette.faintText)
        }
        .padding(15)
        .background(isActive ? accent.opacity(0.10) : Palette.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(isActive ? accent.opacity(0.28) : Palette.cardBorder, lineWidth: 1)
        )
    }

    @ViewBuilder private func dot(for health: FailoverRuntimeState.MemberHealth) -> some View {
        switch health {
        case .carrying:
            PulseDot(color: accent, size: 13)
        case .unhealthy, .probing:
            SolidDot(color: Palette.warning, size: 13)
        case .hotSpareReady, .hotSpareWaiting, .standby:
            RingDot(color: Palette.healthy, size: 13)
        case .idle:
            RingDot(color: Palette.idle, size: 13)
        }
    }

    private var showsHotSpareBadge: Bool {
        if let stateIndex = node.failoverState?.hotSpareConfigIndex {
            return stateIndex == index
        }
        return node.failoverState == nil && node.failoverSettings.hotSpare && index == 1
    }

    private func descriptor(for health: FailoverRuntimeState.MemberHealth) -> String {
        switch health {
        case .carrying:
            if let state = node.failoverState, let rx = state.rxBytes, let tx = state.txBytes {
                return "carrying traffic · ↓\(WGFormat.compactBytes(rx)) ↑\(WGFormat.compactBytes(tx))"
            }
            return "carrying traffic"
        case .unhealthy: return "unhealthy · tx without rx"
        case .hotSpareReady: return "probe healthy · session warm"
        case .hotSpareWaiting: return "hot spare · connecting"
        case .probing: return "probing primary"
        case .standby: return "probe healthy"
        case .idle: return "idle"
        }
    }
}
