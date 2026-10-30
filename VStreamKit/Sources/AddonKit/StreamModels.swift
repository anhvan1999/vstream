import Foundation

public struct Stream: Codable, Sendable, Hashable {
    public var url: URL?
    public var ytId: String?
    public var infoHash: String?
    public var fileIdx: Int?
    public var externalUrl: URL?
    public var name: String?
    public var title: String?
    public var description: String?
    /// Torrent peer sources, e.g. `tracker:udp://...` or `dht:<hash>`.
    public var sources: [String]
    public var subtitles: [Subtitle]
    public var behaviorHints: StreamBehaviorHints

    public init(
        url: URL? = nil,
        ytId: String? = nil,
        infoHash: String? = nil,
        fileIdx: Int? = nil,
        externalUrl: URL? = nil,
        name: String? = nil,
        title: String? = nil,
        description: String? = nil,
        sources: [String] = [],
        subtitles: [Subtitle] = [],
        behaviorHints: StreamBehaviorHints = .init()
    ) {
        self.url = url
        self.ytId = ytId
        self.infoHash = infoHash
        self.fileIdx = fileIdx
        self.externalUrl = externalUrl
        self.name = name
        self.title = title
        self.description = description
        self.sources = sources
        self.subtitles = subtitles
        self.behaviorHints = behaviorHints
    }

    enum CodingKeys: String, CodingKey {
        case url, ytId, infoHash, fileIdx, externalUrl, name, title, description, sources, subtitles, behaviorHints
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = container.lossyURL(.url)
        ytId = container.lossyString(.ytId)
        infoHash = container.lossyString(.infoHash)?.lowercased()
        fileIdx = container.lossyInt(.fileIdx)
        externalUrl = container.lossyURL(.externalUrl)
        name = container.lossyString(.name)
        title = container.lossyString(.title)
        description = container.lossyString(.description)
        sources = container.lossyStringArray(.sources)
        subtitles = container.lossyArray(.subtitles)
        behaviorHints = (try? container.decodeIfPresent(StreamBehaviorHints.self, forKey: .behaviorHints)) ?? .init()

        // A magnet passed in `url` is a torrent in disguise.
        if infoHash == nil, let url, url.scheme == "magnet" {
            infoHash = Magnet.infoHash(from: url)
            sources += Magnet.trackers(from: url).map { "tracker:\($0)" }
            self.url = nil
        }
    }

    public var isPlayable: Bool {
        url != nil || infoHash != nil || ytId != nil || externalUrl != nil
    }

    public var isTorrent: Bool { infoHash != nil }

    /// `description` is the newer name for `title` in the protocol.
    public var details: String? { description ?? title }

    public var trackers: [String] {
        sources.compactMap { source in
            source.hasPrefix("tracker:") ? String(source.dropFirst("tracker:".count)) : nil
        }
    }

    public var magnetURI: String? {
        guard let infoHash else { return nil }
        return Magnet.uri(infoHash: infoHash, name: behaviorHints.filename, trackers: trackers)
    }
}

public struct StreamBehaviorHints: Codable, Sendable, Hashable {
    public var notWebReady: Bool
    public var bingeGroup: String?
    public var countryWhitelist: [String]
    public var filename: String?
    public var videoSize: Int64?
    public var videoHash: String?
    public var requestHeaders: [String: String]

    public init(
        notWebReady: Bool = false,
        bingeGroup: String? = nil,
        countryWhitelist: [String] = [],
        filename: String? = nil,
        videoSize: Int64? = nil,
        videoHash: String? = nil,
        requestHeaders: [String: String] = [:]
    ) {
        self.notWebReady = notWebReady
        self.bingeGroup = bingeGroup
        self.countryWhitelist = countryWhitelist
        self.filename = filename
        self.videoSize = videoSize
        self.videoHash = videoHash
        self.requestHeaders = requestHeaders
    }

    enum CodingKeys: String, CodingKey {
        case notWebReady, bingeGroup, countryWhitelist, filename, videoSize, videoHash, proxyHeaders
    }

    enum ProxyKeys: String, CodingKey { case request }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        notWebReady = container.lossyBool(.notWebReady) ?? false
        bingeGroup = container.lossyString(.bingeGroup)
        countryWhitelist = container.lossyStringArray(.countryWhitelist)
        filename = container.lossyString(.filename)
        videoSize = container.lossyInt(.videoSize).map(Int64.init)
        videoHash = container.lossyString(.videoHash)
        let proxy = try? container.nestedContainer(keyedBy: ProxyKeys.self, forKey: .proxyHeaders)
        requestHeaders = (try? proxy?.decodeIfPresent([String: String].self, forKey: .request)) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(notWebReady, forKey: .notWebReady)
        try container.encodeIfPresent(bingeGroup, forKey: .bingeGroup)
        try container.encodeIfPresent(filename, forKey: .filename)
        try container.encodeIfPresent(videoSize, forKey: .videoSize)
        try container.encodeIfPresent(videoHash, forKey: .videoHash)
        if !requestHeaders.isEmpty {
            var proxy = container.nestedContainer(keyedBy: ProxyKeys.self, forKey: .proxyHeaders)
            try proxy.encode(requestHeaders, forKey: .request)
        }
    }
}

public struct Subtitle: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var url: URL
    public var lang: String

    public init(id: String, url: URL, lang: String) {
        self.id = id
        self.url = url
        self.lang = lang
    }

    enum CodingKeys: String, CodingKey { case id, url, lang, language, label }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let url = container.lossyURL(.url) else {
            throw DecodingError.dataCorruptedError(forKey: .url, in: container, debugDescription: "missing subtitle url")
        }
        self.url = url
        lang = container.lossyString(.lang) ?? container.lossyString(.language) ?? container.lossyString(.label) ?? "und"
        id = container.lossyString(.id) ?? url.absoluteString
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(url, forKey: .url)
        try container.encode(lang, forKey: .lang)
    }
}

public enum Magnet {
    public static let defaultTrackers = [
        "udp://tracker.opentrackr.org:1337/announce",
        "udp://open.stealth.si:80/announce",
        "udp://tracker.torrent.eu.org:451/announce",
        "udp://exodus.desync.com:6969/announce",
        "udp://tracker.openbittorrent.com:6969/announce",
    ]

    public static func uri(infoHash: String, name: String? = nil, trackers: [String]) -> String {
        var components = URLComponents()
        components.scheme = "magnet"
        var items = [URLQueryItem(name: "xt", value: "urn:btih:\(infoHash)")]
        if let name { items.append(URLQueryItem(name: "dn", value: name)) }
        let trackers = trackers.isEmpty ? defaultTrackers : trackers
        items += trackers.map { URLQueryItem(name: "tr", value: $0) }
        components.queryItems = items
        // URLComponents omits the "?" separator rules magnet links expect: `magnet:?xt=...`.
        return "magnet:?" + (components.percentEncodedQuery ?? "")
    }

    public static func infoHash(from url: URL) -> String? {
        queryItems(url).first { $0.name == "xt" }?.value.flatMap { value in
            value.lowercased().hasPrefix("urn:btih:") ? String(value.dropFirst(9)).lowercased() : nil
        }
    }

    public static func trackers(from url: URL) -> [String] {
        queryItems(url).filter { $0.name == "tr" }.compactMap(\.value)
    }

    private static func queryItems(_ url: URL) -> [URLQueryItem] {
        let string = url.absoluteString
        guard let index = string.firstIndex(of: "?") else { return [] }
        return URLComponents(string: "x:" + string[index...])?.queryItems ?? []
    }
}
