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
    func fetchISS() async throws -> OrbitHTTPResponse
}

struct CelesTrakClient: OrbitHTTPClient {
    func fetchISS() async throws -> OrbitHTTPResponse {
        let url = URL(string: "https://celestrak.org/NORAD/elements/gp.php?CATNR=25544&FORMAT=JSON")!
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("SatOrbital/0.2 (iOS; ISS orbital viewer)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw OrbitError.invalidResponse }
        return OrbitHTTPResponse(data: data, status: response.statusCode,
                                 retryAfter: response.value(forHTTPHeaderField: "Retry-After"))
    }
}

/// A single ISS query, at most once per two hours after success. A durable retry
/// deadline also prevents repeated requests across launches after provider failures.
actor OrbitRepository {
    static let updateInterval: TimeInterval = 7_200
    static let failureInterval: TimeInterval = 600

    private struct Envelope: Codable {
        var version = 1
        var cached: CachedOrbit?
        var nextRequestAt: Date
    }
    private let cacheURL: URL
    private let seed: Data?
    private let client: any OrbitHTTPClient
    private var envelope: Envelope?
    private var fetching = false
    private var notice: String?

    init(cacheURL: URL, seed: Data? = nil, client: any OrbitHTTPClient = CelesTrakClient()) {
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
            let response = try await client.fetchISS()
            guard response.status == 200 else {
                let providerLimit = [403, 429].contains(response.status) ? Self.updateInterval : Self.failureInterval
                let retry = Self.retryDelay(response.retryAfter, now: now)
                envelope?.nextRequestAt = now.addingTimeInterval(max(providerLimit, retry))
                throw OrbitError.http(response.status)
            }
            let elements = try OrbitalElements.decodeISS(response.data)
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
        } else if let seed, let bundled = try? decoder.decode(CachedOrbit.self, from: seed), valid(bundled, at: now) {
            envelope = Envelope(cached: bundled, nextRequestAt: bundled.fetchedAt.addingTimeInterval(Self.updateInterval))
        } else {
            envelope = Envelope(cached: nil, nextRequestAt: .distantPast)
        }
    }

    private func valid(_ cached: CachedOrbit, at now: Date) -> Bool {
        guard cached.elements.catalogID == 25544,
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
