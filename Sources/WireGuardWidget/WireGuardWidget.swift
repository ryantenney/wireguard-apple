// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import WidgetKit
import SwiftUI

// MARK: - Timeline Entry

struct VPNStatusEntry: TimelineEntry {
    let date: Date
    let state: VPNStatusData.ConnectionState
    let tunnelName: String
    let connectedAt: Date?
    let isOnDemandEnabled: Bool
    let hasOnDemandRules: Bool
    // Traffic data (from NE via shared UserDefaults)
    let txBytes: UInt64?
    let rxBytes: UInt64?
    let txRate: Double?
    let rxRate: Double?
    let activeConfigName: String?
    let lastHandshakeTime: Date?
    let trafficSamples: [VPNTrafficData.TrafficSample]
    let discoveredIP: String?
}

// MARK: - Timeline Provider

struct VPNStatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> VPNStatusEntry {
        VPNStatusEntry(
            date: Date(), state: .disconnected, tunnelName: "My Tunnel", connectedAt: nil,
            isOnDemandEnabled: false, hasOnDemandRules: false,
            txBytes: nil, rxBytes: nil, txRate: nil, rxRate: nil,
            activeConfigName: nil, lastHandshakeTime: nil, trafficSamples: [],
            discoveredIP: nil
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (VPNStatusEntry) -> Void) {
        if context.isPreview {
            // Rich preview for the widget gallery
            let samples = (0..<20).map { i in
                VPNTrafficData.TrafficSample(
                    timestamp: Date().addingTimeInterval(Double(-20 + i) * 30),
                    rxRate: Double.random(in: 500...50000),
                    txRate: Double.random(in: 100...10000)
                )
            }
            completion(VPNStatusEntry(
                date: Date(), state: .connected, tunnelName: "My Tunnel",
                connectedAt: Date().addingTimeInterval(-3600),
                isOnDemandEnabled: true, hasOnDemandRules: true,
                txBytes: 154_200_000, rxBytes: 892_100_000,
                txRate: 12400, rxRate: 48200,
                activeConfigName: nil, lastHandshakeTime: Date().addingTimeInterval(-45),
                trafficSamples: samples,
                discoveredIP: nil
            ))
        } else {
            completion(buildEntry())
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<VPNStatusEntry>) -> Void) {
        let entry = buildEntry()
        // Refresh more frequently when connected (traffic stats change)
        let interval: TimeInterval = entry.state == .connected ? 120 : 15 * 60
        let nextUpdate = Date().addingTimeInterval(interval)
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
    }

    /// The NE rewrites VPNTrafficData every 30s while a tunnel runs and clears
    /// it on stop; a heartbeat older than this means no extension is running.
    private static let trafficHeartbeatStaleAfter: TimeInterval = 180

    private func buildEntry() -> VPNStatusEntry {
        let status = VPNStatusData.load()
        let traffic = VPNTrafficData.load()

        var state = status?.state ?? .disconnected
        // VPNStatusData is written only by the app process. If the tunnel dies
        // while the app is suspended (server-side disconnect, network loss with
        // on-demand off), nothing updates it and the widget would show
        // "Connected" indefinitely — a false sense of security. Trust the NE's
        // traffic heartbeat as the authority and fail closed.
        if state == .connected {
            let heartbeatAge = traffic.map { Date().timeIntervalSince($0.updatedAt) }
            if heartbeatAge == nil || heartbeatAge! > Self.trafficHeartbeatStaleAfter {
                state = .disconnected
            }
        }
        let tunnelName = status?.tunnelName ?? ""

        // Prefer NE-written connectedSince (more reliable, doesn't reset on status changes)
        // Fall back to app-written connectedAt
        let connectedAt: Date?
        if state == .connected {
            connectedAt = traffic?.connectedSince ?? status?.connectedAt
        } else {
            connectedAt = nil
        }

        return VPNStatusEntry(
            date: Date(),
            state: state,
            tunnelName: tunnelName,
            connectedAt: connectedAt,
            isOnDemandEnabled: status?.isOnDemandEnabled ?? false,
            hasOnDemandRules: status?.hasOnDemandRules ?? false,
            txBytes: traffic?.txBytes,
            rxBytes: traffic?.rxBytes,
            txRate: traffic?.txRate,
            rxRate: traffic?.rxRate,
            activeConfigName: traffic?.activeConfigName,
            lastHandshakeTime: traffic?.lastHandshakeTime,
            trafficSamples: traffic?.trafficSamples ?? [],
            discoveredIP: IPDiscoverySettings.discoveredIP
        )
    }
}

