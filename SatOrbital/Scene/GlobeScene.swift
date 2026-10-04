import Combine
import RealityKit
import UIKit
import ImageIO

@MainActor
final class GlobeScene: NSObject {
    private var frames: [SatelliteTarget: TrackingFrame] = [:]
    private var selected: SatelliteTarget?
    private let footprintEntity = Entity()
    private var lastShowsFootprint: Bool?
    private var lastFootprintPosition: SIMD3<Double>?
    private var overviewOrbit: Entity?
    private var overviewPathDates: [SatelliteTarget: Date] = [:]
    private var overviewBuild: Task<Void, Never>?
    private var overviewRevision = 0
    private var lastPaths: [SatelliteTarget: [SIMD3<Float>]] = [:]
    private var satellites: [SatelliteTarget: Entity] = [:]
    private var orbitModels: [SatelliteTarget: Entity] = [:]
    // Initial data loading must preserve the unselected overview camera.
    private var hasFocused = true
    private var onFailure: ((String) -> Void)?
    var lastResetID = 0
    var lastCameraCommandID = 0
    let orbitEntity = Entity()

    private weak var view: ARView?
    private let root = AnchorEntity(world: .zero)
    private let earth = Entity()
    private let earthGrid = Entity()
    private var nightSurface: ModelEntity?
    private var lastSunMinute: Int?
    private var earthSurface: ModelEntity?
    private var earthTexture: TextureResource?
    private var blueprintTexture: TextureResource?
    private var currentGlobeStyle: GlobeStyle?
    private let sun = DirectionalLight()
    private let nightFill = DirectionalLight()
    private var markerMaterial: UnlitMaterial?
    private var bodyElapsed: TimeInterval = 0
    private var animatesBodies = false
    private let camera = PerspectiveCamera()
    private var subscription: Cancellable?
    private var referenceDate: Date?
    private var viewMode = OrbitViewMode.earthFixed
    private var orbitShell = OrbitShell.all
    private var pendingShellFocus = false
    private var displayDate = Date()
    private var animationDate = Date()
    private var playbackRate: Double = 1
    private var isPlaying = true
    private var pose = GlobeCameraPose.overview
    private var selectionReturnPose: GlobeCameraPose?
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
        // Keep RealityKit’s default environment light from washing out the night side.
        view.environment.lighting.intensityExponent = -3
        view.renderOptions = [.disableMotionBlur, .disableDepthOfField, .disableCameraGrain]
        view.scene.addAnchor(root)
        camera.camera.fieldOfViewInDegrees = 43
        root.addChild(camera)
        root.addChild(earth)
        root.addChild(orbitEntity)
        root.addChild(footprintEntity)

