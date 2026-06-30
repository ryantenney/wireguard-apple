// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import Foundation
import Combine
import NetworkExtension

/// SwiftUI-facing wrapper around a `TunnelContainer`. It republishes the
/// container's KVO-observable properties as `@Published` values and holds the
/// latest runtime statistics (throughput, peer config, failover state).
final class TunnelNode: ObservableObject, Identifiable {
    let container: TunnelContainer
    let id: ObjectIdentifier

    @Published private(set) var name: String
    @Published private(set) var status: TunnelStatus
    @Published private(set) var isOnDemandEnabled: Bool
    @Published private(set) var hasOnDemandRules: Bool
    @Published private(set) var isOnDemandSuspended: Bool

    @Published private(set) var runtimeConfiguration: TunnelConfiguration?
    @Published private(set) var failoverState: FailoverRuntimeState?
    @Published private(set) var titState: TiTRuntimeState?
    @Published private(set) var downloadBytesPerSecond: Double = 0
    @Published private(set) var uploadBytesPerSecond: Double = 0
    @Published private(set) var connectedSince: Date?

    private var cancellables = Set<AnyCancellable>()
    private var lastSample: (rx: UInt64, tx: UInt64, at: Date)?

    init(container: TunnelContainer) {
        self.container = container
        id = ObjectIdentifier(container)
        name = container.name
        status = container.status
        isOnDemandEnabled = container.isActivateOnDemandEnabled
        hasOnDemandRules = container.hasOnDemandRules
        isOnDemandSuspended = container.isOnDemandSuspended
        if container.status == .active {
            connectedSince = Date()
        }
        bind()
    }

    private func bind() {
        container.publisher(for: \.name, options: [.new])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.name = value }
            .store(in: &cancellables)

        container.publisher(for: \.status, options: [.new])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.handleStatusChange(value) }
            .store(in: &cancellables)

        container.publisher(for: \.isActivateOnDemandEnabled, options: [.new])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.isOnDemandEnabled = value }
            .store(in: &cancellables)

        container.publisher(for: \.hasOnDemandRules, options: [.new])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.hasOnDemandRules = value }
            .store(in: &cancellables)

        container.publisher(for: \.isOnDemandSuspended, options: [.new])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.isOnDemandSuspended = value }
            .store(in: &cancellables)
    }

    private func handleStatusChange(_ newStatus: TunnelStatus) {
        status = newStatus
        switch newStatus {
        case .active:
            if connectedSince == nil { connectedSince = Date() }
        case .inactive:
            connectedSince = nil
            runtimeConfiguration = nil
            failoverState = nil
            titState = nil
            downloadBytesPerSecond = 0
            uploadBytesPerSecond = 0
            lastSample = nil
        default:
            break
        }
    }

    // MARK: - Derived state

    var isActive: Bool { status == .active }
    var isFailoverGroup: Bool { container.isFailoverGroup }
    var isTiTGroup: Bool { container.isTiTGroup }
    var isPlainTunnel: Bool { !container.isFailoverGroup && !container.isTiTGroup }

    private var providerConfiguration: [String: Any]? {
        (container.tunnelProvider.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration
    }

    /// Ordered member names for a failover group.
    var failoverMemberNames: [String] {
        (providerConfiguration?["FailoverConfigNames"] as? [String]) ?? []
    }

    /// Stored failover settings for a failover group (defaults if unreadable).
    var failoverSettings: FailoverSettings {
        if let data = providerConfiguration?["FailoverSettings"] as? Data,
           let decoded = try? JSONDecoder().decode(FailoverSettings.self, from: data) {
            return decoded
        }
        return FailoverSettings()
    }

    /// First peer endpoint as "host:port" — the subtitle for plain tunnels.
    var primaryEndpointDescription: String? {
        container.tunnelConfiguration?.peers.first?.endpoint?.stringRepresentation
    }

    // MARK: - Tunnel-in-Tunnel layers

    /// Outer/carrier tunnel name for a TiT group.
    var titOuterName: String {
        (providerConfiguration?[TunnelInTunnelConfigKeys.outerName] as? String) ?? ""
    }

    /// Inner/exit tunnel name for a TiT group.
    var titInnerName: String {
        (providerConfiguration?[TunnelInTunnelConfigKeys.innerName] as? String) ?? ""
    }

    var titOuterEndpoint: String? {
        titEndpoint(forKey: TunnelInTunnelConfigKeys.outerConfig)
    }

    var titInnerEndpoint: String? {
        titEndpoint(forKey: TunnelInTunnelConfigKeys.innerConfig)
    }

    private func titEndpoint(forKey key: String) -> String? {
        guard let wgQuick = providerConfiguration?[key] as? String,
              let config = try? TunnelConfiguration(fromWgQuickConfig: wgQuick, called: nil) else { return nil }
        return config.peers.first?.endpoint?.stringRepresentation
    }

    // MARK: - Runtime polling (driven by TunnelStore)

    func refreshRuntimeConfiguration() {
        container.getRuntimeTunnelConfiguration { [weak self] config in
            DispatchQueue.main.async {
                guard let self = self, let config = config else { return }
                self.runtimeConfiguration = config
                let rx = config.peers.reduce(UInt64(0)) { $0 + ($1.rxBytes ?? 0) }
                let tx = config.peers.reduce(UInt64(0)) { $0 + ($1.txBytes ?? 0) }
                self.ingestSample(rx: rx, tx: tx)
            }
        }
    }

    func refreshFailoverState(using manager: TunnelsManager) {
        manager.getFailoverState(for: container) { [weak self] dictionary in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard let state = FailoverRuntimeState(dictionary: dictionary) else { return }
                self.failoverState = state
                if let rx = state.rxBytes, let tx = state.txBytes {
                    self.ingestSample(rx: rx, tx: tx)
                }
            }
        }
    }

    func refreshTiTState(using manager: TunnelsManager) {
        manager.getTiTState(for: container) { [weak self] dictionary in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard let state = TiTRuntimeState(dictionary: dictionary) else { return }
                self.titState = state
                // Throughput for the hero/list uses the exit (inner) layer the user rides.
                if let rx = state.inner.rxBytes, let tx = state.inner.txBytes {
                    self.ingestSample(rx: rx, tx: tx)
                }
            }
        }
    }

    private func ingestSample(rx: UInt64, tx: UInt64) {
        let now = Date()
        if let last = lastSample {
            let elapsed = now.timeIntervalSince(last.at)
            if elapsed > 0.2 {
                let deltaRx = rx >= last.rx ? rx - last.rx : 0
                let deltaTx = tx >= last.tx ? tx - last.tx : 0
                downloadBytesPerSecond = Double(deltaRx) / elapsed
                uploadBytesPerSecond = Double(deltaTx) / elapsed
            }
        }
        lastSample = (rx, tx, now)
    }
}
