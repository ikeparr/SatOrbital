import CSGP4
import Foundation
import simd

struct OrbitalState: Sendable {
    let date: Date
    let temePosition: SIMD3<Double>
    let temeVelocity: SIMD3<Double>
    let earthFixedPosition: SIMD3<Double>
    let latitude: Double
    let longitude: Double
    let altitudeKilometers: Double
    var speedKilometersPerSecond: Double {
        sqrt(temeVelocity.x * temeVelocity.x + temeVelocity.y * temeVelocity.y + temeVelocity.z * temeVelocity.z)
    }
    var scenePosition: SIMD3<Float> {
        EarthCoordinates.scenePosition(earthFixedPosition)
    }

    /// Instantaneous two-body ellipse through the SGP4 state, used only for display.
    /// All points share this state's Earth rotation; this is not a future ground track.
    /// The radial basis avoids undefined periapsis angles for a circular orbit.
    func orbitRing(samples: Int = 180) throws -> [SIMD3<Float>] {
        precondition(samples >= 4)
        let mu = 398_600.8 // km³/s²; WGS72, matching the SGP4 propagator.
        let radius = simd_length(temePosition)
        let momentum = simd_cross(temePosition, temeVelocity)
        let momentumSquared = simd_length_squared(momentum)
        guard radius.isFinite, radius > 0, momentumSquared.isFinite, momentumSquared > 0 else {
            throw OrbitError.invalidElements
        }
        let radial = temePosition / radius
        let transverse = simd_cross(momentum / sqrt(momentumSquared), radial)
        let eccentricity = simd_cross(temeVelocity, momentum) / mu - radial
        guard simd_length_squared(eccentricity).isFinite, simd_length_squared(eccentricity) < 1 else {
            throw OrbitError.invalidElements
        }
        let parameter = momentumSquared / mu
        var points = [scenePosition]
        for index in 1..<samples {
            let angle = Double(index) / Double(samples) * 2 * .pi
            let direction = radial * cos(angle) + transverse * sin(angle)
            let position = direction * (parameter / (1 + simd_dot(eccentricity, direction)))
            points.append(EarthCoordinates.scenePosition(EarthCoordinates.earthFixed(position, at: date)))
        }
        points.append(points[0]) // Exact shared seam at the current satellite position.
        return points
    }
}

struct OrbitEngine: Sendable {
    let elements: OrbitalElements
    let epoch: Date

    init(elements: OrbitalElements) throws {
        try elements.validate()
        guard let epoch = elements.epoch else { throw OrbitError.invalidElements }
        self.elements = elements
        self.epoch = epoch
    }

    func state(at date: Date) throws -> OrbitalState {
        let days = floor(epoch.timeIntervalSince1970 / 86_400)
        let fractionalDay = (epoch.timeIntervalSince1970 - days * 86_400) / 86_400
        let e = elements
        let input = SATElements(
            epochJD: 2_440_587.5 + days, epochFraction: fractionalDay,
            meanMotion: e.meanMotion, eccentricity: e.eccentricity, inclination: e.inclination,
            ascendingNode: e.ascendingNode, argumentOfPericenter: e.argumentOfPericenter,
            meanAnomaly: e.meanAnomaly, bstar: e.bstar,
            meanMotionDot: e.meanMotionDot, meanMotionDDot: e.meanMotionDDot
        )
        var output = SATState()
        let status = sat_propagate(input, date.timeIntervalSince(epoch) / 60, &output)
        guard status == 0 else { throw OrbitError.propagation(status) }
        let position = SIMD3(output.x, output.y, output.z)
        let fixed = EarthCoordinates.earthFixed(position, at: date)
        let geographic = EarthCoordinates.geodetic(fixed)
        guard geographic.altitude.isFinite, geographic.altitude > 0 else {
            throw OrbitError.propagation(6)
        }
        return OrbitalState(date: date, temePosition: position,
                            temeVelocity: SIMD3(output.vx, output.vy, output.vz),
                            earthFixedPosition: fixed, latitude: geographic.latitude,
                            longitude: geographic.longitude, altitudeKilometers: geographic.altitude)
    }
}

enum EarthCoordinates {
    static let equatorialRadius = 6_378.137
    static let flattening = 1 / 298.257223563
    static let eccentricitySquared = flattening * (2 - flattening)

    /// Vallado GMST. UTC approximates UT1 here; polar motion is omitted.
    /// These sub-kilometer orientation effects are below this globe's display resolution.
    static func siderealAngle(at date: Date) -> Double {
        let jd = date.timeIntervalSince1970 / 86_400 + 2_440_587.5
        let t = (jd - 2_451_545.0) / 36_525
        let seconds = 67_310.54841 + (876_600 * 3_600 + 8_640_184.812866) * t
            + 0.093104 * t * t - 0.0000062 * t * t * t
        let angle = (seconds * .pi / 43_200).truncatingRemainder(dividingBy: 2 * .pi)
        return angle < 0 ? angle + 2 * .pi : angle
    }

    static func earthFixed(_ p: SIMD3<Double>, at date: Date) -> SIMD3<Double> {
        let angle = siderealAngle(at: date)
        return [cos(angle) * p.x + sin(angle) * p.y, -sin(angle) * p.x + cos(angle) * p.y, p.z]
    }

    static func scenePosition(_ p: SIMD3<Double>) -> SIMD3<Float> {
        // ECEF: X = Greenwich, Y = 90°E, Z = north.
        // RealityKit: +X east at Greenwich, +Y north, +Z Greenwich.
        SIMD3(Float(p.y), Float(p.z), Float(p.x)) / Float(equatorialRadius)
    }

    static func geodetic(_ p: SIMD3<Double>) -> (latitude: Double, longitude: Double, altitude: Double) {
        let horizontal = hypot(p.x, p.y)
        let longitude = atan2(p.y, p.x)
        if horizontal < 1e-9 {
            let polarRadius = equatorialRadius * (1 - flattening)
            return (p.z >= 0 ? 90 : -90, 0, abs(p.z) - polarRadius)
        }
        var latitude = atan2(p.z, horizontal * (1 - eccentricitySquared))
        for _ in 0..<12 {
            let n = equatorialRadius / sqrt(1 - eccentricitySquared * pow(sin(latitude), 2))
            let next = atan2(p.z + n * eccentricitySquared * sin(latitude), horizontal)
            if abs(next - latitude) < 1e-12 { latitude = next; break }
            latitude = next
        }
        let n = equatorialRadius / sqrt(1 - eccentricitySquared * pow(sin(latitude), 2))
        let altitude = horizontal / cos(latitude) - n
        return (latitude * 180 / .pi, longitude * 180 / .pi, altitude)
    }
}
