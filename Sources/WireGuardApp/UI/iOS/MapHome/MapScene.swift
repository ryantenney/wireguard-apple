// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import Foundation
import NetworkExtension

/// Everything ConnectionMapView needs to draw for the current selection: the
/// user's approximate position, endpoint nodes, and the connection arcs
/// between them. Equatable so callers can skip redundant redraws when polling.
struct MapScene: Equatable {

    struct Coordinate: Equatable {
        var latitude: Double
        var longitude: Double
    }

    enum NodeKind: Equatable {
        case user
        case endpoint
    }

    enum Emphasis: Equatable {
        case active     // carrying traffic right now
        case standby    // configured failover target, currently idle
        case hotSpare   // pre-connected failover target
        case dimmed     // selection is disconnected
    }

    struct Node: Equatable {
        var coordinate: Coordinate
        var label: String
        var kind: NodeKind
        var emphasis: Emphasis
    }

    enum LinkStyle: Equatable {
        case flow       // animated beads: data is flowing over this leg
        case connecting // animated dashes: handshake in progress
        case standby    // static dashes: configured but idle
        case hotSpare   // dashed, gently pulsing: pre-connected spare
        case dimmed     // faint static line: selection is disconnected
    }

    struct Link: Equatable {
        var from: Coordinate
        var to: Coordinate
        var style: LinkStyle
    }

    var nodes = [Node]()
    var links = [Link]()
    var isProtected = false
    /// Tunnels in the current selection that have no location assigned yet.
    var unlocatedTunnelNames = [String]()
}

/// Convenience accessors for the group membership stored in a group manager's
/// providerConfiguration, used by the Map Home screen.
extension TunnelContainer {
    private var mapHomeProviderConfiguration: [String: Any]? {
        return (tunnelProvider.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration
    }

    var mapHomeFailoverMemberNames: [String] {
        return mapHomeProviderConfiguration?["FailoverConfigNames"] as? [String] ?? []
    }

    var mapHomeTiTOuterName: String? {
        return mapHomeProviderConfiguration?[TunnelInTunnelConfigKeys.outerName] as? String
    }

    var mapHomeTiTInnerName: String? {
        return mapHomeProviderConfiguration?[TunnelInTunnelConfigKeys.innerName] as? String
    }
}

/// Builds a MapScene from the selected tunnel (or group), the latest group
/// state received from the network extension, and the location assignments.
enum MapSceneBuilder {

    static func scene(for tunnel: TunnelContainer?,
                      groupState: [String: Any]?,
                      userLocation: UserLocationProvider.ApproximateLocation) -> MapScene {
        var scene = MapScene()
        let userCoordinate = MapScene.Coordinate(latitude: userLocation.latitude, longitude: userLocation.longitude)

        guard let tunnel = tunnel else {
            scene.nodes.append(MapScene.Node(coordinate: userCoordinate, label: "", kind: .user, emphasis: .dimmed))
            return scene
        }

        let phase = connectionPhase(of: tunnel)
        scene.isProtected = tunnel.status == .active
        scene.nodes.append(MapScene.Node(coordinate: userCoordinate, label: "", kind: .user,
                                         emphasis: phase == .up ? .active : .dimmed))

        let context = BuildContext(phase: phase,
                                   locations: EndpointLocationStore.locationsByTunnelName(),
                                   userCoordinate: userCoordinate)
        switch tunnel.groupKind {
        case .tunnelInTunnel:
            addTunnelInTunnel(to: &scene, tunnel: tunnel, context: context)
        case .failover:
            addFailover(to: &scene, tunnel: tunnel, groupState: groupState, context: context)
        case nil:
            addSingleTunnel(to: &scene, tunnel: tunnel, context: context)
        }
        return scene
    }

    // MARK: - Connection phase

    private enum Phase {
        case up          // traffic is (or should be) flowing
        case comingUp    // activating or waiting for another tunnel
        case down        // inactive or deactivating
    }

    private struct BuildContext {
        let phase: Phase
        let locations: [String: EndpointLocation]
        let userCoordinate: MapScene.Coordinate
    }

    private static func connectionPhase(of tunnel: TunnelContainer) -> Phase {
        switch tunnel.status {
        case .active, .reasserting, .restarting:
            return .up
        case .activating, .waiting:
            return .comingUp
        case .inactive, .deactivating:
            return .down
        }
    }

    private static func mainLinkStyle(for phase: Phase) -> MapScene.LinkStyle {
        switch phase {
        case .up: return .flow
        case .comingUp: return .connecting
        case .down: return .dimmed
        }
    }

