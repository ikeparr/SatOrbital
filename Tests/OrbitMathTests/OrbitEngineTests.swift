import XCTest
import simd
@testable import OrbitMath

final class OrbitEngineTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")))
    }

    func testPublishedValladoVectorsAcrossFourOrbitRegimes() throws {
        struct Vector: Decodable { let r: [Double]; let v: [Double]; let minutesSinceEpoch: Double }
        struct Case: Decodable { let elements: OrbitalElements; let states: [Vector] }
        let cases = try JSONDecoder().decode([Case].self, from: fixture("vallado"))
        var count = 0
        for item in cases {
            let engine = try OrbitEngine(elements: item.elements)
            // Reverse order deliberately checks that propagation has no shared mutable state.
            for reference in item.states.reversed() {
                let state = try engine.state(at: engine.epoch.addingTimeInterval(reference.minutesSinceEpoch * 60))
                for axis in 0..<3 {
                    XCTAssertEqual(state.temePosition[axis], reference.r[axis], accuracy: 0.0001, "ID \(item.elements.catalogID), t=\(reference.minutesSinceEpoch)")
                    XCTAssertEqual(state.temeVelocity[axis], reference.v[axis], accuracy: 0.0000001)
                }
                count += 1
            }
        }
        XCTAssertGreaterThan(count, 50)
    }

    func testISSAgainstIndependentPythonSGP4Reference() throws {
        struct Vector: Decodable { let utc: String; let r: [Double]; let v: [Double] }
        let elements = try OrbitalElements.decodeISS(fixture("iss-omm"))
        let engine = try OrbitEngine(elements: elements)
        let vectors = try JSONDecoder().decode([Vector].self, from: fixture("iss-reference"))
        for vector in vectors {
            let state = try engine.state(at: XCTUnwrap(UTCDate.parse(vector.utc)))
            for axis in 0..<3 {
                XCTAssertEqual(state.temePosition[axis], vector.r[axis], accuracy: 0.0001)
                XCTAssertEqual(state.temeVelocity[axis], vector.v[axis], accuracy: 0.0000001)
            }
            XCTAssertTrue((300...500).contains(state.altitudeKilometers))
            XCTAssertLessThan(abs(state.latitude), 53)
        }
    }

    func testJ2000SiderealTimeAndEarthFixedAxes() throws {
        let j2000 = try XCTUnwrap(UTCDate.parse("2000-01-01T12:00:00Z"))
        XCTAssertEqual(EarthCoordinates.siderealAngle(at: j2000) * 180 / .pi, 280.460618375, accuracy: 0.0000001)
        let angle = EarthCoordinates.siderealAngle(at: j2000)
        let fixed = EarthCoordinates.earthFixed([cos(angle) * 7000, sin(angle) * 7000, 0], at: j2000)
        XCTAssertEqual(fixed.x, 7000, accuracy: 1e-8)
        XCTAssertEqual(fixed.y, 0, accuracy: 1e-8)
        let location = EarthCoordinates.geodetic(fixed)
        XCTAssertEqual(location.longitude, 0, accuracy: 1e-8)
        XCTAssertEqual(location.latitude, 0, accuracy: 1e-8)
        XCTAssertEqual(location.altitude, 7000 - 6378.137, accuracy: 1e-8)
    }

    func testWGS84GeodeticRoundTripIncludingPolesAndDateline() {
        for (lat, lon, height) in [(0.0, 90.0, 420.0), (51.6, -179.99, 410), (-33.8, 151.2, 430), (90, 0, 420), (-90, 0, 420)] {
            let phi = lat * .pi / 180, lambda = lon * .pi / 180
            let e2 = EarthCoordinates.eccentricitySquared
            let n = EarthCoordinates.equatorialRadius / sqrt(1 - e2 * pow(sin(phi), 2))
            let fixed = SIMD3((n + height) * cos(phi) * cos(lambda), (n + height) * cos(phi) * sin(lambda), (n * (1 - e2) + height) * sin(phi))
            let result = EarthCoordinates.geodetic(fixed)
            XCTAssertEqual(result.latitude, lat, accuracy: 1e-7)
            XCTAssertEqual(result.longitude, lon, accuracy: 1e-7)
            XCTAssertEqual(result.altitude, height, accuracy: 1e-6)
        }
    }

    func testISSRingClosesOnMarkerInOneOrbitalPlaneAsTimeAdvances() throws {
        let engine = try OrbitEngine(elements: OrbitalElements.decodeISS(fixture("iss-omm")))
        for minutes in stride(from: 0.0, through: 100.0, by: 5) {
            let state = try engine.state(at: engine.epoch.addingTimeInterval(minutes * 60))
            let points = try state.orbitRing()
            XCTAssertEqual(points.count, 181)
            XCTAssertEqual(points.first, state.scenePosition)
            XCTAssertEqual(points.last, points.first)
            let normal = simd_normalize(simd_cross(state.temePosition, state.temeVelocity))
            let sceneNormal = simd_normalize(EarthCoordinates.scenePosition(EarthCoordinates.earthFixed(normal, at: state.date)))
            for point in points {
                XCTAssertEqual(simd_dot(point, sceneNormal), 0, accuracy: 2e-7)
                XCTAssertTrue((1.04...1.09).contains(simd_length(point)))
            }
            // The old open track had a ~23-degree gap. Every segment must now
            // be an ordinary two-degree step, including both sides of the seam.
            for index in 1..<points.count {
                XCTAssertLessThan(simd_distance(points[index - 1], points[index]), 0.04)
            }
            let next = try engine.state(at: state.date.addingTimeInterval(1))
            let frame = TrackingFrame(state: state, nextPosition: next.scenePosition,
                                      interpolates: true, path: points, pathDate: state.date)
            for fraction in [0.0, 0.5, 1.0] {
                let marker = frame.position(at: state.date.addingTimeInterval(fraction))
                let distance = zip(points, points.dropFirst()).map { start, end in
                    let delta = end - start
                    let t = min(max(simd_dot(marker - start, delta) / simd_length_squared(delta), 0), 1)
                    return simd_distance(marker, start + delta * t)
                }.min()!
                // Less than 1/10 of the rendered tube radius, including Earth
                // rotation and linear marker interpolation between one-second ticks.
                XCTAssertLessThan(distance, 0.00025)
            }
        }
    }

    func testRingPreservesCircularAndEccentricOrbitGeometry() throws {
        let mu = 398_600.8
        let date = try XCTUnwrap(UTCDate.parse("2026-09-23T15:30:06Z"))
        let perigee = 6800.0
        for eccentricity in [0.0, 0.25] {
            let speed = sqrt(mu * (1 + eccentricity) / perigee)
            let position = SIMD3<Double>(perigee, 0, 0)
            let fixed = EarthCoordinates.earthFixed(position, at: date)
            let state = OrbitalState(date: date, temePosition: position,
                                     temeVelocity: [0, speed, 0], earthFixedPosition: fixed,
                                     latitude: 0, longitude: 0, altitudeKilometers: 421.863)
            let points = try state.orbitRing(samples: 180)
            let radii = points.map { Double(simd_length($0)) * EarthCoordinates.equatorialRadius }
            XCTAssertEqual(try XCTUnwrap(radii.min()), perigee, accuracy: 0.002)
            XCTAssertEqual(try XCTUnwrap(radii.max()), perigee * (1 + eccentricity) / (1 - eccentricity), accuracy: 0.003)
            XCTAssertEqual(points.first, points.last)
            XCTAssertEqual(points.first, state.scenePosition)
        }
    }

    func testInvalidAndUnsupportedInputsAreRejected() throws {
        let data = try fixture("iss-omm")
        var records = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        for (key, badValue) in [("MEAN_MOTION", 0), ("ECCENTRICITY", 1), ("INCLINATION", 190), ("NORAD_CAT_ID", 123)] {
            var invalid = records
            invalid[0][key] = badValue
            XCTAssertThrowsError(try OrbitalElements.decodeISS(JSONSerialization.data(withJSONObject: invalid)))
        }
        records[0]["REF_FRAME"] = "GCRF"
        XCTAssertThrowsError(try OrbitalElements.decodeISS(JSONSerialization.data(withJSONObject: records)))
        XCTAssertThrowsError(try OrbitalElements.decodeISS(Data("<html>Error</html>".utf8)))
        XCTAssertThrowsError(try OrbitalElements.decodeISS(Data("[]".utf8)))
    }

    func testFreshnessUsesElementEpochRatherThanDownloadTime() {
        let epoch = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(OrbitFreshness.assess(epoch: epoch, at: epoch.addingTimeInterval(86_400)), .fresh)
        XCTAssertEqual(OrbitFreshness.assess(epoch: epoch, at: epoch.addingTimeInterval(3 * 86_400)), .stale)
        XCTAssertEqual(OrbitFreshness.assess(epoch: epoch, at: epoch.addingTimeInterval(8 * 86_400)), .expired)
    }

    func testFrameInterpolationClampsAndPauseFreezes() throws {
        let engine = try OrbitEngine(elements: OrbitalElements.decodeISS(fixture("iss-omm")))
        let state = try engine.state(at: engine.epoch)
        let next = state.scenePosition + SIMD3<Float>(1, 0, 0)
        let live = TrackingFrame(state: state, nextPosition: next, interpolates: true, path: [], pathDate: state.date)
        XCTAssertEqual(live.position(at: state.date.addingTimeInterval(-1)), state.scenePosition)
        XCTAssertEqual(live.position(at: state.date.addingTimeInterval(0.5)).x, state.scenePosition.x + 0.5, accuracy: 1e-6)
        XCTAssertEqual(live.position(at: state.date.addingTimeInterval(100)), next)
        let paused = TrackingFrame(state: state, nextPosition: next, interpolates: false, path: [], pathDate: state.date)
        XCTAssertEqual(paused.position(at: state.date.addingTimeInterval(100)), state.scenePosition)
        XCTAssertEqual(state.scenePosition.x, Float(state.earthFixedPosition.y / EarthCoordinates.equatorialRadius), accuracy: 1e-6)
        XCTAssertEqual(state.scenePosition.y, Float(state.earthFixedPosition.z / EarthCoordinates.equatorialRadius), accuracy: 1e-6)
        XCTAssertEqual(state.scenePosition.z, Float(state.earthFixedPosition.x / EarthCoordinates.equatorialRadius), accuracy: 1e-6)
    }
}
