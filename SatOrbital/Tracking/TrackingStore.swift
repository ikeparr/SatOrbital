import Combine
import Foundation

@MainActor
final class TrackingStore: ObservableObject {
    @Published private(set) var frame: TrackingFrame?
    @Published private(set) var cached: CachedOrbit?
    @Published private(set) var notice: String?
    @Published private(set) var predictionError: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isLive = true
    @Published private(set) var nextRequestAt = Date.distantPast
    @Published private(set) var now = Date()

    private var frozenDate: Date?
    private var path: [SIMD3<Float>] = []
    private var pathDate = Date.distantPast
    private var pathElements: OrbitalElements?
    private let repository: OrbitRepository
    private var generation = 0

    init() {
        let directory = URL.applicationSupportDirectory.appending(path: "SatOrbital", directoryHint: .isDirectory)
        let seedURL = Bundle.main.url(forResource: "ISSSeed", withExtension: "json")
        let seed = seedURL.flatMap { try? Data(contentsOf: $0) }
        repository = OrbitRepository(cacheURL: directory.appending(path: "iss-orbit.json"), seed: seed)
    }

    var freshness: OrbitFreshness? {
        cached?.elements.epoch.map { OrbitFreshness.assess(epoch: $0, at: now) }
    }
    var canRefresh: Bool { !isRefreshing && now >= nextRequestAt }
    var modeLabel: String {
        if cached == nil { return isRefreshing ? "LOADING ISS ORBIT" : "ORBIT UNAVAILABLE" }
        if freshness == .expired { return "UPDATE REQUIRED" }
        if predictionError != nil { return "POSITION UNAVAILABLE" }
        if !isLive { return "PAUSED · PREDICTED" }
        if freshness == .stale { return "NOW · STALE ELEMENTS" }
        return "NOW · PREDICTED"
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        let available = await repository.current()
        cached = available.cached
        nextRequestAt = available.nextRequestAt
        notice = available.notice
        await tick()
        let result = await repository.load()
        cached = result.cached
        nextRequestAt = result.nextRequestAt
        notice = result.notice
        isRefreshing = false
        await tick()
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
        guard let cached else { frame = nil; return }
        guard freshness != .expired else { frame = nil; predictionError = OrbitError.expired.localizedDescription; return }
        let date = frozenDate ?? now
        let elements = cached.elements
        let rebuild = elements != pathElements || abs(date.timeIntervalSince(pathDate)) >= 60 || path.isEmpty
        let existingPath = path
        let existingPathDate = pathDate
        let live = isLive
        generation += 1
        let currentGeneration = generation
        do {
            // Numerical work and orbit sampling stay off the UI thread.
            let nextFrame = try await Task.detached(priority: .userInitiated) {
                let engine = try OrbitEngine(elements: elements)
                let state = try engine.state(at: date)
                let next = live ? try engine.state(at: date.addingTimeInterval(1)).scenePosition : state.scenePosition
                let points = rebuild ? try engine.nextOrbit(from: date) : existingPath
                return TrackingFrame(state: state, nextPosition: next, interpolates: live,
                                     path: points, pathDate: rebuild ? date : existingPathDate)
            }.value
            guard !Task.isCancelled, currentGeneration == generation else { return }
            frame = nextFrame
            path = nextFrame.path
            pathDate = nextFrame.pathDate
            pathElements = elements
            predictionError = nil
        } catch {
            guard !Task.isCancelled, currentGeneration == generation else { return }
            frame = nil
            predictionError = error.localizedDescription
        }
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
