import Foundation
import simd

/// A manually chosen sea-level observer; no device location is collected.
struct ObserverPlace: Codable, Equatable, Sendable {
    let name: String
    let latitude: Double
    let longitude: Double

    init?(name: String, latitude: Double, longitude: Double) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 80,
              latitude.isFinite, longitude.isFinite,
              (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
        self.name = trimmed
        self.latitude = latitude
        self.longitude = longitude
    }

    var scenePosition: SIMD3<Float> { EarthCoordinates.scenePosition(earthFixedPosition) }

    var earthFixedPosition: SIMD3<Double> {
        let lat = latitude * .pi / 180, lon = longitude * .pi / 180
        let n = EarthCoordinates.equatorialRadius / sqrt(1 - EarthCoordinates.eccentricitySquared * pow(sin(lat), 2))
        return [n * cos(lat) * cos(lon), n * cos(lat) * sin(lon),
                n * (1 - EarthCoordinates.eccentricitySquared) * sin(lat)]
    }

    var coordinates: String { String(format: "%.3f° %@ · %.3f° %@", abs(latitude), latitude < 0 ? "S" : "N", abs(longitude), longitude < 0 ? "W" : "E") }
    var storedValue: String {
        guard let data = try? JSONEncoder().encode(self) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func restore(_ value: String) -> Self? {
        guard let decoded = try? JSONDecoder().decode(Self.self, from: Data(value.utf8)) else { return nil }
        // Synthesized decoding bypasses the validating initializer.
        return Self(name: decoded.name, latitude: decoded.latitude, longitude: decoded.longitude)
    }
}

enum EarthPlacePicking {
    /// Nearest forward ray intersection with the WGS84 globe, in scene units.
    /// Undo Earth's world rotation before converting the hit to geographic coordinates.
    static func place(origin: SIMD3<Float>, direction: SIMD3<Float>, earthAngle: Float) -> ObserverPlace? {
        guard origin.x.isFinite, origin.y.isFinite, origin.z.isFinite,
              direction.x.isFinite, direction.y.isFinite, direction.z.isFinite, earthAngle.isFinite else { return nil }
        let axes = SIMD3<Double>(1, 1 - EarthCoordinates.flattening, 1)
        let o = SIMD3<Double>(Double(origin.x), Double(origin.y), Double(origin.z)) / axes
        let d = SIMD3<Double>(Double(direction.x), Double(direction.y), Double(direction.z)) / axes
        let a = simd_dot(d, d), b = 2 * simd_dot(o, d), c = simd_dot(o, o) - 1
        guard a > 0, a.isFinite else { return nil }
        let discriminant = b * b - 4 * a * c
        guard discriminant >= 0 else { return nil }
        let roots = [(-b - sqrt(discriminant)) / (2 * a), (-b + sqrt(discriminant)) / (2 * a)]
        guard let t = roots.filter({ $0 >= 0 }).min() else { return nil }
        let hit = origin + direction * Float(t)
        let fixed = OrbitViewCoordinates.rotate(hit, by: -earthAngle)
        let radius = EarthCoordinates.equatorialRadius
        let geographic = EarthCoordinates.geodetic([Double(fixed.z) * radius, Double(fixed.x) * radius, Double(fixed.y) * radius])
        return ObserverPlace(name: "Selected place", latitude: geographic.latitude, longitude: geographic.longitude)
    }
}
