import Combine
import Foundation

@MainActor
final class TrackingStore: ObservableObject {
    @Published private(set) var selected: SatelliteTarget? = nil
    @Published private(set) var visibleCategories = Set(SatelliteCategory.allCases)
    @Published private(set) var orbitShell = OrbitShell.all
    var showsStarlinks: Bool { visibleCategories.contains(.starlink) }
    @Published private var snapshots: [SatelliteTarget: TrackingFrame] = [:]
    var frames: [SatelliteTarget: TrackingFrame] {
        let visible = snapshots.filter { visibleCategories.contains($0.key.filterCategory) }
        guard let selected else { return visible.filter { matchesShell($0.key) } }
        return visible[selected].map { [selected: $0] } ?? [:]
    }
    func frame(for target: SatelliteTarget) -> TrackingFrame? { snapshots[target] }
    @Published private(set) var results: [SatelliteTarget: OrbitLoadResult] = [:]
    var frame: TrackingFrame? { selected.flatMap { frames[$0] } }
    var cached: CachedOrbit? { selected.flatMap { results[$0]?.cached } }
    var targets: [SatelliteTarget] {
        (selected.map { [$0] } ?? SatelliteTarget.allCases.filter { repositories[$0] != nil }).filter { visibleCategories.contains($0.filterCategory) && (selected != nil || matchesShell($0)) }
    }
    var selectionName: String { selected?.name ?? "All" }
    var selectionSubtitle: String { selected?.subtitle ?? "All satellites · Earth overview" }
    var notice: String? { targets.compactMap { results[$0]?.notice }.first }
    @Published private(set) var predictionError: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isLive = true
    var nextRequestAt: Date { targets.map { results[$0]?.nextRequestAt ?? .distantPast }.min() ?? .distantPast }
    @Published private(set) var now = Date()

    var displayDate: Date { frozenDate ?? now }

