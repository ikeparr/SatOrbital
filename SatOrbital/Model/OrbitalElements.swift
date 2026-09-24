import Foundation

enum OrbitError: LocalizedError {
    case invalidElements, unsupportedFrame, propagation(Int32), invalidResponse, http(Int), expired
    var errorDescription: String? {
        switch self {
        case .invalidElements: "The orbital data is invalid. Keeping the last usable data."
        case .unsupportedFrame: "This orbital-data format is not supported."
        case .propagation: "A reliable position could not be calculated from these elements."
        case .invalidResponse: "The provider returned an unreadable response."
        case .http(let status): "The data provider is unavailable (HTTP \(status))."
        case .expired: "Orbital data is over seven days from its epoch. Connect to update it."
        }
    }
}

/// CelesTrak's JSON GP fields (OMM keywords). Default frame values are specified
/// by the provider when omitted; explicit incompatible values are rejected.
struct OrbitalElements: Codable, Equatable, Sendable {
    let name: String
    let catalogID: Int
    let epochString: String
    let meanMotion: Double
    let eccentricity: Double
    let inclination: Double
    let ascendingNode: Double
    let argumentOfPericenter: Double
    let meanAnomaly: Double
    let bstar: Double
    let meanMotionDot: Double
    let meanMotionDDot: Double
    var referenceFrame: String? = nil
    var timeSystem: String? = nil
    var theory: String? = nil
    var center: String? = nil

    enum CodingKeys: String, CodingKey {
        case name = "OBJECT_NAME", catalogID = "NORAD_CAT_ID", epochString = "EPOCH"
        case meanMotion = "MEAN_MOTION", eccentricity = "ECCENTRICITY", inclination = "INCLINATION"
        case ascendingNode = "RA_OF_ASC_NODE", argumentOfPericenter = "ARG_OF_PERICENTER"
        case meanAnomaly = "MEAN_ANOMALY", bstar = "BSTAR"
        case meanMotionDot = "MEAN_MOTION_DOT", meanMotionDDot = "MEAN_MOTION_DDOT"
        case referenceFrame = "REF_FRAME", timeSystem = "TIME_SYSTEM"
        case theory = "MEAN_ELEMENT_THEORY", center = "CENTER_NAME"
    }

    var epoch: Date? { UTCDate.parse(epochString) }
    var periodSeconds: Double { 86_400 / meanMotion }

    func validate() throws {
        guard epoch != nil, catalogID > 0, !name.isEmpty,
              [meanMotion, eccentricity, inclination, ascendingNode, argumentOfPericenter,
               meanAnomaly, bstar, meanMotionDot, meanMotionDDot].allSatisfy(\.isFinite),
              meanMotion > 0, meanMotion < 20,
              (0..<1).contains(eccentricity), (0...180).contains(inclination),
              (0..<360).contains(ascendingNode), (0..<360).contains(argumentOfPericenter),
              (0..<360).contains(meanAnomaly), abs(bstar) < 10 else {
            throw OrbitError.invalidElements
        }
        guard referenceFrame == nil || referenceFrame == "TEME",
              timeSystem == nil || timeSystem == "UTC",
              theory == nil || theory == "SGP4",
              center == nil || center == "EARTH" else { throw OrbitError.unsupportedFrame }
    }

    static func decodeISS(_ data: Data) throws -> OrbitalElements {
        try decode(data, catalogID: 25544)
    }

    static func decode(_ data: Data, catalogID: Int) throws -> OrbitalElements {
        guard data.count <= 65_536 else { throw OrbitError.invalidResponse }
        let records = try JSONDecoder().decode([OrbitalElements].self, from: data)
        guard let record = records.filter({ $0.catalogID == catalogID })
            .max(by: { ($0.epoch ?? .distantPast) < ($1.epoch ?? .distantPast) }) else {
            throw OrbitError.invalidElements
        }
        try record.validate()
        return record
    }
}

enum UTCDate {
    static func parse(_ input: String) -> Date? {
        let value = input.hasSuffix("Z") ? input : input + "Z"
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

/// A small curated catalog; IDs identify each object's public CelesTrak record.
enum SatelliteTarget: Int, CaseIterable, Identifiable, Sendable {
    case iss = 25544, tiangong = 48274, hubble = 20580, noaa20 = 43013
    var id: Int { rawValue }
    var name: String {
        switch self {
        case .iss: "ISS"
        case .tiangong: "Tiangong"
        case .hubble: "Hubble"
        case .noaa20: "NOAA-20"
        }
    }
    var subtitle: String {
        switch self {
        case .iss: "International Space Station"
        case .tiangong: "China’s space station"
        case .hubble: "Hubble Space Telescope"
        case .noaa20: "Weather and Earth observation"
        }
    }
}
