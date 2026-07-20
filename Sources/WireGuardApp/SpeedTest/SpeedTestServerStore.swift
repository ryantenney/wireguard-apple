// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import Foundation

/// Persists the user's speed test server list as JSON in the App Group shared
/// container (falling back to Documents when no app group is available, e.g.
/// in the simulator without provisioning).
///
/// On first use the list is seeded with a curated set of well-known public
/// iperf3 servers. These are third-party servers: they may be busy (iperf3
/// runs one test at a time) or disappear over time, so the user can delete
/// them and later restore them via `restoreBuiltInServers()`.
enum SpeedTestServerStore {

    private static let fileName = "speedtest-servers.json"

    static var builtInServers: [SpeedTestServer] {
        return [
            SpeedTestServer(id: UUID(uuidString: "6E31F9F0-0001-4B5B-9F86-000000000001")!,
                            name: "Hurricane Electric (Fremont, US)", kind: .iperf3, host: "iperf.he.net", port: 5201, isBuiltIn: true),
            SpeedTestServer(id: UUID(uuidString: "6E31F9F0-0001-4B5B-9F86-000000000002")!,
                            name: "Clouvider (New York, US)", kind: .iperf3, host: "nyc.speedtest.clouvider.net", port: 5200, isBuiltIn: true),
            SpeedTestServer(id: UUID(uuidString: "6E31F9F0-0001-4B5B-9F86-000000000003")!,
                            name: "Clouvider (Los Angeles, US)", kind: .iperf3, host: "la.speedtest.clouvider.net", port: 5200, isBuiltIn: true),
            SpeedTestServer(id: UUID(uuidString: "6E31F9F0-0001-4B5B-9F86-000000000004")!,
                            name: "Clouvider (London, UK)", kind: .iperf3, host: "lon.speedtest.clouvider.net", port: 5200, isBuiltIn: true),
            SpeedTestServer(id: UUID(uuidString: "6E31F9F0-0001-4B5B-9F86-000000000005")!,
                            name: "Bouygues Telecom (Paris, FR)", kind: .iperf3, host: "bouygues.iperf.fr", port: 5200, isBuiltIn: true),
            SpeedTestServer(id: UUID(uuidString: "6E31F9F0-0001-4B5B-9F86-000000000006")!,
                            name: "Init7 (Winterthur, CH)", kind: .iperf3, host: "speedtest.init7.net", port: 5201, isBuiltIn: true),
            SpeedTestServer(id: UUID(uuidString: "6E31F9F0-0001-4B5B-9F86-000000000007")!,
                            name: "wilhelm.tel (Hamburg, DE)", kind: .iperf3, host: "speedtest.wtnet.de", port: 5200, isBuiltIn: true),
            SpeedTestServer(id: UUID(uuidString: "6E31F9F0-0001-4B5B-9F86-000000000008")!,
                            name: "Moji (Paris, FR)", kind: .iperf3, host: "iperf3.moji.fr", port: 5200, isBuiltIn: true)
        ]
    }

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

    static func loadServers() -> [SpeedTestServer] {
        guard let url = fileURL else { return builtInServers }
        guard FileManager.default.fileExists(atPath: url.path) else {
            let seeded = builtInServers
            saveServers(seeded)
            return seeded
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode([SpeedTestServer].self, from: data)
        } catch {
            wg_log(.error, message: "SpeedTestServerStore: failed to load servers: \(error)")
            return []
        }
    }

    static func saveServers(_ servers: [SpeedTestServer]) {
        guard let url = fileURL else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(servers)
            try data.write(to: url, options: .atomic)
        } catch {
            wg_log(.error, message: "SpeedTestServerStore: failed to save servers: \(error)")
        }
    }

    static func server(withId id: UUID) -> SpeedTestServer? {
        return loadServers().first { $0.id == id }
    }

    static func add(_ server: SpeedTestServer) {
        var servers = loadServers()
        servers.append(server)
        saveServers(servers)
    }

    static func update(_ server: SpeedTestServer) {
        var servers = loadServers()
        if let index = servers.firstIndex(where: { $0.id == server.id }) {
            servers[index] = server
            saveServers(servers)
        }
    }

    static func remove(withId id: UUID) {
        var servers = loadServers()
        servers.removeAll { $0.id == id }
        saveServers(servers)
    }

    /// Re-adds any built-in public servers that the user has deleted.
    static func restoreBuiltInServers() {
        var servers = loadServers()
        let existingIds = Set(servers.map { $0.id })
        for builtIn in builtInServers where !existingIds.contains(builtIn.id) {
            servers.append(builtIn)
        }
        saveServers(servers)
    }
}
