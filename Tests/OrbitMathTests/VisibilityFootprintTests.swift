import XCTest
import simd
@testable import OrbitMath

final class VisibilityFootprintTests: XCTestCase {
    private let a = EarthCoordinates.equatorialRadius
    private var axes: SIMD3<Double> { [a, a, a * (1 - EarthCoordinates.flattening)] }

    func testBoundaryIsOnEllipsoidAndAtZeroElevation() throws {
        // Equator, date line, north/south poles, and an oblique viewing direction.
        for direction in [SIMD3<Double>(1, 0, 0), [-1, 0, 0], [0, 0, 1], [0, 0, -1], [1, -2, 3]] {
            let satellite = simd_normalize(direction) * 6800
            let footprint = try VisibilityFootprint.make(satellite: satellite)
            XCTAssertEqual(footprint.boundary.first, footprint.boundary.last)
            for point in footprint.boundary {
                XCTAssertEqual(simd_length_squared(point / axes), 1, accuracy: 1e-12)
                let normal = simd_normalize(point / (axes * axes))
                let elevationSine = simd_dot(normal, simd_normalize(satellite - point))
                XCTAssertEqual(elevationSine, 0, accuracy: 1e-12)
            }
            for point in footprint.surfacePoints {
                XCTAssertEqual(simd_length_squared(point / axes), 1, accuracy: 1e-12)
                XCTAssertGreaterThanOrEqual(simd_dot(point / (axes * axes), satellite - point), -1e-12)
            }
            XCTAssertTrue(footprint.indices.allSatisfy { Int($0) < footprint.surfacePoints.count })
            for triangle in stride(from: 0, to: footprint.indices.count, by: 3) {
                let p = footprint.surfacePoints[Int(footprint.indices[triangle])]
                let q = footprint.surfacePoints[Int(footprint.indices[triangle + 1])]
                let r = footprint.surfacePoints[Int(footprint.indices[triangle + 2])]
                XCTAssertGreaterThan(simd_dot(simd_cross(q - p, r - p), p), 0)
            }
        }
    }

    func testEquatorialFootprintMatchesAnalyticHorizonAndGrowsWithAltitude() throws {
        var previousAngle = 0.0
        for altitude in [200.0, 420.0, 700.0, 35786.0] {
            let radius = a + altitude
            let footprint = try VisibilityFootprint.make(satellite: [radius, 0, 0])
            let point = try XCTUnwrap(footprint.boundary.first)
            let actualAngle = acos(point.x / a)
            XCTAssertEqual(actualAngle, acos(a / radius), accuracy: 1e-12)
            XCTAssertGreaterThan(actualAngle, previousAngle)
            previousAngle = actualAngle
        }
    }

    func testRejectsInvalidPositionsAndSampling() {
        for position in [SIMD3<Double>(0, 0, 0), [a, 0, 0], [.nan, 1, 1], [.infinity, 0, 0]] {
            XCTAssertThrowsError(try VisibilityFootprint.make(satellite: position))
        }
        XCTAssertThrowsError(try VisibilityFootprint.make(satellite: [6800, 0, 0], samples: 3))
        XCTAssertThrowsError(try VisibilityFootprint.make(satellite: [6800, 0, 0], rings: 0))
    }
}
