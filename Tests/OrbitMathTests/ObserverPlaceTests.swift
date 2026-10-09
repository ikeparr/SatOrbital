import XCTest
import simd
@testable import OrbitMath

final class ObserverPlaceTests: XCTestCase {
    func testCoordinateValidationAndStoredValueRoundTrip() throws {
        let place = try XCTUnwrap(ObserverPlace(name: "  New York  ", latitude: 40.713, longitude: -74.006))
        XCTAssertEqual(place.name, "New York")
        XCTAssertEqual(ObserverPlace.restore(place.storedValue), place)
        XCTAssertNil(ObserverPlace(name: " ", latitude: 0, longitude: 0))
        XCTAssertNil(ObserverPlace(name: String(repeating: "x", count: 81), latitude: 0, longitude: 0))
        XCTAssertNil(ObserverPlace(name: "Bad", latitude: 91, longitude: 0))
        XCTAssertNil(ObserverPlace(name: "Bad", latitude: 0, longitude: -181))
        XCTAssertNil(ObserverPlace(name: "Bad", latitude: .nan, longitude: 0))
        XCTAssertNil(ObserverPlace.restore("{\"name\":\"Bad\",\"latitude\":100,\"longitude\":0}"))
        XCTAssertNil(ObserverPlace.restore("garbage"))
    }

    func testSurfaceMarkerRoundTripsGeographyIncludingPolesAndDateline() throws {
        for (lat, lon) in [(0.0, 0.0), (40.713, -74.006), (-33.869, 151.209), (89.99, 180.0), (-90.0, 0.0)] {
            let place = try XCTUnwrap(ObserverPlace(name: "Test", latitude: lat, longitude: lon))
            let p = place.scenePosition
            let radius = EarthCoordinates.equatorialRadius
            let geographic = EarthCoordinates.geodetic([Double(p.z) * radius, Double(p.x) * radius, Double(p.y) * radius])
            XCTAssertEqual(geographic.latitude, lat, accuracy: 0.00001)
            if abs(lat) < 90 { XCTAssertEqual(abs(geographic.longitude), abs(lon), accuracy: 0.00001) }
            XCTAssertEqual(geographic.altitude, 0, accuracy: 0.001)
        }
    }

    func testPickingUsesNearSurfaceAndRejectsSpaceAndBackwardRays() throws {
        let place = try XCTUnwrap(EarthPlacePicking.place(origin: [0, 0, 4.6], direction: [0, 0, -1], earthAngle: 0))
        XCTAssertEqual(place.latitude, 0, accuracy: 0.00001)
        XCTAssertEqual(place.longitude, 0, accuracy: 0.00001)
        XCTAssertNil(EarthPlacePicking.place(origin: [0, 0, 4.6], direction: [0, 0, 1], earthAngle: 0))
        XCTAssertNil(EarthPlacePicking.place(origin: [0, 0, 4.6], direction: [1, 0, 0], earthAngle: 0))
        XCTAssertNil(EarthPlacePicking.place(origin: [0, 0, 4.6], direction: .zero, earthAngle: 0))
        XCTAssertNil(EarthPlacePicking.place(origin: [.nan, 0, 4.6], direction: [0, 0, -1], earthAngle: 0))
    }

    func testPickingReturnsSamePlaceAsEarthRotatesInSpaceMode() throws {
        for (lat, lon) in [(0.0, 90.0), (51.507, -0.128), (-33.869, 151.209), (89.0, -179.0)] {
            let original = try XCTUnwrap(ObserverPlace(name: "Test", latitude: lat, longitude: lon))
            for angle: Float in [0, 0.4, -.pi, 1.5] {
                let world = OrbitViewCoordinates.rotate(original.scenePosition, by: angle)
                let camera = simd_normalize(world) * 4.6
                let picked = try XCTUnwrap(EarthPlacePicking.place(origin: camera, direction: world - camera, earthAngle: angle))
                XCTAssertEqual(picked.latitude, lat, accuracy: 0.00005)
                XCTAssertEqual(picked.longitude, lon, accuracy: 0.00005)
            }
        }
    }
}
