// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

import Foundation
import Network
import NetworkExtension

#if SWIFT_PACKAGE
import WireGuardKitC
#endif

/// A type alias for `Result` type that holds a tuple with source and resolved endpoint.
typealias EndpointResolutionResult = Result<(Endpoint, Endpoint), DNSResolutionError>

class PacketTunnelSettingsGenerator {
    let tunnelConfiguration: TunnelConfiguration
    let resolvedEndpoints: [Endpoint?]
    /// Already-resolved IP endpoints to install as `excludedRoutes` on the tunnel's
    /// network settings. Used by failover groups to keep traffic destined for sibling
    /// failover endpoints (hot spare probe target, other configs in the group) on the
    /// underlying physical interface instead of recursing through utun. Endpoints with
    /// `.name` hosts are ignored — caller must pre-resolve. See
    /// `docs/probe-routing-bypass.md`.
    let excludedEndpoints: [Endpoint]
    /// Directly connected networks and gateways of the active physical interface, resolved by
    /// the adapter when the interface configuration has `excludeLocalNetwork` set. Installed as
    /// excluded routes alongside `excludedEndpoints` and `interface.excludedIPs`.
    let localNetworkRoutes: [IPAddressRange]

    init(tunnelConfiguration: TunnelConfiguration, resolvedEndpoints: [Endpoint?], excludedEndpoints: [Endpoint] = [], localNetworkRoutes: [IPAddressRange] = []) {
        self.tunnelConfiguration = tunnelConfiguration
        self.resolvedEndpoints = resolvedEndpoints
        self.excludedEndpoints = excludedEndpoints
        self.localNetworkRoutes = localNetworkRoutes
    }

    /// A copy of this generator with different local-network routes (same resolved endpoints).
    func replacingLocalNetworkRoutes(_ routes: [IPAddressRange]) -> PacketTunnelSettingsGenerator {
        return PacketTunnelSettingsGenerator(tunnelConfiguration: tunnelConfiguration, resolvedEndpoints: resolvedEndpoints,
                                             excludedEndpoints: excludedEndpoints, localNetworkRoutes: routes)
    }

    func endpointUapiConfiguration() -> (String, [EndpointResolutionResult?]) {
        var resolutionResults = [EndpointResolutionResult?]()
        var wgSettings = ""

        assert(tunnelConfiguration.peers.count == resolvedEndpoints.count)
        for (peer, resolvedEndpoint) in zip(self.tunnelConfiguration.peers, self.resolvedEndpoints) {
            wgSettings.append("public_key=\(peer.publicKey.hexKey)\n")

            let result = resolvedEndpoint.map(Self.reresolveEndpoint)
            if case .success((_, let resolvedEndpoint)) = result {
                if case .name = resolvedEndpoint.host { assert(false, "Endpoint is not resolved") }
                wgSettings.append("endpoint=\(resolvedEndpoint.stringRepresentation)\n")
            }
            resolutionResults.append(result)
        }

        return (wgSettings, resolutionResults)
    }

    func uapiConfiguration() -> (String, [EndpointResolutionResult?]) {
        var resolutionResults = [EndpointResolutionResult?]()
        var wgSettings = ""
        wgSettings.append("private_key=\(tunnelConfiguration.interface.privateKey.hexKey)\n")
        if let listenPort = tunnelConfiguration.interface.listenPort {
            wgSettings.append("listen_port=\(listenPort)\n")
        }
        if !tunnelConfiguration.peers.isEmpty {
            wgSettings.append("replace_peers=true\n")
        }
        assert(tunnelConfiguration.peers.count == resolvedEndpoints.count)
        for (peer, resolvedEndpoint) in zip(self.tunnelConfiguration.peers, self.resolvedEndpoints) {
            wgSettings.append("public_key=\(peer.publicKey.hexKey)\n")
            if let preSharedKey = peer.preSharedKey?.hexKey {
                wgSettings.append("preshared_key=\(preSharedKey)\n")
            }

            let result = resolvedEndpoint.map(Self.reresolveEndpoint)
            if case .success((_, let resolvedEndpoint)) = result {
                if case .name = resolvedEndpoint.host { assert(false, "Endpoint is not resolved") }
                wgSettings.append("endpoint=\(resolvedEndpoint.stringRepresentation)\n")
            }
            resolutionResults.append(result)

            let persistentKeepAlive = peer.persistentKeepAlive ?? 0
            wgSettings.append("persistent_keepalive_interval=\(persistentKeepAlive)\n")
            if !peer.allowedIPs.isEmpty {
                wgSettings.append("replace_allowed_ips=true\n")
                peer.allowedIPs.forEach { wgSettings.append("allowed_ip=\($0.stringRepresentation)\n") }
            }
        }
        return (wgSettings, resolutionResults)
    }

