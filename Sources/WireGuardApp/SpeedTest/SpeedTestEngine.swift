// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import Foundation

/// App-facing error for a failed speed test run.
struct SpeedTestError: WireGuardAppError {
    let message: String

    var alertText: AlertText {
        return (tr("speedTestAlertTestFailedTitle"), message)
    }
}

/// Orchestrates a speed test run: picks the right client for the server kind,
/// gathers network metadata in parallel with the test, and persists the
/// combined result to `SpeedTestResultsStore` on success.
final class SpeedTestEngine {

    static let shared = SpeedTestEngine()

    private(set) var isRunning = false

    private var iperfClient: Iperf3Client?
    private var httpClient: HTTPSpeedTestClient?
    private var networkContext: SpeedTestNetworkContext?
    private var wasCancelled = false

    private init() {}

    func start(server: SpeedTestServer,
               direction: SpeedTestDirection,
               durationSeconds: Int,
               activeTunnelName: String?,
               onProgress: @escaping (SpeedTestProgress) -> Void,
               completion: @escaping (Result<SpeedTestResult, SpeedTestError>) -> Void) {
        guard !isRunning else { return }
        isRunning = true
        wasCancelled = false
        networkContext = nil

        // Keep the metadata timeout inside the shortest test duration so the
        // context is (almost) always captured before the run completes.
        SpeedTestMetadataCollector.collect(timeout: 5) { [weak self] context in
            self?.networkContext = context
        }

        let finish: (Int64, Int64, Double) -> Void = { [weak self] downloadBytes, uploadBytes, duration in
            guard let self = self else { return }
            self.isRunning = false
            let context = self.networkContext ?? SpeedTestNetworkContext()
            var result = SpeedTestResult(
                id: UUID(),
                date: Date(),
                serverName: server.name,
                serverHost: server.endpointDescription,
                serverKind: server.kind,
                direction: direction,
                requestedDurationSeconds: durationSeconds,
                actualDurationSeconds: duration,
                downloadMbps: nil,
                uploadMbps: nil,
                downloadBytes: nil,
                uploadBytes: nil,
                networkType: context.networkType,
                wifiSSID: context.wifiSSID,
                carrierName: context.carrierName,
                radioTechnology: context.radioTechnology,
                locationDescription: context.locationDescription,
                latitude: context.latitude,
                longitude: context.longitude,
                activeTunnelName: activeTunnelName
            )
            if direction != .upload {
                result.downloadBytes = downloadBytes
                result.downloadMbps = duration > 0 ? Double(downloadBytes) * 8 / duration / 1_000_000 : 0
            }
            if direction != .download {
                result.uploadBytes = uploadBytes
                result.uploadMbps = duration > 0 ? Double(uploadBytes) * 8 / duration / 1_000_000 : 0
            }
            SpeedTestResultsStore.append(result)
            completion(.success(result))
        }

        let fail: (String) -> Void = { [weak self] message in
            guard let self = self else { return }
            self.isRunning = false
            completion(.failure(SpeedTestError(message: message)))
        }

        switch server.kind {
        case .iperf3:
            let client = Iperf3Client(configuration: Iperf3Client.Configuration(
                host: server.host,
                port: server.port,
                direction: direction,
                durationSeconds: durationSeconds
            ))
            iperfClient = client
            client.start(onProgress: onProgress, completion: { [weak self] result in
                self?.iperfClient = nil
                switch result {
                case .success(let summary):
                    finish(summary.downloadBytes, summary.uploadBytes, summary.durationSeconds)
                case .failure(let error):
                    fail(SpeedTestEngine.message(forIperfError: error))
                }
            })
        case .openSpeedTest:
            let client = HTTPSpeedTestClient(configuration: HTTPSpeedTestClient.Configuration(
                server: server,
                direction: direction,
                durationSeconds: durationSeconds
            ))
            httpClient = client
            client.start(onProgress: onProgress, completion: { [weak self] result in
                self?.httpClient = nil
                switch result {
                case .success(let summary):
                    finish(summary.downloadBytes, summary.uploadBytes, summary.durationSeconds)
                case .failure(let error):
                    fail(SpeedTestEngine.message(forHTTPError: error))
                }
            })
        }
    }

    func cancel() {
        wasCancelled = true
        iperfClient?.cancel()
        httpClient?.cancel()
    }

    var lastRunWasCancelled: Bool {
        return wasCancelled
    }

    private static func message(forIperfError error: Iperf3Client.ClientError) -> String {
        switch error {
        case .invalidEndpoint:
            return tr("speedTestErrorInvalidEndpoint")
        case .connectionFailed(let detail):
            return tr(format: "speedTestErrorConnectionFailed (%@)", detail)
        case .serverBusy:
            return tr("speedTestErrorServerBusy")
        case .protocolError(let detail):
            return tr(format: "speedTestErrorProtocol (%@)", detail)
        case .timedOut:
            return tr("speedTestErrorTimedOut")
        case .cancelled:
            return tr("speedTestErrorCancelled")
        }
    }

    private static func message(forHTTPError error: HTTPSpeedTestClient.ClientError) -> String {
        switch error {
        case .invalidURL:
            return tr("speedTestErrorInvalidEndpoint")
        case .requestFailed(let detail):
            return tr(format: "speedTestErrorConnectionFailed (%@)", detail)
        case .cancelled:
            return tr("speedTestErrorCancelled")
        }
    }
}
