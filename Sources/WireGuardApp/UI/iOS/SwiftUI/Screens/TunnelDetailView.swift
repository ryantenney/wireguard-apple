// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import SwiftUI

/// Tunnel detail: status hero, the interface and peer tables (with live
/// handshake and data transfer), and export/delete actions.
struct TunnelDetailView: View {
    @ObservedObject var node: TunnelNode
    @EnvironmentObject var store: TunnelStore
    @EnvironmentObject var router: AppRouter
    @EnvironmentObject var theme: AppTheme

    @State private var showDeleteConfirmation = false

    private var configuration: TunnelConfiguration? {
        node.runtimeConfiguration ?? node.container.tunnelConfiguration
    }

    var body: some View {
        ZStack {
            Palette.screenBackground.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    statusHero
                    if let configuration = configuration {
                        interfaceSection(configuration.interface)
                        ForEach(Array(configuration.peers.enumerated()), id: \.offset) { index, peer in
                            peerSection(peer, number: index, total: configuration.peers.count)
                        }
                    }
                    actionButtons
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 24)
            }
        }
        .onAppear { store.startPolling(node) }
        .onDisappear { store.stopPolling(node) }
        .alert("Delete \(node.name)?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { router.delete(node) }
        } message: {
            Text("This permanently removes the tunnel configuration.")
        }
    }

    // MARK: - Hero

    private var statusHero: some View {
        let accent = theme.accent.color
        return HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 6) {
                Text(node.name)
                    .font(.appSans(24, .bold))
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
        .padding(18)
        .background(accent.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(accent.opacity(0.24), lineWidth: 1)
        )
        .padding(.top, 8)
        .padding(.bottom, 18)
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

    // MARK: - Interface

    private func interfaceSection(_ interface: InterfaceConfiguration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Interface")
            GroupedCard {
                let rows = interfaceRows(interface)
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    if index > 0 { RowDivider() }
                    KeyValueRow(key: row.key, value: row.value,
                                copyAccent: row.copyable ? theme.accent.color : nil,
                                onCopy: row.copyable ? { router.copyToPasteboard(row.copyValue) } : nil)
                }
            }
        }
        .padding(.bottom, 18)
    }

    private struct Row {
        let key: String
        let value: String
        var copyable = false
        var copyValue = ""
    }

    private func interfaceRows(_ interface: InterfaceConfiguration) -> [Row] {
        var rows = [Row]()
        let publicKey = interface.privateKey.publicKey.base64Key
        rows.append(Row(key: "Public key", value: WGFormat.abbreviatedKey(publicKey), copyable: true, copyValue: publicKey))
        if !interface.addresses.isEmpty {
            rows.append(Row(key: "Addresses", value: interface.addresses.map { $0.stringRepresentation }.joined(separator: ", ")))
        }
        let dns = interface.dns.map { $0.stringRepresentation } + interface.dnsSearch
        if !dns.isEmpty {
            rows.append(Row(key: "DNS", value: dns.joined(separator: ", ")))
        }
        if let mtu = interface.mtu {
            rows.append(Row(key: "MTU", value: String(mtu)))
        }
        if let listenPort = interface.listenPort {
            rows.append(Row(key: "Listen port", value: String(listenPort)))
        }
        return rows
    }

    // MARK: - Peer

    private func peerSection(_ peer: PeerConfiguration, number: Int, total: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionHeader(title: total > 1 ? "Peer \(number + 1)" : "Peer")
                Spacer()
                if let handshake = peer.lastHandshakeTime {
                    Text("● handshake \(WGFormat.handshakeAgo(handshake))")
                        .font(.appMono(11))
                        .foregroundColor(Palette.healthy)
                        .padding(.bottom, 9)
                }
            }
            GroupedCard {
                let rows = peerRows(peer)
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    if index > 0 { RowDivider() }
                    if row.isDataTransfer {
                        dataTransferRow(peer)
                    } else {
                        KeyValueRow(key: row.key, value: row.value,
                                    copyAccent: row.copyable ? theme.accent.color : nil,
                                    onCopy: row.copyable ? { router.copyToPasteboard(row.copyValue) } : nil)
                    }
                }
            }
        }
        .padding(.bottom, 18)
    }

    private struct PeerRow {
        let key: String
        var value = ""
        var copyable = false
        var copyValue = ""
        var isDataTransfer = false
    }

    private func peerRows(_ peer: PeerConfiguration) -> [PeerRow] {
        var rows = [PeerRow]()
        let publicKey = peer.publicKey.base64Key
        rows.append(PeerRow(key: "Public key", value: WGFormat.abbreviatedKey(publicKey), copyable: true, copyValue: publicKey))
        if let endpoint = peer.endpoint?.stringRepresentation {
            rows.append(PeerRow(key: "Endpoint", value: endpoint))
        }
        if !peer.allowedIPs.isEmpty {
            rows.append(PeerRow(key: "Allowed IPs", value: peer.allowedIPs.map { $0.stringRepresentation }.joined(separator: ", ")))
        }
        if peer.rxBytes != nil || peer.txBytes != nil {
            rows.append(PeerRow(key: "Data transfer", isDataTransfer: true))
        }
        return rows
    }

    private func dataTransferRow(_ peer: PeerConfiguration) -> some View {
        HStack(spacing: 12) {
            Text("Data transfer")
                .font(.appSans(14))
                .foregroundColor(Palette.secondaryText)
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                Text("↓\(WGFormat.compactBytes(peer.rxBytes ?? 0))")
                    .foregroundColor(Palette.healthy)
                Text("↑\(WGFormat.compactBytes(peer.txBytes ?? 0))")
                    .foregroundColor(theme.accent.color)
            }
            .font(.appMono(12))
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 12)
    }

    // MARK: - Actions

    private var actionButtons: some View {
        HStack(spacing: 10) {
            Button {
                router.exportConfig(for: node)
            } label: {
                Text("Export config")
                    .font(.appSans(14, .medium))
                    .foregroundColor(Palette.primaryText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Palette.cardSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.cardBorder, lineWidth: 1))
            }
            .buttonStyle(.plain)

            Button {
                showDeleteConfirmation = true
            } label: {
                Text("Delete")
                    .font(.appSans(14, .medium))
                    .foregroundColor(Palette.danger)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Palette.danger.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.danger.opacity(0.25), lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 6)
    }
}
