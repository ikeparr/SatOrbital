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

/// A curated selection of current public catalog records. Identity is the NORAD ID.
struct SatelliteTarget: Hashable, CaseIterable, Identifiable, Sendable {
    let id: Int
    let name: String
    let subtitle: String
    let category: String
    let aliases: String
    var rawValue: Int { id }
    private init(id: Int, name: String, subtitle: String, category: String, aliases: String = "") {
        self.id = id; self.name = name; self.subtitle = subtitle
        self.category = category; self.aliases = aliases
    }
    init?(rawValue: Int) {
        guard let target = Self.allCases.first(where: { $0.id == rawValue }) else { return nil }
        self = target
    }
    static let iss = Self(id: 25544, name: "ISS", subtitle: "International Space Station", category: "station", aliases: "Zarya")
    static let tiangong = Self(id: 48274, name: "Tiangong", subtitle: "China’s space station", category: "station", aliases: "Tianhe CSS")
    static let hubble = Self(id: 20580, name: "Hubble", subtitle: "Hubble Space Telescope", category: "science", aliases: "HST")
    static let noaa20 = Self(id: 43013, name: "NOAA-20", subtitle: "Weather and Earth observation", category: "weather", aliases: "JPSS1 JPSS-1")
    static let landsat8 = Self(id: 39084, name: "Landsat 8", subtitle: "NASA / USGS · Earth observation", category: "earth", aliases: "LDCM")
    static let landsat9 = Self(id: 49260, name: "Landsat 9", subtitle: "NASA / USGS · Earth observation", category: "earth", aliases: "")
    static let starlink100759 = Self(id: 100759, name: "STARLINK-38399", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX communications internet broadband")
    static let starlink100760 = Self(id: 100760, name: "STARLINK-38383", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX communications internet broadband")
    static let starlink100765 = Self(id: 100765, name: "STARLINK-38446", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX communications internet broadband")
    static let starlink100767 = Self(id: 100767, name: "STARLINK-38448", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX communications internet broadband")
    static let starlink100768 = Self(id: 100768, name: "STARLINK-38450", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX communications internet broadband")
    static let starlink100769 = Self(id: 100769, name: "STARLINK-38388", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX communications internet broadband")
    static let starlink100770 = Self(id: 100770, name: "STARLINK-38301", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX communications internet broadband")
    static let starlink100774 = Self(id: 100774, name: "STARLINK-38447", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX communications internet broadband")
    static let starlink100777 = Self(id: 100777, name: "STARLINK-38409", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX communications internet broadband")
    static let allCases: [Self] = [
        .iss,
        .tiangong,
        .hubble,
        .noaa20,
        .landsat8,
        .landsat9,
        .starlink100759,
        .starlink100760,
        .starlink100765,
        .starlink100767,
        .starlink100768,
        .starlink100769,
        .starlink100770,
        .starlink100774,
        .starlink100777,
        Self(id: 42956, name: "IRIDIUM 100", subtitle: "Iridium · Mobile communications", category: "communications", aliases: "IRIDIUM "),
        Self(id: 41920, name: "IRIDIUM 102", subtitle: "Iridium · Mobile communications", category: "communications", aliases: "IRIDIUM "),
        Self(id: 41917, name: "IRIDIUM 106", subtitle: "Iridium · Mobile communications", category: "communications", aliases: "IRIDIUM "),
        Self(id: 41924, name: "IRIDIUM 108", subtitle: "Iridium · Mobile communications", category: "communications", aliases: "IRIDIUM "),
        Self(id: 42803, name: "IRIDIUM 113", subtitle: "Iridium · Mobile communications", category: "communications", aliases: "IRIDIUM "),
        Self(id: 42807, name: "IRIDIUM 118", subtitle: "Iridium · Mobile communications", category: "communications", aliases: "IRIDIUM "),
        Self(id: 42959, name: "IRIDIUM 119", subtitle: "Iridium · Mobile communications", category: "communications", aliases: "IRIDIUM "),
        Self(id: 42810, name: "IRIDIUM 124", subtitle: "Iridium · Mobile communications", category: "communications", aliases: "IRIDIUM "),
        Self(id: 42962, name: "IRIDIUM 136", subtitle: "Iridium · Mobile communications", category: "communications", aliases: "IRIDIUM "),
        Self(id: 43071, name: "IRIDIUM 138", subtitle: "Iridium · Mobile communications", category: "communications", aliases: "IRIDIUM "),
        Self(id: 43254, name: "IRIDIUM 146", subtitle: "Iridium · Mobile communications", category: "communications", aliases: "IRIDIUM "),
        Self(id: 43480, name: "IRIDIUM 147", subtitle: "Iridium · Mobile communications", category: "communications", aliases: "IRIDIUM "),
        Self(id: 43250, name: "IRIDIUM 149", subtitle: "Iridium · Mobile communications", category: "communications", aliases: "IRIDIUM "),
        Self(id: 43257, name: "IRIDIUM 150", subtitle: "Iridium · Mobile communications", category: "communications", aliases: "IRIDIUM "),
        Self(id: 43074, name: "IRIDIUM 151", subtitle: "Iridium · Mobile communications", category: "communications", aliases: "IRIDIUM "),
        Self(id: 43078, name: "IRIDIUM 153", subtitle: "Iridium · Mobile communications", category: "communications", aliases: "IRIDIUM "),
        Self(id: 43576, name: "IRIDIUM 156", subtitle: "Iridium · Mobile communications", category: "communications", aliases: "IRIDIUM "),
        Self(id: 43569, name: "IRIDIUM 160", subtitle: "Iridium · Mobile communications", category: "communications", aliases: "IRIDIUM "),
        Self(id: 43572, name: "IRIDIUM 165", subtitle: "Iridium · Mobile communications", category: "communications", aliases: "IRIDIUM "),
        Self(id: 43926, name: "IRIDIUM 169", subtitle: "Iridium · Mobile communications", category: "communications", aliases: "IRIDIUM "),
        Self(id: 43929, name: "IRIDIUM 171", subtitle: "Iridium · Mobile communications", category: "communications", aliases: "IRIDIUM "),
        Self(id: 56727, name: "IRIDIUM 177", subtitle: "Iridium · Mobile communications", category: "communications", aliases: "IRIDIUM "),
        Self(id: 56730, name: "IRIDIUM 179", subtitle: "Iridium · Mobile communications", category: "communications", aliases: "IRIDIUM "),
        Self(id: 43922, name: "IRIDIUM 180", subtitle: "Iridium · Mobile communications", category: "communications", aliases: "IRIDIUM "),
        Self(id: 44057, name: "ONEWEB-0012", subtitle: "OneWeb · Broadband communications", category: "communications", aliases: "ONEWEB-"),
        Self(id: 45155, name: "ONEWEB-0051", subtitle: "OneWeb · Broadband communications", category: "communications", aliases: "ONEWEB-"),
        Self(id: 45443, name: "ONEWEB-0055", subtitle: "OneWeb · Broadband communications", category: "communications", aliases: "ONEWEB-"),
        Self(id: 47271, name: "ONEWEB-0125", subtitle: "OneWeb · Broadband communications", category: "communications", aliases: "ONEWEB-"),
        Self(id: 48047, name: "ONEWEB-0150", subtitle: "OneWeb · Broadband communications", category: "communications", aliases: "ONEWEB-"),
        Self(id: 48075, name: "ONEWEB-0178", subtitle: "OneWeb · Broadband communications", category: "communications", aliases: "ONEWEB-"),
        Self(id: 48236, name: "ONEWEB-0197", subtitle: "OneWeb · Broadband communications", category: "communications", aliases: "ONEWEB-"),
        Self(id: 48785, name: "ONEWEB-0240", subtitle: "OneWeb · Broadband communications", category: "communications", aliases: "ONEWEB-"),
        Self(id: 48978, name: "ONEWEB-0260", subtitle: "OneWeb · Broadband communications", category: "communications", aliases: "ONEWEB-"),
        Self(id: 49079, name: "ONEWEB-0289", subtitle: "OneWeb · Broadband communications", category: "communications", aliases: "ONEWEB-"),
        Self(id: 49108, name: "ONEWEB-0330", subtitle: "OneWeb · Broadband communications", category: "communications", aliases: "ONEWEB-"),
        Self(id: 49213, name: "ONEWEB-0348", subtitle: "OneWeb · Broadband communications", category: "communications", aliases: "ONEWEB-"),
        Self(id: 49300, name: "ONEWEB-0374", subtitle: "OneWeb · Broadband communications", category: "communications", aliases: "ONEWEB-"),
        Self(id: 50482, name: "ONEWEB-0402", subtitle: "OneWeb · Broadband communications", category: "communications", aliases: "ONEWEB-"),
        Self(id: 51628, name: "ONEWEB-0425", subtitle: "OneWeb · Broadband communications", category: "communications", aliases: "ONEWEB-"),
        Self(id: 54114, name: "ONEWEB-0492", subtitle: "OneWeb · Broadband communications", category: "communications", aliases: "ONEWEB-"),
        Self(id: 54142, name: "ONEWEB-0524", subtitle: "OneWeb · Broadband communications", category: "communications", aliases: "ONEWEB-"),
        Self(id: 56060, name: "ONEWEB-0559", subtitle: "OneWeb · Broadband communications", category: "communications", aliases: "ONEWEB-"),
        Self(id: 55150, name: "ONEWEB-0571", subtitle: "OneWeb · Broadband communications", category: "communications", aliases: "ONEWEB-"),
        Self(id: 54663, name: "ONEWEB-0597", subtitle: "OneWeb · Broadband communications", category: "communications", aliases: "ONEWEB-"),
        Self(id: 55822, name: "ONEWEB-0662", subtitle: "OneWeb · Broadband communications", category: "communications", aliases: "ONEWEB-"),
        Self(id: 56717, name: "ONEWEB-0681", subtitle: "OneWeb · Broadband communications", category: "communications", aliases: "ONEWEB-"),
        Self(id: 61613, name: "ONEWEB-0708", subtitle: "OneWeb · Broadband communications", category: "communications", aliases: "ONEWEB-"),
        Self(id: 55178, name: "ONEWEB-0717", subtitle: "OneWeb · Broadband communications", category: "communications", aliases: "ONEWEB-"),
        Self(id: 27424, name: "AQUA", subtitle: "Earth observation and remote sensing", category: "earth", aliases: ""),
        Self(id: 63772, name: "BIOMASS", subtitle: "Earth observation and remote sensing", category: "earth", aliases: ""),
        Self(id: 32783, name: "CARTOSAT-2A", subtitle: "Earth observation and remote sensing", category: "earth", aliases: ""),
        Self(id: 36795, name: "CARTOSAT-2B", subtitle: "Earth observation and remote sensing", category: "earth", aliases: ""),
        Self(id: 41599, name: "CARTOSAT-2C", subtitle: "Earth observation and remote sensing", category: "earth", aliases: ""),
        Self(id: 41948, name: "CARTOSAT-2D", subtitle: "Earth observation and remote sensing", category: "earth", aliases: ""),
        Self(id: 42767, name: "CARTOSAT-2E", subtitle: "Earth observation and remote sensing", category: "earth", aliases: ""),
        Self(id: 43111, name: "CARTOSAT-2F", subtitle: "Earth observation and remote sensing", category: "earth", aliases: ""),
        Self(id: 44804, name: "CARTOSAT-3", subtitle: "Earth observation and remote sensing", category: "earth", aliases: ""),
        Self(id: 31598, name: "COSMO-SKYMED 1", subtitle: "Earth observation and remote sensing", category: "earth", aliases: ""),
        Self(id: 32376, name: "COSMO-SKYMED 2", subtitle: "Earth observation and remote sensing", category: "earth", aliases: ""),
        Self(id: 33412, name: "COSMO-SKYMED 3", subtitle: "Earth observation and remote sensing", category: "earth", aliases: ""),
        Self(id: 37216, name: "COSMO-SKYMED 4", subtitle: "Earth observation and remote sensing", category: "earth", aliases: ""),
        Self(id: 36508, name: "CRYOSAT 2", subtitle: "Earth observation and remote sensing", category: "earth", aliases: ""),
        Self(id: 44873, name: "CSG-1", subtitle: "Earth observation and remote sensing", category: "earth", aliases: ""),
        Self(id: 51444, name: "CSG-2", subtitle: "Earth observation and remote sensing", category: "earth", aliases: ""),
        Self(id: 67304, name: "CSG-3", subtitle: "Earth observation and remote sensing", category: "earth", aliases: ""),
        Self(id: 59908, name: "EARTHCARE", subtitle: "Earth observation and remote sensing", category: "earth", aliases: ""),
        Self(id: 54361, name: "EOS-6 (OCEANSAT-3)", subtitle: "Earth observation and remote sensing", category: "earth", aliases: ""),
        Self(id: 43065, name: "GCOM-C (SHIKISAI)", subtitle: "Earth observation and remote sensing", category: "earth", aliases: ""),
        Self(id: 38337, name: "GCOM-W1 (SHIZUKU)", subtitle: "Earth observation and remote sensing", category: "earth", aliases: ""),
        Self(id: 33492, name: "GOSAT (IBUKI)", subtitle: "Earth observation and remote sensing", category: "earth", aliases: ""),
        Self(id: 43672, name: "GOSAT 2 (IBUKI 1)", subtitle: "Earth observation and remote sensing", category: "earth", aliases: ""),
        Self(id: 64694, name: "GOSAT-GW (IBUKI GW)", subtitle: "Earth observation and remote sensing", category: "earth", aliases: ""),
        Self(id: 43476, name: "GRACE-FO 1", subtitle: "Earth observation and remote sensing", category: "earth", aliases: ""),
        Self(id: 43477, name: "GRACE-FO 2", subtitle: "Earth observation and remote sensing", category: "earth", aliases: ""),
        Self(id: 31113, name: "HAIYANG-1B", subtitle: "Earth observation and remote sensing", category: "earth", aliases: ""),
        Self(id: 43609, name: "HAIYANG-1C", subtitle: "Earth observation and remote sensing", category: "earth", aliases: ""),
        Self(id: 45721, name: "HAIYANG-1D", subtitle: "Earth observation and remote sensing", category: "earth", aliases: ""),
        Self(id: 37781, name: "HAIYANG-2A", subtitle: "Earth observation and remote sensing", category: "earth", aliases: ""),
        Self(id: 43655, name: "HAIYANG-2B", subtitle: "Earth observation and remote sensing", category: "earth", aliases: ""),
        Self(id: 46469, name: "HAIYANG-2C", subtitle: "Earth observation and remote sensing", category: "earth", aliases: ""),
        Self(id: 48621, name: "HAIYANG-2D", subtitle: "Earth observation and remote sensing", category: "earth", aliases: ""),
        Self(id: 69737, name: "HAIYANG-2E", subtitle: "Earth observation and remote sensing", category: "earth", aliases: ""),
        Self(id: 58349, name: "HAIYANG-3A", subtitle: "Earth observation and remote sensing", category: "earth", aliases: ""),
        Self(id: 61936, name: "HAIYANG-4 01", subtitle: "Earth observation and remote sensing", category: "earth", aliases: ""),
        Self(id: 43613, name: "ICESAT-2", subtitle: "Earth observation and remote sensing", category: "earth", aliases: ""),
        Self(id: 41240, name: "JASON-3", subtitle: "Earth observation and remote sensing", category: "earth", aliases: ""),
        Self(id: 35931, name: "OCEANSAT-2", subtitle: "Earth observation and remote sensing", category: "earth", aliases: ""),
        Self(id: 58928, name: "PACE", subtitle: "Earth observation and remote sensing", category: "earth", aliases: ""),
        Self(id: 32382, name: "RADARSAT-2", subtitle: "Earth observation and remote sensing", category: "earth", aliases: ""),
        Self(id: 37387, name: "RESOURCESAT-2", subtitle: "Earth observation and remote sensing", category: "earth", aliases: ""),
        Self(id: 41877, name: "RESOURCESAT-2A", subtitle: "Earth observation and remote sensing", category: "earth", aliases: ""),
        Self(id: 43641, name: "SAOCOM 1A", subtitle: "Earth observation and remote sensing", category: "earth", aliases: ""),
        Self(id: 46265, name: "SAOCOM 1B", subtitle: "Earth observation and remote sensing", category: "earth", aliases: ""),
        Self(id: 39086, name: "SARAL", subtitle: "Earth observation and remote sensing", category: "earth", aliases: ""),
        Self(id: 39634, name: "SENTINEL-1A", subtitle: "Earth observation and remote sensing", category: "earth", aliases: ""),
        Self(id: 62261, name: "SENTINEL-1C", subtitle: "Earth observation and remote sensing", category: "earth", aliases: ""),
        Self(id: 66315, name: "SENTINEL-1D", subtitle: "Earth observation and remote sensing", category: "earth", aliases: ""),
        Self(id: 40697, name: "SENTINEL-2A", subtitle: "Earth observation and remote sensing", category: "earth", aliases: ""),
        Self(id: 42063, name: "SENTINEL-2B", subtitle: "Earth observation and remote sensing", category: "earth", aliases: ""),
        Self(id: 60989, name: "SENTINEL-2C", subtitle: "Earth observation and remote sensing", category: "earth", aliases: ""),
        Self(id: 41335, name: "SENTINEL-3A", subtitle: "Earth observation and remote sensing", category: "earth", aliases: ""),
        Self(id: 43437, name: "SENTINEL-3B", subtitle: "Earth observation and remote sensing", category: "earth", aliases: ""),
        Self(id: 100690, name: "SENTINEL-3C", subtitle: "Earth observation and remote sensing", category: "earth", aliases: ""),
        Self(id: 42969, name: "SENTINEL-5P", subtitle: "Earth observation and remote sensing", category: "earth", aliases: ""),
        Self(id: 46984, name: "SENTINEL-6A", subtitle: "Earth observation and remote sensing", category: "earth", aliases: ""),
        Self(id: 66514, name: "SENTINEL-6B", subtitle: "Earth observation and remote sensing", category: "earth", aliases: ""),
        Self(id: 37849, name: "SUOMI NPP", subtitle: "Earth observation and remote sensing", category: "earth", aliases: ""),
        Self(id: 39452, name: "SWARM A", subtitle: "Earth observation and remote sensing", category: "earth", aliases: ""),
        Self(id: 39451, name: "SWARM B", subtitle: "Earth observation and remote sensing", category: "earth", aliases: ""),
        Self(id: 39453, name: "SWARM C", subtitle: "Earth observation and remote sensing", category: "earth", aliases: ""),
        Self(id: 54754, name: "SWOT", subtitle: "Earth observation and remote sensing", category: "earth", aliases: ""),
        Self(id: 25994, name: "TERRA", subtitle: "Earth observation and remote sensing", category: "earth", aliases: ""),
        Self(id: 36287, name: "BEIDOU-2 G1", subtitle: "BeiDou · Navigation", category: "navigation", aliases: "BEIDOU"),
        Self(id: 41586, name: "BEIDOU-2 G7", subtitle: "BeiDou · Navigation", category: "navigation", aliases: "BEIDOU"),
        Self(id: 37384, name: "BEIDOU-2 IGSO-3", subtitle: "BeiDou · Navigation", category: "navigation", aliases: "BEIDOU"),
        Self(id: 56564, name: "BEIDOU-3 G4", subtitle: "BeiDou · Navigation", category: "navigation", aliases: "BEIDOU"),
        Self(id: 44337, name: "BEIDOU-3 IGSO-2", subtitle: "BeiDou · Navigation", category: "navigation", aliases: "BEIDOU"),
        Self(id: 43246, name: "BEIDOU-3 M10", subtitle: "BeiDou · Navigation", category: "navigation", aliases: "BEIDOU"),
        Self(id: 43603, name: "BEIDOU-3 M11", subtitle: "BeiDou · Navigation", category: "navigation", aliases: "BEIDOU"),
        Self(id: 43648, name: "BEIDOU-3 M15", subtitle: "BeiDou · Navigation", category: "navigation", aliases: "BEIDOU"),
        Self(id: 44864, name: "BEIDOU-3 M19", subtitle: "BeiDou · Navigation", category: "navigation", aliases: "BEIDOU"),
        Self(id: 61187, name: "BEIDOU-3 M27", subtitle: "BeiDou · Navigation", category: "navigation", aliases: "BEIDOU"),
        Self(id: 43108, name: "BEIDOU-3 M8", subtitle: "BeiDou · Navigation", category: "navigation", aliases: "BEIDOU"),
        Self(id: 40549, name: "BEIDOU-3S IGSO-1S", subtitle: "BeiDou · Navigation", category: "navigation", aliases: "BEIDOU"),
        Self(id: 37846, name: "GSAT0101 (GALILEO-PFM)", subtitle: "Galileo · Navigation", category: "navigation", aliases: "GSAT0"),
        Self(id: 37847, name: "GSAT0102 (GALILEO-FM2)", subtitle: "Galileo · Navigation", category: "navigation", aliases: "GSAT0"),
        Self(id: 38857, name: "GSAT0103 (GALILEO-FM3)", subtitle: "Galileo · Navigation", category: "navigation", aliases: "GSAT0"),
        Self(id: 41174, name: "GSAT0209 (GALILEO 12)", subtitle: "Galileo · Navigation", category: "navigation", aliases: "GSAT0"),
        Self(id: 41549, name: "GSAT0211 (GALILEO 14)", subtitle: "Galileo · Navigation", category: "navigation", aliases: "GSAT0"),
        Self(id: 43055, name: "GSAT0215 (GALILEO 19)", subtitle: "Galileo · Navigation", category: "navigation", aliases: "GSAT0"),
        Self(id: 43058, name: "GSAT0218 (GALILEO 22)", subtitle: "Galileo · Navigation", category: "navigation", aliases: "GSAT0"),
        Self(id: 43565, name: "GSAT0222 (GALILEO 26)", subtitle: "Galileo · Navigation", category: "navigation", aliases: "GSAT0"),
        Self(id: 49809, name: "GSAT0223 (GALILEO 27)", subtitle: "Galileo · Navigation", category: "navigation", aliases: "GSAT0"),
        Self(id: 61183, name: "GSAT0226 (GALILEO 31)", subtitle: "Galileo · Navigation", category: "navigation", aliases: "GSAT0"),
        Self(id: 61182, name: "GSAT0232 (GALILEO 32)", subtitle: "Galileo · Navigation", category: "navigation", aliases: "GSAT0"),
        Self(id: 67160, name: "GSAT0233 (GALILEO 33)", subtitle: "Galileo · Navigation", category: "navigation", aliases: "GSAT0"),
        Self(id: 24876, name: "NAVSTAR 43 (USA 132)", subtitle: "GPS · Navigation", category: "navigation", aliases: "NAVSTAR"),
        Self(id: 26605, name: "NAVSTAR 49 (USA 154)", subtitle: "GPS · Navigation", category: "navigation", aliases: "NAVSTAR"),
        Self(id: 28129, name: "NAVSTAR 53 (USA 175)", subtitle: "GPS · Navigation", category: "navigation", aliases: "NAVSTAR"),
        Self(id: 28874, name: "NAVSTAR 57 (USA 183)", subtitle: "GPS · Navigation", category: "navigation", aliases: "NAVSTAR"),
        Self(id: 32260, name: "NAVSTAR 60 (USA 196)", subtitle: "GPS · Navigation", category: "navigation", aliases: "NAVSTAR"),
        Self(id: 34661, name: "NAVSTAR 63 (USA 203)", subtitle: "GPS · Navigation", category: "navigation", aliases: "NAVSTAR"),
        Self(id: 39166, name: "NAVSTAR 68 (USA 242)", subtitle: "GPS · Navigation", category: "navigation", aliases: "NAVSTAR"),
        Self(id: 40105, name: "NAVSTAR 71 (USA 256)", subtitle: "GPS · Navigation", category: "navigation", aliases: "NAVSTAR"),
        Self(id: 41019, name: "NAVSTAR 75 (USA 265)", subtitle: "GPS · Navigation", category: "navigation", aliases: "NAVSTAR"),
        Self(id: 44506, name: "NAVSTAR 78 (USA 293)", subtitle: "GPS · Navigation", category: "navigation", aliases: "NAVSTAR"),
        Self(id: 48859, name: "NAVSTAR 81 (USA 319)", subtitle: "GPS · Navigation", category: "navigation", aliases: "NAVSTAR"),
        Self(id: 67588, name: "NAVSTAR 85 (USA 581)", subtitle: "GPS · Navigation", category: "navigation", aliases: "NAVSTAR"),
        Self(id: 44874, name: "CHEOPS", subtitle: "Space and Earth science", category: "science", aliases: ""),
        Self(id: 49954, name: "IXPE", subtitle: "Space and Earth science", category: "science", aliases: ""),
        Self(id: 38358, name: "NUSTAR", subtitle: "Space and Earth science", category: "science", aliases: ""),
        Self(id: 26958, name: "PROBA-1", subtitle: "Space and Earth science", category: "science", aliases: ""),
        Self(id: 36037, name: "PROBA-2", subtitle: "Space and Earth science", category: "science", aliases: ""),
        Self(id: 39159, name: "PROBA-V", subtitle: "Space and Earth science", category: "science", aliases: ""),
        Self(id: 63182, name: "SPHEREX (MIDEX 9)", subtitle: "Space and Earth science", category: "science", aliases: ""),
        Self(id: 57800, name: "XRISM", subtitle: "Space and Earth science", category: "science", aliases: ""),
        Self(id: 44714, name: "STARLINK-1008", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 59758, name: "STARLINK-11105 [DTC]", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 60048, name: "STARLINK-11135 [DTC]", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 60406, name: "STARLINK-11150 [DTC]", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 60124, name: "STARLINK-11161 [DTC]", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 61540, name: "STARLINK-11350 [DTC]", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 62884, name: "STARLINK-11437 [DTC]", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 62068, name: "STARLINK-11467 [DTC]", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 62521, name: "STARLINK-11528 [DTC]", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 64237, name: "STARLINK-11670 [DTC]", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 45368, name: "STARLINK-1276", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 45679, name: "STARLINK-1394", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 46075, name: "STARLINK-1551", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 47391, name: "STARLINK-2112", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 48022, name: "STARLINK-2298", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 47806, name: "STARLINK-2387", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 48286, name: "STARLINK-2547", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 48375, name: "STARLINK-2603", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 48470, name: "STARLINK-2675", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 48651, name: "STARLINK-2731", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 56304, name: "STARLINK-30099", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 56843, name: "STARLINK-30137", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 57605, name: "STARLINK-30138", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 57448, name: "STARLINK-30196", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 57683, name: "STARLINK-30295", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 57784, name: "STARLINK-30388", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 57874, name: "STARLINK-30447", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 57943, name: "STARLINK-30456", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 49157, name: "STARLINK-3051", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 58032, name: "STARLINK-30561", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 58094, name: "STARLINK-30574", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 58159, name: "STARLINK-30788", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 58384, name: "STARLINK-30825", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 58227, name: "STARLINK-30874", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 58473, name: "STARLINK-30947", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 58544, name: "STARLINK-31048", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 58947, name: "STARLINK-31116", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 58674, name: "STARLINK-31124", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 58767, name: "STARLINK-31140", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 59034, name: "STARLINK-31231", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 58853, name: "STARLINK-31238", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 59243, name: "STARLINK-31433", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 59178, name: "STARLINK-31439", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 59859, name: "STARLINK-31442", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 59329, name: "STARLINK-31493", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 49452, name: "STARLINK-3150", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 59470, name: "STARLINK-31546", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 59544, name: "STARLINK-31556", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 59394, name: "STARLINK-31607", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 59623, name: "STARLINK-31763", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 60603, name: "STARLINK-31874", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 59936, name: "STARLINK-31962", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 59695, name: "STARLINK-32104", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 60260, name: "STARLINK-32125", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 60317, name: "STARLINK-32189", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 60940, name: "STARLINK-32251", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 61662, name: "STARLINK-32310", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 61213, name: "STARLINK-32386", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 62206, name: "STARLINK-32448", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 62141, name: "STARLINK-32482", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 61981, name: "STARLINK-32522", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 61724, name: "STARLINK-32528", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 62304, name: "STARLINK-32597", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 61921, name: "STARLINK-32605", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 62452, name: "STARLINK-32656", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 50830, name: "STARLINK-3278", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 62740, name: "STARLINK-32805", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 63039, name: "STARLINK-32811", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 62819, name: "STARLINK-32856", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 62967, name: "STARLINK-32897", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 63097, name: "STARLINK-32923", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 63196, name: "STARLINK-32946", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 50163, name: "STARLINK-3306", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 51147, name: "STARLINK-3352", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 63439, name: "STARLINK-33730", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 63366, name: "STARLINK-33742", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 63587, name: "STARLINK-33830", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 63501, name: "STARLINK-33837", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 63685, name: "STARLINK-33847", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 63779, name: "STARLINK-33881", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 64034, name: "STARLINK-33946", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 63841, name: "STARLINK-34056", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 64115, name: "STARLINK-34067", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 63900, name: "STARLINK-34118", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 63964, name: "STARLINK-34135", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 64172, name: "STARLINK-34233", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 64302, name: "STARLINK-34379", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 64363, name: "STARLINK-34408", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 64438, name: "STARLINK-34465", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 64596, name: "STARLINK-34510", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 51759, name: "STARLINK-3456", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 64700, name: "STARLINK-34560", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 64852, name: "STARLINK-34564", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 64762, name: "STARLINK-34638", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 65364, name: "STARLINK-34729", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 64946, name: "STARLINK-34753", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 65078, name: "STARLINK-34771", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 65203, name: "STARLINK-34914", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 65893, name: "STARLINK-34921", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 65282, name: "STARLINK-35021", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 65480, name: "STARLINK-35040", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 65422, name: "STARLINK-35074", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 65542, name: "STARLINK-35100", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 65740, name: "STARLINK-35130", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 65654, name: "STARLINK-35227", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 66016, name: "STARLINK-35243", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 65833, name: "STARLINK-35345", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 66563, name: "STARLINK-35437", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 66432, name: "STARLINK-35446", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 66157, name: "STARLINK-35594", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 66493, name: "STARLINK-35597", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 66097, name: "STARLINK-35613", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 66218, name: "STARLINK-35722", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 66276, name: "STARLINK-35742", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 66358, name: "STARLINK-35807", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 66621, name: "STARLINK-35847", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 51867, name: "STARLINK-3590", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 66827, name: "STARLINK-35959", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 66884, name: "STARLINK-36057", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 66965, name: "STARLINK-36067", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 67036, name: "STARLINK-36125", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 67108, name: "STARLINK-36208", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 67196, name: "STARLINK-36239", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 67736, name: "STARLINK-36317", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 67900, name: "STARLINK-36361", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 68612, name: "STARLINK-36386", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 67338, name: "STARLINK-36413", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 51987, name: "STARLINK-3644", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 67447, name: "STARLINK-36440", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 67532, name: "STARLINK-36587", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 67844, name: "STARLINK-36598", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 67595, name: "STARLINK-36628", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 67657, name: "STARLINK-36706", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 68069, name: "STARLINK-36766", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 100389, name: "STARLINK-36776", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 52140, name: "STARLINK-3682", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 67957, name: "STARLINK-36829", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 68331, name: "STARLINK-36932", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 68013, name: "STARLINK-36967", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 68144, name: "STARLINK-37020", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 68270, name: "STARLINK-37028", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 68212, name: "STARLINK-37117", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 68520, name: "STARLINK-37126", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 69220, name: "STARLINK-37201", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 68715, name: "STARLINK-37322", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 69159, name: "STARLINK-37343", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 68784, name: "STARLINK-37401", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 100287, name: "STARLINK-37480", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 68895, name: "STARLINK-37527", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 69309, name: "STARLINK-37619", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 69374, name: "STARLINK-37632", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 69028, name: "STARLINK-37634", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 69470, name: "STARLINK-37686", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 100220, name: "STARLINK-37721", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 69547, name: "STARLINK-37881", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 69963, name: "STARLINK-37931", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 69686, name: "STARLINK-37968", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 100124, name: "STARLINK-37991", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 69756, name: "STARLINK-38036", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 100024, name: "STARLINK-38108", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 100454, name: "STARLINK-38334", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 100523, name: "STARLINK-38390", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 100638, name: "STARLINK-38416", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 52341, name: "STARLINK-3843", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 52472, name: "STARLINK-3881", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 52569, name: "STARLINK-3927", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 52644, name: "STARLINK-3985", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 100880, name: "STARLINK-40097", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 53247, name: "STARLINK-4061", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 52834, name: "STARLINK-4108", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 52999, name: "STARLINK-4217", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 53172, name: "STARLINK-4299", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 53062, name: "STARLINK-4311", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 53665, name: "STARLINK-4334", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 53494, name: "STARLINK-4340", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 53403, name: "STARLINK-4507", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 55315, name: "STARLINK-4623", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 53738, name: "STARLINK-4662", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 53588, name: "STARLINK-4691", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 53842, name: "STARLINK-4754", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 53923, name: "STARLINK-5004", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 54172, name: "STARLINK-5117", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 54054, name: "STARLINK-5163", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 54858, name: "STARLINK-5407", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 54783, name: "STARLINK-5439", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 55659, name: "STARLINK-5477", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 55385, name: "STARLINK-5556", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 55464, name: "STARLINK-5676", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 55592, name: "STARLINK-5759", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 55786, name: "STARLINK-5823", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 57051, name: "STARLINK-5839", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 55988, name: "STARLINK-5916", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 56463, name: "STARLINK-6051", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 57115, name: "STARLINK-6085", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 56101, name: "STARLINK-6095", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 56384, name: "STARLINK-6153", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 56774, name: "STARLINK-6190", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 57236, name: "STARLINK-6315", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 56527, name: "STARLINK-6335", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 57349, name: "STARLINK-6376", subtitle: "SpaceX · Starlink broadband", category: "starlink", aliases: "SpaceX internet communications"),
        Self(id: 40367, name: "FENGYUN 2G", subtitle: "Weather and Earth observation", category: "weather", aliases: ""),
        Self(id: 43491, name: "FENGYUN 2H", subtitle: "Weather and Earth observation", category: "weather", aliases: ""),
        Self(id: 32958, name: "FENGYUN 3A", subtitle: "Weather and Earth observation", category: "weather", aliases: ""),
        Self(id: 37214, name: "FENGYUN 3B", subtitle: "Weather and Earth observation", category: "weather", aliases: ""),
        Self(id: 39260, name: "FENGYUN 3C", subtitle: "Weather and Earth observation", category: "weather", aliases: ""),
        Self(id: 43010, name: "FENGYUN 3D", subtitle: "Weather and Earth observation", category: "weather", aliases: ""),
        Self(id: 49008, name: "FENGYUN 3E", subtitle: "Weather and Earth observation", category: "weather", aliases: ""),
        Self(id: 57490, name: "FENGYUN 3F", subtitle: "Weather and Earth observation", category: "weather", aliases: ""),
        Self(id: 65815, name: "FENGYUN 3H", subtitle: "Weather and Earth observation", category: "weather", aliases: ""),
        Self(id: 41882, name: "FENGYUN 4A", subtitle: "Weather and Earth observation", category: "weather", aliases: ""),
        Self(id: 48808, name: "FENGYUN 4B", subtitle: "Weather and Earth observation", category: "weather", aliases: ""),
        Self(id: 67246, name: "FENGYUN 4C", subtitle: "Weather and Earth observation", category: "weather", aliases: ""),
        Self(id: 41866, name: "GOES 16", subtitle: "Weather and Earth observation", category: "weather", aliases: ""),
        Self(id: 43226, name: "GOES 17", subtitle: "Weather and Earth observation", category: "weather", aliases: ""),
        Self(id: 51850, name: "GOES 18", subtitle: "Weather and Earth observation", category: "weather", aliases: ""),
        Self(id: 60133, name: "GOES 19", subtitle: "Weather and Earth observation", category: "weather", aliases: ""),
        Self(id: 40267, name: "HIMAWARI-8", subtitle: "Weather and Earth observation", category: "weather", aliases: ""),
        Self(id: 38552, name: "METEOSAT-10 (MSG-3)", subtitle: "Weather and Earth observation", category: "weather", aliases: ""),
        Self(id: 40732, name: "METEOSAT-11 (MSG-4)", subtitle: "Weather and Earth observation", category: "weather", aliases: ""),
        Self(id: 54743, name: "METEOSAT-12 (MTG-I1)", subtitle: "Weather and Earth observation", category: "weather", aliases: ""),
        Self(id: 28912, name: "METEOSAT-9 (MSG-2)", subtitle: "Weather and Earth observation", category: "weather", aliases: ""),
        Self(id: 38771, name: "METOP-B", subtitle: "Weather and Earth observation", category: "weather", aliases: ""),
        Self(id: 43689, name: "METOP-C", subtitle: "Weather and Earth observation", category: "weather", aliases: ""),
        Self(id: 65159, name: "METOP-SGA1", subtitle: "Weather and Earth observation", category: "weather", aliases: ""),
        Self(id: 54234, name: "NOAA 21 (JPSS-2)", subtitle: "Weather and Earth observation", category: "weather", aliases: ""),
    ]
}
