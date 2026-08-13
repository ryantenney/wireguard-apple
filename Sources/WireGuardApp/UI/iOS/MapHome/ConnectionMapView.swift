// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import UIKit

/// Fixed dark palette for the Map Home screen (the screen is always rendered
/// in dark appearance, like most VPN map UIs).
enum MapPalette {
    static let background = UIColor(red: 0.055, green: 0.05, blue: 0.09, alpha: 1)
    static let backgroundElevated = UIColor(red: 0.106, green: 0.098, blue: 0.153, alpha: 1)
    static let land = UIColor(red: 0.165, green: 0.157, blue: 0.224, alpha: 1)
    static let landEdge = UIColor(white: 1, alpha: 0.05)
    static let accent = UIColor(red: 0.49, green: 0.42, blue: 1, alpha: 1)
    static let flowBead = UIColor(red: 0.75, green: 0.7, blue: 1, alpha: 1)
    static let standby = UIColor(white: 0.85, alpha: 0.45)
    static let hotSpare = UIColor(red: 1, green: 0.72, blue: 0.25, alpha: 1)
    static let dimmed = UIColor(white: 0.85, alpha: 0.22)
    static let protectedTint = UIColor(red: 0.3, green: 0.78, blue: 0.5, alpha: 1)
    static let connectingTint = UIColor(red: 1, green: 0.72, blue: 0.25, alpha: 1)
    static let unprotectedTint = UIColor(red: 0.95, green: 0.42, blue: 0.5, alpha: 1)
}

/// Normalized Web Mercator projection: x in [0, 1] west→east and y in [0, 1]
/// north→south, so the whole world is the unit square.
enum MapProjection {
    static let maxLatitude = 84.0

    static func worldPoint(longitude: Double, latitude: Double) -> CGPoint {
        let x = (longitude + 180.0) / 360.0
        let clamped = max(-maxLatitude, min(maxLatitude, latitude))
        let mercator = log(tan(Double.pi / 4.0 + clamped * Double.pi / 360.0))
        let y = 0.5 - mercator / (2.0 * Double.pi)
        return CGPoint(x: x, y: y)
    }
}

/// Stylized dark world map that draws the WorldMapData landmasses, the user's
/// approximate position, endpoint markers, and animated data-flow arcs. The
/// camera automatically frames the current scene's points; changes morph
/// smoothly when requested.
class ConnectionMapView: UIView {

    /// View-space insets the auto-camera keeps clear of scene points, so
    /// overlaid UI (status header, connection card) doesn't cover them.
    var cameraInsets = UIEdgeInsets(top: 120, left: 44, bottom: 120, right: 44) {
        didSet { setNeedsLayout() }
    }

    private struct NodeLayers {
        let node: MapScene.Node
        let container: CALayer
        let label: UILabel?
    }

    private struct LinkLayers {
        let link: MapScene.Link
        let base: CAShapeLayer
        let overlay: CAShapeLayer?
    }

    private var scene = MapScene()
    private var nodeLayers = [NodeLayers]()
    private var linkLayers = [LinkLayers]()
    private var currentCamera: CGRect?
    private let landLayer = CAShapeLayer()

