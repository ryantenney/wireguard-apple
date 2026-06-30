// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import SwiftUI

/// The Home screen: the failover group is the headline "connection object",
/// with priority members below and any standalone tunnels under "Other tunnels".
/// When the user manually activates a standalone tunnel, the group pauses and an
/// override banner appears.
struct TunnelsHomeView: View {
    @EnvironmentObject var store: TunnelStore
    @EnvironmentObject var router: AppRouter
    @EnvironmentObject var theme: AppTheme

    var body: some View {
        ZStack(alignment: .bottom) {
            Palette.screenBackground.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    if store.isEmpty {
                        emptyState
                    } else {
                        heroSection
                        groupSection
                        titSection
                        otherTunnelsSection
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 96)
            }
            BottomTabBar(selected: .tunnels,
                         accent: theme.accent.color,
                         onSelectTunnels: {},
                         onSelectSettings: { router.showSettings() })
        }
        .onAppear { store.beginHomePolling() }
        .onDisappear { store.endHomePolling() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Tunnels")
                .font(.appSans(32, .bold))
                .foregroundColor(Palette.primaryText)
            Spacer()
            Button {
                router.presentAddTunnel()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundColor(theme.accent.color)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Palette.cardSurface))
                    .shadow(color: Color.black.opacity(0.06), radius: 2, x: 0, y: 1)
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 8)
        .padding(.bottom, 14)
    }

    // MARK: - Layout decisions

    private var group: TunnelNode? { store.primaryFailoverGroup }
    private var manualTunnel: TunnelNode? { store.activePlainTunnel }

    private var isManualOverride: Bool {
        guard let group = group else { return false }
        return manualTunnel != nil && !group.isOperational
    }

    private var memberNames: Set<String> {
        Set(store.failoverGroups.flatMap { $0.failoverMemberNames })
    }

    /// The standalone tunnel shown as the hero (single-tunnel or override case).
    private var plainHero: TunnelNode? {
        if let group = group {
            return group.isOperational ? nil : (isManualOverride ? manualTunnel : nil)
        }
        return manualTunnel
    }

    private var otherTunnels: [TunnelNode] {
        store.tunnels.filter { node in
            !memberNames.contains(node.name) && node.id != plainHero?.id
        }
    }

    // MARK: - Sections

    @ViewBuilder private var heroSection: some View {
        if let group = group {
            if group.isOperational {
                GroupHeroCard(group: group)
            } else if let manual = manualTunnel {
                ManualOverrideBanner(group: group)
                    .padding(.bottom, 16)
                TunnelHeroCard(node: manual, isManual: true)
            } else {
                GroupHeroCard(group: group)
            }
        } else if let manual = manualTunnel {
            TunnelHeroCard(node: manual, isManual: false)
        }
    }

    @ViewBuilder private var groupSection: some View {
        if let group = group {
            if isManualOverride {
                section("Failover Group") { PausedGroupCard(group: group) }
            } else {
                section("Priority Order") { PriorityOrderCard(group: group) }
            }
        }
    }

    @ViewBuilder private var titSection: some View {
        if !store.titGroups.isEmpty {
            section("Tunnel-in-Tunnel") {
                GroupedCard {
                    ForEach(Array(store.titGroups.enumerated()), id: \.element.id) { index, node in
                        if index > 0 { RowDivider() }
                        OtherTunnelRow(node: node, subtitle: "stacked tunnel")
                    }
                }
            }
        }
    }

    @ViewBuilder private var otherTunnelsSection: some View {
        if !otherTunnels.isEmpty {
            section(group == nil && plainHero == nil ? "Tunnels" : "Other Tunnels") {
                GroupedCard {
                    ForEach(Array(otherTunnels.enumerated()), id: \.element.id) { index, node in
                        if index > 0 { RowDivider() }
                        OtherTunnelRow(node: node, subtitle: node.primaryEndpointDescription)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Text("No tunnels yet")
                .font(.appSans(18, .semibold))
                .foregroundColor(Palette.primaryText)
            Text("Add a tunnel to get started.")
                .font(.appSans(14))
                .foregroundColor(Palette.secondaryText)
            Button {
                router.presentAddTunnel()
            } label: {
                Text("Add a Tunnel")
                    .font(.appSans(15, .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
                    .background(Capsule().fill(theme.accent.color))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    private func section<V: View>(_ title: String, @ViewBuilder content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: title)
            content()
        }
        .padding(.top, 18)
    }
}

// MARK: - Group hero (the connection object)

private struct GroupHeroCard: View {
    @ObservedObject var group: TunnelNode
    @EnvironmentObject var store: TunnelStore
    @EnvironmentObject var theme: AppTheme

    var body: some View {
        let accent = theme.accent.color
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                ConnectionStatusLabel(status: group.status, accent: accent)
                Spacer()
                if group.isActive, let since = group.connectedSince {
                    Text(WGFormat.duration(Date().timeIntervalSince(since)))
                        .font(.appMono(13))
                        .foregroundColor(Palette.secondaryText)
                }
            }
            .padding(.bottom, 14)

            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 9) {
                        Text(group.name)
                            .font(.appSans(22, .semibold))
                            .foregroundColor(Palette.primaryText)
                        if group.hasOnDemandRules && group.isOnDemandEnabled {
                            Badge(text: "ARMED", color: Palette.healthy)
                        }
                    }
                    Text(subtitle)
                        .font(.appMono(12))
                        .foregroundColor(Palette.secondaryText)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { group.switchIsOn },
                    set: { store.setActive($0, node: group) }))
                    .labelsHidden()
                    .tint(accent)
            }

            if group.isActive {
                Rectangle()
                    .fill(accent.opacity(0.16))
                    .frame(height: 1)
                    .padding(.top, 16)
                    .padding(.bottom, 14)
                HStack(spacing: 26) {
                    let download = WGFormat.throughput(bytesPerSecond: group.downloadBytesPerSecond)
                    let upload = WGFormat.throughput(bytesPerSecond: group.uploadBytesPerSecond)
                    ThroughputStat(label: "DOWNLOAD", arrow: "↓", value: download.value, unit: download.unit)
                    ThroughputStat(label: "UPLOAD", arrow: "↑", value: upload.value, unit: upload.unit)
                    Spacer()
                }
            }
        }
        .padding(18)
        .background(accent.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(accent.opacity(0.26), lineWidth: 1)
        )
    }

    private var subtitle: String {
        if group.isActive, let active = group.failoverState?.activeConfig ?? group.failoverMemberNames.first {
            return "failover group · on \(active)"
        }
        return "failover group · \(group.failoverMemberNames.count) tunnels"
    }
}

