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
    var referenceImage: SatelliteImageReference {
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
        case .noaa20:
            return .init(assetName: "NOAA20Photo", caption: "NOAA-20 / JPSS-1 · illustration", credit: "NASA",
                         source: "https://commons.wikimedia.org/wiki/File:NOAA-20_JPSS-1_spacecraft_model_1.png")
        }
    }

    private var searchAliases: String {
        switch self {
        case .iss: return "Zarya"
        case .tiangong: return "Tianhe CSS Chinese space station"
        case .hubble: return "HST"
        case .noaa20: return "JPSS1 JPSS-1"
        }
    }

    static func matching(_ query: String) -> [SatelliteTarget] {
        func words(_ value: String) -> [String] {
            value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        }
        let terms = words(query)
        return allCases.filter { target in
            let searchable = words("\(target.name) \(target.subtitle) \(target.id) NORAD \(target.searchAliases)").joined()
            return terms.allSatisfy { searchable.contains($0) }
        }
    }
}
