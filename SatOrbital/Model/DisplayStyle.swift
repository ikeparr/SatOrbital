import Foundation

import Foundation

enum SatelliteKind: String, CaseIterable, Identifiable, Sendable {
    case satellite, station, starlink
    var id: String { rawValue }
    var name: String {
        switch self {
        case .satellite: "General satellite"
        case .station: "Space station"
        case .starlink: "Starlink"
        }
    }
    var symbol: String {
        switch self {
        case .satellite: "antenna.radiowaves.left.and.right"
        case .station: "square.grid.2x2.fill"
        case .starlink: "rectangle.split.1x2.fill"
        }
    }
    var orbitColorName: String {
        switch self {
        case .satellite: "Soft cyan"
        case .station: "Warm gold"
        case .starlink: "Violet"
        }
    }
    var description: String {
        switch self {
        case .satellite: "Compact body with two blue solar wings"
        case .station: "Long modules with four gold solar arrays"
        case .starlink: "Flat body with a single violet solar array"
        }
    }
}

extension SatelliteTarget {
    var kind: SatelliteKind {
        if self == .iss || self == .tiangong { return .station }
        return isStarlink ? .starlink : .satellite
    }
}

enum GlobeStyle: String, CaseIterable, Identifiable, Sendable {
    case natural, atlas, blueprint
    var id: String { rawValue }
    var name: String {
        switch self {
        case .natural: "Natural"
        case .atlas: "Atlas"
        case .blueprint: "Blueprint"
        }
    }
    var description: String {
        switch self {
        case .natural: "Earth imagery with day and night shading"
        case .atlas: "Evenly lit Earth imagery with latitude and longitude lines"
        case .blueprint: "Outlined continents, midnight blue oceans, and day/night shading"
        }
    }
}

/// Approximate solar direction using NOAA's fractional-year equations.
/// https://gml.noaa.gov/grad/solcalc/solareqns.PDF
/// Intended for globe illumination, not optical pass predictions.
enum SolarIllumination {
    static func sceneDirection(at date: Date) -> SIMD3<Float> {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = Double(calendar.ordinality(of: .day, in: .year, for: date)!)
        let days = Double(calendar.range(of: .day, in: .year, for: date)!.count)
        let minutes = date.timeIntervalSince(calendar.startOfDay(for: date)) / 60
        let gamma = 2 * Double.pi / days * (day - 1 + (minutes / 60 - 12) / 24)
        let equation = 229.18 * (0.000075 + 0.001868 * cos(gamma) - 0.032077 * sin(gamma)
                               - 0.014615 * cos(2 * gamma) - 0.040849 * sin(2 * gamma))
        let declination = 0.006918 - 0.399912 * cos(gamma) + 0.070257 * sin(gamma)
            - 0.006758 * cos(2 * gamma) + 0.000907 * sin(2 * gamma)
            - 0.002697 * cos(3 * gamma) + 0.00148 * sin(3 * gamma)
        let longitude = (180 - (minutes + equation) / 4) * Double.pi / 180
        // Match Earth-fixed (X,Y,Z) -> scene (Y,Z,X).
        return SIMD3(Float(cos(declination) * sin(longitude)), Float(sin(declination)),
                     Float(cos(declination) * cos(longitude)))
    }
}


enum SatelliteCategory: String, CaseIterable, Identifiable, Sendable {
    case station, starlink, weather, earth, navigation, communications, science
    var id: String { rawValue }
    var name: String {
        switch self {
        case .station: "Space stations"
        case .starlink: "Starlinks"
        case .weather: "Weather"
        case .earth: "Earth observation"
        case .navigation: "Navigation"
        case .communications: "Other communications"
        case .science: "Science"
        }
    }
}

extension SatelliteTarget {
    var filterCategory: SatelliteCategory { SatelliteCategory(rawValue: category) ?? .science }
}


enum OrbitViewMode: String, CaseIterable, Identifiable, Sendable {
    case earthFixed, spaceFixed
    var id: String { rawValue }
    var name: String { self == .earthFixed ? "Earth-fixed" : "Space-fixed" }
    var description: String {
        self == .earthFixed ? "Earth stays facing you while the orbits move around it." : "Orbits stay mostly still while Earth rotates beneath them."
    }
}

enum OrbitShell: String, CaseIterable, Identifiable, Sendable {
    case all, low, higher
    var id: String { rawValue }
    var name: String {
        switch self { case .all: "All"; case .low: "LEO"; case .higher: "Higher" }
    }
    var cameraDistance: Float { self == .higher ? 18 : 4.6 }
    var description: String {
        switch self {
        case .all: "All enabled categories, with a close Earth overview."
        case .low: "Orbits staying below 2,000 km, with a close Earth view."
        case .higher: "Orbits extending above 2,000 km, with a wider view for navigation and geostationary satellites."
        }
    }
    func includes(_ elements: OrbitalElements) -> Bool {
        guard self != .all else { return true }
        let motion = elements.meanMotion * 2 * Double.pi / 86_400
        let semiMajor = pow(398_600.8 / (motion * motion), 1.0 / 3)
        let apogee = semiMajor * (1 + elements.eccentricity) - EarthCoordinates.equatorialRadius
        return self == .low ? apogee <= 2_000 : apogee > 2_000
    }
}

/// Rotate about the north axis in scene (Y,Z,X) coordinates.
/// A positive sidereal angle maps Earth-fixed vectors into the reference TEME frame.
enum OrbitViewCoordinates {
    static func rotate(_ point: SIMD3<Float>, by angle: Float) -> SIMD3<Float> {
        let c = cos(angle), s = sin(angle)
        return SIMD3(c * point.x + s * point.z, point.y, -s * point.x + c * point.z)
    }
    static func angle(at date: Date, reference: Date) -> Float {
        let delta = EarthCoordinates.siderealAngle(at: date) - EarthCoordinates.siderealAngle(at: reference)
        return Float(atan2(sin(delta), cos(delta)))
    }
    static func earthAngle(mode: OrbitViewMode, at date: Date, reference: Date) -> Float {
        mode == .spaceFixed ? angle(at: date, reference: reference) : 0
    }
    static func orbitAngle(mode: OrbitViewMode, at date: Date, reference: Date) -> Float {
        mode == .earthFixed ? -angle(at: date, reference: reference) : 0
    }
}
