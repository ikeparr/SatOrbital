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
