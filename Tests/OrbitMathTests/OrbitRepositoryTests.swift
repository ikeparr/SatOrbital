import XCTest
@testable import OrbitMath

private actor StubClient: OrbitHTTPClient {
    var response: OrbitHTTPResponse
    private(set) var calls = 0
    private(set) var requestedIDs: [Int] = []
    init(_ response: OrbitHTTPResponse) { self.response = response }
    func fetchOrbit(catalogID: Int) async throws -> OrbitHTTPResponse { calls += 1; requestedIDs.append(catalogID); return response }
    func set(_ response: OrbitHTTPResponse) { self.response = response }
}

@MainActor
final class OrbitRepositoryTests: XCTestCase {
    private func fixture() throws -> (Data, Date, URL) {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "iss-omm", withExtension: "json", subdirectory: "Fixtures"))
        let data = try Data(contentsOf: url)
        let epoch = try XCTUnwrap(OrbitalElements.decodeISS(data).epoch)
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return (data, epoch.addingTimeInterval(300), directory.appending(path: "orbit.json"))
    }

    func testSuccessIsCachedAndRateLimitSurvivesRelaunch() async throws {
        let (data, now, url) = try fixture()
        let client = StubClient(.init(data: data, status: 200))
        let repo = OrbitRepository(cacheURL: url, client: client)
        let first = await repo.load(at: now)
        XCTAssertEqual(first.cached?.elements.catalogID, 25544)
        XCTAssertNil(first.notice)
        _ = await repo.load(at: now.addingTimeInterval(60))
        let restarted = OrbitRepository(cacheURL: url, client: client)
        let saved = await restarted.load(at: now.addingTimeInterval(120))
        XCTAssertEqual(saved.cached?.fetchedAt.timeIntervalSince1970 ?? 0, now.timeIntervalSince1970, accuracy: 1)
        let count = await client.calls
        XCTAssertEqual(count, 1)
    }

    func testMalformedRefreshPreservesGoodCacheAndBacksOff() async throws {
        let (data, now, url) = try fixture()
        let client = StubClient(.init(data: data, status: 200))
        let repo = OrbitRepository(cacheURL: url, client: client)
        let first = await repo.load(at: now)
        await client.set(.init(data: Data("[]".utf8), status: 200))
        let failed = await repo.load(at: now.addingTimeInterval(7201))
        XCTAssertEqual(failed.cached?.elements, first.cached?.elements)
        XCTAssertEqual(failed.cached?.fetchedAt, first.cached?.fetchedAt)
        XCTAssertNotNil(failed.notice)
        _ = await repo.load(at: now.addingTimeInterval(7210))
        let count = await client.calls
        XCTAssertEqual(count, 2)
    }

    func testProviderBackoffAndNoDataOnFirstOfflineLaunch() async throws {
        let (_, now, url) = try fixture()
        let client = StubClient(.init(data: Data(), status: 429, retryAfter: "10800"))
        let repo = OrbitRepository(cacheURL: url, client: client)
        let result = await repo.load(at: now)
        XCTAssertNil(result.cached)
        XCTAssertEqual(result.nextRequestAt.timeIntervalSince(now), 10800)
        let restarted = OrbitRepository(cacheURL: url, client: client)
        _ = await restarted.load(at: now.addingTimeInterval(3600))
        let count = await client.calls
        XCTAssertEqual(count, 1)
    }

    func testCorruptDiskCacheRecoversWithValidDownload() async throws {
        let (data, now, url) = try fixture()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("corrupt".utf8).write(to: url)
        let client = StubClient(.init(data: data, status: 200))
        let repo = OrbitRepository(cacheURL: url, client: client)
        let result = await repo.load(at: now)
        XCTAssertEqual(result.cached?.elements.catalogID, 25544)
    }

    func testBundledSnapshotWorksOfflineWithoutUnnecessaryRequest() async throws {
        let (data, now, url) = try fixture()
        let cached = CachedOrbit(elements: try OrbitalElements.decodeISS(data), fetchedAt: now, isBundled: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let client = StubClient(.init(data: Data(), status: 503))
        let repo = OrbitRepository(cacheURL: url, seed: try encoder.encode(cached), client: client)
        let result = await repo.load(at: now.addingTimeInterval(60))
        XCTAssertEqual(result.cached?.isBundled, true)
        let count = await client.calls
        XCTAssertEqual(count, 0)
    }

    func testRetryAfterDateAndInvalidValues() throws {
        let now = try XCTUnwrap(UTCDate.parse("2026-09-23T00:00:00Z"))
        XCTAssertEqual(OrbitRepository.retryDelay("Wed, 23 Sep 2026 03:00:00 GMT", now: now), 10800)
        XCTAssertEqual(OrbitRepository.retryDelay("not a date", now: now), 0)
        XCTAssertEqual(OrbitRepository.retryDelay("-1", now: now), 0)
        XCTAssertEqual(OrbitRepository.retryDelay("10000000", now: now), 86400)
    }

    func testSavedDataIsAvailableBeforeNetworkRefresh() async throws {
        let (data, now, url) = try fixture()
        let cached = CachedOrbit(elements: try OrbitalElements.decodeISS(data), fetchedAt: now.addingTimeInterval(-10800), isBundled: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let client = StubClient(.init(data: Data(), status: 503))
        let repo = OrbitRepository(cacheURL: url, seed: try encoder.encode(cached), client: client)
        let immediatelyAvailable = await repo.current(at: now)
        XCTAssertEqual(immediatelyAvailable.cached?.elements.catalogID, 25544)
        let count = await client.calls
        XCTAssertEqual(count, 0)
        let offline = await repo.load(at: now)
        XCTAssertEqual(offline.cached?.elements, cached.elements)
        XCTAssertNotNil(offline.notice)
    }

    func testOlderProviderElementsNeverReplaceNewerCache() async throws {
        let (data, now, url) = try fixture()
        let client = StubClient(.init(data: data, status: 200))
        let repo = OrbitRepository(cacheURL: url, client: client)
        let original = await repo.load(at: now)
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let formatter = ISO8601DateFormatter()
        payload[0]["EPOCH"] = formatter.string(from: now.addingTimeInterval(-3600))
        await client.set(.init(data: try JSONSerialization.data(withJSONObject: payload), status: 200))
        let older = await repo.load(at: now.addingTimeInterval(7201))
        XCTAssertEqual(older.cached?.elements, original.cached?.elements)
        XCTAssertEqual(older.cached?.fetchedAt, original.cached?.fetchedAt)
        XCTAssertNotNil(older.notice)
    }
    func testEachCatalogTargetLoadsItsOwnDataAndClosedOrbit() async throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "satellite-seeds", withExtension: "json", subdirectory: "Fixtures"))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let seeds = try decoder.decode([CachedOrbit].self, from: Data(contentsOf: url))
        XCTAssertEqual(Set(seeds.map { $0.elements.catalogID }), Set(SatelliteTarget.allCases.map(\.id)))
        for target in SatelliteTarget.allCases {
            let seed = try XCTUnwrap(seeds.first { $0.elements.catalogID == target.id })
            let (_, _, cacheURL) = try fixture()
            let now = try XCTUnwrap(seed.elements.epoch).addingTimeInterval(300)
            let client = StubClient(.init(data: try JSONEncoder().encode([seed.elements]), status: 200))
            let repository = OrbitRepository(cacheURL: cacheURL, catalogID: target.id, client: client)
            let loaded = await repository.load(at: now)
            XCTAssertEqual(loaded.cached?.elements.catalogID, target.id)
            XCTAssertNil(loaded.notice)
            let requested = await client.requestedIDs
            XCTAssertEqual(requested, [target.id])
            let state = try OrbitEngine(elements: XCTUnwrap(loaded.cached?.elements)).state(at: now)
            XCTAssertTrue((250...1000).contains(state.altitudeKilometers))
            let ring = try state.orbitRing()
            XCTAssertEqual(ring.first, state.scenePosition)
            XCTAssertEqual(ring.last, ring.first)
            // A fresh repository with another catalog ID must reject this disk cache.
            let otherID = target == .iss ? SatelliteTarget.hubble.id : SatelliteTarget.iss.id
            let other = OrbitRepository(cacheURL: cacheURL, catalogID: otherID, client: client)
            let mismatched = await other.current(at: now)
            XCTAssertNil(mismatched.cached)
            let rejectedDownload = await other.load(at: now)
            XCTAssertNil(rejectedDownload.cached)
            XCTAssertNotNil(rejectedDownload.notice)
        }
    }

}
