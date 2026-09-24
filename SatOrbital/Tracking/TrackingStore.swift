import Combine
import Foundation

@MainActor
final class TrackingStore: ObservableObject {
    @Published private(set) var selected: SatelliteTarget? = .iss
    @Published private(set) var frames: [SatelliteTarget: TrackingFrame] = [:]
    @Published private(set) var results: [SatelliteTarget: OrbitLoadResult] = [:]
    var frame: TrackingFrame? { selected.flatMap { frames[$0] } }
    var cached: CachedOrbit? { selected.flatMap { results[$0]?.cached } }
    var targets: [SatelliteTarget] { selected.map { [$0] } ?? SatelliteTarget.allCases }
    var selectionName: String { selected?.name ?? "All" }
    var selectionSubtitle: String { selected?.subtitle ?? "All satellites · Earth overview" }
    @Published private(set) var notice: String?
    @Published private(set) var predictionError: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isLive = true
    @Published private(set) var nextRequestAt = Date.distantPast
    @Published private(set) var now = Date()

    private var frozenDate: Date?
    private let repositories: [SatelliteTarget: OrbitRepository]
    private var generation = 0

    init() {
        let directory = URL.applicationSupportDirectory.appending(path: "SatOrbital", directoryHint: .isDirectory)
        let seedURL = Bundle.main.url(forResource: "SatelliteSeeds", withExtension: "json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let seeds = seedURL.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? decoder.decode([CachedOrbit].self, from: $0) } ?? []
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        repositories = Dictionary(uniqueKeysWithValues: SatelliteTarget.allCases.map { target in
            let seed = seeds.first { $0.elements.catalogID == target.id }.flatMap { try? encoder.encode($0) }
            // Preserve existing ISS installations' cache and request deadline.
            let filename = target == .iss ? "iss-orbit.json" : "orbit-\(target.id).json"
            return (target, OrbitRepository(cacheURL: directory.appending(path: filename),
                                            catalogID: target.id, seed: seed))
        })
    }

    func select(_ target: SatelliteTarget?) async {
        guard target != selected, !isRefreshing else { return }
        generation += 1 // Invalidate any numerical work from the previous selection.
        selected = target
        frames = [:]
        results = [:]
        predictionError = nil
        notice = nil
        nextRequestAt = .distantPast
        await refresh()
    }

    var freshness: OrbitFreshness? {
        let values = targets.compactMap { results[$0]?.cached?.elements.epoch }
            .map { OrbitFreshness.assess(epoch: $0, at: now) }
        if values.contains(.expired) { return .expired }
        if values.contains(.stale) { return .stale }
        return values.isEmpty ? nil : .fresh
    }
    var canRefresh: Bool { !isRefreshing && now >= nextRequestAt }
    var modeLabel: String {
        if results.values.allSatisfy({ $0.cached == nil }) { return isRefreshing ? "LOADING ORBIT" : "ORBIT UNAVAILABLE" }
        if freshness == .expired && frames.isEmpty { return "UPDATE REQUIRED" }
        if predictionError != nil { return "POSITION UNAVAILABLE" }
        if !isLive { return "PAUSED · PREDICTED" }
        if freshness == .stale { return "NOW · STALE ELEMENTS" }
        return "NOW · PREDICTED"
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        for target in targets {
            results[target] = await repositories[target]!.current()
        }
        await tick()
        for target in targets {
            results[target] = await repositories[target]!.load()
            await tick()
        }
        nextRequestAt = results.values.map(\.nextRequestAt).min() ?? .distantPast
        notice = results.values.compactMap(\.notice).first
        isRefreshing = false
    }

    func run() async {
        await refresh()
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(1)) } catch { break }
            await tick()
            if canRefresh { await refresh() }
        }
    }

    func tick() async {
        now = Date()
        let date = frozenDate ?? now
        let freshnessDate = now
        let cached = results.compactMapValues(\.cached)
        let live = isLive
        generation += 1
        let currentGeneration = generation
        let snapshot = await Task.detached(priority: .userInitiated) {
            TrackingFrame.snapshot(cached, at: date, freshnessDate: freshnessDate, live: live)
        }.value
        guard !Task.isCancelled, currentGeneration == generation else { return }
        frames = snapshot
        predictionError = snapshot.count < targets.count && !isRefreshing
            ? "Some positions are unavailable. Refresh orbital data when available." : nil
    }

    func togglePlayback() async {
        if isLive {
            frozenDate = Date()
            isLive = false
        } else { frozenDate = nil; isLive = true }
        await tick()
    }

    func returnToNow() async {
        frozenDate = nil
        isLive = true
        await tick()
    }

    func pauseForReducedMotion() async {
        guard isLive else { return }
        await togglePlayback()
    }
}
