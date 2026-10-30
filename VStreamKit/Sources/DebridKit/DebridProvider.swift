import Foundation

public enum DebridService: String, Codable, Sendable, CaseIterable, Identifiable {
    case realDebrid, torbox, premiumize

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .realDebrid: "Real-Debrid"
        case .torbox: "TorBox"
        case .premiumize: "Premiumize"
        }
    }

    public var shortName: String {
        switch self {
        case .realDebrid: "RD"
        case .torbox: "TB"
        case .premiumize: "PM"
        }
    }

    /// Where the user finds their API key.
    public var apiKeyPage: URL {
        switch self {
        case .realDebrid: URL(string: "https://real-debrid.com/apitoken")!
        case .torbox: URL(string: "https://torbox.app/settings")!
        case .premiumize: URL(string: "https://www.premiumize.me/account")!
        }
    }

    public func provider(apiKey: String, session: URLSession = .shared) -> any DebridProvider {
        switch self {
        case .realDebrid: RealDebridProvider(apiKey: apiKey, session: session)
        case .torbox: TorboxProvider(apiKey: apiKey, session: session)
        case .premiumize: PremiumizeProvider(apiKey: apiKey, session: session)
        }
    }
}

public struct DebridRequest: Sendable, Hashable {
    public var infoHash: String
    public var magnet: String
    public var filename: String?
    public var fileIndex: Int?
    public var season: Int?
    public var episode: Int?

    public init(infoHash: String, magnet: String, filename: String? = nil, fileIndex: Int? = nil, season: Int? = nil, episode: Int? = nil) {
        self.infoHash = infoHash.lowercased()
        self.magnet = magnet
        self.filename = filename
        self.fileIndex = fileIndex
        self.season = season
        self.episode = episode
    }
}

public struct DebridLink: Sendable, Hashable {
    public var url: URL
    public var filename: String?
    public var size: Int64?

    public init(url: URL, filename: String?, size: Int64?) {
        self.url = url
        self.filename = filename
        self.size = size
    }
}

public enum DebridError: Error, LocalizedError, Sendable {
    case invalidKey
    case notCached
    case noPlayableFile
    case api(String)
    case http(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidKey: "The debrid API key was rejected"
        case .notCached: "This torrent is not cached on your debrid service"
        case .noPlayableFile: "No matching video file in this torrent"
        case let .api(message): message
        case let .http(status): "Debrid service returned HTTP \(status)"
        }
    }
}

public protocol DebridProvider: Sendable {
    var service: DebridService { get }
    func validate() async throws -> Bool
    /// The subset of `hashes` that can be streamed instantly. Providers that cannot check
    /// answer `nil`, meaning "unknown".
    func cachedHashes(_ hashes: [String]) async throws -> Set<String>?
    func resolve(_ request: DebridRequest) async throws -> DebridLink
}

// MARK: - Shared HTTP

struct DebridHTTP: Sendable {
    let apiKey: String
    let session: URLSession

    func request(
        _ url: URL,
        method: String = "GET",
        form: [(String, String)]? = nil,
        json: [String: Any]? = nil,
        multipart: [(String, String)]? = nil
    ) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = method
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let form {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(form.map { "\(Self.formEncode($0))=\(Self.formEncode($1))" }.joined(separator: "&").utf8)
        } else if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        } else if let multipart {
            let boundary = "VStream-\(UUID().uuidString)"
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            var body = ""
            for (name, value) in multipart {
                body += "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n"
            }
            body += "--\(boundary)--\r\n"
            request.httpBody = Data(body.utf8)
        }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 401 || http.statusCode == 403 { throw DebridError.invalidKey }
            if !(200..<300).contains(http.statusCode) {
                let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                    .flatMap { $0["error"] as? String ?? $0["detail"] as? String ?? $0["message"] as? String }
                throw message.map(DebridError.api) ?? DebridError.http(http.statusCode)
            }
        }
        return data
    }

    func jsonObject(_ url: URL, method: String = "GET", form: [(String, String)]? = nil, json: [String: Any]? = nil, multipart: [(String, String)]? = nil) async throws -> [String: Any] {
        let data = try await request(url, method: method, form: form, json: json, multipart: multipart)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._*")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

extension Dictionary where Key == String, Value == Any {
    func int64(_ key: String) -> Int64? {
        if let value = self[key] as? Int64 { return value }
        if let value = self[key] as? Int { return Int64(value) }
        if let value = self[key] as? Double { return Int64(value) }
        return nil
    }

    func int(_ key: String) -> Int? { int64(key).map(Int.init) }
}
