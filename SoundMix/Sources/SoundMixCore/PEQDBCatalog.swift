import Foundation

/// The PEQdB measurement database (peqdb.com/studio), as used by the earphone
/// picker in the profile library.
///
/// How the source site works — reverse engineered, see `reverse-engineering/`:
///
/// * The studio HTML embeds the full catalog as `window.__INDEX__ = {...}`:
///   `IE`/`OE` → source → model → variant → `[offset, channelCount]`.
/// * The curves live in one binary blob, `https://peqdb.com/data/graph-data.bin?v=<cache-buster>`,
///   where every measurement is a 776-byte record:
///   `Float32 scale`, `Float32 offset`, then 384 `Int16` samples.
///   The decoded level is `scale * sample - offset`, on a shared log-spaced
///   384-point grid from 20 Hz to 20 kHz (ratio 20000/20 per 383 steps).
/// * `channelCount` is the number of consecutive records belonging to that
///   variant; 2 means a measured L/R pair, 1 a single curve.
///
/// Nothing here talks to the network until `load()` is called, and everything
/// fetched is cached on disk so the picker works offline afterwards.
public final class PEQDBCatalog: @unchecked Sendable {

    public struct Variant: Identifiable, Hashable, Sendable {
        public var name: String
        public var offset: Int
        public var channelCount: Int
        public var id: String { "\(offset)-\(channelCount)" }
    }

    public struct Model: Identifiable, Hashable, Sendable {
        public var name: String
        public var source: String     // "Super Review", "Timtuned", …
        public var section: String   // "IE" or "OE"
        public var variants: [Variant]
        public var id: String { "\(section)|\(source)|\(name)" }
    }

    public struct Brand: Identifiable, Hashable, Sendable {
        public var name: String
        public var models: [Model]
        public var id: String { name }
    }

    public enum CatalogError: LocalizedError {
        case network(String)
        case malformed(String)
        public var errorDescription: String? {
            switch self {
            case .network(let why):   return "PEQdB could not be reached: \(why)"
            case .malformed(let why): return "PEQdB's data changed shape: \(why)"
            }
        }
    }

    // MARK: - Fixed layout, mirrored from the site's bundle

    /// When the on-disk cache is older than this, `load()` fetches fresh data.
    public static let autoRefreshInterval: TimeInterval = 14 * 24 * 3600

    static let pointsPerCurve = 384
    static let recordBytes = 776
    static let gridLowHz = 20.0
    static let gridHighHz = 20_000.0
    static let studioURL = URL(string: "https://peqdb.com/studio/")!
    static let binURL = URL(string: "https://peqdb.com/data/graph-data.bin")!

    private let cacheDirectory: URL
    private let session: URLSession
    private let queue = DispatchQueue(label: "peqdb.catalog", qos: .userInitiated)

    public private(set) var brands: [Brand] = []
    private var graphData = Data()

    /// Shared instance using the user's Application Support folder for cache.
    public static let shared = PEQDBCatalog()

    public init(cacheDirectory: URL? = nil, session: URLSession = .shared) {
        if let cacheDirectory {
            self.cacheDirectory = cacheDirectory
        } else {
            self.cacheDirectory = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("SoundMix/PEQdB", isDirectory: true)
        }
        self.session = session
        try? FileManager.default.createDirectory(at: self.cacheDirectory,
                                                withIntermediateDirectories: true)
    }

    private var catalogFile: URL { cacheDirectory.appendingPathComponent("catalog.json") }
    private var graphFile: URL { cacheDirectory.appendingPathComponent("graph-data.bin") }
    private var stampFile: URL { cacheDirectory.appendingPathComponent("last-updated.txt") }

    public var isLoaded: Bool { !brands.isEmpty && !graphData.isEmpty }

