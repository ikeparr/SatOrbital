import Combine
import Foundation

@MainActor
final class TrackingStore: ObservableObject {
    @Published private(set) var selected: SatelliteTarget? = nil
    @Published private var snapshots: [SatelliteTarget: TrackingFrame] = [:]
    var frames: [SatelliteTarget: TrackingFrame] {
        guard let selected else { return snapshots }
        return snapshots[selected].map { [selected: $0] } ?? [:]
    }
    func frame(for target: SatelliteTarget) -> TrackingFrame? { snapshots[target] }
    @Published private(set) var results: [SatelliteTarget: OrbitLoadResult] = [:]
    var frame: TrackingFrame? { selected.flatMap { frames[$0] } }
    var cached: CachedOrbit? { selected.flatMap { results[$0]?.cached } }
    var targets: [SatelliteTarget] { selected.map { [$0] } ?? SatelliteTarget.allCases }
    var selectionName: String { selected?.name ?? "All" }
    var selectionSubtitle: String { selected?.subtitle ?? "All satellites · Earth overview" }
    var notice: String? { targets.compactMap { results[$0]?.notice }.first }
    @Published private(set) var predictionError: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isLive = true
    var nextRequestAt: Date { targets.map { results[$0]?.nextRequestAt ?? .distantPast }.min() ?? .distantPast }
    @Published private(set) var now = Date()

    private var frozenDate: Date?
    private let repositories: [SatelliteTarget: OrbitRepository]
    private var generation = 0
    private let clock: @Sendable () -> Date

    convenience init() {
        let directory = URL.applicationSupportDirectory.appending(path: "SatOrbital", directoryHint: .isDirectory)
        let seedURL = Bundle.main.url(forResource: "SatelliteSeeds", withExtension: "json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let seeds = seedURL.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? decoder.decode([CachedOrbit].self, from: $0) } ?? []
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let repositories = Dictionary(uniqueKeysWithValues: SatelliteTarget.allCases.map { target in
            let seed = seeds.first { $0.elements.catalogID == target.id }.flatMap { try? encoder.encode($0) }
            // Preserve existing ISS installations' cache and request deadline.
            let filename = target == .iss ? "iss-orbit.json" : "orbit-\(target.id).json"
            return (target, OrbitRepository(cacheURL: directory.appending(path: filename),
                                            catalogID: target.id, seed: seed))
        })
        self.init(repositories: repositories)
    }

    init(repositories: [SatelliteTarget: OrbitRepository], clock: @escaping @Sendable () -> Date = { Date() }) {
        self.repositories = repositories
        self.clock = clock
        now = clock()
    }

    private func hydrate() async {
        for target in targets {
            if let repository = repositories[target] { results[target] = await repository.current(at: clock()) }
        }
        await tick()
    }

    func select(_ target: SatelliteTarget?) async {
        guard target != selected else { return }
        generation += 1
        selected = target
        predictionError = nil
        // Existing snapshots remain immediately usable while a download is in flight.
        await hydrate()
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
        if targets.allSatisfy({ results[$0]?.cached == nil }) { return isRefreshing ? "LOADING ORBIT" : "ORBIT UNAVAILABLE" }
        if freshness == .expired && frames.isEmpty { return "UPDATE REQUIRED" }
        if predictionError != nil { return "POSITION UNAVAILABLE" }
        if !isLive { return "PAUSED · PREDICTED" }
        if freshness == .stale { return "NOW · STALE ELEMENTS" }
        return "NOW · PREDICTED"
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        let requested = targets
        await hydrate()
        for target in requested {
            guard !Task.isCancelled else { break }
            if let repository = repositories[target] {
                results[target] = await repository.load(at: clock())
                await tick()
            }
        }
        isRefreshing = false
        await tick()
    }

    func run() async {
        await hydrate()
        var refreshTask: Task<Void, Never>?
        defer { refreshTask?.cancel() }
        while !Task.isCancelled {
            if canRefresh {
                refreshTask = Task { await self.refresh() }
            }
            do { try await Task.sleep(for: .seconds(1)) } catch { break }
            await tick()
        }
    }

    func tick() async {
        now = clock()
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
        snapshots = snapshot
        predictionError = frames.count < targets.count && !isRefreshing
            ? "Some positions are unavailable. Refresh orbital data when available." : nil
    }

    func togglePlayback() async {
        if isLive {
            frozenDate = clock()
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
