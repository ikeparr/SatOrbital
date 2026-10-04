import XCTest
import simd
@testable import OrbitMath

final class GlobeInteractionTests: XCTestCase {
    func testEarthOcclusionRejectsFarSideButAllowsPointsAboveLimb() {
        let camera = SIMD3<Float>(0, 0, 4.6)
        XCTAssertTrue(GlobePicking.isVisible(position: [0, 0, 1.07], camera: camera))
        XCTAssertFalse(GlobePicking.isVisible(position: [0, 0, -1.07], camera: camera))
        XCTAssertFalse(GlobePicking.isVisible(position: [0, 0, 0.9], camera: camera))
        XCTAssertTrue(GlobePicking.isVisible(position: [1.12, 0, 0], camera: camera))
        XCTAssertTrue(GlobePicking.isVisible(position: [0, 1.12, 0], camera: camera))
        XCTAssertFalse(GlobePicking.isVisible(position: camera, camera: camera))
    }

    func testPickingUsesTouchRadiusThenNearestMarkerAndStableTieBreak() {
        let candidates = [
            SatellitePickCandidate(target: .iss, point: [50, 50], cameraDistance: 3),
            SatellitePickCandidate(target: .hubble, point: [65, 50], cameraDistance: 2)
        ]
        XCTAssertEqual(GlobePicking.nearest(to: [48, 50], candidates: candidates), .iss)
        XCTAssertEqual(GlobePicking.nearest(to: [66, 50], candidates: candidates), .hubble)
        XCTAssertNil(GlobePicking.nearest(to: [200, 200], candidates: candidates))
        XCTAssertNil(GlobePicking.nearest(to: [0, 0], candidates: []))
        let overlapping = candidates.map { SatellitePickCandidate(target: $0.target, point: [50, 50], cameraDistance: $0.cameraDistance) }
        XCTAssertEqual(GlobePicking.nearest(to: [50, 50], candidates: overlapping), .hubble)
        XCTAssertEqual(GlobePicking.nearest(to: [50, 50], candidates: overlapping.reversed()), .hubble)
    }

    func testCameraTakesShortRouteAcrossDateLineAndStaysOutsideEarth() {
        let start = GlobeCameraPose(yaw: 179 * .pi / 180, pitch: 0.2, distance: 4.6)
        let end = GlobeCameraPose(yaw: -179 * .pi / 180, pitch: -0.4, distance: 2.55)
        let mid = start.interpolated(to: end, fraction: 0.5)
        XCTAssertEqual(mid.yaw, .pi, accuracy: 1e-5)
        XCTAssertEqual(mid.distance, 3.575, accuracy: 1e-5)
        XCTAssertEqual(start.interpolated(to: end, fraction: -1), start)
        XCTAssertLessThan(simd_distance(start.interpolated(to: end, fraction: 2).position, end.position), 1e-5)
        for i in 0...100 {
            let pose = start.interpolated(to: end, fraction: Float(i) / 100)
            XCTAssertTrue((2.54...4.61).contains(simd_length(pose.position)))
        }
    }

    func testFocusAndFollowKeepCameraOnSatelliteRadialDirection() {
        for p: SIMD3<Float> in [[1.05, 0, 0], [0.3, 0.8, -0.6], [-0.2, -0.9, 0.5]] {
            let pose = GlobeCameraPose.focused(on: p)
            XCTAssertEqual(simd_dot(simd_normalize(pose.position), simd_normalize(p)), 1, accuracy: 1e-6)
            XCTAssertEqual(pose.distance, 2.55)
        }
        for p: SIMD3<Float> in [[0, 1.07, 0], [0, -1.07, 0]] {
            let pose = GlobeCameraPose.focused(on: p)
            XCTAssertTrue(pose.position.x.isFinite && pose.position.y.isFinite && pose.position.z.isFinite)
        }
    }
}

 extension GlobeInteractionTests {
    func testFocusCameraStaysOutsideNavigationAndGeostationaryOrbits() {
        for radius: Float in [1.07, 4.2, 6.6] {
            let position = SIMD3<Float>(0, 0, radius)
            let pose = GlobeCameraPose.focused(on: position)
            XCTAssertGreaterThanOrEqual(pose.distance, radius + 1.45)
            XCTAssertEqual(pose.yaw, 0, accuracy: 0.0001)
            XCTAssertEqual(pose.pitch, 0, accuracy: 0.0001)
        }
        XCTAssertEqual(GlobeCameraPose.focused(on: SIMD3<Float>(0, 0, 1.07)).distance, 2.55, accuracy: 0.0001)
    }
}


