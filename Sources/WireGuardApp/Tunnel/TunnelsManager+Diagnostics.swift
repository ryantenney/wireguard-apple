// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import Foundation
import NetworkExtension

extension TunnelsManager {

    /// IPC message type for the connection details payload (see `PacketTunnelProvider.buildDiagnostics`).
    static let connectionDiagnosticsMessageType: UInt8 = 5

    /// Ask the running network extension for the full connection details payload:
    /// adapter state, live peer stats, applied network settings, network path, host
    /// interfaces, routing table, failover/TiT state, session events, and process info.
    /// Calls back with `nil` when the tunnel is not active or the extension did not answer.
    func getConnectionDiagnostics(for tunnel: TunnelContainer, completionHandler: @escaping ([String: Any]?) -> Void) {
        guard tunnel.status == .active,
              let session = tunnel.tunnelProvider.connection as? NETunnelProviderSession else {
            completionHandler(nil)
            return
        }

        do {
            try session.sendProviderMessage(Data([TunnelsManager.connectionDiagnosticsMessageType])) { responseData in
                guard let data = responseData,
                      let diagnostics = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    completionHandler(nil)
                    return
                }
                completionHandler(diagnostics)
            }
        } catch {
            wg_log(.error, message: "Connection details: failed to query the extension: \(error)")
            completionHandler(nil)
        }
    }
}
