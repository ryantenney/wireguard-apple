// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import Foundation

/// Persists completed speed test results as JSON, newest first, capped at
/// `maxResults`. Storage location mirrors `SpeedTestServerStore`.
enum SpeedTestResultsStore {

    static let maxResults = 200
    private static let fileName = "speedtest-results.json"

    private static var fileURL: URL? {
        let folderURL: URL?
        if let appGroupId = FileManager.appGroupId,
           let sharedFolderURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) {
            folderURL = sharedFolderURL
        } else {
            folderURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        }
        return folderURL?.appendingPathComponent(fileName)
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func loadResults() -> [SpeedTestResult] {
        guard let url = fileURL, FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let data = try Data(contentsOf: url)
            return try makeDecoder().decode([SpeedTestResult].self, from: data)
        } catch {
            wg_log(.error, message: "SpeedTestResultsStore: failed to load results: \(error)")
            return []
        }
    }

    static func append(_ result: SpeedTestResult) {
        var results = loadResults()
        results.insert(result, at: 0)
        if results.count > maxResults {
            results.removeLast(results.count - maxResults)
        }
        save(results)
    }

    static func remove(withId id: UUID) {
        var results = loadResults()
        results.removeAll { $0.id == id }
        save(results)
    }

    static func clear() {
        guard let url = fileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func save(_ results: [SpeedTestResult]) {
        guard let url = fileURL else { return }
        do {
            let data = try makeEncoder().encode(results)
            try data.write(to: url, options: .atomic)
        } catch {
            wg_log(.error, message: "SpeedTestResultsStore: failed to save results: \(error)")
        }
    }
}
