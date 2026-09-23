import Foundation

struct TrackingFrame: Sendable {
    let state: OrbitalState
    let nextPosition: SIMD3<Float>
    let interpolates: Bool
    let path: [SIMD3<Float>]
    let pathDate: Date

    func position(at date: Date) -> SIMD3<Float> {
        let fraction = interpolates ? Float(min(max(date.timeIntervalSince(state.date), 0), 1)) : 0
        return state.scenePosition + (nextPosition - state.scenePosition) * fraction
    }
}