    func generateNetworkSettings() -> NEPacketTunnelNetworkSettings {
        /* iOS requires a tunnel endpoint, whereas in WireGuard it's valid for
         * a tunnel to have no endpoint, or for there to be many endpoints, in
         * which case, displaying a single one in settings doesn't really
         * make sense. So, we fill it in with this placeholder, which is not
         * a valid IP address that will actually route over the Internet.
         */
        let networkSettings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")

        if !tunnelConfiguration.interface.dnsSearch.isEmpty || !tunnelConfiguration.interface.dns.isEmpty {
            let dnsServerStrings = tunnelConfiguration.interface.dns.map { $0.stringRepresentation }
            let dnsSettings = NEDNSSettings(servers: dnsServerStrings)
            dnsSettings.searchDomains = tunnelConfiguration.interface.dnsSearch
            if !tunnelConfiguration.interface.dns.isEmpty {
                dnsSettings.matchDomains = [""] // All DNS queries must first go through the tunnel's DNS
            }
            networkSettings.dnsSettings = dnsSettings
        }

        let mtu = tunnelConfiguration.interface.mtu ?? 0

        /* 0 means automatic MTU. In theory, we should just do
         * `networkSettings.tunnelOverheadBytes = 80` but in
         * practice there are too many broken networks out there.
         * Instead set it to 1280. Boohoo. Maybe someday we'll
         * add a nob, maybe, or iOS will do probing for us.
         */
        if mtu == 0 {
            #if os(iOS)
            networkSettings.mtu = NSNumber(value: 1280)
            #elseif os(macOS)
            networkSettings.tunnelOverheadBytes = 80
            #else
            #error("Unimplemented")
            #endif
        } else {
            networkSettings.mtu = NSNumber(value: mtu)
        }

        let (ipv4Addresses, ipv6Addresses) = addresses()
        let (ipv4IncludedRoutes, ipv6IncludedRoutes) = includedRoutes()
        let (ipv4ExcludedRoutes, ipv6ExcludedRoutes) = excludedRoutes()

        let ipv4Settings = NEIPv4Settings(addresses: ipv4Addresses.map { $0.destinationAddress }, subnetMasks: ipv4Addresses.map { $0.destinationSubnetMask })
        ipv4Settings.includedRoutes = ipv4IncludedRoutes
        if !ipv4ExcludedRoutes.isEmpty {
            ipv4Settings.excludedRoutes = ipv4ExcludedRoutes
        }
        networkSettings.ipv4Settings = ipv4Settings

        let ipv6Settings = NEIPv6Settings(addresses: ipv6Addresses.map { $0.destinationAddress }, networkPrefixLengths: ipv6Addresses.map { $0.destinationNetworkPrefixLength })
        ipv6Settings.includedRoutes = ipv6IncludedRoutes
        if !ipv6ExcludedRoutes.isEmpty {
            ipv6Settings.excludedRoutes = ipv6ExcludedRoutes
        }
        networkSettings.ipv6Settings = ipv6Settings

        return networkSettings
    }

    private func addresses() -> ([NEIPv4Route], [NEIPv6Route]) {
        var ipv4Routes = [NEIPv4Route]()
        var ipv6Routes = [NEIPv6Route]()
        for addressRange in tunnelConfiguration.interface.addresses {
            if addressRange.address is IPv4Address {
                ipv4Routes.append(NEIPv4Route(destinationAddress: "\(addressRange.address)", subnetMask: "\(addressRange.subnetMask())"))
            } else if addressRange.address is IPv6Address {
                /* Big fat ugly hack for broken iOS networking stack: the smallest prefix that will have
                 * any effect on iOS is a /120, so we clamp everything above to /120. This is potentially
                 * very bad, if various network parameters were actually relying on that subnet being
                 * intentionally small. TODO: talk about this with upstream iOS devs.
                 */
                ipv6Routes.append(NEIPv6Route(destinationAddress: "\(addressRange.address)", networkPrefixLength: NSNumber(value: min(120, addressRange.networkPrefixLength))))
            }
        }
        return (ipv4Routes, ipv6Routes)
    }

