// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import Foundation

/// Persists the user's speed test server list as JSON in the App Group shared
/// container (falling back to Documents when no app group is available, e.g.
/// in the simulator without provisioning).
///
/// No servers are seeded by default. The well-known public iperf3 servers run
/// a single-connection iperf3 instance per port and expect parallel streams to
/// be spread across a port range (e.g. `-p 5200-5209`); this single-port client
/// sends every stream to one port, so a default parallel test against them is
/// reset. The user adds their own iperf3 or OpenSpeedTest server (e.g. one
/// reachable through the tunnel) via the server list.
enum SpeedTestServerStore {

    private static let fileName = "speedtest-servers.json"

    /// Intentionally empty — see the type doc comment.
    static var builtInServers: [SpeedTestServer] {
        return []
    }

    /// UUIDs of the public iperf3 servers that used to be seeded. They are
    /// removed from any previously persisted list when it loads, so existing
    /// installs are cleaned up automatically rather than leaving stale,
    /// non-working servers behind.
    private static let retiredBuiltInServerIds: Set<UUID> = Set(
        [
            "6E31F9F0-0001-4B5B-9F86-000000000001",
            "6E31F9F0-0001-4B5B-9F86-000000000002",
            "6E31F9F0-0001-4B5B-9F86-000000000003",
            "6E31F9F0-0001-4B5B-9F86-000000000004",
            "6E31F9F0-0001-4B5B-9F86-000000000005",
            "6E31F9F0-0001-4B5B-9F86-000000000006",
            "6E31F9F0-0001-4B5B-9F86-000000000007",
            "6E31F9F0-0001-4B5B-9F86-000000000008"
        ].compactMap(UUID.init(uuidString:))
    )

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
            let servers = try JSONDecoder().decode([SpeedTestServer].self, from: data)
            let cleaned = servers.filter { !retiredBuiltInServerIds.contains($0.id) }
            if cleaned.count != servers.count {
                saveServers(cleaned)
            }
            return cleaned
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

}
