import XCTest
@testable import OrbitMath

private actor HeldCatalogClient: OrbitHTTPClient {
    let records: [SatelliteTarget: CachedOrbit]
    var pending: CheckedContinuation<Void, Never>?
    var started: CheckedContinuation<Void, Never>?
    var hasStarted = false
    init(records: [SatelliteTarget: CachedOrbit]) { self.records = records }
    func fetchOrbit(catalogID: Int) async throws -> OrbitHTTPResponse {
        if catalogID == SatelliteTarget.iss.id && !hasStarted {
            hasStarted = true
            started?.resume(); started = nil
            await withCheckedContinuation { pending = $0 }
        }
        let record = records[SatelliteTarget(rawValue: catalogID)!]!
        return OrbitHTTPResponse(data: try JSONEncoder().encode([record.elements]), status: 200)
    }
    func waitUntilStarted() async {
        if hasStarted { return }
        await withCheckedContinuation { started = $0 }
    }
    func finish() { pending?.resume(); pending = nil }
}

@MainActor
final class TrackingStoreTests: XCTestCase {
    func testSelectionDuringDownloadAndReturnToAllWhilePaused() async throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "satellite-seeds", withExtension: "json", subdirectory: "Fixtures"))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let seeds = try decoder.decode([CachedOrbit].self, from: Data(contentsOf: url))
        let now = try XCTUnwrap(UTCDate.parse("2026-09-23T18:00:00Z"))
        let records = Dictionary(uniqueKeysWithValues: seeds.map {
            (SatelliteTarget(rawValue: $0.elements.catalogID)!, CachedOrbit(elements: $0.elements, fetchedAt: now.addingTimeInterval(-10800), isBundled: true))
        })
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = HeldCatalogClient(records: records)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let repositories = try Dictionary(uniqueKeysWithValues: records.map { target, record in
            (target, OrbitRepository(cacheURL: directory.appending(path: "\(target.id).json"), catalogID: target.id,
                                     seed: try encoder.encode(record), client: client))
        })
        let store = TrackingStore(repositories: repositories, clock: { now })
        let download = Task { await store.refresh() }
        await client.waitUntilStarted()
        XCTAssertTrue(store.isRefreshing)
        XCTAssertEqual(store.frames.count, 4)
        await store.select(.hubble)
        XCTAssertEqual(store.selected, .hubble)
        XCTAssertEqual(Set(store.frames.keys), [.hubble])
        XCTAssertEqual(store.cached?.elements.catalogID, SatelliteTarget.hubble.id)
        await store.togglePlayback()
        XCTAssertFalse(store.isLive)
        let paused = try XCTUnwrap(store.frame?.state.date)
        await client.finish()
        await download.value
        // A previous target's response must not replace selection or its details.
        XCTAssertEqual(store.selected, .hubble)
        XCTAssertEqual(store.cached?.elements.catalogID, SatelliteTarget.hubble.id)
        XCTAssertEqual(store.frame?.state.date, paused)
        await store.select(nil)
        XCTAssertNil(store.selected)
        XCTAssertNil(store.frame)
        XCTAssertNil(store.cached)
        XCTAssertEqual(store.frames.count, 4)
        XCTAssertTrue(store.frames.values.allSatisfy { !$0.interpolates && $0.state.date == paused })
        await store.returnToNow()
        XCTAssertTrue(store.isLive)
        XCTAssertTrue(store.frames.values.allSatisfy(\.interpolates))
    }
}
