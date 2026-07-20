// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import Foundation
import Security

/// HTTP-based speed test client compatible with OpenSpeedTest-Server (and
/// similar servers): downloads by repeatedly GETting a large payload path and
/// uploads by POSTing random data, using a handful of parallel connections,
/// for a fixed duration. Both paths are configurable per server, defaulting
/// to OpenSpeedTest's `/downloading` and `/upload`.
final class HTTPSpeedTestClient: NSObject {

    struct Configuration {
        var server: SpeedTestServer
        var direction: SpeedTestDirection
        var durationSeconds: Int
        var downloadConnections = 4
        var uploadConnections = 2
    }

    struct Summary {
        var downloadBytes: Int64
        var uploadBytes: Int64
        var durationSeconds: Double
    }

    enum ClientError: Error {
        case invalidURL
        case requestFailed(String)
        case cancelled
    }

    private static let uploadBodySize = 8 * 1024 * 1024

    private let configuration: Configuration
    private let queue = DispatchQueue(label: "SpeedTest.HTTPClient")
    private lazy var delegateQueue: OperationQueue = {
        let operationQueue = OperationQueue()
        operationQueue.maxConcurrentOperationCount = 1
        operationQueue.underlyingQueue = queue
        return operationQueue
    }()
    private var session: URLSession?
    private var uploadBody = Data()

    private var isFinished = false
    private var isStopped = false
    private var downloadBytes: Int64 = 0
    private var uploadBytes: Int64 = 0
    private var previousDownloadBytes: Int64 = 0
    private var previousUploadBytes: Int64 = 0
    private var startTime: DispatchTime?
    private var previousIntervalTime: DispatchTime?
    private var measuredDuration: Double = 0
    private var intervalTimer: DispatchSourceTimer?
    private var endWorkItem: DispatchWorkItem?
    private var onProgress: ((SpeedTestProgress) -> Void)?
    private var completionHandler: ((Result<Summary, ClientError>) -> Void)?

    init(configuration: Configuration) {
        self.configuration = configuration
        super.init()
    }

    // MARK: - Public API

    func start(onProgress: @escaping (SpeedTestProgress) -> Void,
               completion: @escaping (Result<Summary, ClientError>) -> Void) {
        queue.async {
            self.onProgress = onProgress
            self.completionHandler = completion
            self.startOnQueue()
        }
    }

    func cancel() {
        queue.async {
            self.finish(with: .failure(.cancelled))
        }
    }

    // MARK: - Setup

    private func makeURL(path: String) -> URL? {
        var components = URLComponents()
        components.scheme = configuration.server.useTLS ? "https" : "http"
        components.host = configuration.server.host
        components.port = Int(configuration.server.port)
        var normalizedPath = path.trimmingCharacters(in: .whitespaces)
        if !normalizedPath.hasPrefix("/") {
            normalizedPath = "/" + normalizedPath
        }
        components.path = normalizedPath
        components.queryItems = [URLQueryItem(name: "n", value: UUID().uuidString)]
        return components.url
    }

    private func startOnQueue() {
        let needsDownload = configuration.direction != .upload
        let needsUpload = configuration.direction != .download

        if needsDownload && makeURL(path: configuration.server.downloadPath) == nil {
            finish(with: .failure(.invalidURL))
            return
        }
        if needsUpload && makeURL(path: configuration.server.uploadPath) == nil {
            finish(with: .failure(.invalidURL))
            return
        }

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        sessionConfiguration.urlCache = nil
        sessionConfiguration.timeoutIntervalForRequest = 15
        sessionConfiguration.httpMaximumConnectionsPerHost = configuration.downloadConnections + configuration.uploadConnections
        session = URLSession(configuration: sessionConfiguration, delegate: self, delegateQueue: delegateQueue)

        if needsUpload {
            var body = Data(count: HTTPSpeedTestClient.uploadBodySize)
            body.withUnsafeMutableBytes { buffer in
                if let baseAddress = buffer.baseAddress {
                    _ = SecRandomCopyBytes(kSecRandomDefault, buffer.count, baseAddress)
                }
            }
            uploadBody = body
        }

        startTime = .now()
        previousIntervalTime = startTime

        if needsDownload {
            for _ in 0..<configuration.downloadConnections {
                startDownloadTask()
            }
        }
        if needsUpload {
            for _ in 0..<configuration.uploadConnections {
                startUploadTask()
            }
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            self?.reportInterval()
        }
        timer.resume()
        intervalTimer = timer

        let endItem = DispatchWorkItem { [weak self] in
            self?.endTest()
        }
        endWorkItem = endItem
        queue.asyncAfter(deadline: .now() + .seconds(configuration.durationSeconds), execute: endItem)
    }