extension GlobeInteractionTests {
    func testSpaceAndEarthFramesShareAlignedGeometryAndCorrectRotation() throws {
        let reference = try XCTUnwrap(UTCDate.parse("2026-10-02T00:00:00Z"))
        for seconds: Double in [0, 60, 3600, 43000, 86000, -86400] {
            let date = reference.addingTimeInterval(seconds)
            let p = SIMD3<Float>(0.4, 0.6, 0.8)
            let delta = OrbitViewCoordinates.angle(at: date, reference: reference)
            let inertial = OrbitViewCoordinates.rotate(p, by: delta)
            let earthWorld = OrbitViewCoordinates.rotate(inertial, by: OrbitViewCoordinates.orbitAngle(mode: .earthFixed, at: date, reference: reference))
            XCTAssertLessThan(simd_distance(earthWorld, p), 0.000001)
            let spaceWorld = OrbitViewCoordinates.rotate(p, by: OrbitViewCoordinates.earthAngle(mode: .spaceFixed, at: date, reference: reference))
            XCTAssertLessThan(simd_distance(spaceWorld, inertial), 0.000001)
            XCTAssertEqual(OrbitViewCoordinates.earthAngle(mode: .earthFixed, at: date, reference: reference), 0)
            XCTAssertEqual(OrbitViewCoordinates.orbitAngle(mode: .spaceFixed, at: date, reference: reference), 0)
        }
        let quarterDay = reference.addingTimeInterval(21541)
        let greenwich = OrbitViewCoordinates.rotate(SIMD3<Float>(0, 0, 1), by: OrbitViewCoordinates.angle(at: quarterDay, reference: reference))
        XCTAssertGreaterThan(greenwich.x, 0.99)
        let before = OrbitViewCoordinates.rotate([0, 0, 1], by: OrbitViewCoordinates.angle(at: reference.addingTimeInterval(43080), reference: reference))
        let after = OrbitViewCoordinates.rotate([0, 0, 1], by: OrbitViewCoordinates.angle(at: reference.addingTimeInterval(43082), reference: reference))
        XCTAssertLessThan(simd_distance(before, after), 0.0002)
    }

    func testLEOAndHigherShellsPartitionCatalogAndProvideWiderCamera() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "large-catalog", withExtension: "json", subdirectory: "Fixtures"))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let records = try decoder.decode([CachedOrbit].self, from: Data(contentsOf: url))
        XCTAssertEqual(records.count, 396)
        XCTAssertTrue(records.allSatisfy { OrbitShell.all.includes($0.elements) })
        XCTAssertTrue(records.allSatisfy { OrbitShell.low.includes($0.elements) != OrbitShell.higher.includes($0.elements) })
        XCTAssertTrue(OrbitShell.low.includes(try XCTUnwrap(records.first { $0.elements.catalogID == SatelliteTarget.iss.id }).elements))
        let navigation = records.filter { SatelliteTarget(rawValue: $0.elements.catalogID)?.filterCategory == .navigation }
        XCTAssertEqual(navigation.count, 36)
        XCTAssertTrue(navigation.allSatisfy { OrbitShell.higher.includes($0.elements) })
        XCTAssertGreaterThan(OrbitShell.higher.cameraDistance, OrbitShell.low.cameraDistance)
    }
}