    /// When the cached database was last fetched from peqdb.com, if known.
    /// The stamp is read from disk each time so it is valid before `load()`.
    public var lastUpdated: Date? {
        guard let text = try? String(contentsOf: stampFile, encoding: .utf8),
              let stamp = Double(text.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        return Date(timeIntervalSince1970: stamp)
    }

    /// True when the cache is missing or older than `autoRefreshInterval`.
    public var cacheIsStale: Bool {
        guard let lastUpdated else { return true }
        return Date().timeIntervalSince(lastUpdated) > PEQDBCatalog.autoRefreshInterval
    }

    // MARK: - Loading

    /// The catalog index and curve blob, from disk cache when present and from
    /// the network otherwise. Runs off the main thread; completion is invoked
    /// on the main queue.
    public func load(refresh: Bool = false, completion: @escaping (Result<Void, CatalogError>) -> Void) {
        queue.async { [self] in
            do {
                if refresh || !hasCompleteCache() || cacheIsStale {
                    try fetchFreshCatalog()
                } else {
                    try loadCached()
                }
                DispatchQueue.main.async {
                    completion(.success(()))
                }
            } catch {
                // A failed refresh must not kill a previously working cache.
                if !isLoaded, !refresh {
                    if (try? loadCached()) != nil, isLoaded {
                        DispatchQueue.main.async { completion(.success(())) }
                        return
                    }
                }
                let wrapped = error as? CatalogError ?? .network(error.localizedDescription)
                DispatchQueue.main.async { completion(.failure(wrapped)) }
            }
        }
    }

    private func hasCompleteCache() -> Bool {
        FileManager.default.fileExists(atPath: catalogFile.path)
            && FileManager.default.fileExists(atPath: graphFile.path)
    }

    /// Same-module tests load the on-disk cache directly, without a network.
    func loadCached() throws {
        brands = try PEQDBIndexParser.parseCatalog(data: Data(contentsOf: catalogFile))
        graphData = try Data(contentsOf: graphFile)
    }

    private func fetchFreshCatalog() throws {
        let html = try fetchString(PEQDBCatalog.studioURL)
        guard let indexData = PEQDBIndexParser.extractIndex(html: html) else {
            throw CatalogError.malformed("no window.__INDEX__ in the studio page")
        }
        brands = try PEQDBIndexParser.parseCatalog(data: indexData)
        try indexData.write(to: catalogFile, options: .atomic)

        graphData = try fetchBinary(PEQDBCatalog.binURL)
        try graphData.write(to: graphFile, options: .atomic)

        let stamp = String(Int(Date().timeIntervalSince1970))
        try stamp.write(to: stampFile, atomically: true, encoding: .utf8)
    }

    private func fetchString(_ url: URL) throws -> String {
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 30)
        let data: Data
        do { data = try session.synchronousData(for: request) }
        catch { throw CatalogError.network(error.localizedDescription) }
        guard let text = String(data: data, encoding: .utf8) else {
            throw CatalogError.network("the studio page is not UTF-8")
        }
        return text
    }

    private func fetchBinary(_ url: URL) throws -> Data {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "v", value: String(Int(Date().timeIntervalSince1970)))]
        let request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 120)
        do { return try session.synchronousData(for: request) }
        catch { throw CatalogError.network(error.localizedDescription) }
    }

    // MARK: - Queries

    /// Case- and diacritic-insensitive model search across every brand/source.
    public func searchModels(matching query: String, limit: Int = 60) -> [Model] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !brands.isEmpty else { return [] }
        var hits: [Model] = []
        for brand in brands {
            for model in brand.models {
                if model.name.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                    hits.append(model)
                    if hits.count >= limit { return hits }
                }
            }
        }
        return hits
    }

    /// Decode one variant into the profile's measurement curves.
    /// A two-channel record is a measured L/R pair and fills both ears; a
    /// single-channel record lands in the chosen ear only.
    public func response(for variant: Variant, model: Model,
                         into side: EQProfile.Side) -> (left: FrequencyResponse?, right: FrequencyResponse?) {
        guard graphData.count >= (variant.offset + variant.channelCount) * PEQDBCatalog.recordBytes else {
            return (nil, nil)
        }
        let curves = (0..<max(variant.channelCount, 1)).map { channel in
            decodeRecord(at: variant.offset + channel,
                         name: PEQDBCatalog.curveName(model: model, variant: variant, channel: channel))
        }
        if curves.count >= 2 {
            return (curves[0].normalized(), curves[1].normalized())
        }
        return side == .left ? (curves[0].normalized(), nil) : (nil, curves[0].normalized())
    }

    static func curveName(model: Model, variant: Variant, channel: Int) -> String {
        let base = "\(model.name) — \(model.source)\(variant.name.isEmpty ? "" : " (\(variant.name))")"
        return channel == 0 ? base : "\(base) ch\(channel + 1)"
    }

    /// `scale * sample - offset` over the shared 384-point log grid.
    func decodeRecord(at index: Int, name: String) -> FrequencyResponse {
        let base = index * PEQDBCatalog.recordBytes
        let scale = graphData.withUnsafeBytes { $0.load(fromByteOffset: base, as: Float.self) }
        let offset = graphData.withUnsafeBytes { $0.load(fromByteOffset: base + 4, as: Float.self) }
        var points: [FrequencyResponse.Point] = []
        points.reserveCapacity(PEQDBCatalog.pointsPerCurve)
        let ratio = PEQDBCatalog.gridHighHz / PEQDBCatalog.gridLowHz
        for i in 0..<PEQDBCatalog.pointsPerCurve {
            let raw = graphData.withUnsafeBytes {
                $0.load(fromByteOffset: base + 8 + i * 2, as: Int16.self)
            }
            let hz = PEQDBCatalog.gridLowHz * pow(ratio, Double(i) / Double(PEQDBCatalog.pointsPerCurve - 1))
            points.append(.init(hz: hz, db: Double(scale) * Double(raw) - Double(offset)))
        }
        return FrequencyResponse(name: name, points: points)
    }
}