    private func startDownloadTask() {
        guard !isStopped, !isFinished, let session = session,
              let url = makeURL(path: configuration.server.downloadPath) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let task = session.dataTask(with: request)
        task.taskDescription = "download"
        task.resume()
    }

    private func startUploadTask() {
        guard !isStopped, !isFinished, let session = session,
              let url = makeURL(path: configuration.server.uploadPath) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let task = session.uploadTask(with: request, from: uploadBody)
        task.taskDescription = "upload"
        task.resume()
    }

    // MARK: - Progress and completion

    private func reportInterval() {
        guard let startTime = startTime, !isStopped else { return }
        let now = DispatchTime.now()
        let elapsed = Double(now.uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000_000
        let intervalSeconds = Double(now.uptimeNanoseconds - (previousIntervalTime ?? startTime).uptimeNanoseconds) / 1_000_000_000
        guard intervalSeconds > 0 else { return }

        let downloadDelta = downloadBytes - previousDownloadBytes
        let uploadDelta = uploadBytes - previousUploadBytes
        previousDownloadBytes = downloadBytes
        previousUploadBytes = uploadBytes
        previousIntervalTime = now

        let progress = SpeedTestProgress(
            elapsedSeconds: elapsed,
            totalSeconds: Double(configuration.durationSeconds),
            downloadMbps: configuration.direction != .upload ? Double(downloadDelta) * 8 / intervalSeconds / 1_000_000 : nil,
            uploadMbps: configuration.direction != .download ? Double(uploadDelta) * 8 / intervalSeconds / 1_000_000 : nil
        )
        if let onProgress = onProgress {
            DispatchQueue.main.async {
                onProgress(progress)
            }
        }
    }

    private func endTest() {
        guard !isStopped, !isFinished else { return }
        isStopped = true
        if let startTime = startTime {
            measuredDuration = Double(DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000_000
        }
        finish(with: .success(Summary(
            downloadBytes: downloadBytes,
            uploadBytes: uploadBytes,
            durationSeconds: measuredDuration
        )))
    }

    private func finish(with result: Result<Summary, ClientError>) {
        guard !isFinished else { return }
        isFinished = true
        isStopped = true
        intervalTimer?.cancel()
        intervalTimer = nil
        endWorkItem?.cancel()
        endWorkItem = nil
        session?.invalidateAndCancel()
        session = nil
        uploadBody = Data()
        let completion = completionHandler
        completionHandler = nil
        onProgress = nil
        if let completion = completion {
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }
}

extension HTTPSpeedTestClient: URLSessionDataDelegate {

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode >= 400 {
            completionHandler(.cancel)
            if downloadBytes == 0 && uploadBytes == 0 {
                finish(with: .failure(.requestFailed("Server returned HTTP \(httpResponse.statusCode)")))
            }
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !isStopped, dataTask.taskDescription == "download" else { return }
        downloadBytes += Int64(data.count)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard !isStopped else { return }
        uploadBytes += bytesSent
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !isFinished, !isStopped else { return }
        if let error = error {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                return
            }
            // If nothing has flowed at all, the server is unreachable or
            // misconfigured — fail the run rather than spinning silently.
            if downloadBytes == 0 && uploadBytes == 0 {
                finish(with: .failure(.requestFailed(error.localizedDescription)))
                return
            }
        }
        // Keep the pipes full until the deadline.
        if task.taskDescription == "download" {
            startDownloadTask()
        } else if task.taskDescription == "upload" {
            startUploadTask()
        }
    }
}
