import XCTest
import simd
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
            (SatelliteTarget(rawValue: $0.elements.catalogID)!, CachedOrbit(elements: $0.elements, fetchedAt: now.addingTimeInterval(-90000), isBundled: true))
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

private struct CatalogFixtureClient: OrbitHTTPClient {
    let data: Data
    func fetchOrbit(catalogID: Int) async throws -> OrbitHTTPResponse {
        .init(data: data, status: 200)
    }
}

extension TrackingStoreTests {
    func testStarlinkVisibilityFiltersFramesAndClearsHiddenSelection() async throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "expanded-catalog", withExtension: "json", subdirectory: "Fixtures"))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let seeds = try decoder.decode([CachedOrbit].self, from: Data(contentsOf: url))
        let now = try XCTUnwrap(UTCDate.parse("2026-09-29T23:00:00Z"))
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = CatalogFixtureClient(data: try JSONEncoder().encode(seeds.map(\.elements)))
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let repositories = try Dictionary(uniqueKeysWithValues: seeds.map { record in
            let target = try XCTUnwrap(SatelliteTarget(rawValue: record.elements.catalogID))
            return (target, OrbitRepository(cacheURL: directory.appending(path: "\(target.id).json"),
                                           catalogID: target.id, seed: try encoder.encode(record), client: client))
        })
        let store = TrackingStore(repositories: repositories, clock: { now })
        await store.refresh()
        XCTAssertEqual(store.frames.count, 15)
        await store.togglePlayback()
        store.setStarlinksVisible(false)
        XCTAssertNil(store.selected)
        XCTAssertEqual(store.frames.count, 6)
        XCTAssertTrue(store.frames.keys.allSatisfy { !$0.isStarlink })
        await store.tick()
        XCTAssertNil(store.predictionError)
        XCTAssertEqual(store.frames.count, 6)
        XCTAssertFalse(store.isLive)
        await store.select(.hubble)
        store.setStarlinksVisible(true)
        XCTAssertEqual(store.selected, .hubble)
        XCTAssertEqual(Set(store.frames.keys), [.hubble])
        let starlink = try XCTUnwrap(SatelliteTarget.allCases.first(where: \.isStarlink))
        await store.select(starlink)
        store.setStarlinksVisible(false)
        XCTAssertNil(store.selected)
        XCTAssertEqual(store.frames.count, 6)
        XCTAssertFalse(store.isLive)
        await store.select(starlink)
        XCTAssertTrue(store.showsStarlinks)
        XCTAssertEqual(Set(store.frames.keys), [starlink])
        await store.select(nil)
        XCTAssertEqual(store.frames.count, 15)
    }
}


private final class PlaybackTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date) { self.date = date }
    func read() -> Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date = date.addingTimeInterval(seconds) } }
}

