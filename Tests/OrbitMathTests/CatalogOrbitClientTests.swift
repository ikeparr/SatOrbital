import Foundation
import XCTest
@testable import OrbitMath

private actor GroupDownloader: CatalogHTTPDownloader {
    let response: OrbitHTTPResponse
    private(set) var calls = 0
    init(_ response: OrbitHTTPResponse) { self.response = response }
    func fetchCatalog() async throws -> OrbitHTTPResponse { calls += 1; return response }
}

final class CatalogOrbitClientTests: XCTestCase {
    func testSharedDownloadAndDurableCacheAcrossLaunches() async throws {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "satellite-seeds", withExtension: "json", subdirectory: "Fixtures"))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let records = try decoder.decode([CachedOrbit].self, from: Data(contentsOf: fixture))
        let response = OrbitHTTPResponse(data: try JSONEncoder().encode(records.map(\.elements)), status: 200)
        let downloader = GroupDownloader(response)
        let now = records[0].fetchedAt
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "group.json")
        let client = CatalogOrbitClient(cacheURL: url, downloader: downloader, clock: { now })
        async let iss = client.fetchOrbit(catalogID: 25544)
        async let hubble = client.fetchOrbit(catalogID: 20580)
        let (a, b) = try await (iss, hubble)
        XCTAssertEqual(try OrbitalElements.decodeISS(a.data).catalogID, 25544)
        XCTAssertEqual(try OrbitalElements.decode(b.data, catalogID: 20580).catalogID, 20580)
        let count = await downloader.calls
        XCTAssertEqual(count, 1)
        let restored = CatalogOrbitClient(cacheURL: url, downloader: downloader, clock: { now.addingTimeInterval(23 * 3600) })
        _ = try await restored.fetchOrbit(catalogID: 43013)
        let afterRelaunch = await downloader.calls
        XCTAssertEqual(afterRelaunch, 1)
        let tomorrow = CatalogOrbitClient(cacheURL: url, downloader: downloader, clock: { now.addingTimeInterval(25 * 3600) })
        _ = try await tomorrow.fetchOrbit(catalogID: 25544)
        let afterDay = await downloader.calls
        XCTAssertEqual(afterDay, 2)
    }

    func testProviderErrorStopsGroupRequestsAndPersistsRetryAfter() async throws {
        let downloader = GroupDownloader(.init(data: Data(), status: 429, retryAfter: "14400"))
        let now = Date(timeIntervalSince1970: 1_790_966_000)
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "group.json")
        let client = CatalogOrbitClient(cacheURL: url, downloader: downloader, clock: { now })
        let first = try await client.fetchOrbit(catalogID: 25544)
        XCTAssertEqual(first.status, 429)
        let second = try await client.fetchOrbit(catalogID: 20580)
        XCTAssertEqual(second.status, 429)
        let restored = CatalogOrbitClient(cacheURL: url, downloader: downloader, clock: { now.addingTimeInterval(23 * 3600) })
        let afterRelaunch = try await restored.fetchOrbit(catalogID: 43013)
        XCTAssertEqual(afterRelaunch.status, 429)
        let count = await downloader.calls
        XCTAssertEqual(count, 1)
    }
}

private struct LegacyGroupCache: Codable {
    let records: [OrbitalElements]
    let nextRequestAt: Date
    let status: Int
}

extension CatalogOrbitClientTests {
    func testPreviousTwoHourCacheMigratesToDailyWithoutDownloading() async throws {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "satellite-seeds", withExtension: "json", subdirectory: "Fixtures"))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let records = try decoder.decode([CachedOrbit].self, from: Data(contentsOf: fixture))
        let now = records[0].fetchedAt
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "group.json")
        try JSONEncoder().encode(LegacyGroupCache(records: records.map(\.elements),
            nextRequestAt: now.addingTimeInterval(7200), status: 200)).write(to: url)
        let downloader = GroupDownloader(.init(data: Data(), status: 429))
        let client = CatalogOrbitClient(cacheURL: url, downloader: downloader, clock: { now.addingTimeInterval(3 * 3600) })
        let result = try await client.fetchOrbit(catalogID: 25544)
        XCTAssertEqual(result.status, 200)
        let calls = await downloader.calls
        XCTAssertEqual(calls, 0)
    }
}
