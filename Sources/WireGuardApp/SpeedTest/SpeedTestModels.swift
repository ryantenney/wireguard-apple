// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import Foundation

/// The kind of speed test server / protocol used to talk to it.
enum SpeedTestServerKind: String, Codable {
    case iperf3
    case openSpeedTest

    var localizedName: String {
        switch self {
        case .iperf3: return tr("speedTestServerKindIperf3")
        case .openSpeedTest: return tr("speedTestServerKindOpenSpeedTest")
        }
    }
}

/// Which way traffic flows during a test, from the device's point of view.
enum SpeedTestDirection: String, Codable, CaseIterable {
    case download
    case upload
    case bidirectional

    var localizedName: String {
        switch self {
        case .download: return tr("speedTestDirectionDownload")
        case .upload: return tr("speedTestDirectionUpload")
        case .bidirectional: return tr("speedTestDirectionBidirectional")
        }
    }
}

/// A saved speed test server. iperf3 servers use host+port only; OpenSpeedTest
/// (HTTP) servers additionally use the TLS flag and download/upload paths.
struct SpeedTestServer: Codable, Equatable {
    var id: UUID
    var name: String
    var kind: SpeedTestServerKind
    var host: String
    var port: UInt16
    var useTLS: Bool
    var downloadPath: String
    var uploadPath: String
    var isBuiltIn: Bool

    init(id: UUID = UUID(),
         name: String,
         kind: SpeedTestServerKind,
         host: String,
         port: UInt16? = nil,
         useTLS: Bool = false,
         downloadPath: String = "/downloading",
         uploadPath: String = "/upload",
         isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.kind = kind
        self.host = host
        self.port = port ?? (kind == .iperf3 ? 5201 : 3000)
        self.useTLS = useTLS
        self.downloadPath = downloadPath
        self.uploadPath = uploadPath
        self.isBuiltIn = isBuiltIn
    }

    var endpointDescription: String {
        return "\(host):\(port)"
    }
}

/// Periodic progress callback payload while a test is running.
struct SpeedTestProgress {
    var elapsedSeconds: Double
    var totalSeconds: Double
    var downloadMbps: Double?
    var uploadMbps: Double?
}

/// A completed test, with the network conditions it ran under.
struct SpeedTestResult: Codable {
    var id: UUID
    var date: Date
    var serverName: String
    var serverHost: String
    var serverKind: SpeedTestServerKind
    var direction: SpeedTestDirection
    var requestedDurationSeconds: Int
    var actualDurationSeconds: Double
    var downloadMbps: Double?
    var uploadMbps: Double?
    var downloadBytes: Int64?
    var uploadBytes: Int64?
    var networkType: String?
    var wifiSSID: String?
    var carrierName: String?
    var radioTechnology: String?
    var locationDescription: String?
    var latitude: Double?
    var longitude: Double?
    var activeTunnelName: String?

    var summaryLine: String {
        var parts = [String]()
        if let downloadMbps = downloadMbps {
            parts.append("↓ " + SpeedTestResult.formatMbps(downloadMbps))
        }
        if let uploadMbps = uploadMbps {
            parts.append("↑ " + SpeedTestResult.formatMbps(uploadMbps))
        }
        return parts.isEmpty ? "—" : parts.joined(separator: "  ")
    }

    static func formatMbps(_ mbps: Double) -> String {
        if mbps >= 1000 {
            return String(format: "%.2f Gbps", mbps / 1000)
        }
        return String(format: "%.1f Mbps", mbps)
    }
}
