import XCTest
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

    func testEarthFixedTrajectoryMatchesSamplesAndDoesNotArtificiallyClose() throws {
        let engine = try OrbitEngine(elements: OrbitalElements.decodeISS(fixture("iss-omm")))
        let points = try engine.nextOrbit(from: engine.epoch, samples: 12)
        XCTAssertEqual(points.count, 13)
        for i in 0...12 {
            let expected = try engine.state(at: engine.epoch.addingTimeInterval(Double(i) / 12 * engine.elements.periodSeconds))
            XCTAssertEqual(points[i], expected.scenePosition)
        }
        XCTAssertGreaterThan(abs(points[0].x - points[12].x) + abs(points[0].z - points[12].z), 0.01)
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
