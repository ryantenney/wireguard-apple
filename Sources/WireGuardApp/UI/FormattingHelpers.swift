// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import Foundation

/// Shared formatting helpers used by group detail controllers on both platforms.
enum FormattingHelpers {

    static func prettyBytes(_ bytes: UInt64) -> String {
        switch bytes {
        case 0..<1024:
            return "\(bytes) B"
        case 1024..<(1024 * 1024):
            return String(format: "%.2f", Double(bytes) / 1024) + " KiB"
        case (1024 * 1024)..<(1024 * 1024 * 1024):
            return String(format: "%.2f", Double(bytes) / (1024 * 1024)) + " MiB"
        case (1024 * 1024 * 1024)..<(1024 * 1024 * 1024 * 1024):
            return String(format: "%.2f", Double(bytes) / (1024 * 1024 * 1024)) + " GiB"
        default:
            return String(format: "%.2f", Double(bytes) / (1024 * 1024 * 1024 * 1024)) + " TiB"
        }
    }

    /// Formats a throughput in bytes per second, e.g. "12.34 KiB/s".
    static func prettyRate(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond >= 0 else { return "0 B/s" }
        if bytesPerSecond < 1024 {
            return String(format: "%.0f B/s", bytesPerSecond)
        }
        return prettyBytes(UInt64(bytesPerSecond)) + "/s"
    }

    static func prettyTimeAgo(since date: Date) -> String {
        let seconds = Int64(Date().timeIntervalSince(date))
        guard seconds >= 0 else { return "the future" }
        if seconds == 0 { return "now" }

        var parts = [String]()
        let days = seconds / 86400
        let hours = (seconds % 86400) / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60

        if days > 0 { parts.append("\(days) day\(days == 1 ? "" : "s")") }
        if hours > 0 { parts.append("\(hours) hour\(hours == 1 ? "" : "s")") }
        if minutes > 0 { parts.append("\(minutes) minute\(minutes == 1 ? "" : "s")") }
        if secs > 0 || parts.isEmpty { parts.append("\(secs) second\(secs == 1 ? "" : "s")") }

        return parts.prefix(2).joined(separator: ", ") + " ago"
    }

    /// Formats a duration compactly, e.g. "3h 4m 5s".
    static func prettyDuration(_ interval: TimeInterval) -> String {
        guard interval.isFinite, interval >= 0 else { return "" }
        return durationFormatter.string(from: interval) ?? "\(Int(interval))s"
    }

    /// Absolute date and time in the user's locale, e.g. "Sep 4, 2026 at 2:03:11 PM".
    static func prettyDateTime(_ date: Date) -> String {
        return dateTimeFormatter.string(from: date)
    }

    /// Time of day only, e.g. "2:03:11 PM".
    static func prettyTime(_ date: Date) -> String {
        return timeFormatter.string(from: date)
    }

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 3
        return formatter
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()
}
