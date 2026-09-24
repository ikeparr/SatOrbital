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
