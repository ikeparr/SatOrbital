import Foundation
import simd

/// Sea-level, zero-elevation line of sight on the WGS84 ellipsoid.
/// No terrain, refraction, sunlight, brightness, or observer altitude model.
struct VisibilityFootprint: Sendable {
    let surfacePoints: [SIMD3<Double>]
    let indices: [UInt32]
    let boundary: [SIMD3<Double>]

    static func make(satellite: SIMD3<Double>, samples: Int = 96, rings: Int = 12) throws -> Self {
        guard samples >= 8, samples <= 720, rings >= 1, rings <= 96,
              satellite.x.isFinite, satellite.y.isFinite, satellite.z.isFinite else {
            throw OrbitError.invalidElements
        }
        let a = EarthCoordinates.equatorialRadius
        let axes = SIMD3(a, a, a * (1 - EarthCoordinates.flattening))
        // Scaling the ellipsoid to a unit sphere makes its tangent condition
        // u · (satellite / axes) = 1. The boundary is a small circle on that sphere.
        let scaled = satellite / axes
        let radius = simd_length(scaled)
        guard radius > 1, radius.isFinite else { throw OrbitError.invalidElements }
        let center = scaled / radius
        let reference = abs(center.z) < 0.9 ? SIMD3<Double>(0, 0, 1) : SIMD3<Double>(1, 0, 0)
        let east = simd_normalize(simd_cross(reference, center))
        let north = simd_cross(center, east)
        let angle = acos(1 / radius)
        var points = [center * axes]
        var indices: [UInt32] = []
        for ring in 1...rings {
            let theta = angle * Double(ring) / Double(rings)
            for sample in 0..<samples {
                let phi = 2 * Double.pi * Double(sample) / Double(samples)
                points.append((center * cos(theta) + (east * cos(phi) + north * sin(phi)) * sin(theta)) * axes)
                let current = UInt32(1 + (ring - 1) * samples + sample)
                let next = UInt32(1 + (ring - 1) * samples + (sample + 1) % samples)
                if ring == 1 { indices += [0, current, next] }
                else {
                    let previous = current - UInt32(samples)
                    let previousNext = next - UInt32(samples)
                    indices += [previous, current, next, previous, next, previousNext]
                }
            }
        }
        var boundary = Array(points.suffix(samples))
        boundary.append(boundary[0])
        return .init(surfacePoints: points, indices: indices, boundary: boundary)
    }
}
