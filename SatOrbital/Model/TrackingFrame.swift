import Foundation

struct TrackingFrame: Sendable {
    let state: OrbitalState
    let nextPosition: SIMD3<Float>
    let interpolates: Bool
    let path: [SIMD3<Float>]
    let pathDate: Date
    var animationDate: Date? = nil
    var simulationStep: TimeInterval = 1

    /// Use a common display time and isolate unavailable or expired targets.
    static func snapshot(_ cached: [SatelliteTarget: CachedOrbit], at date: Date,
                         freshnessDate: Date, live: Bool) -> [SatelliteTarget: TrackingFrame] {
        cached.reduce(into: [:]) { frames, entry in
            let (target, cached) = entry
            guard cached.elements.catalogID == target.id,
                  let epoch = cached.elements.epoch,
                  OrbitFreshness.assess(epoch: epoch, at: freshnessDate) != .expired else { return }
            do {
                let engine = try OrbitEngine(elements: cached.elements)
                let state = try engine.state(at: date)
                let next = live ? try engine.state(at: date.addingTimeInterval(1)).scenePosition : state.scenePosition
                frames[target] = TrackingFrame(state: state, nextPosition: next, interpolates: live,
                                               path: try state.orbitRing(), pathDate: date)
            } catch { /* Keep other satellites visible when one cannot propagate. */ }
        }
    }

    func position(at date: Date) -> SIMD3<Float> {
        let fraction = interpolates ? Float(min(max(date.timeIntervalSince(animationDate ?? state.date), 0), 1)) : 0
        return state.scenePosition + (nextPosition - state.scenePosition) * fraction
    }
    func spacePosition(at date: Date, reference: Date) -> SIMD3<Float> {
        let fraction = interpolates ? Float(min(max(date.timeIntervalSince(animationDate ?? state.date), 0), 1)) : 0
        let start = OrbitViewCoordinates.rotate(state.scenePosition, by: OrbitViewCoordinates.angle(at: state.date, reference: reference))
        let end = OrbitViewCoordinates.rotate(nextPosition, by: OrbitViewCoordinates.angle(at: state.date.addingTimeInterval(simulationStep), reference: reference))
        return start + (end - start) * fraction
    }

}


/// Keeps parsed engines and overview paths between ticks, on its own executor.
actor TrackingCalculator {
    struct Work: Sendable {
        var engines = 0
        var states = 0
        var paths = 0
    }
    private var engines: [SatelliteTarget: OrbitEngine] = [:]
    private var frames: [SatelliteTarget: TrackingFrame] = [:]
    private var pathSamples: [SatelliteTarget: Int] = [:]
    private(set) var lastWork = Work()

    func snapshot(_ cached: [SatelliteTarget: CachedOrbit], targets: Set<SatelliteTarget>,
                  selected: SatelliteTarget?, at date: Date, freshnessDate: Date,
                  live: Bool, animationDate: Date? = nil, playbackRate: Double = 1) -> [SatelliteTarget: TrackingFrame] {
        lastWork = Work()
        for target in Array(engines.keys) where cached[target]?.elements != engines[target]?.elements {
            engines[target] = nil; frames[target] = nil; pathSamples[target] = nil
        }
        for target in targets {
            guard let record = cached[target], record.elements.catalogID == target.id else { continue }
            do {
                if engines[target] == nil {
                    engines[target] = try OrbitEngine(elements: record.elements)
                    lastWork.engines += 1
                }
                let engine = engines[target]!
                guard OrbitFreshness.assess(epoch: engine.epoch, at: freshnessDate) != .expired else {
                    frames[target] = nil; continue
                }
                let samples = target == selected ? 180 : 60
                let previous = frames[target]
                if !live, let previous, previous.state.date == date,
                   !previous.interpolates, pathSamples[target] == samples { continue }
                let state = try engine.state(at: date)
                let next = live ? try engine.state(at: date.addingTimeInterval(playbackRate)).scenePosition : state.scenePosition
                lastWork.states += live ? 2 : 1
                let renewPath = previous == nil || pathSamples[target] != samples ||
                    abs(date.timeIntervalSince(previous!.pathDate)) >= (target == selected ? 300 : 600)
                let path = renewPath ? try state.orbitRing(samples: samples) : previous!.path
                if renewPath { lastWork.paths += 1 }
                frames[target] = TrackingFrame(state: state, nextPosition: next, interpolates: live,
                                              path: path, pathDate: renewPath ? date : previous!.pathDate, animationDate: animationDate, simulationStep: playbackRate)
                pathSamples[target] = samples
            } catch { frames[target] = nil }
        }
        return frames.filter { target, frame in
            guard let epoch = engines[target]?.epoch else { return false }
            return OrbitFreshness.assess(epoch: epoch, at: freshnessDate) != .expired
        }
    }
}