// MARK: - Formatting Helpers

private func formatRate(_ bytesPerSecond: Double) -> String {
    if bytesPerSecond < 1024 {
        return String(format: "%.0f B/s", bytesPerSecond)
    } else if bytesPerSecond < 1024 * 1024 {
        return String(format: "%.1f KB/s", bytesPerSecond / 1024)
    } else {
        return String(format: "%.1f MB/s", bytesPerSecond / (1024 * 1024))
    }
}

private func formatBytes(_ bytes: UInt64) -> String {
    if bytes < 1024 {
        return "\(bytes) B"
    } else if bytes < 1024 * 1024 {
        return String(format: "%.1f KB", Double(bytes) / 1024)
    } else if bytes < 1024 * 1024 * 1024 {
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    } else {
        return String(format: "%.2f GB", Double(bytes) / (1024 * 1024 * 1024))
    }
}

// MARK: - Design tokens

private extension Color {
    init(rgb: UInt32) {
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }
}

private enum WidgetPalette {
    /// Live accent shared with the app via the app group.
    static var accent: Color { Color(rgb: AppearanceStore.accentRGB) }
    static let connecting = Color(rgb: 0xF0B13B)
    static let down = Color(rgb: 0xF4685E)
    static let armed = Color(rgb: 0xF0B13B)
}

// MARK: - Sparkline View

struct SparklineView: View {
    let samples: [VPNTrafficData.TrafficSample]
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            if samples.count >= 2 {
                let rates = samples.map { $0.rxRate + $0.txRate }
                let maxRate = max(rates.max() ?? 1, 1)
                let w = geometry.size.width
                let h = geometry.size.height

                // Filled area under the curve
                Path { path in
                    path.move(to: CGPoint(x: 0, y: h))
                    for (index, rate) in rates.enumerated() {
                        let x = w * CGFloat(index) / CGFloat(rates.count - 1)
                        let y = h * (1 - CGFloat(rate / maxRate))
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                    path.addLine(to: CGPoint(x: w, y: h))
                    path.closeSubpath()
                }
                .fill(color.opacity(0.15))

                // Line on top
                Path { path in
                    for (index, rate) in rates.enumerated() {
                        let x = w * CGFloat(index) / CGFloat(rates.count - 1)
                        let y = h * (1 - CGFloat(rate / maxRate))
                        if index == 0 {
                            path.move(to: CGPoint(x: x, y: y))
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                }
                .stroke(color, lineWidth: 1.5)
            }
        }
    }
}

// MARK: - Widget View

struct VPNStatusWidgetView: View {
    var entry: VPNStatusEntry

    @Environment(\.widgetFamily) var family

    var body: some View {
        if #available(iOSApplicationExtension 17.0, *) {
            content.containerBackground(for: .widget) {
                Rectangle()
                    .fill(.fill.tertiary)
                    .overlay(entry.state == .connected ? WidgetPalette.accent.opacity(0.10) : Color.clear)
            }
        } else {
            content.padding()
        }
    }

    @ViewBuilder
    var content: some View {
        switch family {
        case .systemSmall:
            smallView
        default:
            mediumView
        }
    }

    // MARK: - Small Widget

