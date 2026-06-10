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

private func formatDuration(since date: Date) -> String {
    let seconds = Int(Date().timeIntervalSince(date))
    if seconds < 60 {
        return "<1m"
    }
    let minutes = seconds / 60
    let hours = minutes / 60
    let remainingMinutes = minutes % 60
    if hours == 0 {
        return "\(minutes)m"
    }
    return "\(hours)h \(remainingMinutes)m"
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
            content.containerBackground(.fill.tertiary, for: .widget)
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
            HStack {
                statusIcon
                Text("WGnext")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if entry.state == .connected, let connectedAt = entry.connectedAt {
                Text(formatDuration(since: connectedAt))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            statusLabel
                .font(.headline)

            if let activeConfig = entry.activeConfigName, !activeConfig.isEmpty {
                // Failover: show which specific config is active
                Text(activeConfig)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
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

            if entry.state == .connected {
                if let ip = entry.discoveredIP {
                    Text(ip)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                if let connectedAt = entry.connectedAt {
                    Text(connectedAt, style: .relative)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                if let rxRate = entry.rxRate, let txRate = entry.txRate {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 8))
                        Text(formatRate(rxRate))
                        Image(systemName: "arrow.up")
                            .font(.system(size: 8))
                        Text(formatRate(txRate))
                    }
                    .font(.caption2)
                    .foregroundColor(.secondary)
                }
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
                HStack {
                    statusIcon
                    Text("WGnext")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                }

                Spacer()

                if entry.state == .connected, let connectedAt = entry.connectedAt {
                    Text(formatDuration(since: connectedAt))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                statusLabel
                    .font(.headline)

                if let activeConfig = entry.activeConfigName, !activeConfig.isEmpty {
                    Text(activeConfig)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
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

                if entry.state == .disconnected && entry.hasOnDemandRules {
                    onDemandBadge
                }
            }

            Spacer()

            if entry.state == .connected {
                // Right column: traffic stats + sparkline
                VStack(alignment: .trailing, spacing: 4) {
                    if let ip = entry.discoveredIP {
                        HStack(spacing: 2) {
                            Image(systemName: "network")
                                .font(.system(size: 8))
                            Text(ip)
                                .font(.caption2)
                        }
                        .foregroundColor(.secondary)
                    }
                    if let connectedAt = entry.connectedAt {
                        HStack(spacing: 2) {
                            Text("Connected")
                                .font(.caption2)
                            Text(connectedAt, style: .relative)
                                .font(.caption2)
                        }
                        .foregroundColor(.secondary)
                    }

                    if !entry.trafficSamples.isEmpty {
                        SparklineView(samples: entry.trafficSamples, color: .green)
                            .frame(height: 32)
                    }

                    // Traffic rates
                    if let rxRate = entry.rxRate, let txRate = entry.txRate {
                        HStack(spacing: 6) {
                            Label(formatRate(rxRate), systemImage: "arrow.down")
                            Label(formatRate(txRate), systemImage: "arrow.up")
                        }
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    }

                    // Session totals
                    if let rx = entry.rxBytes, let tx = entry.txBytes, (rx > 0 || tx > 0) {
                        HStack(spacing: 6) {
                            Label(formatBytes(rx), systemImage: "arrow.down.circle")
                            Label(formatBytes(tx), systemImage: "arrow.up.circle")
                        }
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Shared Subviews

    var statusIcon: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 10, height: 10)
    }

    var statusLabel: some View {
        Text(statusText)
            .foregroundColor(statusColor)
    }

    var onDemandBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 8))
            Text(entry.isOnDemandEnabled ? "On-Demand Active" : "On-Demand Configured")
                .font(.caption2)
        }
        .foregroundColor(.orange)
    }

    var statusText: String {
        switch entry.state {
        case .connected: return "Connected"
        case .connecting: return "Connecting..."
        case .disconnected: return "Disconnected"
        case .disconnecting: return "Disconnecting..."
        }
    }

    var statusColor: Color {
        switch entry.state {
        case .connected: return .green
        case .connecting: return .orange
        case .disconnected:
            return entry.hasOnDemandRules ? .orange : .red
        case .disconnecting: return .orange
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
