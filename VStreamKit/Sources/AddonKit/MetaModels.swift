import Foundation

public enum PosterShape: String, Codable, Sendable, Hashable {
    case poster, square, landscape

    init(lossy value: String?) {
        switch value?.lowercased() {
        case "square": self = .square
        case "landscape": self = .landscape
        default: self = .poster
        }
    }

    /// Width / height.
    public var aspectRatio: Double {
        switch self {
        case .poster: 2.0 / 3.0
        case .square: 1
        case .landscape: 16.0 / 9.0
        }
    }
}

public struct MetaLink: Codable, Sendable, Hashable {
    public var name: String
    public var category: String
    public var url: URL?
}

public struct Trailer: Codable, Sendable, Hashable {
    public var source: String
    public var type: String?
}

/// An entry in a catalog response (`{ "metas": [...] }`).
public struct MetaPreview: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var type: String
    public var name: String
    public var poster: URL?
    public var posterShape: PosterShape
    public var background: URL?
    public var logo: URL?
    public var description: String?
    public var releaseInfo: String?
    public var imdbRating: String?
    public var genres: [String]
    public var runtime: String?

    public init(
        id: String,
        type: String,
        name: String,
        poster: URL? = nil,
        posterShape: PosterShape = .poster,
        background: URL? = nil,
        logo: URL? = nil,
        description: String? = nil,
        releaseInfo: String? = nil,
        imdbRating: String? = nil,
        genres: [String] = [],
        runtime: String? = nil
    ) {
        self.id = id
        self.type = type
        self.name = name
        self.poster = poster
        self.posterShape = posterShape
        self.background = background
        self.logo = logo
        self.description = description
        self.releaseInfo = releaseInfo
        self.imdbRating = imdbRating
        self.genres = genres
        self.runtime = runtime
    }

    enum CodingKeys: String, CodingKey {
        case id, type, name, poster, posterShape, background, banner, landscapePoster, logo, description
        case releaseInfo, year, imdbRating, genres, genre, runtime
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        type = try container.decode(String.self, forKey: .type)
        name = container.lossyString(.name) ?? ""
        poster = container.lossyURL(.poster)
        posterShape = PosterShape(lossy: container.lossyString(.posterShape))
        background = container.lossyURL(.background) ?? container.lossyURL(.banner) ?? container.lossyURL(.landscapePoster)
        logo = container.lossyURL(.logo)
        description = container.lossyString(.description)
        releaseInfo = container.lossyString(.releaseInfo) ?? container.lossyString(.year)
        imdbRating = container.lossyString(.imdbRating)
        let genres = container.lossyStringArray(.genres)
        self.genres = genres.isEmpty ? container.lossyStringArray(.genre) : genres
        runtime = container.lossyString(.runtime)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(type, forKey: .type)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(poster, forKey: .poster)
        try container.encode(posterShape, forKey: .posterShape)
        try container.encodeIfPresent(background, forKey: .background)
        try container.encodeIfPresent(logo, forKey: .logo)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(releaseInfo, forKey: .releaseInfo)
        try container.encodeIfPresent(imdbRating, forKey: .imdbRating)
        try container.encode(genres, forKey: .genres)
        try container.encodeIfPresent(runtime, forKey: .runtime)
    }
}

/// Full meta object from `/meta/{type}/{id}.json`.
public struct MetaDetail: Codable, Sendable, Hashable, Identifiable {
    public var preview: MetaPreview
    public var videos: [Video]
    public var released: Date?
    public var country: String?
    public var director: [String]
    public var writer: [String]
    public var cast: [String]
    public var trailers: [Trailer]
    public var links: [MetaLink]
    public var website: URL?
    public var defaultVideoId: String?
    public var hasScheduledVideos: Bool

    public var id: String { preview.id }
    public var type: String { preview.type }
    public var name: String { preview.name }

    enum CodingKeys: String, CodingKey {
        case videos, released, country, director, writer, cast, trailers, trailerStreams, links, website, behaviorHints
    }

    enum HintKeys: String, CodingKey { case defaultVideoId, hasScheduledVideos }

    public init(preview: MetaPreview, videos: [Video] = []) {
        self.preview = preview
        self.videos = videos
        director = []
        writer = []
        cast = []
        trailers = []
        links = []
        hasScheduledVideos = false
    }

