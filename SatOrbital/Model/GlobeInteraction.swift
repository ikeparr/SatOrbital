import Foundation
import simd

struct GlobeCameraPose: Equatable, Sendable {
    var yaw: Float
    var pitch: Float
    var distance: Float

    static let overview = Self(yaw: 0.25, pitch: 0.28, distance: 4.6)
    var position: SIMD3<Float> {
        SIMD3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch)) * distance
    }

    static func focused(on position: SIMD3<Float>, distance: Float = 2.55) -> Self {
        let direction = simd_normalize(position)
        return Self(yaw: atan2(direction.x, direction.z),
                    pitch: min(max(asin(min(max(direction.y, -1), 1)), -1.55), 1.55), distance: distance)
    }

    func interpolated(to target: Self, fraction: Float) -> Self {
        let t = min(max(fraction, 0), 1)
        let eased = t * t * (3 - 2 * t)
        let delta = atan2(sin(target.yaw - yaw), cos(target.yaw - yaw))
        return Self(yaw: yaw + delta * eased, pitch: pitch + (target.pitch - pitch) * eased,
                    distance: distance + (target.distance - distance) * eased)
    }
}

struct SatellitePickCandidate: Sendable {
    let target: SatelliteTarget
    let point: SIMD2<Float>
    let cameraDistance: Float
}

enum GlobePicking {
    /// Segment/ellipsoid intersection prevents picking a marker through Earth.
    static func isVisible(position: SIMD3<Float>, camera: SIMD3<Float>) -> Bool {
        let axes = SIMD3<Float>(1, Float(1 - EarthCoordinates.flattening), 1)
        let origin = camera / axes
        let delta = (position - camera) / axes
        let lengthSquared = simd_length_squared(delta)
        guard lengthSquared.isFinite, lengthSquared > 0 else { return false }
        let t = min(max(-simd_dot(origin, delta) / lengthSquared, 0), 1)
        return simd_length_squared(origin + delta * t) > 1
    }

    /// A finger-sized target independent of the exaggerated model's geometry.
    static func nearest(to point: SIMD2<Float>, candidates: [SatellitePickCandidate], radius: Float = 26) -> SatelliteTarget? {
        candidates.filter { simd_distance($0.point, point) <= radius }.min {
            let a = simd_distance_squared($0.point, point), b = simd_distance_squared($1.point, point)
            if abs(a - b) > 0.01 { return a < b }
            if $0.cameraDistance != $1.cameraDistance { return $0.cameraDistance < $1.cameraDistance }
            return $0.target.id < $1.target.id
        }?.target
    }
}
