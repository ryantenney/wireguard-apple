// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.
// Copyright © 2026 Ryan Tenney.

import Foundation
import NetworkExtension

#if SWIFT_PACKAGE
import WireGuardKitGo
import WireGuardKitC
#endif

public enum WireGuardAdapterError: Error {
    /// Failure to locate tunnel file descriptor.
    case cannotLocateTunnelFileDescriptor

    /// Failure to perform an operation in such state.
    case invalidState

    /// Failure to resolve endpoints.
    case dnsResolution([DNSResolutionError])

    /// Failure to set network settings.
    case setNetworkSettings(Error)

    /// Failure to start WireGuard backend.
    case startWireGuardBackend(Int32)
}

/// Enum representing internal state of the `WireGuardAdapter`
private enum State {
    /// The tunnel is stopped
    case stopped

    /// The tunnel is up and running
    case started(_ handle: Int32, _ settingsGenerator: PacketTunnelSettingsGenerator)

    /// The tunnel is temporarily shutdown due to device going offline
    case temporaryShutdown(_ settingsGenerator: PacketTunnelSettingsGenerator)

    /// Tunnel-in-Tunnel: INNER+OUTER devices running, managed by TiT handle.
    case startedTiT(_ handle: Int32, _ innerSettingsGenerator: PacketTunnelSettingsGenerator)

    /// Tunnel-in-Tunnel paused (iOS offline).
    case temporaryShutdownTiT(_ innerSettingsGenerator: PacketTunnelSettingsGenerator,
                              _ outerUapiConfig: String,
                              _ outerIfaceIP: String)
}

public class WireGuardAdapter {
    public typealias LogHandler = (WireGuardLogLevel, String) -> Void

    /// Network routes monitor.
    private var networkMonitor: NWPathMonitor?

    /// Packet tunnel provider.
    private weak var packetTunnelProvider: NEPacketTunnelProvider?

    /// Log handler closure.
    private let logHandler: LogHandler

    /// Private queue used to synchronize access to `WireGuardAdapter` members.
    private let workQueue = DispatchQueue(label: "WireGuardAdapterWorkQueue")

    /// Adapter state.
    private var state: State = .stopped

    /// Connection health monitor for failover between tunnel configurations.
    /// Written by the packet tunnel provider (start/stop) and read on the
    /// adapter's queue and IPC paths, so access is lock-protected.
    public var healthMonitor: ConnectionHealthMonitor? {
        get {
            healthMonitorLock.lock()
            defer { healthMonitorLock.unlock() }
            return _healthMonitor
        }
        set {
            healthMonitorLock.lock()
            defer { healthMonitorLock.unlock() }
            _healthMonitor = newValue
        }
    }
    private var _healthMonitor: ConnectionHealthMonitor?
    private let healthMonitorLock = NSLock()

    /// Stored OUTER settings generator for TiT restart after iOS offline/online transitions.
    private var titOuterSettingsGenerator: PacketTunnelSettingsGenerator?

    /// Stored OUTER interface IP string for TiT restart.
    private var titOuterIfaceIP: String?

    /// Sibling failover endpoints whose IPs should be added to `excludedRoutes`
    /// so probe and active traffic destined for *other* failover servers bypasses
    /// the active utun. Updated on every `start`/`update`. See
    /// `docs/probe-routing-bypass.md`.
    private var excludedEndpoints: [Endpoint] = []

    /// The most recent `NEPacketTunnelNetworkSettings` handed to the system. Kept only
    /// so the connection details view can show what was actually applied.
    private var lastAppliedNetworkSettings: NEPacketTunnelNetworkSettings?

    /// Local network last resolved for `ExcludeLocalNetwork` (empty when the active config
    /// does not use it). Compared on every path change to decide whether routes need re-applying.
    private var localNetworkSnapshot = LocalNetworkSnapshot.empty

