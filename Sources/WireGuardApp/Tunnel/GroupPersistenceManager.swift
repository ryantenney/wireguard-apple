// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import Foundation

/// Generic persistence manager for group models stored as JSON in the app group shared folder.
class GroupPersistenceManager<T: Codable> where T: Identifiable, T.ID == UUID {

    private let fileName: String
    private let logPrefix: String

    private var fileURL: URL? {
        guard let appGroupId = FileManager.appGroupId else { return nil }
        guard let sharedFolder = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) else { return nil }
        return sharedFolder.appendingPathComponent(fileName)
    }

    init(fileName: String, logPrefix: String) {
        self.fileName = fileName
        self.logPrefix = logPrefix
    }

    func loadGroups() -> [T] {
        guard let url = fileURL else { return [] }
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([T].self, from: data)) ?? []
    }

    func saveGroups(_ groups: [T]) {
        guard let url = fileURL else {
            wg_log(.error, message: "\(logPrefix): cannot determine shared folder for saving groups")
            return
        }
        do {
            let data = try JSONEncoder().encode(groups)
            try data.write(to: url, options: .atomic)
        } catch {
            wg_log(.error, message: "\(logPrefix): failed to save groups: \(error)")
        }
    }

    func addGroup(_ group: T) {
        var groups = loadGroups()
        groups.append(group)
        saveGroups(groups)
    }

    func updateGroup(_ group: T) {
        var groups = loadGroups()
        if let index = groups.firstIndex(where: { $0.id == group.id }) {
            groups[index] = group
        }
        saveGroups(groups)
    }

    func removeGroup(withId id: UUID) {
        var groups = loadGroups()
        groups.removeAll { $0.id == id }
        saveGroups(groups)
    }

    func group(withId id: UUID) -> T? {
        return loadGroups().first { $0.id == id }
    }
}

// MARK: - Shared Instances

let titGroupPersistence = GroupPersistenceManager<TunnelInTunnelGroup>(fileName: "tit-groups.json", logPrefix: "TiT")
