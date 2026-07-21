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

        let fail: (String) -> Void = { [weak self] message in
            guard let self = self else { return }
            self.isRunning = false
            completion(.failure(SpeedTestError(message: message)))
        }

        // Build the combined result from whichever phases ran, and persist it.
        let store: (_ download: (bytes: Int64, duration: Double)?, _ upload: (bytes: Int64, duration: Double)?) -> Void = { [weak self] download, upload in
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
                actualDurationSeconds: (download?.duration ?? 0) + (upload?.duration ?? 0),
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
            if let download = download {
                result.downloadBytes = download.bytes
                result.downloadMbps = download.duration > 0 ? Double(download.bytes) * 8 / download.duration / 1_000_000 : 0
            }
            if let upload = upload {
                result.uploadBytes = upload.bytes
                result.uploadMbps = upload.duration > 0 ? Double(upload.bytes) * 8 / upload.duration / 1_000_000 : 0
            }
            SpeedTestResultsStore.append(result)
            completion(.success(result))
        }

        switch direction {
        case .download:
            runPhase(server: server, direction: .download, durationSeconds: durationSeconds, onProgress: onProgress) { result in
                switch result {
                case .failure(let error): fail(error.message)
                case .success(let phase): store((bytes: phase.down, duration: phase.dur), nil)
                }
            }
        case .upload:
            runPhase(server: server, direction: .upload, durationSeconds: durationSeconds, onProgress: onProgress) { result in
                switch result {
                case .failure(let error): fail(error.message)
                case .success(let phase): store(nil, (bytes: phase.up, duration: phase.dur))
                }
            }
        case .bidirectional:
            // Run download first, then upload — two standard uni-directional
            // tests — so we never use iperf3's fragile concurrent bidirectional
            // mode (which resets data streams on many public servers).
            runPhase(server: server, direction: .download, durationSeconds: durationSeconds, onProgress: { progress in
                onProgress(SpeedTestProgress(elapsedSeconds: progress.elapsedSeconds, totalSeconds: progress.totalSeconds, downloadMbps: progress.downloadMbps, uploadMbps: nil))
            }) { [weak self] downloadResult in
                guard let self = self else { return }
                switch downloadResult {
                case .failure(let error):
                    fail(error.message)
                case .success(let downloadPhase):
                    if self.wasCancelled {
                        fail(tr("speedTestErrorCancelled"))
                        return
                    }
                    let downloadMbps = downloadPhase.dur > 0 ? Double(downloadPhase.down) * 8 / downloadPhase.dur / 1_000_000 : 0
                    self.runPhase(server: server, direction: .upload, durationSeconds: durationSeconds, onProgress: { progress in
                        // Carry the finished download figure so the UI shows both.
                        onProgress(SpeedTestProgress(elapsedSeconds: progress.elapsedSeconds, totalSeconds: progress.totalSeconds, downloadMbps: downloadMbps, uploadMbps: progress.uploadMbps))
                    }) { uploadResult in
                        switch uploadResult {
                        case .failure(let error): fail(error.message)
                        case .success(let uploadPhase):
                            store((bytes: downloadPhase.down, duration: downloadPhase.dur), (bytes: uploadPhase.up, duration: uploadPhase.dur))
                        }
                    }
                }
            }
        }
    }

    /// Runs a single-direction test with the right client for the server kind,
    /// reporting its byte totals and measured duration.
    private func runPhase(server: SpeedTestServer,
                          direction: SpeedTestDirection,
                          durationSeconds: Int,
                          onProgress: @escaping (SpeedTestProgress) -> Void,
                          completion: @escaping (Result<(down: Int64, up: Int64, dur: Double), SpeedTestError>) -> Void) {
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
                    completion(.success((down: summary.downloadBytes, up: summary.uploadBytes, dur: summary.durationSeconds)))
                case .failure(let error):
                    completion(.failure(SpeedTestError(message: SpeedTestEngine.message(forIperfError: error))))
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
                    completion(.success((down: summary.downloadBytes, up: summary.uploadBytes, dur: summary.durationSeconds)))
                case .failure(let error):
                    completion(.failure(SpeedTestError(message: SpeedTestEngine.message(forHTTPError: error))))
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