// MARK: - Standalone tunnel hero (single tunnel / manual override)

private struct TunnelHeroCard: View {
    @ObservedObject var node: TunnelNode
    let isManual: Bool
    @EnvironmentObject var store: TunnelStore
    @EnvironmentObject var theme: AppTheme
    @EnvironmentObject var router: AppRouter

    var body: some View {
        let accent = theme.accent.color
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                ConnectionStatusLabel(status: node.status, accent: accent)
                Spacer()
                if isManual {
                    Badge(text: "MANUAL", color: Palette.manualAmber)
                } else if node.isActive, let since = node.connectedSince {
                    Text(WGFormat.duration(Date().timeIntervalSince(since)))
                        .font(.appMono(13))
                        .foregroundColor(Palette.secondaryText)
                }
            }
            .padding(.bottom, 14)

            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(node.name)
                        .font(.appSans(22, .semibold))
                        .foregroundColor(Palette.primaryText)
                    if let endpoint = node.primaryEndpointDescription {
                        Text(endpoint)
                            .font(.appMono(12))
                            .foregroundColor(Palette.secondaryText)
                    }
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { node.switchIsOn },
                    set: { store.setActive($0, node: node) }))
                    .labelsHidden()
                    .tint(accent)
            }

            if node.isActive {
                Rectangle()
                    .fill(accent.opacity(0.16))
                    .frame(height: 1)
                    .padding(.top, 16)
                    .padding(.bottom, 14)
                HStack(spacing: 26) {
                    let download = WGFormat.throughput(bytesPerSecond: node.downloadBytesPerSecond)
                    let upload = WGFormat.throughput(bytesPerSecond: node.uploadBytesPerSecond)
                    ThroughputStat(label: "DOWNLOAD", arrow: "↓", value: download.value, unit: download.unit)
                    ThroughputStat(label: "UPLOAD", arrow: "↑", value: upload.value, unit: upload.unit)
                    Spacer()
                }
            }
        }
        .padding(18)
        .background(accent.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(accent.opacity(0.28), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { router.showTunnelDetail(node) }
    }
}

// MARK: - Manual override banner

private struct ManualOverrideBanner: View {
    @ObservedObject var group: TunnelNode
    @EnvironmentObject var store: TunnelStore

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 14))
                .foregroundColor(Palette.manualAmber)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.manualAmber.opacity(0.18)))
            VStack(alignment: .leading, spacing: 1) {
                Text("Manual override")
                    .font(.appSans(13, .semibold))
                    .foregroundColor(Palette.primaryText)
                Text("\(group.name) paused · on-demand rules stay live")
                    .font(.appSans(11))
                    .foregroundColor(Palette.secondaryText)
            }
            Spacer(minLength: 8)
            Button {
                store.resumeFailoverGroup(group)
            } label: {
                Text("Resume")
                    .font(.appMono(11, .semibold))
                    .foregroundColor(.black)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Palette.manualAmber))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
        .background(Palette.manualAmber.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Palette.manualAmber.opacity(0.28), lineWidth: 1)
        )
    }
}

// MARK: - Priority order card

private struct PriorityOrderCard: View {
    @ObservedObject var group: TunnelNode
    @EnvironmentObject var router: AppRouter
    @EnvironmentObject var theme: AppTheme

