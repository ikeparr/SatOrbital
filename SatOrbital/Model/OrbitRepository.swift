import Foundation

enum OrbitFreshness: String, Sendable {
    case fresh, stale, expired
    static func assess(epoch: Date, at date: Date) -> Self {
        let age = abs(date.timeIntervalSince(epoch))
        if age > 7 * 86_400 { return .expired }
        if age > 2 * 86_400 { return .stale }
        return .fresh
    }
}

struct CachedOrbit: Codable, Sendable {
    let elements: OrbitalElements
    let fetchedAt: Date
    let isBundled: Bool
}

struct OrbitLoadResult: Sendable {
    let cached: CachedOrbit?
    let nextRequestAt: Date
    let notice: String?
}

struct OrbitHTTPResponse: Sendable {
    let data: Data
    let status: Int
    var retryAfter: String? = nil
}

protocol OrbitHTTPClient: Sendable {
    func fetchOrbit(catalogID: Int) async throws -> OrbitHTTPResponse
}

struct CelesTrakClient: OrbitHTTPClient {
    func fetchOrbit(catalogID: Int) async throws -> OrbitHTTPResponse {
        let url = URL(string: "https://celestrak.org/NORAD/elements/gp.php?CATNR=\(catalogID)&FORMAT=JSON")!
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("SatOrbital/0.2 (iOS; satellite orbital viewer)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw OrbitError.invalidResponse }
        return OrbitHTTPResponse(data: data, status: response.statusCode,
                                 retryAfter: response.value(forHTTPHeaderField: "Retry-After"))
    }
}

/// A single satellite query, at most once per 24 hours after success. A durable retry
/// deadline also prevents repeated requests across launches after provider failures.
actor OrbitRepository {
    static let updateInterval: TimeInterval = 86_400
    static let failureInterval: TimeInterval = 86_400

    private struct Envelope: Codable {
        var version = 1
        var cached: CachedOrbit?
        var nextRequestAt: Date
    }
    private let catalogID: Int
    private let cacheURL: URL
    private let seed: Data?
    private let client: any OrbitHTTPClient
    private var envelope: Envelope?
    private var fetching = false
    private var notice: String?

    init(cacheURL: URL, catalogID: Int = 25544, seed: Data? = nil, client: any OrbitHTTPClient = CelesTrakClient()) {
        self.catalogID = catalogID
        self.cacheURL = cacheURL
        self.seed = seed
        self.client = client
    }

    /// Return disk/bundled data immediately, without waiting for a network timeout.
    func current(at now: Date = Date()) -> OrbitLoadResult {
        if envelope == nil { restore(at: now) }
        return result()
    }

    func load(at now: Date = Date()) async -> OrbitLoadResult {
        if envelope == nil { restore(at: now) }
        guard !fetching, now >= (envelope?.nextRequestAt ?? .distantPast) else { return result() }
        fetching = true
        defer { fetching = false }

        // Persist the attempt before suspension, so termination cannot cause a retry loop.
        envelope?.nextRequestAt = now.addingTimeInterval(Self.failureInterval)
        persist()
        do {
            let response = try await client.fetchOrbit(catalogID: catalogID)
            guard response.status == 200 else {
                let providerLimit = [403, 429].contains(response.status) ? Self.updateInterval : Self.failureInterval
                let retry = Self.retryDelay(response.retryAfter, now: now)
                envelope?.nextRequestAt = now.addingTimeInterval(max(providerLimit, retry))
                throw OrbitError.http(response.status)
            }
            let elements = try OrbitalElements.decode(response.data, catalogID: catalogID)
            guard let epoch = elements.epoch, epoch <= now.addingTimeInterval(86_400),
                  OrbitFreshness.assess(epoch: epoch, at: now) != .expired else { throw OrbitError.invalidElements }
            _ = try OrbitEngine(elements: elements).state(at: now)
            envelope?.nextRequestAt = now.addingTimeInterval(Self.updateInterval)
            if let previous = envelope?.cached?.elements.epoch, epoch < previous {
                notice = "The provider returned older elements. Keeping the newer saved data."
            } else {
                envelope?.cached = CachedOrbit(elements: elements, fetchedAt: now, isBundled: false)
                notice = nil
            }
        } catch {
            notice = envelope?.cached == nil
                ? "An orbital update is unavailable. Connect to the internet and retry when available."
                : "Update unavailable. Continuing with saved orbital data."
        }
        persist()
        return result()
    }

    private func restore(at now: Date) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: cacheURL),
           let saved = try? decoder.decode(Envelope.self, from: data), saved.version == 1,
           saved.nextRequestAt.timeIntervalSince1970.isFinite,
           saved.nextRequestAt <= now.addingTimeInterval(86_400),
           saved.cached == nil || valid(saved.cached!, at: now) {
            envelope = saved
            if let fetched = saved.cached?.fetchedAt {
                envelope?.nextRequestAt = max(saved.nextRequestAt, fetched.addingTimeInterval(Self.updateInterval))
            }
        } else if let seed, let bundled = try? decoder.decode(CachedOrbit.self, from: seed), valid(bundled, at: now) {
            envelope = Envelope(cached: bundled, nextRequestAt: bundled.fetchedAt.addingTimeInterval(Self.updateInterval))
        } else {
            envelope = Envelope(cached: nil, nextRequestAt: .distantPast)
        }
    }

    private func valid(_ cached: CachedOrbit, at now: Date) -> Bool {
        guard cached.elements.catalogID == catalogID,
              cached.fetchedAt.timeIntervalSince1970.isFinite,
              cached.fetchedAt <= now.addingTimeInterval(300),
              let epoch = cached.elements.epoch, epoch <= now.addingTimeInterval(86_400) else { return false }
        do { try cached.elements.validate(); return true } catch { return false }
    }

    private func persist() {
        guard let envelope else { return }
        do {
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(envelope).write(to: cacheURL, options: .atomic)
        } catch {
            notice = "Offline storage is unavailable. This session can still use data already loaded."
        }
    }

    private func result() -> OrbitLoadResult {
        OrbitLoadResult(cached: envelope?.cached, nextRequestAt: envelope?.nextRequestAt ?? .distantPast, notice: notice)
    }

    static func retryDelay(_ header: String?, now: Date) -> TimeInterval {
        guard let header else { return 0 }
        if let seconds = TimeInterval(header), seconds.isFinite {
            return min(max(seconds, 0), 86_400)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return min(max(formatter.date(from: header)?.timeIntervalSince(now) ?? 0, 0), 86_400)
    }
}

