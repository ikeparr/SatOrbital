import XCTest
import simd
@testable import OrbitMath

final class SkyObservationTests: XCTestCase {
    func testCardinalDirectionsElevationAndRange() throws {
        let place = try XCTUnwrap(ObserverPlace(name: "Equator", latitude: 0, longitude: 0))
        for (relative, azimuth) in [(SIMD3<Double>(0, 500, 0), 90.0), ([0, 0, 500], 0), ([0, -500, 0], 270), ([0, 0, -500], 180)] {
            let observation = try XCTUnwrap(SkyObservation(place: place, satellite: place.earthFixedPosition + relative))
            XCTAssertEqual(observation.azimuthDegrees, azimuth, accuracy: 1e-9)
            XCTAssertEqual(observation.elevationDegrees, 0, accuracy: 1e-9)
            XCTAssertEqual(observation.rangeKilometers, 500, accuracy: 1e-9)
            XCTAssertFalse(observation.isAboveHorizon)
        }
        let diagonal = try XCTUnwrap(SkyObservation(place: place, satellite: place.earthFixedPosition + [500, 500, 0]))
        XCTAssertEqual(diagonal.elevationDegrees, 45, accuracy: 1e-9)
        XCTAssertEqual(diagonal.rangeKilometers, sqrt(500_000), accuracy: 1e-9)
        XCTAssertTrue(diagonal.isAboveHorizon)
        let below = try XCTUnwrap(SkyObservation(place: place, satellite: place.earthFixedPosition + [-500, 0, 0]))
        XCTAssertEqual(below.elevationDegrees, -90, accuracy: 1e-9)
        XCTAssertFalse(below.isAboveHorizon)
        XCTAssertNil(SkyObservation(place: place, satellite: place.earthFixedPosition))
        XCTAssertNil(SkyObservation(place: place, satellite: [.nan, 0, 0]))
    }

    func testGeodeticLocalFrameAtNonzeroLatitudesPolesAndDateline() throws {
        for (latitude, longitude) in [(40.713, -74.006), (-33.869, 151.209), (90.0, 180.0), (-90.0, -179.0)] {
            let place = try XCTUnwrap(ObserverPlace(name: "Test", latitude: latitude, longitude: longitude))
            let lat = latitude * .pi / 180, lon = longitude * .pi / 180
            let east = SIMD3<Double>(-sin(lon), cos(lon), 0)
            let north = SIMD3<Double>(-sin(lat) * cos(lon), -sin(lat) * sin(lon), cos(lat))
            let up = SIMD3<Double>(cos(lat) * cos(lon), cos(lat) * sin(lon), sin(lat))
            let direction = SkyViewPose.direction(azimuth: 123, elevation: 35)
            let satellite = place.earthFixedPosition + (east * direction.x + north * direction.y + up * direction.z) * 1_200
            let observation = try XCTUnwrap(SkyObservation(place: place, satellite: satellite))
            XCTAssertEqual(observation.azimuthDegrees, 123, accuracy: 1e-9)
            XCTAssertEqual(observation.elevationDegrees, 35, accuracy: 1e-9)
            XCTAssertEqual(observation.rangeKilometers, 1_200, accuracy: 1e-9)
        }
    }

    func testPerspectiveProjectionCompassOrientationAndHorizon() throws {
        for heading in [0.0, 90, 180, 270, 359] {
            let pose = SkyViewPose(heading: heading, elevation: 25)
            let center = try XCTUnwrap(pose.project(SkyViewPose.direction(azimuth: heading, elevation: 25), aspect: 0.7))
            XCTAssertEqual(center.x, 0.5, accuracy: 1e-9)
            XCTAssertEqual(center.y, 0.5, accuracy: 1e-9)
            let right = try XCTUnwrap(pose.project(SkyViewPose.direction(azimuth: heading + 10, elevation: 25), aspect: 0.7))
            XCTAssertGreaterThan(right.x, 0.5)
            let higher = try XCTUnwrap(pose.project(SkyViewPose.direction(azimuth: heading, elevation: 40), aspect: 0.7))
            XCTAssertLessThan(higher.y, 0.5)
            for offset in [-20.0, 0, 20] {
                let horizon = try XCTUnwrap(pose.project(SkyViewPose.direction(azimuth: heading + offset, elevation: 0), aspect: 0.7))
                XCTAssertEqual(horizon.y, pose.horizonY, accuracy: 1e-9)
            }
            XCTAssertNil(pose.project(SkyViewPose.direction(azimuth: heading + 180, elevation: -25), aspect: 0.7))
            XCTAssertNil(pose.project([0, 0, 1], aspect: 0))
        }
    }

    func testSkyInterpolationUsesSimulationStepAndClampsWhilePauseHolds() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "iss-omm", withExtension: "json", subdirectory: "Fixtures"))
        let elements = try OrbitalElements.decode(Data(contentsOf: url), catalogID: SatelliteTarget.iss.id)
        let engine = try OrbitEngine(elements: elements)
        let date = try XCTUnwrap(elements.epoch)
        let wall = Date(timeIntervalSince1970: 123_456)
        let state = try engine.state(at: date)
        let next = try engine.state(at: date.addingTimeInterval(60))
        let frame = TrackingFrame(state: state, nextPosition: next.scenePosition, interpolates: true,
                                  path: [], pathDate: date, animationDate: wall, simulationStep: 60)
        XCTAssertLessThan(simd_distance(frame.skyEarthFixedPosition(at: wall.addingTimeInterval(-1)), state.earthFixedPosition), 0.003)
        XCTAssertLessThan(simd_distance(frame.skyEarthFixedPosition(at: wall.addingTimeInterval(2)), next.earthFixedPosition), 0.003)
        let halfway = frame.skyEarthFixedPosition(at: wall.addingTimeInterval(0.5))
        XCTAssertGreaterThan(simd_distance(halfway, state.earthFixedPosition), 100)
        XCTAssertGreaterThan(simd_distance(halfway, next.earthFixedPosition), 100)
        let paused = TrackingFrame(state: state, nextPosition: next.scenePosition, interpolates: false,
                                   path: [], pathDate: date, animationDate: wall, simulationStep: 60)
        XCTAssertEqual(paused.skyEarthFixedPosition(at: wall), paused.skyEarthFixedPosition(at: wall.addingTimeInterval(100)))
    }
}
