// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import Foundation

/// Discovers the device's public IPv4 address after tunnel state changes.
/// Requests ride the active tunnel, so the result reflects the VPN exit
/// address. Extracted from TunnelsManager, which is an orchestrator, not an
/// HTTP client.
enum PublicIPFetcher {

    /// Plain-text IPv4 echo service used for discovery.
    static let discoveryURL = URL(string: "https://ipv4.icanhazip.com")!

    /// Guards against stacking concurrent fetches when status flaps
    /// (reasserting → connected cycles re-trigger discovery).
    private static var isFetching = false

    /// Fetch and store the public IP if IP discovery is enabled. Delays
    /// slightly to let the tunnel settle before fetching. `isTunnelActive` is
    /// re-checked either side of the request: without a tunnel the request
    /// would egress the physical interface, leaking the user's real IP to the
    /// lookup service — and then displaying it as the "public IP".
    static func fetchIfEnabled(isTunnelActive: @escaping () -> Bool) {
        guard IPDiscoverySettings.isEnabled else { return }
        guard !isFetching else { return }
        isFetching = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            // The tunnel may have dropped during the delay.
            guard isTunnelActive() else {
                isFetching = false
                return
            }

            var request = URLRequest(url: discoveryURL)
            request.timeoutInterval = 10
            request.cachePolicy = .reloadIgnoringLocalCacheData

            let task = URLSession.shared.dataTask(with: request) { data, _, error in
                DispatchQueue.main.async {
                    isFetching = false
                    if let error = error {
                        wg_log(.error, message: "IP discovery failed: \(error.localizedDescription)")
                        return
                    }
                    guard let data = data,
                          let ip = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !ip.isEmpty else { return }
                    // Discard a result that raced the tunnel going down — it
                    // may be the real (untunneled) address.
                    guard isTunnelActive() else { return }
                    IPDiscoverySettings.discoveredIP = ip
                    // Never log the address itself: exported logs would carry
                    // a timestamped list of the user's exit (or real) IPs.
                    wg_log(.debug, staticMessage: "IP discovery succeeded")
                }
            }
            task.resume()
        }
    }

    static func clearDiscoveredIP() {
        IPDiscoverySettings.discoveredIP = nil
    }
}