    var smallView: some View {
        VStack(alignment: .leading, spacing: 4) {
            wordmark
            Spacer()
            statusLabel
            primaryName
            if entry.state == .connected {
                if let connectedAt = entry.connectedAt {
                    Text(connectedAt, style: .relative)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                throughputRow
            } else if entry.state == .disconnected && entry.hasOnDemandRules {
                onDemandBadge
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Medium Widget

    var mediumView: some View {
        HStack(spacing: 12) {
            // Left column: status info
            VStack(alignment: .leading, spacing: 4) {
                wordmark
                Spacer()
                statusLabel
                primaryName
                if entry.state == .disconnected && entry.hasOnDemandRules {
                    onDemandBadge
                }
            }

            Spacer()

            // Right column: traffic stats + sparkline
            if entry.state == .connected {
                VStack(alignment: .trailing, spacing: 5) {
                    if let connectedAt = entry.connectedAt {
                        Text(connectedAt, style: .relative)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    if !entry.trafficSamples.isEmpty {
                        SparklineView(samples: entry.trafficSamples, color: WidgetPalette.accent)
                            .frame(width: 132, height: 30)
                    }
                    throughputRow
                    if let rx = entry.rxBytes, let tx = entry.txBytes, rx > 0 || tx > 0 {
                        Text("↓\(formatBytes(rx))  ↑\(formatBytes(tx))")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    if let ip = entry.discoveredIP {
                        Text(ip)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Shared Subviews

    var wordmark: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 9, height: 9)
            Text("WGNEXT")
                .font(.system(.caption2, design: .monospaced).weight(.semibold))
                .foregroundColor(.secondary)
        }
    }

    var statusLabel: some View {
        Text(statusText)
            .font(.system(.headline, design: .rounded).weight(.semibold))
            .foregroundColor(statusColor)
    }

    @ViewBuilder var primaryName: some View {
        if let activeConfig = entry.activeConfigName, !activeConfig.isEmpty {
            Text(activeConfig)
                .font(.subheadline)
                .foregroundColor(.primary)
                .lineLimit(1)
            if !entry.tunnelName.isEmpty && entry.tunnelName != activeConfig {
                Text(entry.tunnelName)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        } else if !entry.tunnelName.isEmpty {
            Text(entry.tunnelName)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
    }

    @ViewBuilder var throughputRow: some View {
        if let rxRate = entry.rxRate, let txRate = entry.txRate {
            HStack(spacing: 8) {
                Text("↓\(formatRate(rxRate))")
                    .foregroundColor(WidgetPalette.accent)
                Text("↑\(formatRate(txRate))")
                    .foregroundColor(.secondary)
            }
            .font(.system(.caption2, design: .monospaced))
        }
    }

    var onDemandBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 8))
            Text(entry.isOnDemandEnabled ? "On-Demand Active" : "On-Demand Configured")
                .font(.system(.caption2, design: .monospaced))
        }
        .foregroundColor(WidgetPalette.armed)
    }

    var statusText: String {
        switch entry.state {
        case .connected: return "Connected"
        case .connecting: return "Connecting…"
        case .disconnected: return entry.hasOnDemandRules ? "Armed" : "Disconnected"
        case .disconnecting: return "Disconnecting…"
        }
    }

    var statusColor: Color {
        switch entry.state {
        case .connected: return WidgetPalette.accent
        case .connecting, .disconnecting: return WidgetPalette.connecting
        case .disconnected: return entry.hasOnDemandRules ? WidgetPalette.armed : WidgetPalette.down
        }
    }
}

// MARK: - Widget Configuration

@main
struct WireGuardStatusWidget: Widget {
    let kind: String = "WireGuardStatus"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: VPNStatusProvider()) { entry in
            VPNStatusWidgetView(entry: entry)
        }
        .configurationDisplayName("VPN Status")
        .description("Shows current WireGuard VPN connection status and traffic.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