    private func includedRoutes() -> ([NEIPv4Route], [NEIPv6Route]) {
        var ipv4IncludedRoutes = [NEIPv4Route]()
        var ipv6IncludedRoutes = [NEIPv6Route]()

        for addressRange in tunnelConfiguration.interface.addresses {
            if addressRange.address is IPv4Address {
                let route = NEIPv4Route(destinationAddress: "\(addressRange.maskedAddress())", subnetMask: "\(addressRange.subnetMask())")
                route.gatewayAddress = "\(addressRange.address)"
                ipv4IncludedRoutes.append(route)
            } else if addressRange.address is IPv6Address {
                let route = NEIPv6Route(destinationAddress: "\(addressRange.maskedAddress())", networkPrefixLength: NSNumber(value: addressRange.networkPrefixLength))
                route.gatewayAddress = "\(addressRange.address)"
                ipv6IncludedRoutes.append(route)
            }
        }

        for peer in tunnelConfiguration.peers {
            for addressRange in peer.allowedIPs {
                if addressRange.address is IPv4Address {
                    ipv4IncludedRoutes.append(NEIPv4Route(destinationAddress: "\(addressRange.address)", subnetMask: "\(addressRange.subnetMask())"))
                } else if addressRange.address is IPv6Address {
                    ipv6IncludedRoutes.append(NEIPv6Route(destinationAddress: "\(addressRange.address)", networkPrefixLength: NSNumber(value: addressRange.networkPrefixLength)))
                }
            }
        }
        return (ipv4IncludedRoutes, ipv6IncludedRoutes)
    }

    /// Every route that must bypass the tunnel: sibling failover endpoints (host routes), the
    /// user's `ExcludedIPs`, and the resolved local network. De-duplicated; the tunnel's own
    /// addresses are never excluded.
    private func excludedRoutes() -> ([NEIPv4Route], [NEIPv6Route]) {
        var ipv4 = [NEIPv4Route]()
        var ipv6 = [NEIPv6Route]()
        var seen: Set<String> = []
        let ownAddresses = Set(tunnelConfiguration.interface.addresses.map { "\($0.address)" })

        func add(_ range: IPAddressRange) {
            let network = range.network()
            let key = network.stringRepresentation
            guard !seen.contains(key) else { return }
            let isHostRoute = (network.address is IPv4Address && network.networkPrefixLength == 32)
                || (network.address is IPv6Address && network.networkPrefixLength == 128)
            if isHostRoute && ownAddresses.contains("\(network.address)") { return }
            seen.insert(key)
            if network.address is IPv4Address {
                ipv4.append(NEIPv4Route(destinationAddress: "\(network.address)", subnetMask: "\(network.subnetMask())"))
            } else if network.address is IPv6Address {
                ipv6.append(NEIPv6Route(destinationAddress: "\(network.address)", networkPrefixLength: NSNumber(value: network.networkPrefixLength)))
            }
        }

        for endpoint in excludedEndpoints {
            switch endpoint.host {
            case .ipv4(let address):
                add(IPAddressRange(address: address, networkPrefixLength: 32))
            case .ipv6(let address):
                add(IPAddressRange(address: address, networkPrefixLength: 128))
            case .name:
                continue
            @unknown default:
                continue
            }
        }
        for range in tunnelConfiguration.interface.excludedIPs {
            add(range)
        }
        for range in localNetworkRoutes {
            add(range)
        }
        return (ipv4, ipv6)
    }

    private class func reresolveEndpoint(endpoint: Endpoint) -> EndpointResolutionResult {
        return Result { (endpoint, try endpoint.withReresolvedIP()) }
            .mapError { error -> DNSResolutionError in
                // swiftlint:disable:next force_cast
                return error as! DNSResolutionError
            }
    }
}
