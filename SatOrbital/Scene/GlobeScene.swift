import Combine
import RealityKit
import UIKit

@MainActor
final class GlobeScene: NSObject {
    private var frames: [SatelliteTarget: TrackingFrame] = [:]
    private var selected: SatelliteTarget?
    private var lastPaths: [SatelliteTarget: [SIMD3<Float>]] = [:]
    private var satellites: [SatelliteTarget: Entity] = [:]
    private var orbitModels: [SatelliteTarget: Entity] = [:]
    private var hasFocused = false
    private var onFailure: ((String) -> Void)?
    var lastResetID = 0
    var lastCameraCommandID = 0
    let orbitEntity = Entity()

    private weak var view: ARView?
    private let root = AnchorEntity(world: .zero)
    private let earth = Entity()
    private let camera = PerspectiveCamera()
    private var subscription: Cancellable?
    private var pose = GlobeCameraPose.overview
    private var flightOrigin: GlobeCameraPose?
    private var flightTarget = GlobeCameraPose.overview
    private var flightElapsed: TimeInterval = 0
    private var followsSatellite = false
    private var reducedMotion = false
    var onSelect: ((SatelliteTarget) -> Void)?
    var onManualControl: (() -> Void)?
    private var isActive = true

    func install(in view: ARView, interactionView: UIView, onFailure: @escaping (String) -> Void) {
        self.view = view
        self.onFailure = onFailure
        view.environment.background = .color(UIColor(red: 0.018, green: 0.030, blue: 0.055, alpha: 1))
        view.renderOptions = [.disableMotionBlur, .disableDepthOfField, .disableCameraGrain]
        view.scene.addAnchor(root)
        camera.camera.fieldOfViewInDegrees = 43
        root.addChild(camera)
        root.addChild(earth)
        root.addChild(orbitEntity)

        do {
            try buildEarth()
        } catch {
            // A fallback keeps camera controls usable, while the UI explains the failure.
            earth.addChild(ModelEntity(mesh: .generateSphere(radius: 1), materials: [
                SimpleMaterial(color: .systemTeal, roughness: 0.9, isMetallic: false)
            ]))
            DispatchQueue.main.async { onFailure("The Earth texture could not load. Showing a simplified globe.") }
        }
        for target in SatelliteTarget.allCases {
            let satellite = Entity()
            buildSatellite(satellite)
            root.addChild(satellite)
            satellites[target] = satellite
        }
        buildLights()
        buildStars()
        updateCamera()
        updateBodies()

        let pan = UIPanGestureRecognizer(target: self, action: #selector(pan(_:)))
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinch(_:)))
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(resetView))
        doubleTap.numberOfTapsRequired = 2
        interactionView.addGestureRecognizer(pan)
        interactionView.addGestureRecognizer(pinch)
        interactionView.addGestureRecognizer(doubleTap)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapSatellite(_:)))
        tap.require(toFail: doubleTap)
        tap.require(toFail: pan)
        tap.require(toFail: pinch)
        interactionView.addGestureRecognizer(tap)
        subscribe()
    }

    private func buildEarth() throws {
        guard let url = Bundle.main.url(forResource: "Earth", withExtension: "jpg") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let texture = try TextureResource.load(contentsOf: url)
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(texture: .init(texture))
        material.roughness = .init(floatLiteral: 0.95)
        material.emissiveColor = .init(texture: .init(texture))
        material.emissiveIntensity = 0.15
        earth.addChild(ModelEntity(mesh: try SceneGeometry.globe(), materials: [material]))
    }

    func setFrames(_ frames: [SatelliteTarget: TrackingFrame], selected: SatelliteTarget?) {
        let selectionChanged = self.selected != selected
        if selectionChanged {
            self.selected = selected
            hasFocused = false
        }
        self.frames = frames
        for target in SatelliteTarget.allCases {
            satellites[target]?.isEnabled = frames[target] != nil
            satellites[target]?.scale = SIMD3(repeating: selected == target ? 1.2 : 1)
            guard let frame = frames[target] else {
                orbitModels.removeValue(forKey: target)?.removeFromParent()
                lastPaths[target] = nil
                continue
            }
            if selectionChanged || lastPaths[target] != frame.path {
                do {
                    let material = UnlitMaterial(color: selected == target ? UIColor(red: 1, green: 0.72, blue: 0.38, alpha: 1) : UIColor(red: 0.32, green: 0.77, blue: 0.69, alpha: 1))
                    let model = ModelEntity(mesh: try SceneGeometry.orbitTube(points: frame.path), materials: [material])
                    orbitModels[target]?.removeFromParent()
                    orbitEntity.addChild(model)
                    orbitModels[target] = model
                    lastPaths[target] = frame.path
                } catch {
                    orbitModels.removeValue(forKey: target)?.removeFromParent()
                    lastPaths[target] = nil
                    DispatchQueue.main.async { [weak self] in self?.onFailure?("An orbit line could not be drawn.") }
                }
            }
        }
        updateBodies()
        if !hasFocused, selected == nil || selected.flatMap({ frames[$0] }) != nil {
            hasFocused = true
            focusSatellite()
        }
    }

    private func buildSatellite(_ satellite: Entity) {
        let white = UnlitMaterial(color: UIColor(red: 0.96, green: 0.98, blue: 1, alpha: 1))
        let panel = UnlitMaterial(color: UIColor(red: 0.23, green: 0.63, blue: 0.80, alpha: 1))
        let body = ModelEntity(mesh: .generateBox(size: [0.018, 0.025, 0.034], cornerRadius: 0.003), materials: [white])
        satellite.addChild(body)
        for x: Float in [-0.037, 0.037] {
            let wing = ModelEntity(mesh: .generateBox(size: [0.047, 0.003, 0.028]), materials: [panel])
            wing.position.x = x
            satellite.addChild(wing)
        }
        let beacon = ModelEntity(mesh: .generateSphere(radius: 0.010), materials: [
            UnlitMaterial(color: UIColor(red: 1, green: 0.68, blue: 0.32, alpha: 1))
        ])
        beacon.position.y = 0.02
        satellite.addChild(beacon)
    }

    private func buildLights() {
        let key = DirectionalLight()
        key.light.intensity = 2_600
        key.light.color = UIColor(red: 0.87, green: 0.94, blue: 1, alpha: 1)
        key.look(at: .zero, from: [-3, 2, 4], relativeTo: nil)
        root.addChild(key)
        let fill = DirectionalLight()
        fill.light.intensity = 280
        fill.light.color = .systemTeal
        fill.look(at: .zero, from: [3, -1, -2], relativeTo: nil)
        root.addChild(fill)
    }

    private func buildStars() {
        let mesh = MeshResource.generateSphere(radius: 0.017)
        // Fixed deterministic placement keeps the initial scene and screenshots repeatable.
        for index in 0..<190 {
            let y = 1 - 2 * Float(index + 1) / 191
            let angle = Float(index) * 2.3999632
            let radius = sqrt(1 - y * y)
            let brightness = CGFloat(0.24 + Double(index % 5) * 0.10)
            let star = ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: UIColor(white: brightness, alpha: 1))])
            star.position = SIMD3(cos(angle) * radius, y, sin(angle) * radius) * 18
            if index % 9 == 0 { star.scale = .init(repeating: 1.8) }
            root.addChild(star)
        }
    }

    private func subscribe() {
        guard subscription == nil, let view else { return }
        subscription = view.scene.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            // RealityKit delivers scene updates on the main thread for this ARView.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.updateBodies()
                self.advanceCamera(by: event.deltaTime)
            }
        }
    }

    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active { subscribe() } else { subscription?.cancel(); subscription = nil }
    }

    func stop() {
        subscription?.cancel()
        subscription = nil
        view?.scene.removeAnchor(root)
    }

    private func updateBodies() {
        let date = Date()
        for (target, satellite) in satellites {
            guard let frame = frames[target] else { satellite.isEnabled = false; continue }
            let position = frame.position(at: date)
            satellite.position = position
            satellite.orientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: normalize(position))
        }
    }

    func setInteraction(following: Bool, reducedMotion: Bool) {
        let beganFollowing = following && !followsSatellite
        followsSatellite = following && !reducedMotion
        self.reducedMotion = reducedMotion
        if reducedMotion, flightOrigin != nil {
            pose = flightTarget
            flightOrigin = nil
            updateCamera()
        }
        if beganFollowing && followsSatellite { focusSatellite() }
    }

    private func startFlight(to target: GlobeCameraPose) {
        flightTarget = target
        flightElapsed = 0
        if reducedMotion {
            pose = target
            flightOrigin = nil
            updateCamera()
        } else { flightOrigin = pose }
    }

    private func advanceCamera(by seconds: TimeInterval) {
        if let origin = flightOrigin {
            if let selected, let frame = frames[selected] {
                flightTarget = .focused(on: frame.position(at: Date()), distance: flightTarget.distance)
            }
            flightElapsed += min(max(seconds, 0), 0.1)
            pose = origin.interpolated(to: flightTarget, fraction: Float(flightElapsed / 0.85))
            if flightElapsed >= 0.85 { flightOrigin = nil }
            updateCamera()
        } else if followsSatellite, let selected, let frame = frames[selected] {
            pose = .focused(on: frame.position(at: Date()), distance: pose.distance)
            updateCamera()
        }
    }

    private func focusSatellite() {
        guard let selected, let frame = frames[selected] else {
            startFlight(to: .overview)
            return
        }
        startFlight(to: .focused(on: frame.position(at: Date())))
    }

    @objc private func tapSatellite(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, let view else { return }
        let location = gesture.location(in: view)
        let candidates = SatelliteTarget.allCases.compactMap { target -> SatellitePickCandidate? in
            guard let satellite = satellites[target], satellite.isEnabled,
                  GlobePicking.isVisible(position: satellite.position, camera: pose.position),
                  simd_dot(satellite.position - pose.position, -pose.position) > 0,
                  let point = view.project(satellite.position), view.bounds.contains(point) else { return nil }
            return SatellitePickCandidate(target: target, point: SIMD2(Float(point.x), Float(point.y)),
                                          cameraDistance: simd_distance(satellite.position, pose.position))
        }
        if let target = GlobePicking.nearest(to: SIMD2(Float(location.x), Float(location.y)), candidates: candidates) {
            onSelect?(target)
        }
    }

    @objc private func pan(_ gesture: UIPanGestureRecognizer) {
        let delta = gesture.translation(in: view)
        adjustCamera(yaw: -Float(delta.x) * 0.006, pitch: Float(delta.y) * 0.006)
        gesture.setTranslation(.zero, in: view)
    }

    @objc private func pinch(_ gesture: UIPinchGestureRecognizer) {
        adjustCamera(zoom: 1 / Float(gesture.scale))
        gesture.scale = 1
    }

    func adjustCamera(yaw deltaYaw: Float = 0, pitch deltaPitch: Float = 0, zoom: Float = 1, notifyManualInteraction: Bool = true) {
        flightOrigin = nil
        followsSatellite = false
        if notifyManualInteraction { onManualControl?() }
        pose.yaw += deltaYaw
        pose.pitch = min(max(pose.pitch + deltaPitch, -1.55), 1.55)
        pose.distance = min(max(pose.distance * zoom, 1.65), 6.0)
        updateCamera()
    }

    private func updateCamera() {
        camera.look(at: .zero, from: pose.position, relativeTo: nil)
    }

    @objc private func resetView() {
        focusSatellite()
    }

    func reset() {
        focusSatellite()
        updateBodies()
    }
}
