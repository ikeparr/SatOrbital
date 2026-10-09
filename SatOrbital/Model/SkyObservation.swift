import Foundation
import simd

/// Geometric topocentric direction for a sea-level WGS84 observer.
/// ENU uses east, north, up. No refraction, terrain, or optical visibility model.
struct SkyObservation: Equatable, Sendable {
    let direction: SIMD3<Double>
    let azimuthDegrees: Double
    let elevationDegrees: Double
    let rangeKilometers: Double
    var isAboveHorizon: Bool { elevationDegrees > 0 }

    init?(place: ObserverPlace, satellite: SIMD3<Double>) {
        let relative = satellite - place.earthFixedPosition
        let range = simd_length(relative)
        guard range.isFinite, range > 0 else { return nil }
        let lat = place.latitude * .pi / 180, lon = place.longitude * .pi / 180
        let east = -sin(lon) * relative.x + cos(lon) * relative.y
        let north = -sin(lat) * cos(lon) * relative.x - sin(lat) * sin(lon) * relative.y + cos(lat) * relative.z
        let up = cos(lat) * cos(lon) * relative.x + cos(lat) * sin(lon) * relative.y + sin(lat) * relative.z
        direction = SIMD3(east, north, up) / range
        let azimuth = atan2(east, north) * 180 / .pi
        azimuthDegrees = (azimuth + 360).truncatingRemainder(dividingBy: 360)
        elevationDegrees = asin(min(max(direction.z, -1), 1)) * 180 / .pi
        rangeKilometers = range
    }
}

struct SkyViewPose: Equatable, Sendable {
    var heading: Double = 0
    var elevation: Double = 25
    static let verticalFieldOfView: Double = 65

    static func direction(azimuth: Double, elevation: Double) -> SIMD3<Double> {
        let az = azimuth * .pi / 180, el = elevation * .pi / 180
        return [sin(az) * cos(el), cos(az) * cos(el), sin(el)]
    }

    /// Perspective coordinates normalized to the viewport; offscreen points may be returned.
    func project(_ direction: SIMD3<Double>, aspect: Double) -> SIMD2<Double>? {
        guard aspect.isFinite, aspect > 0 else { return nil }
        let az = heading * .pi / 180, el = elevation * .pi / 180
        let forward = Self.direction(azimuth: heading, elevation: elevation)
        let right = SIMD3<Double>(cos(az), -sin(az), 0)
        let up = SIMD3<Double>(-sin(az) * sin(el), -cos(az) * sin(el), cos(el))
        let depth = simd_dot(direction, forward)
        guard depth.isFinite, depth > 0.0001 else { return nil }
        let scale = 2 * tan(Self.verticalFieldOfView * .pi / 360)
        let point = SIMD2(0.5 + simd_dot(direction, right) / (depth * scale * aspect),
                          0.5 - simd_dot(direction, up) / (depth * scale))
        return point.x.isFinite && point.y.isFinite ? point : nil
    }

    var horizonY: Double { 0.5 + tan(elevation * .pi / 180) / (2 * tan(Self.verticalFieldOfView * .pi / 360)) }
}

extension TrackingFrame {
    /// Match the interpolated simulation time while undoing Earth rotation in the shared frame.
    func skyEarthFixedPosition(at wallDate: Date) -> SIMD3<Double> {
        let fraction = interpolates ? min(max(wallDate.timeIntervalSince(animationDate ?? state.date), 0), 1) : 0
        let reference = state.date
        let space = spacePosition(at: wallDate, reference: reference)
        let fixed = OrbitViewCoordinates.rotate(space, by: -OrbitViewCoordinates.angle(
            at: reference.addingTimeInterval(fraction * simulationStep), reference: reference))
        let radius = EarthCoordinates.equatorialRadius
        return [Double(fixed.z) * radius, Double(fixed.x) * radius, Double(fixed.y) * radius]
    }
}