    /// Tunnel device file descriptor.
    private var tunnelFileDescriptor: Int32? {
        var ctlInfo = ctl_info()
        withUnsafeMutablePointer(to: &ctlInfo.ctl_name) {
            $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: $0.pointee)) {
                _ = strcpy($0, "com.apple.net.utun_control")
            }
        }
        for fd: Int32 in 0...1024 {
            var addr = sockaddr_ctl()
            var ret: Int32 = -1
            var len = socklen_t(MemoryLayout.size(ofValue: addr))
            withUnsafeMutablePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    ret = getpeername(fd, $0, &len)
                }
            }
            if ret != 0 || addr.sc_family != AF_SYSTEM {
                continue
            }
            if ctlInfo.ctl_id == 0 {
                ret = ioctl(fd, CTLIOCGINFO, &ctlInfo)
                if ret != 0 {
                    continue
                }
            }
            if addr.sc_id == ctlInfo.ctl_id {
                return fd
            }
        }
        return nil
    }

    /// Returns a WireGuard version.
    class var backendVersion: String {
        guard let ver = wgVersion() else { return "unknown" }
        let str = String(cString: ver)
        free(UnsafeMutableRawPointer(mutating: ver))
        return str
    }

    /// Returns the tunnel device interface name, or nil on error.
    /// - Returns: String.
    public var interfaceName: String? {
        guard let tunnelFileDescriptor = self.tunnelFileDescriptor else { return nil }

        var buffer = [UInt8](repeating: 0, count: Int(IFNAMSIZ))

        return buffer.withUnsafeMutableBufferPointer { mutableBufferPointer in
            guard let baseAddress = mutableBufferPointer.baseAddress else { return nil }

            var ifnameSize = socklen_t(IFNAMSIZ)
            let result = getsockopt(
                tunnelFileDescriptor,
                2 /* SYSPROTO_CONTROL */,
                2 /* UTUN_OPT_IFNAME */,
                baseAddress,
                &ifnameSize)

            if result == 0 {
                return String(cString: baseAddress)
            } else {
                return nil
            }
        }
    }

    // MARK: - Initialization

    /// Designated initializer.
    /// - Parameter packetTunnelProvider: an instance of `NEPacketTunnelProvider`. Internally stored
    ///   as a weak reference.
    /// - Parameter logHandler: a log handler closure.
    public init(with packetTunnelProvider: NEPacketTunnelProvider, logHandler: @escaping LogHandler) {
        self.packetTunnelProvider = packetTunnelProvider
        self.logHandler = logHandler

        setupLogHandler()
    }

    deinit {
        // Force remove logger to make sure that no further calls to the instance of this class
        // can happen after deallocation.
        wgSetLogger(nil, nil)

        // Cancel network monitor
        networkMonitor?.cancel()

        // Stop all background probes
        stopAllProbes()

        // Shutdown the tunnel
        switch self.state {
        case .started(let handle, _):
            wgTurnOff(handle)
        case .startedTiT(let handle, _):
            wgTurnOffTiT(handle)
        default:
            break
        }
    }

    // MARK: - Public methods

    /// Returns a runtime configuration from WireGuard.
    /// - Parameter completionHandler: completion handler.
    public func getRuntimeConfiguration(completionHandler: @escaping (String?) -> Void) {
        workQueue.async {
            switch self.state {
            case .started(let handle, _):
                if let settings = wgGetConfig(handle) {
                    completionHandler(String(cString: settings))
                    free(settings)
                } else {
                    completionHandler(nil)
                }
            case .startedTiT(let handle, _):
                if let settings = wgGetConfigTiT(handle) {
                    completionHandler(String(cString: settings))
                    free(settings)
                } else {
                    completionHandler(nil)
                }
            default:
                completionHandler(nil)
            }
        }
    }

    /// Get runtime configurations for both INNER and OUTER TiT tunnels.
    /// Returns `(inner, outer)` UAPI config strings, or `(nil, nil)` if not in TiT mode.
    public func getTiTRuntimeConfigurations(completionHandler: @escaping (String?, String?) -> Void) {
        workQueue.async {
            guard case .startedTiT(let handle, _) = self.state else {
                completionHandler(nil, nil)
                return
            }
            let inner: String?
            if let settings = wgGetConfigTiT(handle) {
                inner = String(cString: settings)
                free(settings)
            } else {
                inner = nil
            }
            let outer: String?
            if let settings = wgGetOuterConfigTiT(handle) {
                outer = String(cString: settings)
                free(settings)
            } else {
                outer = nil
            }
            completionHandler(inner, outer)
        }
    }

    /// Start the tunnel tunnel.
    /// - Parameters:
    ///   - tunnelConfiguration: tunnel configuration.
    ///   - completionHandler: completion handler.
    public func start(tunnelConfiguration: TunnelConfiguration, excludedEndpoints: [Endpoint] = [], completionHandler: @escaping (WireGuardAdapterError?) -> Void) {
        workQueue.async {
            guard case .stopped = self.state else {
                completionHandler(.invalidState)
                return
            }

            let networkMonitor = NWPathMonitor()
            networkMonitor.pathUpdateHandler = { [weak self] path in
                self?.didReceivePathUpdate(path: path)
            }
            networkMonitor.start(queue: self.workQueue)

            do {
                self.excludedEndpoints = excludedEndpoints
                let settingsGenerator = try self.makeSettingsGenerator(with: tunnelConfiguration)
                try self.setNetworkSettings(settingsGenerator.generateNetworkSettings())

                let (wgConfig, resolutionResults) = settingsGenerator.uapiConfiguration()
                self.logEndpointResolutionResults(resolutionResults)

                self.state = .started(
                    try self.startWireGuardBackend(wgConfig: wgConfig),
                    settingsGenerator
                )
                self.networkMonitor = networkMonitor
                completionHandler(nil)
            } catch let error as WireGuardAdapterError {
                networkMonitor.cancel()
                completionHandler(error)
            } catch {
                fatalError()
            }
        }
    }

    /// Start a tunnel-in-tunnel (TiT) session.
    /// OUTER connects to `outerTunnelConfiguration` using real UDP sockets.
    /// INNER handles user traffic through the real utun fd, routing via OUTER.
    /// - Parameters:
    ///   - outerTunnelConfiguration: OUTER WireGuard config (Server A).
    ///   - innerTunnelConfiguration: INNER WireGuard config (Server B); its network settings are applied to the system.
    ///   - completionHandler: completion handler.
    public func startTunnelInTunnel(
        outerTunnelConfiguration: TunnelConfiguration,
        innerTunnelConfiguration: TunnelConfiguration,
        completionHandler: @escaping (WireGuardAdapterError?) -> Void
    ) {
        workQueue.async {
            guard case .stopped = self.state else {
                completionHandler(.invalidState)
                return
            }

            let networkMonitor = NWPathMonitor()
            networkMonitor.pathUpdateHandler = { [weak self] path in
                self?.didReceivePathUpdate(path: path)
            }
            networkMonitor.start(queue: self.workQueue)

            do {
                let (handle, innerSettingsGenerator) = try self.bringUpTunnelInTunnel(
                    outerTunnelConfiguration: outerTunnelConfiguration,
                    innerTunnelConfiguration: innerTunnelConfiguration
                )
                self.state = .startedTiT(handle, innerSettingsGenerator)
                self.networkMonitor = networkMonitor
                completionHandler(nil)
            } catch let error as WireGuardAdapterError {
                networkMonitor.cancel()
                completionHandler(error)
            } catch {
                fatalError()
            }
        }
    }

    /// Replace both halves of a running tunnel-in-tunnel session with new configurations
    /// without stopping the packet tunnel provider. The old devices are torn down and new
    /// ones brought up; the system sees a brief "reasserting" rather than a disconnect.
    /// On failure the adapter is left stopped and the caller should cancel the tunnel.
    public func restartTunnelInTunnel(
        outerTunnelConfiguration: TunnelConfiguration,
        innerTunnelConfiguration: TunnelConfiguration,
        completionHandler: @escaping (WireGuardAdapterError?) -> Void
    ) {
        workQueue.async {
            guard case .startedTiT(let oldHandle, _) = self.state else {
                completionHandler(.invalidState)
                return
            }

            self.packetTunnelProvider?.reasserting = true
            defer {
                self.packetTunnelProvider?.reasserting = false
            }

            wgTurnOffTiT(oldHandle)
            self.state = .stopped

            do {
                let (handle, innerSettingsGenerator) = try self.bringUpTunnelInTunnel(
                    outerTunnelConfiguration: outerTunnelConfiguration,
                    innerTunnelConfiguration: innerTunnelConfiguration
                )
                self.state = .startedTiT(handle, innerSettingsGenerator)
                self.logHandler(.verbose, "TiT: restarted with updated configuration")
                completionHandler(nil)
            } catch let error as WireGuardAdapterError {
                self.logHandler(.error, "TiT: failed to restart with updated configuration: \(error)")
                self.tearDownAfterFailedRestart()
                completionHandler(error)
            } catch {
                fatalError()
            }
        }
    }

    /// Release everything `stop()` would have released, for the case where a restart failed
    /// after the old devices were torn down (state is already `.stopped`, so `stop()` would
    /// refuse to run). Must be called on `workQueue`.
    private func tearDownAfterFailedRestart() {
        networkMonitor?.cancel()
        networkMonitor = nil
        titOuterSettingsGenerator = nil
        titOuterIfaceIP = nil
        lastAppliedNetworkSettings = nil
        localNetworkSnapshot = .empty
        stopAllProbes()
        state = .stopped
    }

    /// Shared TiT bring-up: applies INNER's network settings, resolves both configs, and starts
    /// the paired devices. Must be called on `workQueue`. Stores the OUTER generator and interface
    /// IP needed for the iOS offline/online restart path.
    private func bringUpTunnelInTunnel(
        outerTunnelConfiguration: TunnelConfiguration,
        innerTunnelConfiguration: TunnelConfiguration
    ) throws -> (Int32, PacketTunnelSettingsGenerator) {
        // Apply INNER's network settings to the system (DNS, routes, MTU).
        let innerSettingsGenerator = try self.makeSettingsGenerator(with: innerTunnelConfiguration)
        try self.setNetworkSettings(innerSettingsGenerator.generateNetworkSettings())

        // Resolve OUTER peers and build UAPI config.
        let outerSettingsGenerator = try self.makeSettingsGenerator(with: outerTunnelConfiguration)
        let (outerWgConfig, outerResolutionResults) = outerSettingsGenerator.uapiConfiguration()
        self.logEndpointResolutionResults(outerResolutionResults)

        // Build INNER's UAPI config (uses PipedBind, so no real endpoint resolution matters).
        let (innerWgConfig, innerResolutionResults) = innerSettingsGenerator.uapiConfiguration()
        self.logEndpointResolutionResults(innerResolutionResults)

        // OUTER's first interface address is used as the IP source in the TiT pipe.
        let outerIfaceIP: String
        if let firstAddr = outerTunnelConfiguration.interface.addresses.first?.address {
            outerIfaceIP = "\(firstAddr)"
        } else {
            outerIfaceIP = "10.200.0.1"
        }

        guard let tunnelFileDescriptor = self.tunnelFileDescriptor else {
            throw WireGuardAdapterError.cannotLocateTunnelFileDescriptor
        }

        let handle = wgTurnOnTiT(outerWgConfig, innerWgConfig, outerIfaceIP, tunnelFileDescriptor)
        if handle < 0 {
            throw WireGuardAdapterError.startWireGuardBackend(handle)
        }
        #if os(iOS)
        wgDisableSomeRoamingForBrokenMobileSemanticsForOuterTiT(handle)
        #endif

        self.titOuterSettingsGenerator = outerSettingsGenerator
        self.titOuterIfaceIP = outerIfaceIP
        return (handle, innerSettingsGenerator)
    }

    /// Stop the tunnel.
    /// - Parameter completionHandler: completion handler.
    public func stop(completionHandler: @escaping (WireGuardAdapterError?) -> Void) {
        workQueue.async {
            switch self.state {
            case .started(let handle, _):
                wgTurnOff(handle)

            case .startedTiT(let handle, _):
                wgTurnOffTiT(handle)

            case .temporaryShutdown, .temporaryShutdownTiT:
                break

            case .stopped:
                completionHandler(.invalidState)
                return
            }

            self.networkMonitor?.cancel()
            self.networkMonitor = nil
            self.titOuterSettingsGenerator = nil
            self.titOuterIfaceIP = nil
            self.lastAppliedNetworkSettings = nil
            self.stopAllProbes()

            self.state = .stopped

            completionHandler(nil)
        }
    }

    /// Update runtime configuration.
    /// - Parameters:
    ///   - tunnelConfiguration: tunnel configuration.
    ///   - completionHandler: completion handler.
    public func update(tunnelConfiguration: TunnelConfiguration, excludedEndpoints: [Endpoint] = [], completionHandler: @escaping (WireGuardAdapterError?) -> Void) {
        workQueue.async {
            if case .stopped = self.state {
                completionHandler(.invalidState)
                return
            }

            // Tell the system that the tunnel is going to reconnect using new WireGuard
            // configuration.
            // This will broadcast the `NEVPNStatusDidChange` notification to the GUI process.
            self.packetTunnelProvider?.reasserting = true
            defer {
                self.packetTunnelProvider?.reasserting = false
            }

            do {
                self.excludedEndpoints = excludedEndpoints
                let settingsGenerator = try self.makeSettingsGenerator(with: tunnelConfiguration)
                try self.setNetworkSettings(settingsGenerator.generateNetworkSettings())

                switch self.state {
                case .started(let handle, _):
                    let (wgConfig, resolutionResults) = settingsGenerator.uapiConfiguration()
                    self.logEndpointResolutionResults(resolutionResults)

                    wgSetConfig(handle, wgConfig)
                    #if os(iOS)
                    wgDisableSomeRoamingForBrokenMobileSemantics(handle)
                    #endif

                    self.state = .started(handle, settingsGenerator)

                case .temporaryShutdown:
                    self.state = .temporaryShutdown(settingsGenerator)

                case .startedTiT(let handle, _):
                    // For TiT, `update` applies to the INNER tunnel configuration.
                    let (innerWgConfig, resolutionResults) = settingsGenerator.uapiConfiguration()
                    self.logEndpointResolutionResults(resolutionResults)
                    wgSetInnerConfigTiT(handle, innerWgConfig)
                    self.state = .startedTiT(handle, settingsGenerator)

                case .temporaryShutdownTiT(_, let outerWgConfig, let outerIfaceIP):
                    self.state = .temporaryShutdownTiT(settingsGenerator, outerWgConfig, outerIfaceIP)

                case .stopped:
                    fatalError()
                }

                completionHandler(nil)
            } catch let error as WireGuardAdapterError {
                completionHandler(error)
            } catch {
                fatalError()
            }
        }
    }

    /// Rebind the active tunnel's UDP sockets and retry handshakes. Safe to call in any
    /// state; does nothing unless a tunnel is running. Used by the health monitor to kick
    /// the tunnel immediately after the underlying network recovers (e.g. captive portal
    /// sign-in), when no network path change fires to do it for us.
    public func bumpTunnelSockets() {
        workQueue.async {
            switch self.state {
            case .started(let handle, _):
                wgBumpSockets(handle)
            case .startedTiT(let handle, _):
                wgBumpSocketsTiT(handle)
            default:
                break
            }
        }
    }

    // MARK: - Diagnostics

    /// Snapshot of the adapter's view of the world for the connection details view:
    /// state, utun name, backend version, applied network settings, current network
    /// path, and endpoint resolution results. Keys are JSON-serializable.
    public func getDiagnostics(completionHandler: @escaping ([String: Any]) -> Void) {
        workQueue.async {
            var info: [String: Any] = [
                "backendVersion": WireGuardAdapter.backendVersion,
                "probeCount": self.probeHandles.count,
                "probeHandles": self.probeHandles.keys.sorted().map { Int($0) }
            ]
            if let interfaceName = self.interfaceName {
                info["interfaceName"] = interfaceName
            }

            let settingsGenerator: PacketTunnelSettingsGenerator?
            switch self.state {
            case .stopped:
                info["adapterState"] = "stopped"
                settingsGenerator = nil
            case .started(let handle, let generator):
                info["adapterState"] = "started"
                info["tunnelHandle"] = Int(handle)
                settingsGenerator = generator
            case .temporaryShutdown(let generator):
                info["adapterState"] = "temporaryShutdown"
                settingsGenerator = generator
            case .startedTiT(let handle, let generator):
                info["adapterState"] = "startedTiT"
                info["tunnelHandle"] = Int(handle)
                settingsGenerator = generator
            case .temporaryShutdownTiT(let generator, _, _):
                info["adapterState"] = "temporaryShutdownTiT"
                settingsGenerator = generator
            }

            if let generator = settingsGenerator {
                info["endpoints"] = Self.endpointDiagnostics(for: generator)
                info["excludedEndpoints"] = generator.excludedEndpoints.map { $0.stringRepresentation }
                info["configuredMTU"] = generator.tunnelConfiguration.interface.mtu.map { Int($0) } ?? 0
                info["excludedIPs"] = generator.tunnelConfiguration.interface.excludedIPs.map { $0.stringRepresentation }
                info["excludeLocalNetwork"] = generator.tunnelConfiguration.interface.excludeLocalNetwork
                info["localNetworkRoutes"] = generator.localNetworkRoutes.map { $0.stringRepresentation }
            }
            if let localInterface = self.localNetworkSnapshot.interfaceName {
                info["localNetworkInterface"] = localInterface
            }
            if let outerGenerator = self.titOuterSettingsGenerator {
                info["outerEndpoints"] = Self.endpointDiagnostics(for: outerGenerator)
            }
            if let outerIfaceIP = self.titOuterIfaceIP {
                info["titOuterInterfaceIP"] = outerIfaceIP
            }
            info["configuredExcludedEndpoints"] = self.excludedEndpoints.map { $0.stringRepresentation }

            if let networkSettings = self.lastAppliedNetworkSettings {
                info["networkSettings"] = Self.networkSettingsDiagnostics(networkSettings)
            }
            if let path = self.networkMonitor?.currentPath {
                info["networkPath"] = Self.networkPathDiagnostics(path)
            }

            completionHandler(info)
        }
    }

    private static func endpointDiagnostics(for generator: PacketTunnelSettingsGenerator) -> [[String: Any]] {
        return zip(generator.tunnelConfiguration.peers, generator.resolvedEndpoints).map { peer, resolved in
            var entry: [String: Any] = ["publicKey": peer.publicKey.base64Key]
            if let configured = peer.endpoint {
                entry["configured"] = configured.stringRepresentation
            }
            if let resolved = resolved {
                entry["resolved"] = resolved.stringRepresentation
            }
            return entry
        }
    }

    private static func networkSettingsDiagnostics(_ settings: NEPacketTunnelNetworkSettings) -> [String: Any] {
        var info: [String: Any] = ["tunnelRemoteAddress": settings.tunnelRemoteAddress]
        if let mtu = settings.mtu {
            info["mtu"] = mtu.intValue
        }
        if let overhead = settings.tunnelOverheadBytes {
            info["tunnelOverheadBytes"] = overhead.intValue
        }
        if let dns = settings.dnsSettings {
            info["dnsServers"] = dns.servers
            info["dnsSearchDomains"] = dns.searchDomains ?? []
            info["dnsMatchDomains"] = dns.matchDomains ?? []
            info["dnsMatchDomainsNoSearch"] = dns.matchDomainsNoSearch
        }
        if let ipv4 = settings.ipv4Settings {
            info["ipv4Addresses"] = zip(ipv4.addresses, ipv4.subnetMasks).map { "\($0)/\(Self.prefixLength(fromIPv4Mask: $1))" }
            info["ipv4IncludedRoutes"] = (ipv4.includedRoutes ?? []).map(Self.describe)
            info["ipv4ExcludedRoutes"] = (ipv4.excludedRoutes ?? []).map(Self.describe)
        }
        if let ipv6 = settings.ipv6Settings {
            info["ipv6Addresses"] = zip(ipv6.addresses, ipv6.networkPrefixLengths).map { "\($0)/\($1.intValue)" }
            info["ipv6IncludedRoutes"] = (ipv6.includedRoutes ?? []).map(Self.describe)
            info["ipv6ExcludedRoutes"] = (ipv6.excludedRoutes ?? []).map(Self.describe)
        }
        return info
    }

    private static func describe(_ route: NEIPv4Route) -> String {
        var text = "\(route.destinationAddress)/\(prefixLength(fromIPv4Mask: route.destinationSubnetMask))"
        if let gateway = route.gatewayAddress {
            text += " via \(gateway)"
        }
        return text
    }

    private static func describe(_ route: NEIPv6Route) -> String {
        var text = "\(route.destinationAddress)/\(route.destinationNetworkPrefixLength.intValue)"
        if let gateway = route.gatewayAddress {
            text += " via \(gateway)"
        }
        return text
    }

    private static func prefixLength(fromIPv4Mask mask: String) -> Int {
        return mask.split(separator: ".").compactMap { UInt8($0) }.reduce(0) { $0 + $1.nonzeroBitCount }
    }

    private static func networkPathDiagnostics(_ path: Network.NWPath) -> [String: Any] {
        var info: [String: Any] = [
            "isExpensive": path.isExpensive,
            "isConstrained": path.isConstrained,
            "supportsIPv4": path.supportsIPv4,
            "supportsIPv6": path.supportsIPv6,
            "supportsDNS": path.supportsDNS
        ]
        switch path.status {
        case .satisfied:
            info["status"] = "satisfied"
        case .unsatisfied:
            info["status"] = "unsatisfied"
            info["unsatisfiedReason"] = String(describing: path.unsatisfiedReason)
        case .requiresConnection:
            info["status"] = "requiresConnection"
        @unknown default:
            info["status"] = "unknown"
        }
        info["interfaces"] = path.availableInterfaces.map { interface -> [String: Any] in
            return ["name": interface.name, "type": Self.describe(interface.type), "index": interface.index]
        }
        info["gateways"] = path.gateways.map(Self.describe)
        return info
    }

    private static func describe(_ type: NWInterface.InterfaceType) -> String {
        switch type {
        case .wifi: return "wifi"
        case .cellular: return "cellular"
        case .wiredEthernet: return "wiredEthernet"
        case .loopback: return "loopback"
        case .other: return "other"
        @unknown default: return "unknown"
        }
    }

    private static func describe(_ endpoint: Network.NWEndpoint) -> String {
        if case .hostPort(let host, _) = endpoint {
            return "\(host)"
        }
        return String(describing: endpoint)
    }

    // MARK: - Background Probe methods

    /// Active background probe handles, keyed by an arbitrary caller-chosen ID.
    private var probeHandles: [Int32: Bool] = [:]

    /// Start a background probe for the given tunnel configuration.
    /// The probe creates a lightweight WireGuard device with real UDP sockets and a null tun.
    /// It performs a full Noise IK handshake without routing any user traffic.
    public func startProbe(tunnelConfiguration: TunnelConfiguration, completionHandler: @escaping (Int32?, Error?) -> Void) {
        workQueue.async {
            // Don't start probe devices unless the tunnel is actually running —
            // e.g. during iOS temporaryShutdown a probe would just burn battery
            // and leak past the offline stopAllProbes() sweep.
            guard case .started = self.state else {
                completionHandler(nil, WireGuardAdapterError.invalidState)
                return
            }
            do {
                let settingsGenerator = try self.makeSettingsGenerator(with: tunnelConfiguration)
                let (wgConfig, resolutionResults) = settingsGenerator.uapiConfiguration()
                self.logEndpointResolutionResults(resolutionResults)

                let handle = wgProbeOn(wgConfig, 25) // 25s keepalive override
                if handle < 0 {
                    completionHandler(nil, WireGuardAdapterError.startWireGuardBackend(handle))
                    return
                }
                self.probeHandles[handle] = true
                self.logHandler(.verbose, "Probe: started with handle \(handle)")
                completionHandler(handle, nil)
            } catch let error as WireGuardAdapterError {
                completionHandler(nil, error)
            } catch {
                fatalError()
            }
        }
    }

    /// Stop a running background probe and release its resources.
    public func stopProbe(handle: Int32) {
        workQueue.async {
            guard self.probeHandles.removeValue(forKey: handle) != nil else { return }
            wgProbeOff(handle)
            self.logHandler(.verbose, "Probe: stopped handle \(handle)")
        }
    }

    /// Get UAPI runtime configuration from a background probe.
    /// Returns the config string containing last_handshake_time_sec, tx_bytes, rx_bytes, etc.
    public func getProbeRuntimeConfiguration(handle: Int32, completionHandler: @escaping (String?) -> Void) {
        workQueue.async {
            guard self.probeHandles[handle] != nil else {
                completionHandler(nil)
                return
            }
            if let settings = wgProbeGetConfig(handle) {
                completionHandler(String(cString: settings))
                free(settings)
            } else {
                completionHandler(nil)
            }
        }
    }

    /// Rebind probe sockets after a network path change.
    public func bumpProbeSockets(handle: Int32) {
        workQueue.async {
            guard self.probeHandles[handle] != nil else { return }
            wgProbeBumpSockets(handle)
        }
    }

    /// Promote a background probe to become the active tunnel.
    /// Swaps the probe's null tun for the real utun fd, preserving the existing WireGuard
    /// session (no re-handshake). The old active tunnel is torn down.
    /// - Parameters:
    ///   - probeHandle: handle returned by startProbe()
    ///   - tunnelConfiguration: the configuration that the probe was started with
    ///   - completionHandler: called with nil on success, or an error
    public func promoteProbe(probeHandle: Int32, tunnelConfiguration: TunnelConfiguration,
                             excludedEndpoints: [Endpoint] = [],
                             completionHandler: @escaping (Error?) -> Void) {
        workQueue.async {
            self.excludedEndpoints = excludedEndpoints
            // Must have a running tunnel to promote into
            guard case .started(let oldHandle, _) = self.state else {
                // The caller has already disowned the probe handle; without a
                // tunnel to promote into the probe device would orphan and keep
                // handshaking forever — stop it here.
                if self.probeHandles.removeValue(forKey: probeHandle) != nil {
                    wgProbeOff(probeHandle)
                }
                if case .startedTiT = self.state {
                    // TiT promotion not supported yet
                    self.logHandler(.error, "Probe promote: not supported for TiT tunnels")
                }
                completionHandler(WireGuardAdapterError.invalidState)
                return
            }

            guard self.probeHandles.removeValue(forKey: probeHandle) != nil else {
                self.logHandler(.error, "Probe promote: unknown probe handle \(probeHandle)")
                completionHandler(WireGuardAdapterError.invalidState)
                return
            }

            self.packetTunnelProvider?.reasserting = true
            defer { self.packetTunnelProvider?.reasserting = false }

            do {
                let settingsGenerator = try self.makeSettingsGenerator(with: tunnelConfiguration)
                try self.setNetworkSettings(settingsGenerator.generateNetworkSettings())

                guard let tunnelFileDescriptor = self.tunnelFileDescriptor else {
                    throw WireGuardAdapterError.cannotLocateTunnelFileDescriptor
                }

                // Promote: swaps null tun → real utun inside the probe's device,
                // moves it to tunnelHandles, and returns the new tunnel handle.
                let newHandle = wgProbePromote(probeHandle, tunnelFileDescriptor)
                if newHandle < 0 {
                    throw WireGuardAdapterError.startWireGuardBackend(newHandle)
                }

                // Tear down the old tunnel device.
                wgTurnOff(oldHandle)

                #if os(iOS)
                wgDisableSomeRoamingForBrokenMobileSemantics(newHandle)
                #endif

                self.state = .started(newHandle, settingsGenerator)
                self.logHandler(.verbose, "Probe promote: probe \(probeHandle) → tunnel \(newHandle), session preserved")
                completionHandler(nil)
            } catch let error as WireGuardAdapterError {
                // Probe is gone from probeHandles but promote failed — clean it up
                wgProbeOff(probeHandle)
                // The new config's network settings were applied before the
                // failure, but the old device is still the one running. Restore
                // its settings so routes/DNS match reality; if this also fails,
                // the caller's fallback adapter.update() will reapply settings.
                if case .started(_, let oldSettingsGenerator) = self.state {
                    try? self.setNetworkSettings(oldSettingsGenerator.generateNetworkSettings())
                }
                completionHandler(error)
            } catch {
                fatalError()
            }
        }
    }

    /// Stop all running probes. Called during tunnel shutdown.
    private func stopAllProbes() {
        for handle in probeHandles.keys {
            wgProbeOff(handle)
        }
        probeHandles.removeAll()
    }

    // MARK: - Private methods

    /// Setup WireGuard log handler.
    private func setupLogHandler() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        wgSetLogger(context) { context, logLevel, message in
            guard let context = context, let message = message else { return }

            let unretainedSelf = Unmanaged<WireGuardAdapter>.fromOpaque(context)
                .takeUnretainedValue()

            let swiftString = String(cString: message).trimmingCharacters(in: .newlines)
            let tunnelLogLevel = WireGuardLogLevel(rawValue: logLevel) ?? .verbose

            unretainedSelf.logHandler(tunnelLogLevel, swiftString)
        }
    }

    /// Set network tunnel configuration.
    /// This method ensures that the call to `setTunnelNetworkSettings` does not time out, as in
    /// certain scenarios the completion handler given to it may not be invoked by the system.
    ///
    /// - Parameters:
    ///   - networkSettings: an instance of type `NEPacketTunnelNetworkSettings`.
    /// - Throws: an error of type `WireGuardAdapterError`.
    /// - Returns: `PacketTunnelSettingsGenerator`.
    private func setNetworkSettings(_ networkSettings: NEPacketTunnelNetworkSettings) throws {
        var systemError: Error?
        let condition = NSCondition()

        self.lastAppliedNetworkSettings = networkSettings

        // Activate the condition
        condition.lock()
        defer { condition.unlock() }

        self.packetTunnelProvider?.setTunnelNetworkSettings(networkSettings) { error in
            systemError = error
            condition.signal()
        }

        // Packet tunnel's `setTunnelNetworkSettings` times out in certain
        // scenarios & never calls the given callback.
        let setTunnelNetworkSettingsTimeout: TimeInterval = 5 // seconds

        if condition.wait(until: Date().addingTimeInterval(setTunnelNetworkSettingsTimeout)) {
            if let systemError = systemError {
                throw WireGuardAdapterError.setNetworkSettings(systemError)
            }
        } else {
            self.logHandler(.error, "setTunnelNetworkSettings timed out after 5 seconds; proceeding anyway")
        }
    }

    /// Resolve peers of the given tunnel configuration.
    /// - Parameter tunnelConfiguration: tunnel configuration.
    /// - Throws: an error of type `WireGuardAdapterError`.
    /// - Returns: The list of resolved endpoints.
    private func resolvePeers(for tunnelConfiguration: TunnelConfiguration) throws -> [Endpoint?] {
        let endpoints = tunnelConfiguration.peers.map { $0.endpoint }
        let resolutionResults = DNSResolver.resolveSync(endpoints: endpoints)
        let resolutionErrors = resolutionResults.compactMap { result -> DNSResolutionError? in
            if case .failure(let error) = result {
                return error
            } else {
                return nil
            }
        }
        assert(endpoints.count == resolutionResults.count)
        guard resolutionErrors.isEmpty else {
            throw WireGuardAdapterError.dnsResolution(resolutionErrors)
        }

        let resolvedEndpoints = resolutionResults.map { result -> Endpoint? in
            // swiftlint:disable:next force_try
            return try! result?.get()
        }

        return resolvedEndpoints
    }

    /// Start WireGuard backend.
    /// - Parameter wgConfig: WireGuard configuration
    /// - Throws: an error of type `WireGuardAdapterError`
    /// - Returns: tunnel handle
    private func startWireGuardBackend(wgConfig: String) throws -> Int32 {
        guard let tunnelFileDescriptor = self.tunnelFileDescriptor else {
            throw WireGuardAdapterError.cannotLocateTunnelFileDescriptor
        }

        let handle = wgTurnOn(wgConfig, tunnelFileDescriptor)
        if handle < 0 {
            throw WireGuardAdapterError.startWireGuardBackend(handle)
        }
        #if os(iOS)
        wgDisableSomeRoamingForBrokenMobileSemantics(handle)
        #endif
        return handle
    }

    /// Resolves the hostnames in the given tunnel configuration and return settings generator.
    /// - Parameter tunnelConfiguration: an instance of type `TunnelConfiguration`.
    /// - Throws: an error of type `WireGuardAdapterError`.
    /// - Returns: an instance of type `PacketTunnelSettingsGenerator`.
    private func makeSettingsGenerator(with tunnelConfiguration: TunnelConfiguration) throws -> PacketTunnelSettingsGenerator {
        return PacketTunnelSettingsGenerator(
            tunnelConfiguration: tunnelConfiguration,
            resolvedEndpoints: try self.resolvePeers(for: tunnelConfiguration),
            excludedEndpoints: self.resolveExcludedEndpoints(),
            localNetworkRoutes: self.resolveLocalNetworkRoutes(for: tunnelConfiguration, path: self.networkMonitor?.currentPath)
        )
    }

    /// Resolve the local network for configs that ask to bypass it; records the snapshot so
    /// path changes can detect when it moves. Returns no routes otherwise.
    private func resolveLocalNetworkRoutes(for tunnelConfiguration: TunnelConfiguration, path: Network.NWPath?) -> [IPAddressRange] {
        guard tunnelConfiguration.interface.excludeLocalNetwork else {
            localNetworkSnapshot = .empty
            return []
        }
        let snapshot = LocalNetwork.snapshot(
            preferredInterface: path?.availableInterfaces.first?.name,
            tunnelInterface: interfaceName,
            gateways: path?.gateways.map(Self.describe) ?? []
        )
        if snapshot != localNetworkSnapshot {
            logHandler(.verbose, "Local network bypass: \(snapshot.interfaceName ?? "no interface") → \(snapshot.routes.map { $0.stringRepresentation }.joined(separator: ", "))")
        }
        localNetworkSnapshot = snapshot
        return snapshot.routes
    }

    /// After a network path change, re-install excluded routes when the local network moved
    /// (Wi-Fi → cellular, a different LAN). Only acts for configs with `ExcludeLocalNetwork`.
    private func refreshLocalNetworkExclusionsIfNeeded(path: Network.NWPath) {
        guard path.status.isSatisfiable else { return }
        let generator: PacketTunnelSettingsGenerator
        switch state {
        case .started(_, let current), .startedTiT(_, let current):
            generator = current
        default:
            return
        }
        guard generator.tunnelConfiguration.interface.excludeLocalNetwork else { return }

        let snapshot = LocalNetwork.snapshot(
            preferredInterface: path.availableInterfaces.first?.name,
            tunnelInterface: interfaceName,
            gateways: path.gateways.map(Self.describe)
        )
        guard snapshot != localNetworkSnapshot else { return }
        logHandler(.verbose, "Local network bypass changed: \(snapshot.interfaceName ?? "no interface") → \(snapshot.routes.map { $0.stringRepresentation }.joined(separator: ", ")); re-applying routes")
        localNetworkSnapshot = snapshot

        let updated = generator.replacingLocalNetworkRoutes(snapshot.routes)
        packetTunnelProvider?.reasserting = true
        defer { packetTunnelProvider?.reasserting = false }
        do {
            try setNetworkSettings(updated.generateNetworkSettings())
        } catch {
            logHandler(.error, "Failed to re-apply excluded routes after network change: \(error)")
            return
        }
        switch state {
        case .started(let handle, _):
            state = .started(handle, updated)
        case .startedTiT(let handle, _):
            state = .startedTiT(handle, updated)
        default:
            break
        }
    }

    /// Resolve the stored sibling endpoints to IPs. Hostnames that fail to resolve are
    /// dropped with a log entry — this leaves the corresponding sibling without a route
    /// exception, but doesn't fail the tunnel.
    private func resolveExcludedEndpoints() -> [Endpoint] {
        var resolved: [Endpoint] = []
        for endpoint in excludedEndpoints {
            do {
                resolved.append(try endpoint.withReresolvedIP())
            } catch {
                logHandler(.error, "Failed to resolve sibling failover endpoint \(endpoint.stringRepresentation): \(error). Probe traffic for this endpoint will route through the active tunnel until next re-resolution.")
            }
        }
        return resolved
    }

    /// Log DNS resolution results.
    /// - Parameter resolutionErrors: an array of type `[DNSResolutionError]`.
    private func logEndpointResolutionResults(_ resolutionResults: [EndpointResolutionResult?]) {
        for case .some(let result) in resolutionResults {
            switch result {
            case .success((let sourceEndpoint, let resolvedEndpoint)):
                if sourceEndpoint.host == resolvedEndpoint.host {
                    self.logHandler(.verbose, "DNS64: mapped \(sourceEndpoint.host) to itself.")
                } else {
                    self.logHandler(.verbose, "DNS64: mapped \(sourceEndpoint.host) to \(resolvedEndpoint.host)")
                }
            case .failure(let resolutionError):
                self.logHandler(.error, "Failed to resolve endpoint \(resolutionError.address): \(resolutionError.errorDescription ?? "(nil)")")
            }
        }
    }

    /// Helper method used by network path monitor.
    /// - Parameter path: new network path
    private func didReceivePathUpdate(path: Network.NWPath) {
        self.logHandler(.verbose, "Network change detected with \(path.status) route and interface order \(path.availableInterfaces)")

        // Notify health monitor of network changes (may trigger failback probe)
        self.healthMonitor?.networkPathDidChange()

        #if os(macOS)
        switch self.state {
        case .started(let handle, _):
            wgBumpSockets(handle)
        case .startedTiT(let handle, _):
            wgBumpSocketsTiT(handle)
        default:
            break
        }
        // Bump all probe sockets on network change
        for probeHandle in self.probeHandles.keys {
            wgProbeBumpSockets(probeHandle)
        }
        #elseif os(iOS)
        switch self.state {
        case .started(let handle, let settingsGenerator):
            if path.status.isSatisfiable {
                let (wgConfig, resolutionResults) = settingsGenerator.endpointUapiConfiguration()
                self.logEndpointResolutionResults(resolutionResults)

                wgSetConfig(handle, wgConfig)
                wgDisableSomeRoamingForBrokenMobileSemantics(handle)
                wgBumpSockets(handle)
                // Bump all probe sockets on network change
                for probeHandle in self.probeHandles.keys {
                    wgProbeBumpSockets(probeHandle)
                }
            } else {
                self.logHandler(.verbose, "Connectivity offline, pausing backend.")

                self.state = .temporaryShutdown(settingsGenerator)
                wgTurnOff(handle)
                // Stop all probes when going offline — they'll be restarted by the health monitor
                self.stopAllProbes()
                // The monitor must drop its stale probe handles: Go recycles
                // handle IDs, so a kept handle could later alias a new probe.
                self.healthMonitor?.probesWereStopped()
            }

        case .temporaryShutdown(let settingsGenerator):
            guard path.status.isSatisfiable else { return }

            self.logHandler(.verbose, "Connectivity online, resuming backend.")

            do {
                try self.setNetworkSettings(settingsGenerator.generateNetworkSettings())

                let (wgConfig, resolutionResults) = settingsGenerator.uapiConfiguration()
                self.logEndpointResolutionResults(resolutionResults)

                self.state = .started(
                    try self.startWireGuardBackend(wgConfig: wgConfig),
                    settingsGenerator
                )
            } catch {
                self.logHandler(.error, "Failed to restart backend: \(error.localizedDescription)")
            }

        case .startedTiT(let handle, let innerSettingsGenerator):
            if path.status.isSatisfiable {
                // Update INNER's endpoint config (e.g. after DNS64 re-resolution).
                let (innerWgConfig, resolutionResults) = innerSettingsGenerator.endpointUapiConfiguration()
                self.logEndpointResolutionResults(resolutionResults)
                wgSetInnerConfigTiT(handle, innerWgConfig)
                // Bump OUTER's real sockets for the new network path.
                wgDisableSomeRoamingForBrokenMobileSemanticsForOuterTiT(handle)
                wgBumpSocketsTiT(handle)
            } else {
                self.logHandler(.verbose, "TiT: Connectivity offline, pausing backend.")
                // Capture enough state to restart TiT on reconnect.
                if let outerSettingsGenerator = self.titOuterSettingsGenerator {
                    let (outerWgConfig, _) = outerSettingsGenerator.uapiConfiguration()
                    let outerIfaceIP = self.titOuterIfaceIP ?? "10.200.0.1"
                    self.state = .temporaryShutdownTiT(innerSettingsGenerator, outerWgConfig, outerIfaceIP)
                } else {
                    self.state = .temporaryShutdown(innerSettingsGenerator)
                }
                wgTurnOffTiT(handle)
            }

        case .temporaryShutdownTiT(let innerSettingsGenerator, let outerWgConfig, let outerIfaceIP):
            guard path.status.isSatisfiable else { return }

            self.logHandler(.verbose, "TiT: Connectivity online, resuming backend.")

            do {
                try self.setNetworkSettings(innerSettingsGenerator.generateNetworkSettings())

                let (innerWgConfig, resolutionResults) = innerSettingsGenerator.uapiConfiguration()
                self.logEndpointResolutionResults(resolutionResults)

                guard let tunnelFileDescriptor = self.tunnelFileDescriptor else {
                    throw WireGuardAdapterError.cannotLocateTunnelFileDescriptor
                }

                let handle = wgTurnOnTiT(outerWgConfig, innerWgConfig, outerIfaceIP, tunnelFileDescriptor)
                if handle < 0 {
                    throw WireGuardAdapterError.startWireGuardBackend(handle)
                }
                wgDisableSomeRoamingForBrokenMobileSemanticsForOuterTiT(handle)
                self.state = .startedTiT(handle, innerSettingsGenerator)
            } catch {
                self.logHandler(.error, "TiT: Failed to restart backend: \(error.localizedDescription)")
            }

        case .stopped:
            // no-op
            break
        }
        #else
        #error("Unsupported")
        #endif

        self.refreshLocalNetworkExclusionsIfNeeded(path: path)
    }
}

/// A enum describing WireGuard log levels defined in `api-apple.go`.
public enum WireGuardLogLevel: Int32 {
    case verbose = 0
    case error = 1
}

private extension Network.NWPath.Status {
    /// Returns `true` if the path is potentially satisfiable.
    var isSatisfiable: Bool {
        switch self {
        case .requiresConnection, .satisfied:
            return true
        case .unsatisfied:
            return false
        @unknown default:
            return true
        }
    }
}
