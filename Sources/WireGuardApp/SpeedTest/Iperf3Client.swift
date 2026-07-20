// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import Foundation
import Network
import Security

/// A minimal pure-Swift iperf3 client (TCP tests only), speaking the iperf 3.x
/// control protocol:
///
///   1. Connect a control TCP connection and send a 37-byte cookie.
///   2. Server drives a state machine with single-byte state messages:
///      PARAM_EXCHANGE → client sends a length-prefixed JSON parameter blob.
///      CREATE_STREAMS → client opens the data connections (each one sends the
///      same cookie). In bidirectional mode the server treats the first
///      `parallel` accepted connections as client→server streams and the rest
///      as server→client streams, so streams are connected sequentially in
///      that order.
///      TEST_START / TEST_RUNNING → data flows for the configured duration,
///      after which the client sends TEST_END on the control connection.
///      EXCHANGE_RESULTS → client sends its results JSON, then reads the
///      server's. DISPLAY_RESULTS → client replies IPERF_DONE and closes.
///
/// JSON blobs are framed with a 4-byte big-endian length prefix.
final class Iperf3Client {

    struct Configuration {
        var host: String
        var port: UInt16
        var direction: SpeedTestDirection
        var durationSeconds: Int
        var parallelStreams = 2
    }

    struct Summary {
        var downloadBytes: Int64
        var uploadBytes: Int64
        var durationSeconds: Double
    }

    enum ClientError: Error {
        case invalidEndpoint
        case connectionFailed(String)
        case serverBusy
        case protocolError(String)
        case timedOut
        case cancelled
    }

    // Control-channel states (see iperf_api.h in the reference implementation)
    private static let stateTestStart: Int8 = 1
    private static let stateTestRunning: Int8 = 2
    private static let stateTestEnd: Int8 = 4
    private static let stateParamExchange: Int8 = 9
    private static let stateCreateStreams: Int8 = 10
    private static let stateServerTerminate: Int8 = 11
    private static let stateExchangeResults: Int8 = 13
    private static let stateDisplayResults: Int8 = 14
    private static let stateIperfStart: Int8 = 15
    private static let stateIperfDone: Int8 = 16
    private static let stateAccessDenied: Int8 = -1
    private static let stateServerError: Int8 = -2

    private static let blockSize = 131072

    private final class DataStream {
        let connection: NWConnection
        let isSender: Bool
        var bytesTransferred: Int64 = 0

        init(connection: NWConnection, isSender: Bool) {
            self.connection = connection
            self.isSender = isSender
        }
    }

    private let configuration: Configuration
    private let queue = DispatchQueue(label: "SpeedTest.Iperf3Client")
    private let cookie: Data
    private let sendBlock: Data

    private var controlConnection: NWConnection?
    private var streams = [DataStream]()
    private var isStopped = false
    private var isFinished = false
    private var measuredDuration: Double = 0
    private var testStartTime: DispatchTime?
    private var intervalTimer: DispatchSourceTimer?
    private var watchdogTimer: DispatchSourceTimer?
    private var endWorkItem: DispatchWorkItem?
    private var previousDownloadBytes: Int64 = 0
    private var previousUploadBytes: Int64 = 0
    private var previousIntervalTime: DispatchTime?
    private var onProgress: ((SpeedTestProgress) -> Void)?
    private var completionHandler: ((Result<Summary, ClientError>) -> Void)?

    init(configuration: Configuration) {
        self.configuration = configuration
        cookie = Iperf3Client.makeCookie()
        sendBlock = Iperf3Client.makeRandomBlock(count: Iperf3Client.blockSize)
    }

    private static func makeCookie() -> Data {
        // 36 random characters from iperf3's base32-ish alphabet plus a NUL terminator
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")
        var string = ""
        for _ in 0..<36 {
            string.append(alphabet.randomElement()!)
        }
        var data = string.data(using: .ascii)!
        data.append(0)
        return data
    }

