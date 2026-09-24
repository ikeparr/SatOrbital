import Foundation

struct TrackingFrame: Sendable {
    let state: OrbitalState
    let nextPosition: SIMD3<Float>
    let interpolates: Bool
    let path: [SIMD3<Float>]
    let pathDate: Date

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
        let fraction = interpolates ? Float(min(max(date.timeIntervalSince(state.date), 0), 1)) : 0
        return state.scenePosition + (nextPosition - state.scenePosition) * fraction
    }
}