    @Published private(set) var playbackRate: Double = 1
    var isCurrentTime: Bool { frozenDate == nil }
    static let timeRange: TimeInterval = 86_400
    private var frozenDate: Date?
    private var lastClockDate: Date?
    private let repositories: [SatelliteTarget: OrbitRepository]
    private var epochCache: [SatelliteTarget: (elements: OrbitalElements, date: Date)] = [:]
    private let calculator = TrackingCalculator()
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
        let client = CatalogOrbitClient(cacheURL: directory.appending(path: "catalog-group.json"), seed: seeds)
        let repositories = Dictionary(uniqueKeysWithValues: SatelliteTarget.allCases.map { target in
            let seed = seeds.first { $0.elements.catalogID == target.id }.flatMap { try? encoder.encode($0) }
            // Preserve existing ISS installations' cache and request deadline.
            let filename = target == .iss ? "iss-orbit.json" : "orbit-\(target.id).json"
            return (target, OrbitRepository(cacheURL: directory.appending(path: filename),
                                            catalogID: target.id, seed: seed, client: client))
        })
        self.init(repositories: repositories)
    }

    init(repositories: [SatelliteTarget: OrbitRepository], clock: @escaping @Sendable () -> Date = { Date() }) {
        self.repositories = repositories
        self.clock = clock
        now = clock()
    }

    private func hydrate() async {
        var hydrated = results
        for target in targets {
            if let repository = repositories[target] { hydrated[target] = await repository.current(at: clock()) }
        }
        results = hydrated
        await tick()
    }

    // Visibility filters the same frames used for rendering and tap picking.
    // Clear a hidden selection immediately without changing the displayed time.
    func setVisibleCategories(_ categories: Set<SatelliteCategory>) {
        visibleCategories = categories
        if let selected, !categories.contains(selected.filterCategory) {
            generation += 1
            self.selected = nil
            predictionError = nil
        }
    }

    func setStarlinksVisible(_ visible: Bool) {
        var categories = visibleCategories
        if visible { categories.insert(.starlink) } else { categories.remove(.starlink) }
        setVisibleCategories(categories)
    }

    private func matchesShell(_ target: SatelliteTarget) -> Bool {
        guard let elements = results[target]?.cached?.elements else { return true }
        return orbitShell.includes(elements)
    }

    func setOrbitShell(_ shell: OrbitShell) {
        guard orbitShell != shell else { return }
        orbitShell = shell
        generation += 1
        selected = nil
        predictionError = nil
    }

    func reloadVisible() async { await hydrate() }

    func select(_ target: SatelliteTarget?) async {
        if let target { visibleCategories.insert(target.filterCategory) }
        guard target != selected else { return }
        generation += 1
        selected = target
        predictionError = nil
        // Existing snapshots remain immediately usable while a download is in flight.
        await hydrate()
        await refresh()
    }

    var freshness: OrbitFreshness? {
        let values = targets.compactMap { epoch(for: $0) }
            .map { OrbitFreshness.assess(epoch: $0, at: now) }
        if values.contains(.expired) { return .expired }
        if values.contains(.stale) { return .stale }
        return values.isEmpty ? nil : .fresh
    }
    func freshness(for target: SatelliteTarget) -> OrbitFreshness? {
        epoch(for: target).map { OrbitFreshness.assess(epoch: $0, at: now) }
    }

    private func epoch(for target: SatelliteTarget) -> Date? {
        guard let elements = results[target]?.cached?.elements else { return nil }
        if let saved = epochCache[target], saved.elements == elements { return saved.date }
        guard let date = elements.epoch else { return nil }
        epochCache[target] = (elements, date)
        return date
    }

    var canRefresh: Bool { !targets.isEmpty && !isRefreshing && now >= nextRequestAt }
    var modeLabel: String {
        if targets.isEmpty { return visibleCategories.isEmpty ? "NO CATEGORIES SELECTED" : "NO MATCHING SATELLITES" }
        if targets.allSatisfy({ results[$0]?.cached == nil }) { return isRefreshing ? "LOADING ORBIT" : "ORBIT UNAVAILABLE" }
        if freshness == .expired && frames.isEmpty { return "UPDATE REQUIRED" }
        if predictionError != nil { return "POSITION UNAVAILABLE" }
        if !isLive { return "PAUSED · PREDICTED" }
        if !isCurrentTime { return "\(Int(playbackRate))× · PREDICTED" }
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
                if target == selected { await tick() }
            }
        }
        isRefreshing = false
        await tick()
    }

    func run() async {
        lastClockDate = clock()
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
        advanceTime(to: clock())
        let date = displayDate
        let freshnessDate = now
        let cached = results.compactMapValues(\.cached)
        let live = isLive
        generation += 1
        let currentGeneration = generation
        let snapshot = await calculator.snapshot(cached, targets: Set(targets), selected: selected,
                                                 at: date, freshnessDate: freshnessDate, live: live,
                                                 animationDate: now, playbackRate: playbackRate)
        guard !Task.isCancelled, currentGeneration == generation else { return }
        snapshots = snapshot
        predictionError = frames.count < targets.count && !isRefreshing
            ? "Some positions are unavailable. Refresh orbital data when available." : nil
    }

    private func advanceTime(to date: Date) {
        if isLive, let frozenDate, let lastClockDate {
            let advanced = frozenDate.addingTimeInterval(max(0, date.timeIntervalSince(lastClockDate)) * playbackRate)
            let limit = date.addingTimeInterval(Self.timeRange)
            self.frozenDate = min(advanced, limit)
            if advanced >= limit { isLive = false }
        }
        now = date
        lastClockDate = date
    }

    func seek(to date: Date) async {
        let current = clock()
        frozenDate = min(max(date, current.addingTimeInterval(-Self.timeRange)), current.addingTimeInterval(Self.timeRange))
        isLive = false
        lastClockDate = current
        await tick()
    }

    func setPlaybackRate(_ rate: Double) async {
        guard [1.0, 10.0, 60.0].contains(rate) else { return }
        advanceTime(to: clock())
        if rate != 1, frozenDate == nil { frozenDate = now }
        playbackRate = rate
        await tick()
    }

    func togglePlayback() async {
        advanceTime(to: clock())
        if isLive {
            frozenDate = displayDate
            isLive = false
        } else { isLive = true }
        await tick()
    }

    func returnToNow() async {
        frozenDate = nil
        playbackRate = 1
        isLive = true
        lastClockDate = clock()
        await tick()
    }

    func pauseForReducedMotion() async {
        guard isLive else { return }
        await togglePlayback()
    }
}
