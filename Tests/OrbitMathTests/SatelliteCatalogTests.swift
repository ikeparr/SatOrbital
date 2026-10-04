import XCTest
@testable import OrbitMath

final class SatelliteCatalogTests: XCTestCase {
    func testEmptySearchIncludesEntireCatalog() {
        XCTAssertEqual(SatelliteTarget.matching("  "), SatelliteTarget.allCases)
    }
    func testNamesAliasesAndCatalogIDs() {
        XCTAssertEqual(SatelliteTarget.matching("hÚbble"), [.hubble])
        XCTAssertEqual(SatelliteTarget.matching("HST"), [.hubble])
        XCTAssertEqual(SatelliteTarget.matching("noaa20"), [.noaa20])
        XCTAssertEqual(SatelliteTarget.matching("JPSS-1"), [.noaa20])
        XCTAssertEqual(SatelliteTarget.matching("NORAD 25544"), [.iss])
        XCTAssertEqual(SatelliteTarget.matching("Tianhe"), [.tiangong])
        XCTAssertEqual(SatelliteTarget.matching("weather 43013"), [.noaa20])
        XCTAssertTrue(SatelliteTarget.matching("unknown spacecraft").isEmpty)
    }
    @MainActor func testInitialSelectionIsEmpty() {
        let store = TrackingStore(repositories: [:])
        XCTAssertNil(store.selected)
        XCTAssertNil(store.frame)
        XCTAssertEqual(store.selectionName, "All")
    }
}

extension SatelliteCatalogTests {
    func testExpandedCatalogIdentityAndPropagation() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "expanded-catalog", withExtension: "json", subdirectory: "Fixtures"))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let seeds = try decoder.decode([CachedOrbit].self, from: Data(contentsOf: url))
        XCTAssertEqual(seeds.count, Set(seeds.map { $0.elements.catalogID }).count)
        XCTAssertEqual(Set(seeds.map { $0.elements.catalogID }), Set(SatelliteTarget.allCases.prefix(15).map(\.id)))
        let date = try XCTUnwrap(UTCDate.parse("2026-09-29T18:00:00Z"))
        let cached = Dictionary(uniqueKeysWithValues: seeds.map { (SatelliteTarget(rawValue: $0.elements.catalogID)!, $0) })
        let snapshot = TrackingFrame.snapshot(cached, at: date, freshnessDate: date, live: true)
        XCTAssertEqual(snapshot.count, seeds.count)
        for frame in snapshot.values {
            XCTAssertTrue((200...1000).contains(frame.state.altitudeKilometers))
            XCTAssertEqual(frame.path.first, frame.path.last)
            XCTAssertEqual(frame.path.first, frame.state.scenePosition)
        }
        let stars = SatelliteTarget.matching("starlink")
        XCTAssertEqual(stars.count, 209)
        XCTAssertTrue(stars.allSatisfy(\.isStarlink))
        XCTAssertEqual(SatelliteTarget.matching("100759").map(\.id), [100759])
        XCTAssertEqual(SatelliteTarget.matching("landsat").count, 2)
        // JSON identifiers above 99999 remain intact through the model and propagation.
        let record = try XCTUnwrap(seeds.first { $0.elements.catalogID == 100759 })
        let decoded = try OrbitalElements.decode(JSONEncoder().encode([record.elements]), catalogID: 100759)
        XCTAssertEqual(decoded.catalogID, 100759)
    }
}

 extension SatelliteCatalogTests {
    func testLargeCatalogHasUniqueFreshPropagatableRecordsAndSearch() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "large-catalog", withExtension: "json", subdirectory: "Fixtures"))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let seeds = try decoder.decode([CachedOrbit].self, from: Data(contentsOf: url))
        XCTAssertEqual(Set(seeds.map { $0.elements.catalogID }), Set(SatelliteTarget.allCases.map(\.id)))
        XCTAssertEqual(seeds.count, 396)
        XCTAssertEqual(Set(SatelliteTarget.allCases.map(\.id)).count, 396)
        let date = try XCTUnwrap(seeds.map(\.fetchedAt).max())
        let cached = Dictionary(uniqueKeysWithValues: seeds.map { (SatelliteTarget(rawValue: $0.elements.catalogID)!, $0) })
        let frames = TrackingFrame.snapshot(cached, at: date, freshnessDate: date, live: true)
        XCTAssertEqual(frames.count, seeds.count)
        for frame in frames.values {
            XCTAssertTrue(frame.state.altitudeKilometers.isFinite)
            XCTAssertGreaterThan(frame.state.altitudeKilometers, 100)
            XCTAssertEqual(frame.path.first, frame.path.last)
            XCTAssertEqual(frame.path.first, frame.state.scenePosition)
        }
        XCTAssertEqual(SatelliteTarget.matching("GPS").count, 12)
        XCTAssertEqual(SatelliteTarget.matching("Galileo").count, 12)
        XCTAssertEqual(SatelliteTarget.matching("OneWeb").count, 24)
        XCTAssertFalse(SatelliteTarget.matching("Sentinel").isEmpty)
        XCTAssertFalse(SatelliteTarget.matching("NOAA 21").isEmpty)
        XCTAssertTrue(SatelliteTarget.allCases.filter { !$0.isStarlink && $0.id > 100000 }.allSatisfy { $0.referenceImage == nil })
    }
}
