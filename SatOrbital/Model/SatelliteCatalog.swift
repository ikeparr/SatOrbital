import Foundation

struct SatelliteImageReference {
    let assetName: String
    let caption: String
    let credit: String
    let source: String
    var license: String? = nil
    var sourceURL: URL { URL(string: source)! }
}

extension SatelliteTarget {
    var referenceImage: SatelliteImageReference? {
        switch self {
        case .iss:
            return .init(assetName: "ISSPhoto", caption: "Archival photograph · 2009", credit: "NASA",
                         source: "https://www.nasa.gov/feature/iss-virtual-tour/")
        case .tiangong:
            return .init(assetName: "TiangongPhoto", caption: "Rear view · 2023", credit: "China Manned Space Engineering Office",
                         source: "https://commons.wikimedia.org/wiki/File:Rear_view_of_Tiangong_Space_Station.jpg",
                         license: "https://creativecommons.org/licenses/by/4.0/")
        case .hubble:
            return .init(assetName: "HubblePhoto", caption: "Archival photograph · 1997", credit: "NASA",
                         source: "https://science.nasa.gov/mission/hubble/observatory/")
        case .landsat8:
            return .init(assetName: "Landsat8Photo", caption: "Landsat 8/9 · spacecraft line illustration", credit: "NASA / Ross Walter",
                         source: "https://commons.wikimedia.org/wiki/File:Landsat_8-9_line_art.png")
        case .landsat9:
            return .init(assetName: "Landsat9Photo", caption: "Landsat 9 · artist’s conception", credit: "NASA / Goddard / Conceptual Image Lab",
                         source: "https://svs.gsfc.nasa.gov/13259/")
        case .noaa20:
            return .init(assetName: "NOAA20Photo", caption: "NOAA-20 / JPSS-1 · illustration", credit: "NASA",
                         source: "https://commons.wikimedia.org/wiki/File:NOAA-20_JPSS-1_spacecraft_model_1.png")
        default:
            guard isStarlink else { return nil }
            return .init(assetName: "StarlinkPhoto", caption: "Representative Starlink illustration · not this individual spacecraft", credit: "Wikideas1 · CC BY 4.0",
                         source: "https://commons.wikimedia.org/wiki/File:Starlink_01.webp",
                         license: "https://creativecommons.org/licenses/by/4.0/")
        }
    }

    var isStarlink: Bool { category == "starlink" }

    static func matching(_ query: String) -> [SatelliteTarget] {
        func words(_ value: String) -> [String] {
            value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        }
        // Keep hyphenated names/aliases together (JPSS-1 must not match JPSS-2
        // merely because a separate digit 1 appears elsewhere in that record).
        let terms = query.components(separatedBy: .whitespacesAndNewlines)
            .map { words($0).joined() }.filter { !$0.isEmpty }
        return allCases.filter { target in
            let searchable = words("\(target.name) \(target.subtitle) \(target.id) NORAD \(target.aliases)").joined()
            return terms.allSatisfy { searchable.contains($0) }
        }
    }
}
