// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import Foundation
import Network

#if SWIFT_PACKAGE
import WireGuardKitC
#endif

/// The networks a device is directly attached to through its active physical interface,
/// expressed as routes that can be excluded from the tunnel: the interface's on-link
/// subnets plus its default gateways (as host routes when they fall outside those subnets).
public struct LocalNetworkSnapshot: Equatable {
    /// Physical interface the snapshot was taken from (e.g. `en0`), if one was identified.
    public var interfaceName: String?
    /// Routes to exclude, de-duplicated and sorted for stable comparison.
    public var routes: [IPAddressRange]

    public static let empty = LocalNetworkSnapshot(interfaceName: nil, routes: [])
}

enum LocalNetwork {

    /// Compute the current local-network snapshot.
    /// - Parameters:
    ///   - preferredInterface: interface reported by `NWPath.availableInterfaces.first`, if known.
    ///   - tunnelInterface: our own utun name, never treated as the physical interface.
    ///   - gateways: gateway addresses reported by `NWPath.gateways` (may carry a `%scope` suffix).
    static func snapshot(preferredInterface: String?, tunnelInterface: String?, gateways: [String]) -> LocalNetworkSnapshot {
        let defaultRoutes = physicalDefaultRoutes(excluding: tunnelInterface)
        let interfaceName = preferredInterface.flatMap { $0.hasPrefix("utun") || $0 == tunnelInterface ? nil : $0 }
            ?? defaultRoutes.first?.interface
        guard let interface = interfaceName else { return .empty }

        var routes: [IPAddressRange] = []
        var seen: Set<String> = []
        func add(_ range: IPAddressRange) {
            let key = range.stringRepresentation
            guard !seen.contains(key) else { return }
            seen.insert(key)
            routes.append(range)
        }

        for subnet in onLinkSubnets(of: interface) {
            add(subnet)
        }

        let gatewayStrings = gateways + defaultRoutes.filter { $0.interface == interface }.map { $0.gateway }
        for gatewayString in gatewayStrings {
            let bare = gatewayString.split(separator: "%").first.map(String.init) ?? gatewayString
            guard let gateway = IPAddressRange(from: bare), isRoutable(gateway.address) else { continue }
            if !routes.contains(where: { contains(range: $0, address: gateway.address) }) {
                add(gateway)
            }
        }

        return LocalNetworkSnapshot(interfaceName: interface, routes: routes.sorted { $0.stringRepresentation < $1.stringRepresentation })
    }

    // MARK: - Interfaces

    /// On-link subnets of the named interface: IPv4 networks narrower than a host route and
    /// globally routable IPv6 prefixes. Link-local, loopback, and point-to-point host
    /// addresses (cellular) contribute nothing.
    private static func onLinkSubnets(of interfaceName: String) -> [IPAddressRange] {
        var subnets: [IPAddressRange] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifaddr = cursor {
            cursor = ifaddr.pointee.ifa_next
            guard String(cString: ifaddr.pointee.ifa_name) == interfaceName,
                  let address = ifaddr.pointee.ifa_addr,
                  let netmask = ifaddr.pointee.ifa_netmask else { continue }
            let flags = ifaddr.pointee.ifa_flags
            guard flags & UInt32(IFF_UP) != 0, flags & UInt32(IFF_LOOPBACK) == 0 else { continue }

            switch Int32(address.pointee.sa_family) {
            case AF_INET:
                let raw = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
                let prefix = netmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr.nonzeroBitCount }
                guard prefix > 0, prefix < 31, let ip = IPv4Address(Data(withUnsafeBytes(of: raw) { Array($0) })) else { continue }
                guard isRoutable(ip) else { continue }
                subnets.append(IPAddressRange(address: ip, networkPrefixLength: UInt8(prefix)).network())
            case AF_INET6:
                let bytes = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { pointer -> [UInt8] in
                    withUnsafeBytes(of: pointer.pointee.sin6_addr) { Array($0) }
                }
                let prefix = netmask.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { pointer -> Int in
                    let words = pointer.pointee.sin6_addr.__u6_addr.__u6_addr32
                    return words.0.nonzeroBitCount + words.1.nonzeroBitCount + words.2.nonzeroBitCount + words.3.nonzeroBitCount
                }
                guard prefix > 0, prefix < 127, let ip = IPv6Address(Data(bytes)) else { continue }
                guard isRoutable(ip) else { continue }
                subnets.append(IPAddressRange(address: ip, networkPrefixLength: UInt8(prefix)).network())
            default:
                continue
            }
        }
        return subnets
    }

    // MARK: - Routing table

    private struct DefaultRoute {
        let interface: String
        let gateway: String
    }

    /// Default routes that leave through a physical interface (the tunnel's own default route
    /// and interface-scoped copies of it are skipped). IPv4 first, then IPv6.
    private static func physicalDefaultRoutes(excluding tunnelInterface: String?) -> [DefaultRoute] {
        guard let dump = wgd_dump_routing_table() else { return [] }
        defer { free(dump) }
        var ipv4: [DefaultRoute] = []
        var ipv6: [DefaultRoute] = []
        for line in String(cString: dump).split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 5, fields[1] == "default" else { continue }
            let gateway = fields[2]
            let interface = fields[4]
            guard !interface.isEmpty, interface != tunnelInterface, !interface.hasPrefix("utun"),
                  !gateway.isEmpty, !gateway.hasPrefix("link#") else { continue }
            let route = DefaultRoute(interface: interface, gateway: gateway)
            if fields[0] == "inet" {
                ipv4.append(route)
            } else {
                ipv6.append(route)
            }
        }
        return ipv4 + ipv6
    }

    // MARK: - Address helpers

    private static func isRoutable(_ address: IPAddress) -> Bool {
        if let ipv6 = address as? IPv6Address {
            return !ipv6.isLinkLocal && !ipv6.isLoopback && !ipv6.isMulticast
        }
        if let ipv4 = address as? IPv4Address {
            return !ipv4.isLinkLocal && !ipv4.isLoopback && !ipv4.isMulticast
        }
        return false
    }

    private static func contains(range: IPAddressRange, address: IPAddress) -> Bool {
        guard type(of: range.address) == type(of: address) else { return false }
        let probe = IPAddressRange(address: address, networkPrefixLength: range.networkPrefixLength)
        return probe.maskedAddress().rawValue == range.maskedAddress().rawValue
    }
}

extension IPAddressRange {
    /// The same prefix anchored at its network address (e.g. 192.168.1.37/24 → 192.168.1.0/24).
    func network() -> IPAddressRange {
        return IPAddressRange(address: maskedAddress(), networkPrefixLength: networkPrefixLength)
    }
}