    private static let worldLandRings: [[CGPoint]] = WorldMapData.landRings.map { ring in
        ring.map { MapProjection.worldPoint(longitude: Double($0.x), latitude: Double($0.y)) }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        clipsToBounds = true
        isUserInteractionEnabled = false

        landLayer.fillColor = MapPalette.land.cgColor
        landLayer.fillRule = .evenOdd
        landLayer.strokeColor = MapPalette.landEdge.cgColor
        landLayer.lineWidth = 0.5
        layer.addSublayer(landLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Public API

    func setScene(_ newScene: MapScene, animated: Bool) {
        scene = newScene
        rebuildSceneLayers()
        guard bounds.width > 0 && bounds.height > 0 else { return }

        let newCamera = computeCamera()
        if animated, let oldCamera = currentCamera, !camerasAreClose(oldCamera, newCamera) {
            applyLayout(camera: oldCamera, animated: false)
            currentCamera = newCamera
            applyLayout(camera: newCamera, animated: true)
        } else {
            currentCamera = newCamera
            applyLayout(camera: newCamera, animated: false)
        }
    }

    /// Re-adds the repeating flow/pulse animations, which UIKit strips when
    /// the app is backgrounded.
    func restartAnimations() {
        setScene(scene, animated: false)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0 && bounds.height > 0 else { return }
        currentCamera = computeCamera()
        applyLayout(camera: currentCamera ?? CGRect(x: 0, y: 0, width: 1, height: 1), animated: false)
    }

    // MARK: - Camera

    private func camerasAreClose(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        let epsilon: CGFloat = 0.0005
        return abs(lhs.origin.x - rhs.origin.x) < epsilon
            && abs(lhs.origin.y - rhs.origin.y) < epsilon
            && abs(lhs.width - rhs.width) < epsilon
    }

    /// World points of all scene nodes, wrapped so their longitudes take the
    /// shortest representation around the first node.
    private func wrappedNodeWorldPoints() -> [CGPoint] {
        var points = [CGPoint]()
        var referenceX: CGFloat?
        for node in scene.nodes {
            var point = MapProjection.worldPoint(longitude: node.coordinate.longitude, latitude: node.coordinate.latitude)
            if let referenceX = referenceX {
                point.x -= (point.x - referenceX).rounded()
            } else {
                referenceX = point.x
            }
            points.append(point)
        }
        return points
    }

    private func computeCamera() -> CGRect {
        let insetBounds = bounds.inset(by: cameraInsets)
        guard insetBounds.width > 40 && insetBounds.height > 40 else {
            return wholeWorldCamera()
        }

        let points = wrappedNodeWorldPoints()
        guard let first = points.first else {
            return wholeWorldCamera()
        }

        var minPoint = first
        var maxPoint = first
        for point in points.dropFirst() {
            minPoint.x = min(minPoint.x, point.x)
            minPoint.y = min(minPoint.y, point.y)
            maxPoint.x = max(maxPoint.x, point.x)
            maxPoint.y = max(maxPoint.y, point.y)
        }
        var fit = CGRect(x: minPoint.x, y: minPoint.y,
                         width: maxPoint.x - minPoint.x, height: maxPoint.y - minPoint.y)

        // Pad around the points, then enforce a minimum span so a single
        // point doesn't zoom in absurdly close.
        fit = fit.insetBy(dx: -max(fit.width * 0.3, 0.018), dy: -max(fit.height * 0.3, 0.014))

        let minWidth: CGFloat = 0.15
        if fit.width < minWidth {
            fit = fit.insetBy(dx: -(minWidth - fit.width) / 2, dy: 0)
        }

        let minHeight: CGFloat = 0.11
        if fit.height < minHeight {
            fit = fit.insetBy(dx: 0, dy: -(minHeight - fit.height) / 2)
        }

        // World units per view point, fitting the padded box into the inset
        // area, clamped between a sensible max zoom and the whole world.
        var scale = max(fit.width / insetBounds.width, fit.height / insetBounds.height)
        scale = max(scale, 0.05 / bounds.width)
        scale = min(scale, 1.25 / bounds.width)

        var camera = CGRect(x: fit.midX - (insetBounds.midX - bounds.minX) * scale,
                            y: fit.midY - (insetBounds.midY - bounds.minY) * scale,
                            width: bounds.width * scale,
                            height: bounds.height * scale)

        // Keep the visible area from drifting far beyond the poles.
        if camera.height < 1.04 {
            camera.origin.y = min(max(camera.origin.y, -0.02), 1.02 - camera.height)
        } else {
            camera.origin.y = 0.5 - camera.height / 2
        }

        // Normalize so the camera center's longitude is within the base world
        // copy; the land is drawn at offsets -1, 0, +1 around it.
        let normalizedMidX = camera.midX - camera.midX.rounded(.down)
        camera.origin.x = normalizedMidX - camera.width / 2
        return camera
    }

    private func wholeWorldCamera() -> CGRect {
        guard bounds.width > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let height = bounds.height / bounds.width
        return CGRect(x: 0, y: 0.42 - height / 2, width: 1, height: height)
    }

    /// Projects a coordinate into view space under the given camera, wrapping
    /// its longitude to the world copy nearest the camera center.
    private func viewPoint(for coordinate: MapScene.Coordinate, camera: CGRect) -> CGPoint {
        var world = MapProjection.worldPoint(longitude: coordinate.longitude, latitude: coordinate.latitude)
        world.x -= (world.x - camera.midX).rounded()
        let scale = bounds.width / camera.width
        return CGPoint(x: (world.x - camera.minX) * scale, y: (world.y - camera.minY) * scale)
    }

    // MARK: - Layout

    private func applyLayout(camera: CGRect, animated: Bool) {
        let duration = 0.55
        let timing = CAMediaTimingFunction(name: .easeInEaseOut)

        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(duration)
            CATransaction.setAnimationTimingFunction(timing)
        } else {
            CATransaction.setDisableActions(true)
        }

        setPath(landPath(camera: camera), on: landLayer, animated: animated, duration: duration, timing: timing)

        for entry in linkLayers {
            let path = arcPath(from: viewPoint(for: entry.link.from, camera: camera),
                               to: viewPoint(for: entry.link.to, camera: camera))
            setPath(path, on: entry.base, animated: animated, duration: duration, timing: timing)
            if let overlay = entry.overlay {
                setPath(path, on: overlay, animated: animated, duration: duration, timing: timing)
            }
        }

        for entry in nodeLayers {
            entry.container.position = viewPoint(for: entry.node.coordinate, camera: camera)
        }
        CATransaction.commit()

        let placeLabels = { [self] in
            for entry in nodeLayers {
                guard let label = entry.label else { continue }
                let anchor = viewPoint(for: entry.node.coordinate, camera: camera)
                label.center = CGPoint(x: anchor.x, y: anchor.y + 22)
            }
        }
        if animated {
            UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseInOut], animations: placeLabels)
        } else {
            placeLabels()
        }
    }

    /// CAShapeLayer.path has no implicit action, so animate it explicitly.
    /// All paths keep an identical element structure across cameras, which
    /// makes the interpolation exact.
    private func setPath(_ path: CGPath, on shapeLayer: CAShapeLayer, animated: Bool, duration: CFTimeInterval, timing: CAMediaTimingFunction) {
        if animated, let oldPath = shapeLayer.path {
            let animation = CABasicAnimation(keyPath: "path")
            animation.fromValue = oldPath
            animation.toValue = path
            animation.duration = duration
            animation.timingFunction = timing
            shapeLayer.add(animation, forKey: "pathMorph")
        }
        shapeLayer.path = path
    }

    private func landPath(camera: CGRect) -> CGPath {
        let path = CGMutablePath()
        guard camera.width > 0, bounds.width > 0 else { return path }
        let scale = bounds.width / camera.width
        for copy in -1 ... 1 {
            let transform = CGAffineTransform(scaleX: scale, y: scale)
                .translatedBy(x: CGFloat(copy) - camera.minX, y: -camera.minY)
            for ring in Self.worldLandRings {
                path.addLines(between: ring, transform: transform)
                path.closeSubpath()
            }
        }
        return path
    }

    /// A quadratic arc that bows gently northward between two view points.
    private func arcPath(from start: CGPoint, to end: CGPoint) -> CGPath {
        let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        let distance = hypot(end.x - start.x, end.y - start.y)
        var control = mid
        if distance > 4 {
            var normal = CGPoint(x: (end.y - start.y) / distance, y: -(end.x - start.x) / distance)
            if normal.y > 0 {
                normal = CGPoint(x: -normal.x, y: -normal.y)
            }
            let lift = min(distance * 0.22, 90)
            control = CGPoint(x: mid.x + normal.x * lift, y: mid.y + normal.y * lift)
        }
        let path = CGMutablePath()
        path.move(to: start)
        path.addQuadCurve(to: end, control: control)
        return path
    }

    // MARK: - Scene layers

    private func rebuildSceneLayers() {
        for entry in linkLayers {
            entry.base.removeFromSuperlayer()
            entry.overlay?.removeFromSuperlayer()
        }
        for entry in nodeLayers {
            entry.container.removeFromSuperlayer()
            entry.label?.removeFromSuperview()
        }
        linkLayers = scene.links.map { makeLinkLayers(for: $0) }
        nodeLayers = scene.nodes.map { makeNodeLayers(for: $0) }
    }

    private func makeLinkLayers(for link: MapScene.Link) -> LinkLayers {
        let base = CAShapeLayer()
        base.fillColor = nil
        base.lineCap = .round
        layer.addSublayer(base)

        var overlay: CAShapeLayer?
        switch link.style {
        case .flow:
            base.strokeColor = MapPalette.accent.withAlphaComponent(0.3).cgColor
            base.lineWidth = 2

            let beads = CAShapeLayer()
            beads.fillColor = nil
            beads.lineCap = .round
            beads.strokeColor = MapPalette.flowBead.cgColor
            beads.lineWidth = 3
            beads.lineDashPattern = [0.1, 10]
            beads.add(dashPhaseAnimation(distance: -10.1, duration: 0.9), forKey: "flow")
            layer.addSublayer(beads)
            overlay = beads
        case .connecting:
            base.strokeColor = MapPalette.accent.withAlphaComponent(0.65).cgColor
            base.lineWidth = 2
            base.lineDashPattern = [6, 5]
            base.add(dashPhaseAnimation(distance: -11, duration: 1.6), forKey: "connecting")
        case .standby:
            base.strokeColor = MapPalette.standby.withAlphaComponent(0.35).cgColor
            base.lineWidth = 1.5
            base.lineDashPattern = [4, 6]
        case .hotSpare:
            base.strokeColor = MapPalette.hotSpare.withAlphaComponent(0.75).cgColor
            base.lineWidth = 1.5
            base.lineDashPattern = [4, 6]
            base.add(opacityPulseAnimation(from: 0.45, to: 1, duration: 1.4), forKey: "sparePulse")
        case .dimmed:
            base.strokeColor = MapPalette.dimmed.cgColor
            base.lineWidth = 1.5
        }
        return LinkLayers(link: link, base: base, overlay: overlay)
    }

    private func makeNodeLayers(for node: MapScene.Node) -> NodeLayers {
        let container = CALayer()
        layer.addSublayer(container)

        switch node.kind {
        case .user:
            addUserMarker(to: container)
        case .endpoint:
            addEndpointMarker(to: container, emphasis: node.emphasis)
        }

        var label: UILabel?
        if !node.label.isEmpty {
            let nodeLabel = UILabel()
            nodeLabel.text = node.label
            nodeLabel.font = .systemFont(ofSize: 11, weight: .semibold)
            nodeLabel.textColor = UIColor(white: 1, alpha: node.emphasis == .active ? 0.95 : 0.65)
            nodeLabel.layer.shadowColor = UIColor.black.cgColor
            nodeLabel.layer.shadowOpacity = 0.9
            nodeLabel.layer.shadowRadius = 2
            nodeLabel.layer.shadowOffset = CGSize(width: 0, height: 1)
            nodeLabel.sizeToFit()
            addSubview(nodeLabel)
            label = nodeLabel
        }
        return NodeLayers(node: node, container: container, label: label)
    }

    private func addUserMarker(to container: CALayer) {
        let pulseColor = scene.isProtected ? MapPalette.protectedTint : MapPalette.unprotectedTint

        for index in 0 ..< 2 {
            let pulse = CAShapeLayer()
            pulse.path = CGPath(ellipseIn: CGRect(x: -22, y: -22, width: 44, height: 44), transform: nil)
            pulse.fillColor = pulseColor.withAlphaComponent(0.32).cgColor
            pulse.opacity = 0

            let scaleAnimation = CABasicAnimation(keyPath: "transform.scale")
            scaleAnimation.fromValue = 0.25
            scaleAnimation.toValue = 1.9

            let fadeAnimation = CABasicAnimation(keyPath: "opacity")
            fadeAnimation.fromValue = 0.9
            fadeAnimation.toValue = 0

            let group = CAAnimationGroup()
            group.animations = [scaleAnimation, fadeAnimation]
            group.duration = 2.6
            group.repeatCount = .infinity
            group.beginTime = CACurrentMediaTime() + Double(index) * 1.3
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            pulse.add(group, forKey: "pulse")
            container.addSublayer(pulse)
        }

        let halo = CAShapeLayer()
        halo.path = CGPath(ellipseIn: CGRect(x: -10, y: -10, width: 20, height: 20), transform: nil)
        halo.fillColor = pulseColor.withAlphaComponent(0.35).cgColor
        container.addSublayer(halo)

        let core = CAShapeLayer()
        core.path = CGPath(ellipseIn: CGRect(x: -5, y: -5, width: 10, height: 10), transform: nil)
        core.fillColor = UIColor.white.cgColor
        core.shadowColor = pulseColor.cgColor
        core.shadowOpacity = 0.9
        core.shadowRadius = 5
        core.shadowOffset = .zero
        container.addSublayer(core)
    }

    private func addEndpointMarker(to container: CALayer, emphasis: MapScene.Emphasis) {
        let ring = CAShapeLayer()
        ring.path = CGPath(ellipseIn: CGRect(x: -9, y: -9, width: 18, height: 18), transform: nil)
        ring.fillColor = nil
        ring.lineWidth = 1.5

        let core = CAShapeLayer()
        core.path = CGPath(ellipseIn: CGRect(x: -4.5, y: -4.5, width: 9, height: 9), transform: nil)

        switch emphasis {
        case .active:
            let halo = CAShapeLayer()
            halo.path = CGPath(ellipseIn: CGRect(x: -16, y: -16, width: 32, height: 32), transform: nil)
            halo.fillColor = MapPalette.accent.withAlphaComponent(0.18).cgColor
            container.addSublayer(halo)
            ring.strokeColor = MapPalette.accent.withAlphaComponent(0.9).cgColor
            core.fillColor = MapPalette.accent.cgColor
            core.shadowColor = MapPalette.accent.cgColor
            core.shadowOpacity = 0.9
            core.shadowRadius = 6
            core.shadowOffset = .zero
        case .hotSpare:
            ring.strokeColor = MapPalette.hotSpare.withAlphaComponent(0.85).cgColor
            ring.lineDashPattern = [3, 3]
            ring.add(opacityPulseAnimation(from: 0.45, to: 1, duration: 1.4), forKey: "sparePulse")
            core.fillColor = MapPalette.hotSpare.cgColor
        case .standby:
            ring.strokeColor = UIColor(white: 1, alpha: 0.25).cgColor
            core.fillColor = UIColor(white: 0.9, alpha: 0.8).cgColor
        case .dimmed:
            ring.strokeColor = UIColor(white: 1, alpha: 0.12).cgColor
            core.fillColor = UIColor(white: 0.9, alpha: 0.4).cgColor
        }

        container.addSublayer(ring)
        container.addSublayer(core)
    }

    // MARK: - Animations

    private func dashPhaseAnimation(distance: CGFloat, duration: CFTimeInterval) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: "lineDashPhase")
        animation.fromValue = 0
        animation.toValue = distance
        animation.duration = duration
        animation.repeatCount = .infinity
        return animation
    }

    private func opacityPulseAnimation(from: CGFloat, to: CGFloat, duration: CFTimeInterval) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        return animation
    }
}