        do {
            try buildEarth()
        } catch {
            // A fallback keeps camera controls usable, while the UI explains the failure.
            earth.addChild(ModelEntity(mesh: .generateSphere(radius: 1), materials: [
                SimpleMaterial(color: .systemTeal, roughness: 0.9, isMetallic: false)
            ]))
            DispatchQueue.main.async { onFailure("The Earth texture could not load. Showing a simplified globe.") }
        }
        makeMarkerMaterial()
        let prototypes = Dictionary(uniqueKeysWithValues: SatelliteKind.allCases.map { kind in
            let model = Entity()
            buildSatellite(model, kind: kind)
            return (kind, model)
        })
        for target in SatelliteTarget.allCases {
            let satellite = prototypes[target.kind]!.clone(recursive: true)
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

    func setView(mode: OrbitViewMode, shell: OrbitShell, at date: Date,
                 animationDate: Date, rate: Double, playing: Bool) {
        if referenceDate == nil { referenceDate = date }
        let modeChanged = mode != viewMode
        if modeChanged {
            let oldAngle = earthRotation(at: sceneDate())
            viewMode = mode
            let delta = earthRotation(at: sceneDate()) - oldAngle
            // Preserve the region currently in view when switching coordinate modes.
            pose.yaw += delta
            flightTarget.yaw += delta
            flightOrigin?.yaw += delta
            selectionReturnPose?.yaw += delta
            updateCamera()
        }
        if shell != orbitShell {
            orbitShell = shell
            pendingShellFocus = true
            overviewPathDates.removeAll()
        }
        displayDate = date
        self.animationDate = animationDate
        playbackRate = rate
        isPlaying = playing
        updateReferenceFrames()
        if modeChanged { updateBodies() }
    }

    func finishViewUpdate() {
        guard pendingShellFocus else { return }
        pendingShellFocus = false
        hasFocused = true
        startFlight(to: GlobeCameraPose(yaw: pose.yaw, pitch: pose.pitch, distance: orbitShell.cameraDistance))
    }

    private func sceneDate(at wallDate: Date = Date()) -> Date {
        displayDate.addingTimeInterval(isPlaying ? min(max(wallDate.timeIntervalSince(animationDate), 0), 1) * playbackRate : 0)
    }

    private func earthRotation(at date: Date) -> Float {
        OrbitViewCoordinates.earthAngle(mode: viewMode, at: date, reference: referenceDate ?? date)
    }

    private func updateReferenceFrames() {
        let date = sceneDate()
        earth.orientation = simd_quatf(angle: earthRotation(at: date), axis: [0, 1, 0])
        footprintEntity.orientation = earth.orientation
        orbitEntity.orientation = simd_quatf(angle: OrbitViewCoordinates.orbitAngle(mode: viewMode, at: date,
                                                  reference: referenceDate ?? date), axis: [0, 1, 0])
    }

    private func spacePath(_ frame: TrackingFrame) -> [SIMD3<Float>] {
        let angle = OrbitViewCoordinates.angle(at: frame.pathDate, reference: referenceDate ?? frame.pathDate)
        return frame.path.map { OrbitViewCoordinates.rotate($0, by: angle) }
    }

    private func worldPosition(_ frame: TrackingFrame, at wallDate: Date) -> SIMD3<Float> {
        let date = sceneDate(at: wallDate)
        let reference = referenceDate ?? date
        let position = frame.spacePosition(at: wallDate, reference: reference)
        return OrbitViewCoordinates.rotate(position, by: OrbitViewCoordinates.orbitAngle(mode: viewMode, at: date, reference: reference))
    }

    private func buildEarth() throws {
        guard let url = Bundle.main.url(forResource: "Earth", withExtension: "jpg") else {
            throw CocoaError(.fileNoSuchFile)
        }
        earthTexture = try TextureResource.generate(from: earthMap(url: url), options: .init(semantic: .color))
        let surface = ModelEntity(mesh: try SceneGeometry.globe())
        earthSurface = surface
        earth.addChild(surface)
        let night = ModelEntity(mesh: surface.model!.mesh)
        night.scale = SIMD3(repeating: 1.0006)
        earth.addChild(night)
        nightSurface = night
        earth.addChild(earthGrid)
        setGlobeStyle(.natural)
    }

    func setGlobeStyle(_ style: GlobeStyle) {
        guard style != currentGlobeStyle, let surface = earthSurface, let texture = earthTexture else { return }
        switch style {
        case .natural:
            var material = PhysicallyBasedMaterial()
            material.baseColor = .init(texture: .init(texture))
            material.roughness = .init(floatLiteral: 0.95)
            material.emissiveColor = .init(texture: .init(texture))
            material.emissiveIntensity = 0.15
            surface.model?.materials = [material]
        case .atlas:
            var material = UnlitMaterial()
            material.color = .init(texture: .init(texture))
            surface.model?.materials = [material]
        case .blueprint:
            do {
                if blueprintTexture == nil { blueprintTexture = try makeBlueprintTexture() }
                var material = PhysicallyBasedMaterial()
                material.baseColor = .init(texture: .init(blueprintTexture!))
                material.roughness = .init(floatLiteral: 1)
                material.emissiveColor = .init(texture: .init(blueprintTexture!))
                material.emissiveIntensity = 0.12
                surface.model?.materials = [material]
            } catch {
                DispatchQueue.main.async { [weak self] in self?.onFailure?("The Blueprint map could not load.") }
                return
            }
        }
        if style != .natural, earthGrid.children.isEmpty {
            do {
                for mesh in try SceneGeometry.graticule() {
                    earthGrid.addChild(ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: .white)]))
                }
            } catch {
                DispatchQueue.main.async { [weak self] in self?.onFailure?("The globe coordinate grid could not be drawn.") }
            }
        }
        let gridColor = style == .atlas ? UIColor(white: 0.8, alpha: 1) : UIColor(red: 0.25, green: 0.48, blue: 0.65, alpha: 1)
        for case let model as ModelEntity in earthGrid.children {
            model.model?.materials = [UnlitMaterial(color: gridColor)]
        }
        earthGrid.isEnabled = style != .natural
        nightSurface?.isEnabled = style != .atlas
        currentGlobeStyle = style
    }

    private func earthMap(url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 2048,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw CocoaError(.fileReadCorruptFile) }
        return image
    }

    /// Apply a two-color map palette to the bundled cloud-free Earth imagery.
    /// This is a visual land/water approximation, not a geographic boundary dataset.
    /// Create it once on first use; retain the original UVs and coastline alignment.
    private func makeBlueprintTexture() throws -> TextureResource {
        guard let url = Bundle.main.url(forResource: "Earth", withExtension: "jpg"),
              let source = try? earthMap(url: url) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let width = 2048, height = 1024
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                                          CGBitmapInfo.byteOrder32Big.rawValue),
              let data = context.data else { throw CocoaError(.fileReadCorruptFile) }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var landMask = [Float](repeating: 0, count: width * height)
        for pixel in landMask.indices {
            let index = pixel * 4
            let red = Float(pixels[index]) / 255
            let green = Float(pixels[index + 1]) / 255
            let blue = Float(pixels[index + 2]) / 255
            let edge = min(max((max(red, green) - 0.8 * blue - 0.018) / 0.027, 0), 1)
            landMask[pixel] = edge * edge * (3 - 2 * edge)
        }
        for y in 0..<height {
            for x in 0..<width {
                let pixel = y * width + x
                let land = landMask[pixel]
                // Outline the land side of coastlines, wrapping at the date line.
                var water: Float = 0
                for offset in [-2, -1, 1, 2] {
                    water = max(water, 1 - landMask[y * width + (x + offset + width) % width])
                    water = max(water, 1 - landMask[min(max(y + offset, 0), height - 1) * width + x])
                }
                let coast = land * water
                let red: Float = 3 + 28 * land
                let green: Float = 10 + 51 * land
                let blue: Float = 22 + 65 * land
                let index = pixel * 4
                pixels[index] = UInt8(red + (132 - red) * coast)
                pixels[index + 1] = UInt8(green + (205 - green) * coast)
                pixels[index + 2] = UInt8(blue + (228 - blue) * coast)
                pixels[index + 3] = 255
            }
        }
        guard let image = context.makeImage() else { throw CocoaError(.fileReadCorruptFile) }
        return try TextureResource.generate(from: image, options: .init(semantic: .color))
    }

    func setFrames(_ frames: [SatelliteTarget: TrackingFrame], selected: SatelliteTarget?, showsFootprint: Bool) {
        if !pendingShellFocus, self.selected == selected, lastShowsFootprint == showsFootprint,
           self.frames.count == frames.count,
           frames.allSatisfy({ target, frame in
               self.frames[target]?.state.date == frame.state.date && self.frames[target]?.pathDate == frame.pathDate &&
               self.frames[target]?.state.earthFixedPosition == frame.state.earthFixedPosition &&
               self.frames[target]?.interpolates == frame.interpolates &&
               self.frames[target]?.nextPosition == frame.nextPosition &&
               self.frames[target]?.simulationStep == frame.simulationStep &&
               (!frame.interpolates || self.frames[target]?.animationDate == frame.animationDate)
           }) { return }
        lastShowsFootprint = showsFootprint
        let selectionChanged = self.selected != selected
        if selectionChanged {
            // Keep the original browsing view when switching between satellites.
            if self.selected == nil, selected != nil { selectionReturnPose = pose }
            self.selected = selected
            hasFocused = false
            if selected == nil, let returnPose = selectionReturnPose {
                selectionReturnPose = nil
                hasFocused = true
                startFlight(to: returnPose)
            }
            orbitModels.values.forEach { $0.removeFromParent() }
            orbitModels.removeAll(); lastPaths.removeAll()
            overviewRevision += 1; overviewBuild?.cancel(); overviewBuild = nil
            if selected != nil { overviewOrbit?.removeFromParent(); overviewOrbit = nil }
        }
        self.frames = frames
        animatesBodies = frames.values.contains(where: \.interpolates)
        let dates = frames.mapValues(\.pathDate)
        let updateOverviewOrbits = selectionChanged || dates != overviewPathDates
        for target in SatelliteTarget.allCases {
            satellites[target]?.isEnabled = frames[target] != nil
            guard let frame = frames[target] else {
                orbitModels.removeValue(forKey: target)?.removeFromParent()
                lastPaths[target] = nil
                continue
            }
            if selected == nil { continue }
            if selectionChanged || lastPaths[target] == nil ||
                lastPaths[target] != frame.path {
                do {
                    let material = orbitMaterial(for: target.kind, selected: selected == target)
                    let model = ModelEntity(mesh: try SceneGeometry.orbitTube(points: spacePath(frame)), materials: [material])
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
        if selected == nil, updateOverviewOrbits || overviewOrbit == nil && overviewBuild == nil {
            overviewPathDates = dates
            rebuildOverview()
        }
        updateFootprint(visible: showsFootprint)
        updateBodies()
        if !hasFocused, selected == nil || selected.flatMap({ frames[$0] }) != nil {
            hasFocused = true
            focusSatellite()
        }
    }

    private func rebuildOverview() {
        overviewRevision += 1
        let revision = overviewRevision
        overviewBuild?.cancel()
        guard !frames.isEmpty else {
            overviewOrbit?.removeFromParent(); overviewOrbit = nil; overviewBuild = nil
            return
        }
        // Cached overview paths already use sixty samples. Keep the existing mesh
        // visible until its replacement is ready; never block camera input on the math.
        let groups = SatelliteKind.allCases.map { kind in
            (kind, frames.filter { $0.key.kind == kind }.values.map { spacePath($0) })
        }.filter { !$0.1.isEmpty }
        let tubeRadius: Float = orbitShell == .higher ? 0.0044 : 0.0011
        overviewBuild = Task { [weak self] in
            let data = await Task.detached(priority: .utility) {
                groups.map { kind, lines in
                    (kind, SceneGeometry.orbitData(lines: lines, radius: tubeRadius, sides: 3))
                }
            }.value
            guard !Task.isCancelled, let self, self.selected == nil,
                  self.overviewRevision == revision else { return }
            do {
                // Batch by category: three transparent meshes, not hundreds.
                let overview = Entity()
                for (kind, geometry) in data {
                    let mesh = try SceneGeometry.makeOrbitMesh(geometry)
                    overview.addChild(ModelEntity(mesh: mesh, materials: [self.orbitMaterial(for: kind)]))
                }
                self.overviewOrbit?.removeFromParent()
                self.orbitEntity.addChild(overview); self.overviewOrbit = overview
            } catch { self.onFailure?("The overview orbit lines could not be drawn.") }
            self.overviewBuild = nil
        }
    }

    private func orbitMaterial(for kind: SatelliteKind, selected: Bool = false) -> UnlitMaterial {
        let color: UIColor
        let opacity: Float
        switch kind {
        case .satellite:
            color = UIColor(red: 0.43, green: 0.82, blue: 0.93, alpha: 1)
            opacity = 0.28
        case .station:
            color = UIColor(red: 1, green: 0.76, blue: 0.40, alpha: 1)
            opacity = 0.55
        case .starlink:
            color = UIColor(red: 0.75, green: 0.53, blue: 0.95, alpha: 1)
            opacity = 0.23
        }
        var material = UnlitMaterial(color: color)
        if !selected { material.blending = .transparent(opacity: .init(floatLiteral: opacity)) }
        return material
    }

    private func updateFootprint(visible: Bool) {
        guard visible, let selected, let frame = frames[selected] else {
            footprintEntity.isEnabled = false
            lastFootprintPosition = nil
            footprintEntity.children.forEach { $0.removeFromParent() }
            return
        }
        let position = frame.state.earthFixedPosition
        guard position != lastFootprintPosition else { return }
        footprintEntity.children.forEach { $0.removeFromParent() }
        do {
            let footprint = try VisibilityFootprint.make(satellite: position)
            let color = UIColor(red: 1, green: 0.72, blue: 0.38, alpha: 1)
            var fill = UnlitMaterial(color: color)
            fill.blending = .transparent(opacity: .init(floatLiteral: 0.16))
            footprintEntity.addChild(ModelEntity(mesh: try SceneGeometry.footprint(footprint), materials: [fill]))
            let boundary = footprint.boundary.map { EarthCoordinates.scenePosition($0 * 1.0015) }
            footprintEntity.addChild(ModelEntity(mesh: try SceneGeometry.orbitTube(points: boundary),
                                                 materials: [UnlitMaterial(color: color)]))
            footprintEntity.isEnabled = true
            lastFootprintPosition = position
        } catch {
            footprintEntity.isEnabled = false
            lastFootprintPosition = nil
            DispatchQueue.main.async { [weak self] in self?.onFailure?("The visibility footprint could not be drawn.") }
        }
    }

    private func makeMarkerMaterial() {
        let colors: [UInt8] = [245, 250, 255, 255, 59, 161, 235, 255, 250, 173, 64, 255, 184, 133, 255, 255]
        guard let provider = CGDataProvider(data: Data(colors) as CFData),
              let image = CGImage(width: 4, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: 16, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let texture = try? TextureResource.generate(from: image, options: .init(semantic: .color)) else { return }
        var material = UnlitMaterial()
        material.color = .init(texture: .init(texture)); markerMaterial = material
    }

    private func buildSatellite(_ satellite: Entity, kind: SatelliteKind) {
        var boxes: [SceneGeometry.MarkerBox] = []
        func box(_ size: SIMD3<Float>, at center: SIMD3<Float> = .zero, palette: Int = 0) {
            boxes.append(.init(size: size, center: center, palette: palette))
        }
        switch kind {
        case .satellite:
            box([0.025, 0.022, 0.032])
            for x: Float in [-0.038, 0.038] { box([0.045, 0.003, 0.032], at: [x, 0, 0], palette: 1) }
            box([0.004, 0.018, 0.004], at: [0, 0.02, 0])
        case .station:
            box([0.018, 0.016, 0.09]); box([0.115, 0.007, 0.009]); box([0.028, 0.018, 0.024])
            for x: Float in [-0.055, 0.055] { for z: Float in [-0.032, 0.032] {
                box([0.037, 0.003, 0.047], at: [x, 0, z], palette: 2)
            } }
        case .starlink:
            box([0.034, 0.008, 0.042])
            box([0.073, 0.002, 0.042], at: [0.054, 0, 0], palette: 3)
            box([0.026, 0.004, 0.018], at: [0, 0.006, 0], palette: 3)
        }
        do {
            satellite.addChild(ModelEntity(mesh: try SceneGeometry.marker(boxes: boxes),
                                          materials: [markerMaterial ?? UnlitMaterial(color: .white)]))
        } catch { onFailure?("A satellite model could not be drawn.") }
    }

    private func buildLights() {
        sun.light.intensity = 2_600
        sun.light.color = .white
        root.addChild(sun)
        nightFill.light.intensity = 35
        nightFill.light.color = UIColor(red: 0.55, green: 0.68, blue: 1, alpha: 1)
        root.addChild(nightFill)
        setSunlight(at: Date())
    }

    func setSunlight(at date: Date) {
        let direction = SolarIllumination.sceneDirection(at: date)
        let worldDirection = OrbitViewCoordinates.rotate(direction, by: earthRotation(at: date))
        sun.look(at: .zero, from: worldDirection * 4, relativeTo: nil)
        nightFill.look(at: .zero, from: -worldDirection * 4, relativeTo: nil)
        let minute = Int(date.timeIntervalSince1970 / 60)
        guard minute != lastSunMinute, let nightSurface else { return }
        do {
            var material = UnlitMaterial()
            material.color = .init(texture: .init(try nightTexture(sun: direction)))
            material.blending = .transparent(opacity: .init(floatLiteral: 1))
            nightSurface.model?.materials = [material]
            lastSunMinute = minute
        } catch {
            DispatchQueue.main.async { [weak self] in self?.onFailure?("The day/night shading could not be drawn.") }
        }
    }

    /// A soft darkness overlay makes the terminator readable even when the
    /// renderer supplies ambient lighting. It shares Earth's UVs and ellipsoid.
    private func nightTexture(sun: SIMD3<Float>) throws -> TextureResource {
        let width = 512, height = 256
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                                          CGBitmapInfo.byteOrder32Big.rawValue),
              let data = context.data else { throw CocoaError(.fileReadCorruptFile) }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        for y in 0..<height {
            let latitude = Float.pi / 2 - (Float(y) + 0.5) / Float(height) * .pi
            for x in 0..<width {
                let longitude = (Float(x) + 0.5) / Float(width) * 2 * .pi - .pi
                let normal = SIMD3(cos(latitude) * sin(longitude), sin(latitude),
                                   cos(latitude) * cos(longitude))
                let edge = min(max((0.025 - simd_dot(normal, sun)) / 0.15, 0), 1)
                let alpha = edge * edge * (3 - 2 * edge) * 0.72
                let index = (y * width + x) * 4
                pixels[index] = 0; pixels[index + 1] = 0; pixels[index + 2] = 0
                pixels[index + 3] = UInt8(alpha * 255)
            }
        }
        guard let image = context.makeImage() else { throw CocoaError(.fileReadCorruptFile) }
        return try TextureResource.generate(from: image, options: .init(semantic: .color))
    }

    private func buildStars() {
        // One static mesh replaces 190 individual sphere entities and draw calls.
        let boxes = (0..<190).map { index -> SceneGeometry.MarkerBox in
            let y = 1 - 2 * Float(index + 1) / 191
            let angle = Float(index) * 2.3999632
            let radius = sqrt(1 - y * y)
            let position = SIMD3(cos(angle) * radius, y, sin(angle) * radius) * 18
            let size: Float = index % 9 == 0 ? 0.045 : 0.02 + Float(index % 5) * 0.003
            return .init(size: SIMD3(repeating: size), center: position, palette: 0)
        }
        if let mesh = try? SceneGeometry.marker(boxes: boxes) {
            root.addChild(ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: UIColor(white: 0.5, alpha: 1))]))
        }
    }

    private func subscribe() {
        guard subscription == nil, let view else { return }
        subscription = view.scene.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            // RealityKit delivers scene updates on the main thread for this ARView.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.bodyElapsed += event.deltaTime
                if self.bodyElapsed >= 1.0 / 30 {
                    self.bodyElapsed = 0
                    if self.isPlaying { self.updateReferenceFrames() }
                    if self.animatesBodies { self.updateBodies() }
                }
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
        overviewRevision += 1; overviewBuild?.cancel(); overviewBuild = nil
        view?.scene.removeAnchor(root)
    }

    private func updateBodies() {
        let date = Date()
        for (target, frame) in frames {
            guard let satellite = satellites[target] else { continue }
            let position = worldPosition(frame, at: date)
            satellite.position = position
            updateMarkerScale(satellite, target: target)
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
                flightTarget = .focused(on: worldPosition(frame, at: Date()), distance: flightTarget.distance)
            }
            flightElapsed += min(max(seconds, 0), 0.1)
            pose = origin.interpolated(to: flightTarget, fraction: Float(flightElapsed / 0.85))
            if flightElapsed >= 0.85 { flightOrigin = nil }
            updateCamera()
        } else if followsSatellite, let selected, let frame = frames[selected] {
            pose = .focused(on: worldPosition(frame, at: Date()), distance: pose.distance)
            updateCamera()
        }
    }

    private func focusSatellite() {
        guard let selected, let frame = frames[selected] else {
            startFlight(to: GlobeCameraPose(yaw: GlobeCameraPose.overview.yaw, pitch: GlobeCameraPose.overview.pitch, distance: orbitShell.cameraDistance))
            return
        }
        startFlight(to: .focused(on: worldPosition(frame, at: Date())))
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
        pose.distance = min(max(pose.distance * zoom, 1.65), 32.0)
        updateCamera()
    }

    private func updateMarkerScale(_ satellite: Entity, target: SatelliteTarget) {
        // High orbits can cross the close overview camera. Bound apparent size
        // rather than letting an enlarged marker fill the entire screen.
        let scale = min(1, simd_distance(satellite.position, pose.position) / 2)
        let emphasis: Float = selected == target ? 1.2 : selected == nil && orbitShell == .higher ? 2.4 : 1
        satellite.scale = SIMD3(repeating: scale * emphasis)
    }

    private func updateCamera() {
        camera.look(at: .zero, from: pose.position, relativeTo: nil)
        for target in frames.keys {
            if let satellite = satellites[target] { updateMarkerScale(satellite, target: target) }
        }
    }

    @objc private func resetView() {
        focusSatellite()
    }

    func reset() {
        focusSatellite()
        updateBodies()
    }
}
