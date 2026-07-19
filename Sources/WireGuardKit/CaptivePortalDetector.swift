// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import Foundation

/// Status of the underlying (physical) network, as determined by an HTTP probe
/// that bypasses the tunnel.
public enum UnderlyingNetworkStatus: Equatable {
    /// The probe returned 200 with the expected body — the underlying network passes traffic.
    case clear

    /// The probe was intercepted (redirected, or answered with an unexpected page) —
    /// a captive portal is blocking traffic until the user signs in.
    case captive

    /// The probe could not complete at all — the underlying network is down or fully blocked.
    case offline
}

/// Probes the underlying physical network from the Network Extension process.
///
/// Traffic originating in the packet tunnel provider process bypasses its own utun
/// (this is how wireguard-go's UDP sockets reach the network while the tunnel holds
/// the default route), so a plain URLSession request made here tests the *underlying*
/// network even while the tunnel is up. Requires an ATS exception for the probe host
/// in the extension's Info.plist. See DESIGN-captive-portal-handling.md.
public final class CaptivePortalDetector {

    /// Apple's captive-check endpoint — the same URL the system's captive network
    /// assistant fetches. Plain HTTP on purpose, so a portal can intercept it.
    public static let defaultProbeURL = URL(string: "http://captive.apple.com/hotspot-detect.html")!

    /// Body substring expected from `defaultProbeURL` when the network is clear.
    private static let expectedBodyFragment = "Success"

    private let probeURL: URL
    private let timeout: TimeInterval

    public init(probeURL: URL = CaptivePortalDetector.defaultProbeURL, timeout: TimeInterval = 5) {
        self.probeURL = probeURL
        self.timeout = timeout
    }

    /// Fetch the probe URL and classify the underlying network.
    /// The completion handler is called on an arbitrary queue.
    public func check(completionHandler: @escaping (UnderlyingNetworkStatus) -> Void) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.waitsForConnectivity = false

        let redirectTrap = RedirectTrap()
        let session = URLSession(configuration: configuration, delegate: redirectTrap, delegateQueue: nil)

        let task = session.dataTask(with: URLRequest(url: probeURL)) { data, response, error in
            defer { session.finishTasksAndInvalidate() }

            // A redirect is the primary captive-portal signature: the portal is
            // bouncing us to its sign-in page.
            if redirectTrap.wasRedirected {
                completionHandler(.captive)
                return
            }
            if error != nil {
                completionHandler(.offline)
                return
            }
            guard let httpResponse = response as? HTTPURLResponse else {
                completionHandler(.offline)
                return
            }
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            if httpResponse.statusCode == 200 && body.contains(Self.expectedBodyFragment) {
                completionHandler(.clear)
            } else {
                // 200 with the wrong body (interception page served in place),
                // 511 Network Authentication Required, or other tampering.
                completionHandler(.captive)
            }
        }
        task.resume()
    }

    /// URLSession delegate that records — and refuses to follow — HTTP redirects.
    /// Refusing keeps the redirect visible as the task's final response instead of
    /// silently landing on the portal page. The flag is written and read on the
    /// session's serial delegate queue.
    private final class RedirectTrap: NSObject, URLSessionTaskDelegate {
        private(set) var wasRedirected = false

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            wasRedirected = true
            completionHandler(nil)
        }
    }
}
