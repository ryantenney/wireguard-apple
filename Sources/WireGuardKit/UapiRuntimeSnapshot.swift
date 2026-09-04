// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import Foundation

/// Converts a wireguard-go UAPI `get=1` dump into a JSON-friendly dictionary with
/// secrets removed. Used by the connection details IPC so the app never has to
/// parse UAPI text itself.
///
/// Output shape:
///
/// ```
/// {
///   "interface": { "publicKey": <base64>, "listenPort": Int, "fwmark": Int },
///   "peers": [ { "publicKey": <base64>, "endpoint": String, "presharedKey": Bool,
///                "persistentKeepalive": Int, "lastHandshakeTime": Double (unix seconds),
///                "rxBytes": UInt64, "txBytes": UInt64, "allowedIPs": [String],
///                "protocolVersion": Int } ],
///   "rxBytes": UInt64, "txBytes": UInt64, "lastHandshakeTime": Double
/// }
/// ```
public enum UapiRuntimeSnapshot {

    private static let zeroKeyHex = String(repeating: "0", count: 64)

    public static func parse(_ uapiConfig: String) -> [String: Any] {
        var interface: [String: Any] = [:]
        var peers: [[String: Any]] = []
        var currentPeer: [String: Any]?
        var allowedIPs: [String] = []
        var handshakeSeconds: Double = 0
        var handshakeNanoseconds: Double = 0

        func finishPeer() {
            guard var peer = currentPeer else { return }
            if !allowedIPs.isEmpty {
                peer["allowedIPs"] = allowedIPs
            }
            if handshakeSeconds > 0 {
                peer["lastHandshakeTime"] = handshakeSeconds + handshakeNanoseconds / 1_000_000_000
            }
            peers.append(peer)
            currentPeer = nil
            allowedIPs = []
            handshakeSeconds = 0
            handshakeNanoseconds = 0
        }

        for line in uapiConfig.split(separator: "\n") {
            guard let equalsIndex = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<equalsIndex])
            let value = String(line[line.index(after: equalsIndex)...])

            switch key {
            case "public_key":
                finishPeer()
                currentPeer = ["publicKey": PublicKey(hexKey: value)?.base64Key ?? value]
            case "private_key":
                if let privateKey = PrivateKey(hexKey: value) {
                    interface["publicKey"] = privateKey.publicKey.base64Key
                }
            case "listen_port":
                if let port = Int(value) {
                    interface["listenPort"] = port
                }
            case "fwmark":
                if let fwmark = Int(value) {
                    interface["fwmark"] = fwmark
                }
            case "errno":
                if let code = Int(value) {
                    interface["errno"] = code
                }
            case "preshared_key":
                currentPeer?["presharedKey"] = value != zeroKeyHex
            case "endpoint":
                currentPeer?["endpoint"] = value
            case "persistent_keepalive_interval":
                if let interval = Int(value) {
                    currentPeer?["persistentKeepalive"] = interval
                }
            case "last_handshake_time_sec":
                handshakeSeconds = Double(value) ?? 0
            case "last_handshake_time_nsec":
                handshakeNanoseconds = Double(value) ?? 0
            case "rx_bytes":
                if let bytes = UInt64(value) {
                    currentPeer?["rxBytes"] = bytes
                }
            case "tx_bytes":
                if let bytes = UInt64(value) {
                    currentPeer?["txBytes"] = bytes
                }
            case "allowed_ip":
                allowedIPs.append(value)
            case "protocol_version":
                if let version = Int(value) {
                    currentPeer?["protocolVersion"] = version
                }
            default:
                break
            }
        }
        finishPeer()

        var totalRx: UInt64 = 0
        var totalTx: UInt64 = 0
        var latestHandshake: Double = 0
        for peer in peers {
            totalRx &+= peer["rxBytes"] as? UInt64 ?? 0
            totalTx &+= peer["txBytes"] as? UInt64 ?? 0
            if let handshake = peer["lastHandshakeTime"] as? Double, handshake > latestHandshake {
                latestHandshake = handshake
            }
        }

        var result: [String: Any] = [
            "interface": interface,
            "peers": peers,
            "rxBytes": totalRx,
            "txBytes": totalTx
        ]
        if latestHandshake > 0 {
            result["lastHandshakeTime"] = latestHandshake
        }
        return result
    }
}