extension TrackingStoreTests {
    private func timeFixture(clock: PlaybackTestClock) throws -> TrackingStore {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "expanded-catalog", withExtension: "json", subdirectory: "Fixtures"))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let records = try decoder.decode([CachedOrbit].self, from: Data(contentsOf: url))
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let client = CatalogFixtureClient(data: try JSONEncoder().encode(records.map(\.elements)))
        // Fresh bundled records prevent network attempts; all tests use a fixture client.
        let repositories = try Dictionary(uniqueKeysWithValues: records.map { record in
            let target = try XCTUnwrap(SatelliteTarget(rawValue: record.elements.catalogID))
            let fresh = CachedOrbit(elements: record.elements, fetchedAt: clock.read(), isBundled: true)
            return (target, OrbitRepository(cacheURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString),
                                           catalogID: target.id, seed: try encoder.encode(fresh), client: client))
        })
        return TrackingStore(repositories: repositories, clock: { clock.read() })
    }

    func testTimelineSeekPlaybackInterpolationAndReturnToNow() async throws {
        let realDate = try XCTUnwrap(UTCDate.parse("2026-09-29T23:00:00Z"))
        let clock = PlaybackTestClock(realDate)
        let store = try timeFixture(clock: clock)
        await store.reloadVisible()
        let future = realDate.addingTimeInterval(3600)
        await store.seek(to: future)
        XCTAssertFalse(store.isLive)
        XCTAssertEqual(store.displayDate, future)
        await store.setPlaybackRate(60)
        await store.togglePlayback()
        clock.advance(2)
        await store.tick()
        XCTAssertEqual(store.displayDate, future.addingTimeInterval(120))
        let frame = try XCTUnwrap(store.frame(for: .iss))
        XCTAssertEqual(frame.state.date, store.displayDate)
        let engine = try OrbitEngine(elements: XCTUnwrap(store.results[.iss]?.cached?.elements))
        let next = try engine.state(at: store.displayDate.addingTimeInterval(60)).scenePosition
        XCTAssertLessThan(simd_distance(frame.nextPosition, next), 0.000001)
        let mid = frame.position(at: clock.read().addingTimeInterval(0.5))
        XCTAssertLessThan(simd_distance(mid, (frame.state.scenePosition + next) / 2), 0.000001)
        await store.togglePlayback()
        let paused = store.displayDate
        clock.advance(30)
        await store.tick()
        XCTAssertEqual(store.displayDate, paused)
        await store.select(.hubble)
        XCTAssertEqual(store.frame?.state.date, paused)
        await store.togglePlayback()
        clock.advance(1)
        await store.tick()
        XCTAssertEqual(store.displayDate, paused.addingTimeInterval(60))
        await store.returnToNow()
        XCTAssertTrue(store.isLive)
        XCTAssertTrue(store.isCurrentTime)
        XCTAssertEqual(store.playbackRate, 1)
        XCTAssertEqual(store.displayDate, clock.read())
    }

    func testTimeBoundsAndCategoryFilteringPreservePausedTime() async throws {
        let clock = PlaybackTestClock(try XCTUnwrap(UTCDate.parse("2026-09-29T23:00:00Z")))
        let store = try timeFixture(clock: clock)
        await store.reloadVisible()
        await store.seek(to: clock.read().addingTimeInterval(200000))
        XCTAssertEqual(store.displayDate, clock.read().addingTimeInterval(86400))
        await store.setPlaybackRate(60)
        await store.togglePlayback()
        clock.advance(1)
        await store.tick()
        XCTAssertFalse(store.isLive)
        await store.seek(to: clock.read().addingTimeInterval(-200000))
        XCTAssertEqual(store.displayDate, clock.read().addingTimeInterval(-86400))
        let paused = store.displayDate
        store.setVisibleCategories([.station, .weather])
        await store.reloadVisible()
        XCTAssertEqual(Set(store.frames.keys), [.iss, .tiangong, .noaa20])
        XCTAssertEqual(store.displayDate, paused)
        await store.select(.iss)
        store.setVisibleCategories([.weather])
        XCTAssertNil(store.selected)
        XCTAssertEqual(Set(store.frames.keys), [.noaa20])
        store.setVisibleCategories([])
        await store.reloadVisible()
        XCTAssertTrue(store.frames.isEmpty)
        XCTAssertNil(store.predictionError)
        XCTAssertFalse(store.canRefresh)
        XCTAssertEqual(store.modeLabel, "NO CATEGORIES SELECTED")
        await store.select(.hubble)
        XCTAssertTrue(store.visibleCategories.contains(.science))
        XCTAssertEqual(Set(store.frames.keys), [.hubble])
        XCTAssertEqual(store.displayDate, paused)
        XCTAssertTrue(SatelliteTarget.allCases.allSatisfy { SatelliteCategory(rawValue: $0.category) != nil })
    }
}


extension TrackingStoreTests {
    func testShellSwitchClearsSelectionAndSearchCanFocusOutsideShell() async throws {
        let clock = PlaybackTestClock(try XCTUnwrap(UTCDate.parse("2026-09-29T23:00:00Z")))
        let store = try timeFixture(clock: clock)
        await store.reloadVisible()
        await store.seek(to: clock.read().addingTimeInterval(3600))
        let paused = store.displayDate
        store.setOrbitShell(.low)
        await store.reloadVisible()
        XCTAssertTrue(store.frames.keys.contains(.iss))
        XCTAssertTrue(store.frames.keys.allSatisfy { OrbitShell.low.includes(store.results[$0]!.cached!.elements) })
        await store.select(.iss)
        store.setOrbitShell(.higher)
        XCTAssertNil(store.selected)
        await store.reloadVisible()
        XCTAssertFalse(store.frames.keys.contains(.iss))
        XCTAssertEqual(store.displayDate, paused)
        await store.select(.hubble)
        XCTAssertEqual(Set(store.frames.keys), [.hubble])
        await store.select(nil)
        XCTAssertFalse(store.frames.keys.contains(.hubble))
        XCTAssertEqual(store.displayDate, paused)
    }
}