/// Parsing of the site's `window.__INDEX__` literal and the cached catalog.
enum PEQDBIndexParser {

    /// Extract the raw JSON assigned to `window.__INDEX__ = …;` in the page.
    static func extractIndex(html: String) -> Data? {
        guard let start = html.range(of: "window.__INDEX__ = ") else { return nil }
        let afterStart = html.index(start.upperBound, offsetBy: 0)
        let rest = html[afterStart...]
        guard let end = rest.range(of: "</script>") else { return nil }
        var literal = String(rest[..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        while literal.hasSuffix(";") { literal.removeLast() }
        return literal.data(using: .utf8)
    }

    struct RawIndex: Decodable {
        // section ("IE"/"OE") → source → model → variant → [offset, channels]
        let IE: [String: [String: [String: [Int]]]]
        let OE: [String: [String: [String: [Int]]]]?
    }

    /// Parse the raw index into the pickers's flat brand list.
    static func parseCatalog(data: Data) throws -> [PEQDBCatalog.Brand] {
        let index = try JSONDecoder().decode(RawIndex.self, from: data)
        var byBrand: [String: [PEQDBCatalog.Model]] = [:]
        for (section, sources) in [("IE", index.IE), ("OE", index.OE ?? [:])] {
            for (source, models) in sources {
                for (modelName, variants) in models {
                    let parsed = variants.compactMap { name, pair -> PEQDBCatalog.Variant? in
                        guard pair.count == 2, pair[0] >= 0, pair[1] >= 1 else { return nil }
                        return PEQDBCatalog.Variant(name: name.isEmpty ? "Standard" : name,
                                                    offset: pair[0], channelCount: pair[1])
                    }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                    guard !parsed.isEmpty else { continue }
                    let key = brandKey(for: modelName)
                    byBrand[key, default: []].append(
                        PEQDBCatalog.Model(name: modelName, source: source,
                                           section: section, variants: parsed))
                }
            }
        }
        return byBrand
            .map { PEQDBCatalog.Brand(name: $0.key,
                                      models: $0.value.sorted {
                                          $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                                      }) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The site names models "BRAND REST…"; the first token is the brand key.
    static func brandKey(for modelName: String) -> String {
        let first = modelName.split(separator: " ").first.map(String.init) ?? modelName
        return first.isEmpty ? "?" : first.uppercased()
    }
}

extension URLSession {
    /// Blocking fetch for background queues only.
    func synchronousData(for request: URLRequest) throws -> Data {
        var box: Result<Data, Error> = .failure(URLError(.badURL))
        let semaphore = DispatchSemaphore(value: 0)
        let task = dataTask(with: request) { data, response, error in
            if let error { box = .failure(error) }
            else if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                box = .failure(URLError(.badServerResponse))
            } else if let data { box = .success(data) }
            else { box = .failure(URLError(.zeroByteResource)) }
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()
        return try box.get()
    }
}
