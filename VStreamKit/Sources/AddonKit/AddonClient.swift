import Foundation

public enum AddonError: Error, LocalizedError, Sendable {
    case invalidURL(String)
    case http(status: Int, url: URL)
    case unsupported(resource: String, addon: String)
    case decoding(url: URL, underlying: String)

    public var errorDescription: String? {
        switch self {
        case let .invalidURL(input): "Invalid addon URL: \(input)"
        case let .http(status, url): "HTTP \(status) from \(url.host ?? url.absoluteString)"
        case let .unsupported(resource, addon): "\(addon) does not provide \(resource)"
        case let .decoding(url, underlying): "Could not read response from \(url.host ?? "addon"): \(underlying)"
        }
    }
}

public struct CatalogPage: Sendable, Hashable {
    public var metas: [MetaPreview]
    /// Number of raw items returned (before dedupe), used to compute the next `skip`.
    public var rawCount: Int
}

/// Stateless HTTP client for the Stremio addon protocol. Identical in-flight requests are coalesced.
public actor AddonClient {
    public static let shared = AddonClient()

    private let session: URLSession
    private var inFlight: [URL: Task<Data, Error>] = [:]

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 30
            configuration.httpMaximumConnectionsPerHost = 6
            configuration.requestCachePolicy = .useProtocolCachePolicy
            configuration.urlCache = URLCache(memoryCapacity: 32 << 20, diskCapacity: 256 << 20)
            self.session = URLSession(configuration: configuration)
        }
    }

    // MARK: Manifest

    public func fetchManifest(from input: String, bypassCache: Bool = false) async throws -> AddonDescriptor {
        guard let url = AddonURL.normalizeManifestURL(input) else { throw AddonError.invalidURL(input) }
        let data = try await fetch(url, timeout: 15, bypassCache: bypassCache)
        let manifest = try decode(Manifest.self, from: data, url: url)
        return AddonDescriptor(manifest: manifest, transportUrl: url)
    }

    // MARK: Resources

    public func catalog(
        _ addon: AddonDescriptor,
        type: String,
        id: String,
        extra: [ExtraArgument] = []
    ) async throws -> CatalogPage {
        let url = try resourceURL(addon, "catalog", type: type, id: id, extra: extra)
        let data = try await fetch(url, timeout: 20)
        let response = try decode(MetasResponse.self, from: data, url: url)
        var seen = Set<String>()
        let metas = response.metas.filter { seen.insert("\($0.type):\($0.id)").inserted }
        return CatalogPage(metas: metas, rawCount: response.metas.count)
    }

    public func meta(_ addon: AddonDescriptor, type: String, id: String) async throws -> MetaDetail {
        let url = try resourceURL(addon, "meta", type: type, id: id)
        let data = try await fetch(url, timeout: 10)
        return try decode(MetaResponse.self, from: data, url: url).meta
    }

    public func streams(_ addon: AddonDescriptor, type: String, id: String) async throws -> [Stream] {
        let url = try resourceURL(addon, "stream", type: type, id: id)
        let data = try await fetch(url, timeout: 30)
        return try decode(StreamsResponse.self, from: data, url: url).streams.filter(\.isPlayable)
    }

    public func subtitles(
        _ addon: AddonDescriptor,
        type: String,
        id: String,
        extra: [ExtraArgument] = []
    ) async throws -> [Subtitle] {
        let url = try resourceURL(addon, "subtitles", type: type, id: id, extra: extra)
        let data = try await fetch(url, timeout: 10)
        return try decode(SubtitlesResponse.self, from: data, url: url).subtitles
    }

    // MARK: Transport

    private func resourceURL(
        _ addon: AddonDescriptor,
        _ resource: String,
        type: String,
        id: String,
        extra: [ExtraArgument] = []
    ) throws -> URL {
        guard let url = AddonURL.resource(
            transportURL: addon.transportUrl,
            resource: resource,
            type: type,
            id: id,
            extra: extra
        ) else {
            throw AddonError.invalidURL(addon.transportUrl.absoluteString)
        }
        return url
    }

    private func fetch(_ url: URL, timeout: TimeInterval, bypassCache: Bool = false) async throws -> Data {
        if !bypassCache, let task = inFlight[url] {
            return try await task.value
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if bypassCache { request.cachePolicy = .reloadIgnoringLocalCacheData }
        let session = self.session
        let task = Task<Data, Error> {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw AddonError.http(status: http.statusCode, url: url)
            }
            return data
        }
        inFlight[url] = task
        defer { inFlight[url] = nil }
        return try await task.value
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data, url: URL) throws -> T {
        do {
            return try JSONDecoder.addon.decode(T.self, from: data)
        } catch {
            throw AddonError.decoding(url: url, underlying: String(describing: error))
        }
    }
}

struct MetasResponse: Decodable {
    let metas: [MetaPreview]

    enum CodingKeys: String, CodingKey { case metas }

    init(from decoder: Decoder) throws {
        metas = try decoder.container(keyedBy: CodingKeys.self).lossyArray(.metas)
    }
}

struct StreamsResponse: Decodable {
    let streams: [Stream]

    enum CodingKeys: String, CodingKey { case streams }

    init(from decoder: Decoder) throws {
        streams = try decoder.container(keyedBy: CodingKeys.self).lossyArray(.streams)
    }
}

struct SubtitlesResponse: Decodable {
    let subtitles: [Subtitle]

    enum CodingKeys: String, CodingKey { case subtitles }

    init(from decoder: Decoder) throws {
        subtitles = try decoder.container(keyedBy: CodingKeys.self).lossyArray(.subtitles)
    }
}

/// Accepts `{meta: {...}}`, `{data: {meta: {...}}}`, `{data: {...}}` or a bare meta object.
struct MetaResponse: Decodable {
    let meta: MetaDetail

    enum CodingKeys: String, CodingKey { case meta, data }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let meta = try? container.decode(MetaDetail.self, forKey: .meta) {
            self.meta = meta
        } else if let data = try? container.nestedContainer(keyedBy: CodingKeys.self, forKey: .data),
                  let meta = try? data.decode(MetaDetail.self, forKey: .meta) {
            self.meta = meta
        } else if let meta = try? container.decode(MetaDetail.self, forKey: .data) {
            self.meta = meta
        } else {
            meta = try MetaDetail(from: decoder)
        }
    }
}