    public init(from decoder: Decoder) throws {
        preview = try MetaPreview(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        videos = container.lossyArray(.videos, of: Video.self).sorted()
        released = StremioDate.parse(container.lossyString(.released))
        country = container.lossyString(.country)
        links = container.lossyArray(.links)
        director = container.lossyStringArray(.director)
        writer = container.lossyStringArray(.writer)
        cast = container.lossyStringArray(.cast)
        if cast.isEmpty { cast = links.filter { $0.category.lowercased() == "cast" }.map(\.name) }
        if director.isEmpty { director = links.filter { $0.category.lowercased() == "directors" }.map(\.name) }
        if writer.isEmpty { writer = links.filter { $0.category.lowercased() == "writers" }.map(\.name) }
        trailers = container.lossyArray(.trailers)
        if trailers.isEmpty {
            trailers = container.lossyArray(.trailerStreams, of: AddonStream.self).compactMap { stream in
                stream.ytId.map { Trailer(source: $0, type: "Trailer") }
            }
        }
        website = container.lossyURL(.website)
        let hints = try? container.nestedContainer(keyedBy: HintKeys.self, forKey: .behaviorHints)
        defaultVideoId = hints?.lossyString(.defaultVideoId)
        hasScheduledVideos = hints?.lossyBool(.hasScheduledVideos) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        try preview.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(videos, forKey: .videos)
        try container.encode(cast, forKey: .cast)
        try container.encode(director, forKey: .director)
        try container.encode(writer, forKey: .writer)
        try container.encode(trailers, forKey: .trailers)
        try container.encode(links, forKey: .links)
        // Same date format as Video, so `StremioDate.parse` reads it back.
        try container.encodeIfPresent(released.map { ISO8601DateFormatter().string(from: $0) }, forKey: .released)
        try container.encodeIfPresent(country, forKey: .country)
        try container.encodeIfPresent(website, forKey: .website)
        if defaultVideoId != nil || hasScheduledVideos {
            var hints = container.nestedContainer(keyedBy: HintKeys.self, forKey: .behaviorHints)
            try hints.encodeIfPresent(defaultVideoId, forKey: .defaultVideoId)
            if hasScheduledVideos { try hints.encode(true, forKey: .hasScheduledVideos) }
        }
    }

    public var seasons: [Int] {
        Array(Set(videos.compactMap(\.season))).sorted { lhs, rhs in
            // Specials (season 0) go last.
            if lhs == 0 { return false }
            if rhs == 0 { return true }
            return lhs < rhs
        }
    }

    public func videos(inSeason season: Int) -> [Video] {
        videos.filter { $0.season == season }
    }

    /// Movies typically have no `videos`; their playable id is the meta id itself.
    public var isSeriesLike: Bool { !videos.isEmpty && type != "movie" }
}

public struct Video: Codable, Sendable, Hashable, Identifiable, Comparable {
    public var id: String
    public var title: String
    public var released: Date?
    public var season: Int?
    public var episode: Int?
    public var thumbnail: URL?
    public var overview: String?
    public var streams: [AddonStream]

    public init(
        id: String,
        title: String,
        released: Date? = nil,
        season: Int? = nil,
        episode: Int? = nil,
        thumbnail: URL? = nil,
        overview: String? = nil,
        streams: [AddonStream] = []
    ) {
        self.id = id
        self.title = title
        self.released = released
        self.season = season
        self.episode = episode
        self.thumbnail = thumbnail
        self.overview = overview
        self.streams = streams
    }

    enum CodingKeys: String, CodingKey {
        case id, title, name, released, firstAired, season, episode, number, thumbnail, overview, description, streams
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = container.lossyString(.title) ?? container.lossyString(.name) ?? ""
        released = StremioDate.parse(container.lossyString(.released) ?? container.lossyString(.firstAired))
        season = container.lossyInt(.season)
        episode = container.lossyInt(.episode) ?? container.lossyInt(.number)
        thumbnail = container.lossyURL(.thumbnail)
        overview = container.lossyString(.overview) ?? container.lossyString(.description)
        streams = container.lossyArray(.streams)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(released.map { ISO8601DateFormatter().string(from: $0) }, forKey: .released)
        try container.encodeIfPresent(season, forKey: .season)
        try container.encodeIfPresent(episode, forKey: .episode)
        try container.encodeIfPresent(thumbnail, forKey: .thumbnail)
        try container.encodeIfPresent(overview, forKey: .overview)
    }

    public static func < (lhs: Video, rhs: Video) -> Bool {
        switch (lhs.season, rhs.season) {
        case let (l?, r?) where l != r:
            return l < r
        default:
            break
        }
        switch (lhs.episode, rhs.episode) {
        case let (l?, r?) where l != r:
            return l < r
        default:
            break
        }
        return (lhs.released ?? .distantFuture) < (rhs.released ?? .distantFuture)
    }

    public var isReleased: Bool {
        guard let released else { return true }
        return released <= Date()
    }

    public var episodeLabel: String? {
        guard let season, let episode else { return nil }
        return "S\(season)E\(episode)"
    }
}
