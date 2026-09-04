// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import Foundation

/// Host-level network facts gathered inside the Network Extension process for the
/// connection details view: local interface addresses, the kernel routing table,
/// and information about the extension process itself.
enum NetworkDiagnostics {

    // MARK: - Interfaces

    /// Every IPv4/IPv6 address bound to a local interface, one entry per address.
    static func interfaceAddresses() -> [[String: Any]] {
        var entries: [[String: Any]] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifaddr = cursor {
            cursor = ifaddr.pointee.ifa_next

            guard let address = ifaddr.pointee.ifa_addr else { continue }
            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }

            let flags = ifaddr.pointee.ifa_flags
            var entry: [String: Any] = [
                "name": String(cString: ifaddr.pointee.ifa_name),
                "family": family == AF_INET ? "inet" : "inet6",
                "isUp": flags & UInt32(IFF_UP) != 0,
                "isRunning": flags & UInt32(IFF_RUNNING) != 0,
                "isLoopback": flags & UInt32(IFF_LOOPBACK) != 0,
                "isPointToPoint": flags & UInt32(IFF_POINTOPOINT) != 0
            ]
            if let text = numericHost(address) {
                entry["address"] = text
            }
            if let netmask = ifaddr.pointee.ifa_netmask {
                entry["prefixLength"] = prefixLength(ofMask: netmask, family: family)
            }
            if flags & UInt32(IFF_POINTOPOINT) != 0, let destination = ifaddr.pointee.ifa_dstaddr, let text = numericHost(destination) {
                entry["destination"] = text
            }
            entries.append(entry)
        }
        return entries
    }

    private static func numericHost(_ address: UnsafeMutablePointer<sockaddr>) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let length = socklen_t(address.pointee.sa_len)
        guard getnameinfo(address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else {
            return nil
        }
        return String(cString: host)
    }

    private static func prefixLength(ofMask mask: UnsafeMutablePointer<sockaddr>, family: Int32) -> Int {
        if family == AF_INET {
            return mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
                pointer.pointee.sin_addr.s_addr.nonzeroBitCount
            }
        } else {
            return mask.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { pointer in
                let words = pointer.pointee.sin6_addr.__u6_addr.__u6_addr32
                return words.0.nonzeroBitCount + words.1.nonzeroBitCount + words.2.nonzeroBitCount + words.3.nonzeroBitCount
            }
        }
    }

    /// MTU of the named interface as reported by the kernel, or nil.
    static func interfaceMTU(named name: String) -> Int? {
        let mtu = wgd_interface_mtu(name)
        return mtu > 0 ? Int(mtu) : nil
    }

    // MARK: - Routing table

    /// The kernel routing table (see `wgd_dump_routing_table` for field semantics).
    static func routingTable() -> [[String: Any]]? {
        guard let dump = wgd_dump_routing_table() else { return nil }
        defer { free(dump) }

        let text = String(cString: dump)
        return text.split(separator: "\n").compactMap { line -> [String: Any]? in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 7 else { return nil }
            var entry: [String: Any] = [
                "family": fields[0],
                "destination": fields[1],
                "gateway": fields[2],
                "flags": fields[3],
                "interface": fields[4]
            ]
            if let mtu = Int(fields[5]), mtu > 0 {
                entry["mtu"] = mtu
            }
            if let expire = Int(fields[6]), expire > 0 {
                entry["expire"] = expire
            }
            return entry
        }
    }

    // MARK: - Process

    private static let launchDate = Date()

    /// Facts about the extension process: version, pid, uptime, memory, host OS.
    static func processInfo() -> [String: Any] {
        let info = ProcessInfo.processInfo
        var entry: [String: Any] = [
            "pid": Int(info.processIdentifier),
            "osVersion": info.operatingSystemVersionString,
            "uptime": Date().timeIntervalSince(launchDate),
            "activeProcessorCount": info.activeProcessorCount,
            "isLowPowerModeEnabled": info.isLowPowerModeEnabled,
            "thermalState": thermalStateDescription(info.thermalState)
        ]
        if let bundleIdentifier = Bundle.main.bundleIdentifier {
            entry["bundleIdentifier"] = bundleIdentifier
        }
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            entry["version"] = version
        }
        if let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
            entry["build"] = build
        }
        if let footprint = physicalFootprint() {
            entry["memoryFootprint"] = footprint
        }
        return entry
    }

    private static func thermalStateDescription(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    /// Resident memory footprint of this process in bytes (`phys_footprint`, the same
    /// number the OS uses for jetsam limits on iOS).
    private static func physicalFootprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return UInt64(info.phys_footprint)
    }
}
