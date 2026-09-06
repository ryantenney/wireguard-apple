// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

import Foundation
import Network

public struct InterfaceConfiguration {
    public var privateKey: PrivateKey
    public var addresses = [IPAddressRange]()
    public var listenPort: UInt16?
    public var mtu: UInt16?
    public var dns = [DNSServer]()
    public var dnsSearch = [String]()
    /// Destinations that bypass the tunnel. Installed as system excluded routes while the
    /// tunnel is up; AllowedIPs are left untouched. (`ExcludedIPs` in wg-quick text.)
    public var excludedIPs = [IPAddressRange]()
    /// Also bypass the network the active physical interface is directly connected to, and
    /// its gateway, recomputed on every network change. (`ExcludeLocalNetwork` in wg-quick text.)
    public var excludeLocalNetwork = false

    public init(privateKey: PrivateKey) {
        self.privateKey = privateKey
    }
}

extension InterfaceConfiguration: Equatable {
    public static func == (lhs: InterfaceConfiguration, rhs: InterfaceConfiguration) -> Bool {
        let lhsAddresses = lhs.addresses.filter { $0.address is IPv4Address } + lhs.addresses.filter { $0.address is IPv6Address }
        let rhsAddresses = rhs.addresses.filter { $0.address is IPv4Address } + rhs.addresses.filter { $0.address is IPv6Address }

        return lhs.privateKey == rhs.privateKey &&
            lhsAddresses == rhsAddresses &&
            lhs.listenPort == rhs.listenPort &&
            lhs.mtu == rhs.mtu &&
            lhs.dns == rhs.dns &&
            lhs.dnsSearch == rhs.dnsSearch &&
            Set(lhs.excludedIPs) == Set(rhs.excludedIPs) &&
            lhs.excludeLocalNetwork == rhs.excludeLocalNetwork
    }
}
