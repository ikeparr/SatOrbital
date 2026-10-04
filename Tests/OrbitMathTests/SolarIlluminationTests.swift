import Foundation
import XCTest
@testable import OrbitMath

final class SolarIlluminationTests: XCTestCase {
    private func direction(_ utc: String) -> SIMD3<Float> {
        SolarIllumination.sceneDirection(at: ISO8601DateFormatter().date(from: utc)!)
    }

    func testSeasonsAndLeapYear() {
        let cases: [(String, Double)] = [
            ("2026-03-20T12:00:00Z", 0),
            ("2026-06-21T12:00:00Z", 23.44),
            ("2026-09-23T12:00:00Z", 0),
            ("2026-12-21T12:00:00Z", -23.44),
            ("2024-06-21T12:00:00Z", 23.44)
        ]
        for (utc, latitude) in cases {
            let sun = direction(utc)
            XCTAssertEqual(sqrt(sun.x * sun.x + sun.y * sun.y + sun.z * sun.z), 1, accuracy: 0.00001)
            XCTAssertEqual(asin(Double(sun.y)) * 180 / .pi, latitude, accuracy: 1)
            // UTC noon puts the Sun near Greenwich; scene +Z is ECEF +X.
            XCTAssertGreaterThan(sun.z, 0.9)
            XCTAssertLessThan(abs(sun.x), 0.08)
        }
    }

    func testDailyRotationAndDateLineContinuity() {
        XCTAssertGreaterThan(direction("2026-03-20T06:00:00Z").x, 0.99)
        XCTAssertLessThan(direction("2026-03-20T18:00:00Z").x, -0.99)
        XCTAssertLessThan(direction("2026-03-20T00:00:00Z").z, -0.99)
        let before = direction("2026-12-31T23:59:59Z")
        let after = direction("2027-01-01T00:00:00Z")
        let delta = before - after
        XCTAssertLessThan(sqrt(delta.x * delta.x + delta.y * delta.y + delta.z * delta.z), 0.005)
    }
}