    private static func makeRandomBlock(count: Int) -> Data {
        var data = Data(count: count)
        data.withUnsafeMutableBytes { buffer in
            if let baseAddress = buffer.baseAddress {
                _ = SecRandomCopyBytes(kSecRandomDefault, count, baseAddress)
            }
        }
        return data
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

    private func startOnQueue() {
        guard let port = NWEndpoint.Port(rawValue: configuration.port) else {
            finish(with: .failure(.invalidEndpoint))
            return
        }

        startWatchdog()

        let connection = NWConnection(host: NWEndpoint.Host(configuration.host), port: port, using: .tcp)
        controlConnection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self, !self.isFinished else { return }
            switch state {
            case .ready:
                self.sendRaw(on: connection, data: self.cookie) {
                    self.readControlState()
                }
            case .failed(let error):
                self.finish(with: .failure(.connectionFailed(error.localizedDescription)))
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(configuration.durationSeconds + 30))
        timer.setEventHandler { [weak self] in
            self?.finish(with: .failure(.timedOut))
        }
        timer.resume()
        watchdogTimer = timer
    }

    // MARK: - Control channel

    private func readControlState() {
        controlConnection?.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] data, _, isComplete, error in
            guard let self = self, !self.isFinished else { return }
            if let error = error {
                self.finish(with: .failure(.protocolError("Control channel error: \(error.localizedDescription)")))
                return
            }
            guard let byte = data?.first else {
                if isComplete {
                    self.finish(with: .failure(.protocolError("Control connection closed by server")))
                }
                return
            }
            self.handleControlState(Int8(bitPattern: byte))
        }
    }

    private func handleControlState(_ state: Int8) {
        switch state {
        case Iperf3Client.stateParamExchange:
            sendParameters()
        case Iperf3Client.stateCreateStreams:
            connectNextStream(index: 0)
        case Iperf3Client.stateTestStart, Iperf3Client.stateIperfStart:
            readControlState()
        case Iperf3Client.stateTestRunning:
            beginTest()
            readControlState()
        case Iperf3Client.stateExchangeResults:
            exchangeResults()
        case Iperf3Client.stateDisplayResults:
            sendControlState(Iperf3Client.stateIperfDone) {
                self.finish(with: .success(self.makeSummary()))
            }
        case Iperf3Client.stateAccessDenied:
            finish(with: .failure(.serverBusy))
        case Iperf3Client.stateServerError, Iperf3Client.stateServerTerminate:
            finish(with: .failure(.protocolError("Server reported an error")))
        default:
            // States we don't act on (e.g. TEST_END echoes); keep listening.
            readControlState()
        }
    }

    private func sendControlState(_ state: Int8, then continuation: (() -> Void)? = nil) {
        guard let connection = controlConnection else { return }
        sendRaw(on: connection, data: Data([UInt8(bitPattern: state)])) {
            continuation?()
        }
    }

    private func sendRaw(on connection: NWConnection, data: Data, then continuation: (() -> Void)? = nil) {
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self = self, !self.isFinished else { return }
            if let error = error {
                self.finish(with: .failure(.protocolError("Send failed: \(error.localizedDescription)")))
                return
            }
            continuation?()
        })
    }

    // MARK: - Parameter exchange

    private func sendParameters() {
        var params: [String: Any] = [
            "tcp": true,
            "omit": 0,
            "time": configuration.durationSeconds,
            "parallel": configuration.parallelStreams,
            "len": Iperf3Client.blockSize,
            "pacing_timer": 1000,
            "client_version": "3.16"
        ]
        switch configuration.direction {
        case .download:
            params["reverse"] = true
        case .bidirectional:
            params["bidirectional"] = true
        case .upload:
            break
        }
        guard let json = try? JSONSerialization.data(withJSONObject: params) else {
            finish(with: .failure(.protocolError("Could not encode parameters")))
            return
        }
        sendLengthPrefixed(json) {
            self.readControlState()
        }
    }

    private func sendLengthPrefixed(_ payload: Data, then continuation: @escaping () -> Void) {
        guard let connection = controlConnection else { return }
        var framed = Data()
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { framed.append(contentsOf: $0) }
        framed.append(payload)
        sendRaw(on: connection, data: framed, then: continuation)
    }

    // MARK: - Data streams

    private var totalStreamCount: Int {
        return configuration.direction == .bidirectional ? configuration.parallelStreams * 2 : configuration.parallelStreams
    }

    private func streamIsSender(at index: Int) -> Bool {
        switch configuration.direction {
        case .upload:
            return true
        case .download:
            return false
        case .bidirectional:
            // The server assigns its receivers (= our senders) to the first
            // accepted connections, so ours must connect senders-first.
            return index < configuration.parallelStreams
        }
    }

    private func connectNextStream(index: Int) {
        if index == totalStreamCount {
            readControlState()
            return
        }
        guard let port = NWEndpoint.Port(rawValue: configuration.port) else {
            finish(with: .failure(.invalidEndpoint))
            return
        }
        let connection = NWConnection(host: NWEndpoint.Host(configuration.host), port: port, using: .tcp)
        let stream = DataStream(connection: connection, isSender: streamIsSender(at: index))
        streams.append(stream)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self, !self.isFinished else { return }
            switch state {
            case .ready:
                self.sendRaw(on: connection, data: self.cookie) {
                    self.connectNextStream(index: index + 1)
                }
            case .failed(let error):
                self.finish(with: .failure(.connectionFailed("Data stream failed: \(error.localizedDescription)")))
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    // MARK: - Running the test

    private func beginTest() {
        guard testStartTime == nil else { return }
        testStartTime = .now()
        previousIntervalTime = testStartTime

        for stream in streams {
            if stream.isSender {
                sendPump(stream)
            } else {
                receivePump(stream)
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

    private func sendPump(_ stream: DataStream) {
        guard !isStopped, !isFinished else { return }
        stream.connection.send(content: sendBlock, completion: .contentProcessed { [weak self] error in
            guard let self = self, !self.isFinished, error == nil else { return }
            if !self.isStopped {
                stream.bytesTransferred += Int64(self.sendBlock.count)
            }
            self.sendPump(stream)
        })
    }

    private func receivePump(_ stream: DataStream) {
        stream.connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self = self, !self.isFinished else { return }
            if let data = data, !self.isStopped {
                stream.bytesTransferred += Int64(data.count)
            }
            if error == nil && !isComplete {
                self.receivePump(stream)
            }
        }
    }

    private func reportInterval() {
        guard let startTime = testStartTime, !isStopped else { return }
        let now = DispatchTime.now()
        let elapsed = Double(now.uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000_000
        let intervalSeconds = Double(now.uptimeNanoseconds - (previousIntervalTime ?? startTime).uptimeNanoseconds) / 1_000_000_000
        guard intervalSeconds > 0 else { return }

        let downloadBytes = totalBytes(sender: false)
        let uploadBytes = totalBytes(sender: true)
        let downloadDelta = downloadBytes - previousDownloadBytes
        let uploadDelta = uploadBytes - previousUploadBytes
        previousDownloadBytes = downloadBytes
        previousUploadBytes = uploadBytes
        previousIntervalTime = now

        let progress = SpeedTestProgress(
            elapsedSeconds: elapsed,
            totalSeconds: Double(configuration.durationSeconds),
            downloadMbps: hasReceivers ? Double(downloadDelta) * 8 / intervalSeconds / 1_000_000 : nil,
            uploadMbps: hasSenders ? Double(uploadDelta) * 8 / intervalSeconds / 1_000_000 : nil
        )
        if let onProgress = onProgress {
            DispatchQueue.main.async {
                onProgress(progress)
            }
        }
    }

    private var hasSenders: Bool {
        return configuration.direction != .download
    }

    private var hasReceivers: Bool {
        return configuration.direction != .upload
    }

    private func totalBytes(sender: Bool) -> Int64 {
        return streams.filter { $0.isSender == sender }.reduce(0) { $0 + $1.bytesTransferred }
    }

    private func stopMeasuring() {
        guard !isStopped else { return }
        isStopped = true
        intervalTimer?.cancel()
        intervalTimer = nil
        if let startTime = testStartTime {
            measuredDuration = Double(DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000_000
        }
    }

    private func endTest() {
        guard !isStopped, !isFinished else { return }
        stopMeasuring()
        sendControlState(Iperf3Client.stateTestEnd)
    }

    // MARK: - Results exchange

    private func exchangeResults() {
        // If the server moved to results before our own deadline fired
        // (server-side timing), stop measuring without sending TEST_END.
        if !isStopped {
            endWorkItem?.cancel()
            stopMeasuring()
        }

        var streamResults = [[String: Any]]()
        for (index, stream) in streams.enumerated() {
            streamResults.append([
                "id": index + 1,
                "bytes": stream.bytesTransferred,
                "retransmits": -1,
                "jitter": 0,
                "errors": 0,
                "packets": 0,
                "start_time": 0,
                "end_time": measuredDuration
            ])
        }
        let results: [String: Any] = [
            "cpu_util_total": 0.0,
            "cpu_util_user": 0.0,
            "cpu_util_system": 0.0,
            "sender_has_retransmits": 0,
            "streams": streamResults
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: results) else {
            finish(with: .failure(.protocolError("Could not encode results")))
            return
        }
        sendLengthPrefixed(json) {
            self.readLengthPrefixed { serverResults in
                self.processServerResults(serverResults)
                self.readControlState()
            }
        }
    }

    private func readLengthPrefixed(completion: @escaping ([String: Any]?) -> Void) {
        guard let connection = controlConnection else {
            completion(nil)
            return
        }
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, _, error in
            guard let self = self, !self.isFinished else { return }
            guard error == nil, let data = data, data.count == 4 else {
                self.finish(with: .failure(.protocolError("Failed to read results length")))
                return
            }
            let length = data.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard length > 0, length < 4 * 1024 * 1024 else {
                completion(nil)
                return
            }
            self.readExactly(Int(length), accumulated: Data()) { payload in
                guard let payload = payload,
                      let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
                    completion(nil)
                    return
                }
                completion(object)
            }
        }
    }

    private func readExactly(_ count: Int, accumulated: Data, completion: @escaping (Data?) -> Void) {
        let remaining = count - accumulated.count
        if remaining <= 0 {
            completion(accumulated)
            return
        }
        controlConnection?.receive(minimumIncompleteLength: 1, maximumLength: remaining) { [weak self] data, _, isComplete, error in
            guard let self = self, !self.isFinished else { return }
            guard error == nil, let data = data else {
                if isComplete || error != nil {
                    completion(nil)
                }
                return
            }
            var next = accumulated
            next.append(data)
            self.readExactly(count, accumulated: next, completion: completion)
        }
    }

    private var serverReportedUploadBytes: Int64?

    private func processServerResults(_ results: [String: Any]?) {
        guard let streamEntries = results?["streams"] as? [[String: Any]] else { return }
        let totalServerBytes = streamEntries.reduce(Int64(0)) { total, entry in
            total + ((entry["bytes"] as? NSNumber)?.int64Value ?? 0)
        }
        // In upload-only mode every byte the server reports is a byte it
        // received from us, which is more accurate than our sent-count.
        if configuration.direction == .upload, totalServerBytes > 0 {
            serverReportedUploadBytes = totalServerBytes
        }
    }

    // MARK: - Completion

    private func makeSummary() -> Summary {
        return Summary(
            downloadBytes: totalBytes(sender: false),
            uploadBytes: serverReportedUploadBytes ?? totalBytes(sender: true),
            durationSeconds: measuredDuration > 0 ? measuredDuration : Double(configuration.durationSeconds)
        )
    }

    private func finish(with result: Result<Summary, ClientError>) {
        guard !isFinished else { return }
        isFinished = true
        isStopped = true
        intervalTimer?.cancel()
        intervalTimer = nil
        watchdogTimer?.cancel()
        watchdogTimer = nil
        endWorkItem?.cancel()
        endWorkItem = nil
        controlConnection?.cancel()
        controlConnection = nil
        for stream in streams {
            stream.connection.cancel()
        }
        streams.removeAll()
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