    private static func mainNodeEmphasis(for phase: Phase) -> MapScene.Emphasis {
        return phase == .up ? .active : .dimmed
    }

    // MARK: - Single tunnel

    private static func addSingleTunnel(to scene: inout MapScene, tunnel: TunnelContainer, context: BuildContext) {
        guard let location = context.locations[tunnel.name] else {
            scene.unlocatedTunnelNames.append(tunnel.name)
            return
        }
        let coordinate = MapScene.Coordinate(latitude: location.latitude, longitude: location.longitude)
        scene.nodes.append(MapScene.Node(coordinate: coordinate, label: location.flaggedDisplayName,
                                         kind: .endpoint, emphasis: mainNodeEmphasis(for: context.phase)))
        scene.links.append(MapScene.Link(from: context.userCoordinate, to: coordinate, style: mainLinkStyle(for: context.phase)))
    }

    // MARK: - Tunnel-in-tunnel

    private static func addTunnelInTunnel(to scene: inout MapScene, tunnel: TunnelContainer, context: BuildContext) {
        let outerName = tunnel.mapHomeTiTOuterName ?? ""
        let innerName = tunnel.mapHomeTiTInnerName ?? ""

        let outerLocation = context.locations[outerName]
        let innerLocation = context.locations[innerName]
        if outerLocation == nil && !outerName.isEmpty {
            scene.unlocatedTunnelNames.append(outerName)
        }
        if innerLocation == nil && !innerName.isEmpty {
            scene.unlocatedTunnelNames.append(innerName)
        }

        let emphasis = mainNodeEmphasis(for: context.phase)
        let style = mainLinkStyle(for: context.phase)
        let outerCoordinate = outerLocation.map { MapScene.Coordinate(latitude: $0.latitude, longitude: $0.longitude) }
        let innerCoordinate = innerLocation.map { MapScene.Coordinate(latitude: $0.latitude, longitude: $0.longitude) }

        if let outerLocation = outerLocation, let outerCoordinate = outerCoordinate {
            scene.nodes.append(MapScene.Node(coordinate: outerCoordinate, label: outerLocation.flaggedDisplayName,
                                             kind: .endpoint, emphasis: emphasis))
            scene.links.append(MapScene.Link(from: context.userCoordinate, to: outerCoordinate, style: style))
        }
        if let innerLocation = innerLocation, let innerCoordinate = innerCoordinate {
            scene.nodes.append(MapScene.Node(coordinate: innerCoordinate, label: innerLocation.flaggedDisplayName,
                                             kind: .endpoint, emphasis: emphasis))
            // Second leg of the chain; fall back to a direct arc from the user
            // when the outer hop has no location yet.
            scene.links.append(MapScene.Link(from: outerCoordinate ?? context.userCoordinate, to: innerCoordinate, style: style))
        }
    }

    // MARK: - Failover group

    private static func addFailover(to scene: inout MapScene, tunnel: TunnelContainer, groupState: [String: Any]?, context: BuildContext) {
        let memberNames = tunnel.mapHomeFailoverMemberNames
        guard !memberNames.isEmpty else { return }

        let activeName = (groupState?["activeConfig"] as? String) ?? memberNames[0]
        let hotSpareIndex = groupState?["hotSpareConfigIndex"] as? Int
        let hotSpareHandshakeAge = groupState?["hotSpareHandshakeAge"] as? Double
        let isHotSpareReady = hotSpareHandshakeAge.map { $0 < 180 } ?? false

        for (index, memberName) in memberNames.enumerated() {
            guard let location = context.locations[memberName] else {
                scene.unlocatedTunnelNames.append(memberName)
                continue
            }
            let coordinate = MapScene.Coordinate(latitude: location.latitude, longitude: location.longitude)
            let emphasis: MapScene.Emphasis
            let style: MapScene.LinkStyle
            if memberName == activeName {
                emphasis = mainNodeEmphasis(for: context.phase)
                style = mainLinkStyle(for: context.phase)
            } else if context.phase == .up && index == hotSpareIndex && isHotSpareReady {
                emphasis = .hotSpare
                style = .hotSpare
            } else if context.phase == .up {
                emphasis = .standby
                style = .standby
            } else {
                emphasis = .dimmed
                style = .dimmed
            }
            scene.nodes.append(MapScene.Node(coordinate: coordinate, label: location.flaggedDisplayName,
                                             kind: .endpoint, emphasis: emphasis))
            scene.links.append(MapScene.Link(from: context.userCoordinate, to: coordinate, style: style))
        }
    }
}