protocol CatalogHTTPDownloader: Sendable {
    func fetchCatalog() async throws -> OrbitHTTPResponse
}

struct CelesTrakCatalogDownloader: CatalogHTTPDownloader {
    func fetchCatalog() async throws -> OrbitHTTPResponse {
        let url = URL(string: "https://celestrak.org/NORAD/elements/gp.php?GROUP=active&FORMAT=JSON")!
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 40)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("SatOrbital/0.3 (iOS; satellite orbital viewer)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw OrbitError.invalidResponse }
        return OrbitHTTPResponse(data: data, status: response.statusCode,
                                 retryAfter: response.value(forHTTPHeaderField: "Retry-After"))
    }
}

/// One shared, durable group download serves the entire curated catalog.
/// Persist an attempt before downloading, and stop network requests for at least
/// 24 hours after any provider error, including across application launches.
actor CatalogOrbitClient: OrbitHTTPClient {
    static let updateInterval: TimeInterval = 86_400
    private struct Saved: Codable {
        var records: [OrbitalElements]
        var nextRequestAt: Date
        var status: Int
        var attemptedAt: Date? = nil
    }
    private let cacheURL: URL
    private let downloader: any CatalogHTTPDownloader
    private let clock: @Sendable () -> Date
    private var saved: Saved
    private var records: [Int: OrbitalElements]
    private var pending: Task<Void, Never>?

    init(cacheURL: URL, seed: [CachedOrbit] = [], downloader: any CatalogHTTPDownloader = CelesTrakCatalogDownloader(),
         clock: @escaping @Sendable () -> Date = { Date() }) {
        self.cacheURL = cacheURL; self.downloader = downloader; self.clock = clock
        let now = clock()
        let restored = (try? Data(contentsOf: cacheURL)).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
        if let restored, restored.nextRequestAt.timeIntervalSince1970.isFinite,
           restored.nextRequestAt <= now.addingTimeInterval(86_400),
           restored.records.allSatisfy({ (try? $0.validate()) != nil }) {
            saved = restored
            // Older group files stored a two-hour deadline, but not the attempt time.
            let attempted = restored.attemptedAt ?? restored.nextRequestAt.addingTimeInterval(-7_200)
            saved.nextRequestAt = max(restored.nextRequestAt, attempted.addingTimeInterval(Self.updateInterval))
            saved.attemptedAt = attempted
        } else {
            let fetched = seed.map(\.fetchedAt).max() ?? .distantPast
            saved = Saved(records: seed.map(\.elements),
                          nextRequestAt: fetched.addingTimeInterval(Self.updateInterval), status: 200)
        }
        records = Dictionary(saved.records.map { ($0.catalogID, $0) }, uniquingKeysWith: { a, b in
            (a.epoch ?? .distantPast) > (b.epoch ?? .distantPast) ? a : b
        })
    }

    func fetchOrbit(catalogID: Int) async throws -> OrbitHTTPResponse {
        if let pending {
            await pending.value
        } else if clock() >= saved.nextRequestAt {
            saved.attemptedAt = clock()
            saved.nextRequestAt = clock().addingTimeInterval(Self.updateInterval)
            saved.status = 503
            persist()
            let task = Task { await self.downloadCatalog() }
            pending = task
            await task.value
            pending = nil
        }
        guard saved.status == 200 else { return OrbitHTTPResponse(data: Data(), status: saved.status) }
        guard let record = records[catalogID] else { throw OrbitError.invalidElements }
        return OrbitHTTPResponse(data: try JSONEncoder().encode([record]), status: 200)
    }

    private func downloadCatalog() async {
            do {
                let response = try await downloader.fetchCatalog()
                if response.status == 200 {
                    guard response.data.count <= 32_000_000 else { throw OrbitError.invalidResponse }
                    let decoded = try JSONDecoder().decode([OrbitalElements].self, from: response.data)
                    let wanted = Set(SatelliteTarget.allCases.map(\.id))
                    let valid = decoded.filter { wanted.contains($0.catalogID) && (try? $0.validate()) != nil }
                    guard !valid.isEmpty else { throw OrbitError.invalidResponse }
                    // Retain last usable records if a group omits an object or returns older elements.
                    for record in valid {
                        if (record.epoch ?? .distantPast) >= (records[record.catalogID]?.epoch ?? .distantPast) {
                            records[record.catalogID] = record
                        }
                    }
                    saved.records = Array(records.values)
                    saved.status = 200
                } else {
                    saved.status = response.status
                    let retry = OrbitRepository.retryDelay(response.retryAfter, now: clock())
                    saved.nextRequestAt = clock().addingTimeInterval(max(Self.updateInterval, retry))
                }
            } catch {
                saved.status = 503
            }
        persist()
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(saved).write(to: cacheURL, options: .atomic)
        } catch { /* Per-object repositories still provide their saved offline data. */ }
    }
}
