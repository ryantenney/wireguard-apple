// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import Foundation

/// Compact, display-oriented formatters for the redesigned UI. These complement
/// `FormattingHelpers` (which produces verbose strings like "2.41 MiB" and
/// "5 days, 3 hours ago") with the tighter forms the mockup uses, e.g. "2.41G",
/// "1.24 MB/s", "00:42:18", "12s ago".
enum WGFormat {

    private static let kib = 1024.0
    private static let mib = kib * 1024
    private static let gib = mib * 1024
    private static let tib = gib * 1024

    /// Abbreviate a base64 key to "x7Hk…q2A=" (first four + ellipsis + last four).
    static func abbreviatedKey(_ key: String) -> String {
        guard key.count > 9 else { return key }
        return "\(key.prefix(4))…\(key.suffix(4))"
    }

    /// Single-letter byte total, e.g. "2.41G", "184M", "512K", "0B".
    static func compactBytes(_ bytes: UInt64) -> String {
        let value = Double(bytes)
        switch value {
        case 0..<kib:
            return "\(bytes)B"
        case kib..<mib:
            return String(format: "%.0fK", value / kib)
        case mib..<gib:
            return String(format: "%.0fM", value / mib)
        case gib..<tib:
            return String(format: "%.2fG", value / gib)
        default:
            return String(format: "%.2fT", value / tib)
        }
    }

    /// Throughput split into a numeric value and its unit so the view can size
    /// the unit smaller, e.g. ("1.24", "MB/s") or ("340", "KB/s").
    static func throughput(bytesPerSecond: Double) -> (value: String, unit: String) {
        let rate = max(0, bytesPerSecond)
        switch rate {
        case 0..<kib:
            return (String(format: "%.0f", rate), "B/s")
        case kib..<mib:
            return (String(format: "%.0f", rate / kib), "KB/s")
        case mib..<gib:
            return (String(format: "%.2f", rate / mib), "MB/s")
        default:
            return (String(format: "%.2f", rate / gib), "GB/s")
        }
    }

    /// Elapsed connection time as "HH:MM:SS".
    static func duration(_ interval: TimeInterval) -> String {
        let total = Int(max(0, interval))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    /// Compact "time ago" such as "now", "12s ago", "4m ago", "2h ago", "3d ago".
    static func handshakeAgo(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        guard seconds >= 0 else { return "just now" }
        switch seconds {
        case 0..<2:
            return "just now"
        case 2..<60:
            return "\(seconds)s ago"
        case 60..<3600:
            return "\(seconds / 60)m ago"
        case 3600..<86400:
            return "\(seconds / 3600)h ago"
        default:
            return "\(seconds / 86400)d ago"
        }
    }

    /// "HH:MM" wall-clock time for the failover event trail.
    static func clockTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