    var body: some View {
        GroupedCard(cornerRadius: 20) {
            let names = group.failoverMemberNames
            ForEach(Array(names.enumerated()), id: \.offset) { index, name in
                if index > 0 { RowDivider() }
                MemberRow(group: group, index: index, name: name, accent: theme.accent.color)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { router.showFailoverGroup(group) }
    }
}

private struct MemberRow: View {
    @ObservedObject var group: TunnelNode
    let index: Int
    let name: String
    let accent: Color

    var body: some View {
        let health = group.failoverState?.health(forMemberAt: index, name: name, groupIsActive: group.isActive) ?? .standby
        HStack(spacing: 13) {
            dot(for: health)
            HStack(spacing: 8) {
                Text(name)
                    .font(.appSans(15, .medium))
                    .foregroundColor(Palette.primaryText)
                if showsHotSpareBadge {
                    Badge(text: "HOT SPARE", color: Palette.warning)
                }
            }
            Spacer(minLength: 8)
            Text(descriptor(for: health))
                .font(.appMono(11))
                .foregroundColor(color(for: health))
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    @ViewBuilder private func dot(for health: FailoverRuntimeState.MemberHealth) -> some View {
        switch health {
        case .carrying:
            PulseDot(color: accent, size: 11)
        case .unhealthy, .probing:
            SolidDot(color: Palette.warning, size: 11)
        case .hotSpareReady, .hotSpareWaiting, .standby:
            RingDot(color: Palette.healthy, size: 11)
        case .idle:
            RingDot(color: Palette.idle, size: 11)
        }
    }

    private var showsHotSpareBadge: Bool {
        if let stateIndex = group.failoverState?.hotSpareConfigIndex {
            return stateIndex == index
        }
        return group.failoverState == nil && group.failoverSettings.hotSpare && index == 1
    }

    private func descriptor(for health: FailoverRuntimeState.MemberHealth) -> String {
        switch health {
        case .carrying:
            if let state = group.failoverState, let rx = state.rxBytes, let tx = state.txBytes {
                return "carrying · ↓\(WGFormat.compactBytes(rx)) ↑\(WGFormat.compactBytes(tx))"
            }
            return "carrying traffic"
        case .unhealthy: return "unhealthy"
        case .hotSpareReady: return "hot spare · warm"
        case .hotSpareWaiting: return "hot spare · connecting"
        case .probing: return "probing primary"
        case .standby: return "standby"
        case .idle: return "idle"
        }
    }

    private func color(for health: FailoverRuntimeState.MemberHealth) -> Color {
        switch health {
        case .carrying: return accent
        case .unhealthy, .probing: return Palette.warning
        default: return Palette.mutedText
        }
    }
}

// MARK: - Paused group card (manual override)

private struct PausedGroupCard: View {
    @ObservedObject var group: TunnelNode
    @EnvironmentObject var router: AppRouter

    var body: some View {
        GroupedCard(cornerRadius: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text(group.name)
                            .font(.appSans(16, .semibold))
                            .foregroundColor(Palette.primaryText)
                        Badge(text: "PAUSED", color: Palette.mutedText, filled: false)
                    }
                    HStack(spacing: 9) {
                        SolidDot(color: Palette.idle, size: 9)
                        Text("\(group.failoverMemberNames.count) tunnels · ready to resume")
                            .font(.appSans(13))
                            .foregroundColor(Palette.secondaryText)
                    }
                }
                Spacer()
            }
            .padding(16)
        }
        .opacity(0.7)
        .contentShape(Rectangle())
        .onTapGesture { router.showFailoverGroup(group) }
    }
}

// MARK: - Other tunnels row

private struct OtherTunnelRow: View {
    @ObservedObject var node: TunnelNode
    var subtitle: String?
    @EnvironmentObject var store: TunnelStore
    @EnvironmentObject var router: AppRouter
    @EnvironmentObject var theme: AppTheme

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(node.name)
                    .font(.appSans(15, .medium))
                    .foregroundColor(node.isOnDemandSuspended ? Palette.mutedText : Palette.primaryText)
                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(.appMono(11))
                        .foregroundColor(Palette.mutedText)
                }
            }
            Spacer(minLength: 12)
            Toggle("", isOn: Binding(
                get: { node.switchIsOn },
                set: { store.setActive($0, node: node) }))
                .labelsHidden()
                .tint(theme.accent.color)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
        .onTapGesture { router.showDetail(for: node) }
    }
}

// MARK: - Shared connection status label

struct ConnectionStatusLabel: View {
    let status: TunnelStatus
    var accent: Color

    var body: some View {
        HStack(spacing: 7) {
            if status == .active {
                PulseDot(color: accent, size: 9)
            } else {
                SolidDot(color: dotColor, size: 9)
            }
            Text(text)
                .font(.appMono(11, .semibold))
                .foregroundColor(status == .active ? accent : Palette.mutedText)
        }
    }

    private var text: String {
        switch status {
        case .active: return "CONNECTED"
        case .activating, .reasserting, .restarting, .waiting: return "CONNECTING"
        case .deactivating: return "DISCONNECTING"
        case .inactive: return "DISCONNECTED"
        }
    }

    private var dotColor: Color {
        switch status {
        case .activating, .reasserting, .restarting, .waiting: return Palette.warning
        default: return Palette.idle
        }
    }
}
