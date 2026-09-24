import RealityKit
import SwiftUI

struct GlobeView: UIViewRepresentable {
    let frames: [SatelliteTarget: TrackingFrame]
    let selected: SatelliteTarget?
    let isActive: Bool
    let showsOrbit: Bool
    let resetID: Int
    let cameraCommand: CameraCommand
    let onFailure: (String) -> Void

    struct CameraCommand: Equatable {
        var id = 0
        var yaw: Float = 0
        var pitch: Float = 0
        var zoom: Float = 1
    }

    func makeCoordinator() -> GlobeScene { GlobeScene() }

    func makeUIView(context: Context) -> UIView {
        let surface = UIView()
        let view = ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        // Route gestures through a plain UIView so RealityKit's internal input
        // handling cannot compete with our camera controls.
        view.isUserInteractionEnabled = false
        surface.isMultipleTouchEnabled = true
        surface.addSubview(view)
        surface.accessibilityLabel = "Interactive Earth and the selected satellite"
        surface.accessibilityHint = "Drag to rotate. Pinch to zoom. View controls also provide accessible buttons."
        context.coordinator.install(in: view, interactionView: surface, onFailure: onFailure)
        return surface
    }

    func updateUIView(_ view: UIView, context: Context) {
        view.accessibilityLabel = selected == nil ? "Interactive Earth and all satellites" : "Interactive Earth and the selected satellite"
        let scene = context.coordinator
        scene.setFrames(frames, selected: selected)
        scene.orbitEntity.isEnabled = showsOrbit && !frames.isEmpty
        scene.setActive(isActive)
        if scene.lastResetID != resetID {
            scene.lastResetID = resetID
            scene.reset()
        }
        if scene.lastCameraCommandID != cameraCommand.id {
            scene.lastCameraCommandID = cameraCommand.id
            scene.adjustCamera(yaw: cameraCommand.yaw, pitch: cameraCommand.pitch, zoom: cameraCommand.zoom)
        }
    }

    static func dismantleUIView(_ view: UIView, coordinator: GlobeScene) {
        coordinator.stop()
    }
}
