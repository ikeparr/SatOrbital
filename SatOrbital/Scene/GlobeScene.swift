import Combine
import RealityKit
import UIKit

@MainActor
final class GlobeScene: NSObject {
    private var frame: TrackingFrame?
    private var lastPath: [SIMD3<Float>]?
    private var hasFocused = false
    private var onFailure: ((String) -> Void)?
    var lastResetID = 0
    var lastCameraCommandID = 0
    let orbitEntity = Entity()

    private weak var view: ARView?
    private let root = AnchorEntity(world: .zero)
    private let earth = Entity()
    private let satellite = Entity()
    private let camera = PerspectiveCamera()
    private var subscription: Cancellable?
    private var yaw: Float = 0.25
    private var pitch: Float = 0.28
    private var distance: Float = 3.65
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
        root.addChild(satellite)

        do {
            try buildEarth()
        } catch {
            // A fallback keeps camera controls usable, while the UI explains the failure.
            earth.addChild(ModelEntity(mesh: .generateSphere(radius: 1), materials: [
                SimpleMaterial(color: .systemTeal, roughness: 0.9, isMetallic: false)
            ]))
            DispatchQueue.main.async { onFailure("The Earth texture could not load. Showing a simplified globe.") }
        }
        buildSatellite()
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

    func setFrame(_ frame: TrackingFrame?) {
        self.frame = frame
        satellite.isEnabled = frame != nil
        guard let frame else {
            for child in Array(orbitEntity.children) { child.removeFromParent() }
            lastPath = nil
            return
        }
        if lastPath != frame.path {
            do {
                let material = UnlitMaterial(color: UIColor(red: 0.32, green: 0.77, blue: 0.69, alpha: 1))
                let model = ModelEntity(mesh: try SceneGeometry.orbitTube(points: frame.path), materials: [material])
                for child in Array(orbitEntity.children) { child.removeFromParent() }
                orbitEntity.addChild(model)
                lastPath = frame.path
            } catch {
                for child in Array(orbitEntity.children) { child.removeFromParent() }
                DispatchQueue.main.async { [weak self] in self?.onFailure?("The orbit line could not be drawn.") }
            }
        }
        updateBodies()
        if !hasFocused { hasFocused = true; focusSatellite() }
    }

    private func buildSatellite() {
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
        guard let frame else { satellite.isEnabled = false; return }
        let position = frame.position(at: Date())
        satellite.position = position
        satellite.orientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: normalize(position))
        // Earth, the marker, and the instantaneous orbit share the Earth-fixed frame.
        // Do not apply the demo's extra Earth rotation here.
    }

    private func focusSatellite() {
        guard let frame else { resetView(); return }
        let direction = normalize(frame.position(at: Date()))
        yaw = atan2(direction.x, direction.z)
        pitch = min(max(asin(direction.y), -1.35), 1.35)
        distance = 3.65
        updateCamera()
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

    func adjustCamera(yaw deltaYaw: Float = 0, pitch deltaPitch: Float = 0, zoom: Float = 1) {
        yaw += deltaYaw
        pitch = min(max(pitch + deltaPitch, -1.35), 1.35)
        distance = min(max(distance * zoom, 1.65), 6.0)
        updateCamera()
    }

    private func updateCamera() {
        let position = SIMD3<Float>(
            sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch)
        ) * distance
        camera.look(at: .zero, from: position, relativeTo: nil)
    }

    @objc private func resetView() {
        yaw = 0.25
        pitch = 0.28
        distance = 3.65
        updateCamera()
    }

    func reset() {
        focusSatellite()
        updateBodies()
    }
}
