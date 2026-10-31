import Foundation
import Testing
@testable import AddonKit

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(json.utf8))
}

private func roundTrip<T: Codable>(_ value: T) throws -> T {
    try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
}

@Suite struct PosterShapeTests {
    @Test func lossyAndRatios() {
        #expect(PosterShape(lossy: "SQUARE") == .square)
        #expect(PosterShape(lossy: "landscape") == .landscape)
        #expect(PosterShape(lossy: "regular") == .poster)
        #expect(PosterShape(lossy: nil) == .poster)
        #expect(PosterShape.poster.aspectRatio == 2.0 / 3.0)
        #expect(PosterShape.square.aspectRatio == 1)
        #expect(PosterShape.landscape.aspectRatio == 16.0 / 9.0)
    }
}

@Suite struct MetaPreviewTests {
    @Test func fallbacks() throws {
        let meta = try decode(MetaPreview.self, """
        {"id":"tt1","type":"movie","banner":"https://a.example/banner.jpg","landscapePoster":"https://a.example/lp.jpg",
         "year":"2014–","genre":["Drama"],"runtime":169,"posterShape":"Square","description":"Space"}
        """)
        #expect(meta.name == "")
        #expect(meta.background?.absoluteString == "https://a.example/banner.jpg")
        #expect(meta.releaseInfo == "2014–")
        #expect(meta.genres == ["Drama"])
        #expect(meta.runtime == "169")
        #expect(meta.posterShape == .square)
        #expect(meta.description == "Space")
        #expect(meta.poster == nil)
        #expect(meta.logo == nil)
    }

    @Test func preferredKeysWin() throws {
        let meta = try decode(MetaPreview.self, """
        {"id":"tt1","type":"movie","background":"https://a.example/bg.jpg","banner":"https://a.example/banner.jpg",
         "releaseInfo":"2014","year":"1999","genres":["Sci-Fi"],"genre":["Drama"]}
        """)
        #expect(meta.background?.absoluteString == "https://a.example/bg.jpg")
        #expect(meta.releaseInfo == "2014")
        #expect(meta.genres == ["Sci-Fi"])
    }

    @Test func landscapePosterIsLastBackgroundFallback() throws {
        let meta = try decode(MetaPreview.self, #"{"id":"a","type":"tv","landscapePoster":"https://a.example/lp.jpg"}"#)
        #expect(meta.background?.absoluteString == "https://a.example/lp.jpg")
    }

    @Test func requiresIdAndType() {
        #expect(throws: DecodingError.self) { try decode(MetaPreview.self, #"{"id":"a"}"#) }
        #expect(throws: DecodingError.self) { try decode(MetaPreview.self, #"{"type":"movie"}"#) }
    }

    @Test func roundTrips() throws {
        let meta = MetaPreview(
            id: "tt1", type: "movie", name: "One",
            poster: URL(string: "https://a.example/p.jpg"), posterShape: .landscape,
            background: URL(string: "https://a.example/b.jpg"), logo: URL(string: "https://a.example/l.png"),
            description: "d", releaseInfo: "2020", imdbRating: "8.1", genres: ["A", "B"], runtime: "2h"
        )
        #expect(try roundTrip(meta) == meta)
        #expect(try roundTrip(MetaPreview(id: "x", type: "y", name: "z")) == MetaPreview(id: "x", type: "y", name: "z"))
    }
}

@Suite struct MetaDetailTests {
    @Test func castCrewFromLinks() throws {
        let meta = try decode(MetaDetail.self, """
        {"id":"tt1","type":"movie","name":"M","links":[
          {"name":"Actor A","category":"Cast","url":"stremio:///search?search=A"},
          {"name":"Dir D","category":"Directors","url":"stremio:///search?search=D"},
          {"name":"Wri W","category":"Writers"},
          {"name":"Drama","category":"Genres"},
          {"name":"broken"}
        ]}
        """)
        #expect(meta.cast == ["Actor A"])
        #expect(meta.director == ["Dir D"])
        #expect(meta.writer == ["Wri W"])
        #expect(meta.links.count == 4)
        #expect(meta.links.first?.url?.scheme == "stremio")
    }

    @Test func explicitCrewWinsOverLinks() throws {
        let meta = try decode(MetaDetail.self, """
        {"id":"tt1","type":"movie","cast":"X, Y","director":["Z"],"links":[{"name":"L","category":"Cast"}]}
        """)
        #expect(meta.cast == ["X", "Y"])
        #expect(meta.director == ["Z"])
        #expect(meta.writer.isEmpty)
    }

    @Test func trailersFromTrailerStreams() throws {
        let fromStreams = try decode(MetaDetail.self, """
        {"id":"tt1","type":"movie","trailerStreams":[{"ytId":"abc","title":"T"},{"url":"https://a.example/t.mp4"}]}
        """)
        #expect(fromStreams.trailers == [Trailer(source: "abc", type: "Trailer")])
        let explicit = try decode(MetaDetail.self, """
        {"id":"tt1","type":"movie","trailers":[{"source":"xyz","type":"Clip"}],"trailerStreams":[{"ytId":"abc"}]}
        """)
        #expect(explicit.trailers == [Trailer(source: "xyz", type: "Clip")])
    }

    @Test func detailFields() throws {
        let meta = try decode(MetaDetail.self, """
        {"id":"tt1","type":"series","name":"S","released":"2008-01-20T00:00:00.000Z","country":"USA",
         "website":"https://s.example","behaviorHints":{"defaultVideoId":"tt1:1:1","hasScheduledVideos":"true"},
         "videos":[{"id":"tt1:1:1","season":1,"episode":1}]}
        """)
        #expect(meta.released == Date(timeIntervalSince1970: 1_200_787_200))
        #expect(meta.country == "USA")
        #expect(meta.website?.host == "s.example")
        #expect(meta.defaultVideoId == "tt1:1:1")
        #expect(meta.hasScheduledVideos)
        #expect(meta.id == "tt1")
        #expect(meta.type == "series")
        #expect(meta.name == "S")
    }

    @Test func missingBehaviorHints() throws {
        let meta = try decode(MetaDetail.self, #"{"id":"tt1","type":"movie","behaviorHints":5}"#)
        #expect(meta.defaultVideoId == nil)
        #expect(!meta.hasScheduledVideos)
        #expect(meta.videos.isEmpty)
        #expect(!meta.isSeriesLike)
    }

    @Test func videosSortedAndSeasonsSpecialsLast() throws {
        let meta = try decode(MetaDetail.self, """
        {"id":"tt1","type":"series","videos":[
          {"id":"s2e1","season":2,"episode":1},
          {"id":"s0e1","season":0,"episode":1},
          {"id":"s1e2","season":1,"episode":2},
          {"id":"s1e1","season":"1","number":1},
          {"id":"s10e1","season":10,"episode":1},
          {"title":"no id"}
        ]}
        """)
        #expect(meta.videos.map(\.id) == ["s0e1", "s1e1", "s1e2", "s2e1", "s10e1"])
        #expect(meta.seasons == [1, 2, 10, 0])
        #expect(meta.videos(inSeason: 1).map(\.id) == ["s1e1", "s1e2"])
        #expect(meta.videos(inSeason: 5).isEmpty)
        #expect(meta.isSeriesLike)
    }

    @Test func movieWithVideosIsNotSeriesLike() {
        let movie = MetaDetail(preview: MetaPreview(id: "tt1", type: "movie", name: "M"), videos: [Video(id: "tt1", title: "M")])
        #expect(!movie.isSeriesLike)
        let channel = MetaDetail(preview: MetaPreview(id: "yt", type: "channel", name: "C"), videos: [Video(id: "v", title: "V")])
        #expect(channel.isSeriesLike)
        #expect(channel.cast.isEmpty && channel.trailers.isEmpty && !channel.hasScheduledVideos)
    }

    @Test func encodeKeepsPreviewVideosAndCrew() throws {
        var meta = MetaDetail(
            preview: MetaPreview(id: "tt1", type: "series", name: "S", genres: ["Drama"]),
            videos: [Video(id: "tt1:1:1", title: "Pilot", season: 1, episode: 1)]
        )
        meta.cast = ["A"]
        meta.director = ["D"]
        meta.writer = ["W"]
        meta.trailers = [Trailer(source: "yt", type: nil)]
        meta.links = [MetaLink(name: "A", category: "Cast", url: nil)]
        let decoded = try roundTrip(meta)
        #expect(decoded.preview == meta.preview)
        #expect(decoded.videos == meta.videos)
        #expect(decoded.cast == ["A"])
        #expect(decoded.director == ["D"])
        #expect(decoded.writer == ["W"])
        #expect(decoded.trailers == meta.trailers)
        #expect(decoded.links == meta.links)
    }

    @Test func encodeKeepsReleaseCountryWebsiteAndHints() throws {
        var meta = MetaDetail(preview: MetaPreview(id: "tt1", type: "series", name: "S"))
        meta.released = Date(timeIntervalSince1970: 1_200_787_200)
        meta.country = "USA"
        meta.website = URL(string: "https://s.example")
        meta.defaultVideoId = "tt1:1:1"
        meta.hasScheduledVideos = true
        let decoded = try roundTrip(meta)
        #expect(decoded.released == meta.released)
        #expect(decoded.country == meta.country)
        #expect(decoded.website == meta.website)
        #expect(decoded.defaultVideoId == meta.defaultVideoId)
        #expect(decoded.hasScheduledVideos)
    }

    @Test func seriesFixtureEpisodeLabels() throws {
        let url = try #require(Bundle.module.url(forResource: "cinemeta-meta-series", withExtension: "json", subdirectory: "Fixtures"))
        let meta = try JSONDecoder().decode(MetaResponse.self, from: Data(contentsOf: url)).meta
        let pilot = try #require(meta.videos.first { $0.id == "tt0903747:1:1" })
        #expect(pilot.episodeLabel == "S1E1")
        #expect(pilot.released != nil)
        #expect(pilot.isReleased)
        #expect(!pilot.title.isEmpty)
    }
}

@Suite struct VideoTests {
    @Test func fallbackKeys() throws {
        let video = try decode(Video.self, """
        {"id":"v","name":"Named","firstAired":"2020-05-01T00:00:00Z","season":"3","number":4.0,
         "description":"About","thumbnail":"https://a.example/t.jpg","streams":[{"url":"https://a.example/v.mp4"},{"bad":1}]}
        """)
        #expect(video.title == "Named")
        #expect(video.released == Date(timeIntervalSince1970: 1_588_291_200))
        #expect(video.season == 3)
        #expect(video.episode == 4)
        #expect(video.overview == "About")
        #expect(video.thumbnail?.lastPathComponent == "t.jpg")
        #expect(video.streams.count == 2)
        #expect(video.streams.first?.url != nil)
        #expect(video.episodeLabel == "S3E4")
    }

    @Test func preferredKeys() throws {
        let video = try decode(Video.self, """
        {"id":"v","title":"T","name":"N","released":"2021-01-01T00:00:00Z","firstAired":"2020-01-01T00:00:00Z",
         "episode":2,"number":9,"overview":"O","description":"D"}
        """)
        #expect(video.title == "T")
        #expect(video.released == Date(timeIntervalSince1970: 1_609_459_200))
        #expect(video.episode == 2)
        #expect(video.overview == "O")
        #expect(video.episodeLabel == nil)
    }

    @Test func minimal() throws {
        let video = try decode(Video.self, #"{"id":"v"}"#)
        #expect(video.title == "")
        #expect(video.released == nil)
        #expect(video.isReleased)
        #expect(video.streams.isEmpty)
    }

    @Test func isReleased() {
        #expect(Video(id: "a", title: "", released: Date().addingTimeInterval(-60)).isReleased)
        #expect(!Video(id: "a", title: "", released: Date().addingTimeInterval(86_400)).isReleased)
    }

    @Test func ordering() {
        let s1e2 = Video(id: "a", title: "", season: 1, episode: 2)
        let s2e1 = Video(id: "b", title: "", season: 2, episode: 1)
        let s1e1Late = Video(id: "c", title: "", released: Date(timeIntervalSince1970: 200), season: 1, episode: 1)
        let s1e1Early = Video(id: "d", title: "", released: Date(timeIntervalSince1970: 100), season: 1, episode: 1)
        let undated = Video(id: "e", title: "", season: 1, episode: 1)
        #expect(s1e2 < s2e1)
        #expect(!(s2e1 < s1e2))
        #expect(s1e1Late < s1e2)
        #expect(s1e1Early < s1e1Late)
        #expect(s1e1Late < undated)
        #expect(!(undated < s1e1Late))
        let byDate = Video(id: "f", title: "", released: Date(timeIntervalSince1970: 1))
        #expect(byDate < Video(id: "g", title: "", released: Date(timeIntervalSince1970: 2)))
    }

    @Test func encodeRoundTripWithoutStreams() throws {
        let video = Video(
            id: "tt1:1:1", title: "Pilot", released: Date(timeIntervalSince1970: 1_200_787_200),
            season: 1, episode: 1, thumbnail: URL(string: "https://a.example/t.jpg"), overview: "O",
            streams: [AddonStream(url: URL(string: "https://a.example/v.mp4"))]
        )
        let decoded = try roundTrip(video)
        var expected = video
        expected.streams = []
        #expect(decoded == expected)
        let json = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(video))
        #expect(json["released"] == .string("2008-01-20T00:00:00Z"))
    }
}

@Suite struct AddonStreamTests {
    @Test func decodesAllFields() throws {
        let stream = try decode(AddonStream.self, """
        {"infoHash":"ABCDEF","fileIdx":"3","name":"N","title":"T","description":"D",
         "sources":["tracker:udp://a.example:1/announce","dht:abcdef","tracker:http://b.example/announce"],
         "subtitles":[{"id":"1","url":"https://a.example/s.srt","lang":"eng"},{"lang":"no url"}],
         "behaviorHints":{"notWebReady":true,"bingeGroup":"g","countryWhitelist":["US","GB"],"filename":"f.mkv",
                          "videoSize":"1234567890123","videoHash":"h",
                          "proxyHeaders":{"request":{"User-Agent":"UA"},"response":{"X":"Y"}}}}
        """)
        #expect(stream.infoHash == "abcdef")
        #expect(stream.fileIdx == 3)
        #expect(stream.details == "D")
        #expect(stream.isTorrent)
        #expect(stream.isPlayable)
        #expect(stream.trackers == ["udp://a.example:1/announce", "http://b.example/announce"])
        #expect(stream.subtitles.map(\.id) == ["1"])
        let hints = stream.behaviorHints
        #expect(hints.notWebReady)
        #expect(hints.bingeGroup == "g")
        #expect(hints.countryWhitelist == ["US", "GB"])
        #expect(hints.filename == "f.mkv")
        #expect(hints.videoSize == 1_234_567_890_123)
        #expect(hints.videoHash == "h")
        #expect(hints.requestHeaders == ["User-Agent": "UA"])
    }

    @Test func detailsFallsBackToTitle() throws {
        #expect(try decode(AddonStream.self, #"{"title":"T"}"#).details == "T")
        #expect(try decode(AddonStream.self, #"{}"#).details == nil)
    }

    @Test(arguments: [
        (#"{"url":"https://a.example/v.mp4"}"#, true, false),
        (#"{"ytId":"abc"}"#, true, false),
        (#"{"externalUrl":"https://a.example"}"#, true, false),
        (#"{"infoHash":"aa"}"#, true, true),
        (#"{"name":"nothing"}"#, false, false),
        (#"{"url":""}"#, false, false),
    ])
    func playability(json: String, playable: Bool, torrent: Bool) throws {
        let stream = try decode(AddonStream.self, json)
        #expect(stream.isPlayable == playable)
        #expect(stream.isTorrent == torrent)
    }

    @Test func malformedBehaviorHintsDefault() throws {
        let stream = try decode(AddonStream.self, #"{"url":"https://a.example","behaviorHints":"x"}"#)
        #expect(stream.behaviorHints == .init())
    }

    @Test func proxyHeadersWithoutRequest() throws {
        let hints = try decode(StreamBehaviorHints.self, #"{"proxyHeaders":{"response":{"a":"b"}}}"#)
        #expect(hints.requestHeaders.isEmpty)
        let bad = try decode(StreamBehaviorHints.self, #"{"proxyHeaders":{"request":{"a":1}}}"#)
        #expect(bad.requestHeaders.isEmpty)
    }

    @Test func magnetURLWithMultipleTrackers() throws {
        let stream = try decode(AddonStream.self, """
        {"url":"magnet:?xt=urn:btih:ABC123&dn=Name&tr=udp%3A%2F%2Fa.example%3A1&tr=udp%3A%2F%2Fb.example%3A2","sources":["dht:abc123"]}
        """)
        #expect(stream.url == nil)
        #expect(stream.infoHash == "abc123")
        #expect(stream.sources == ["dht:abc123", "tracker:udp://a.example:1", "tracker:udp://b.example:2"])
        #expect(stream.isPlayable)
    }

    @Test func magnetURLIsKeptWhenInfoHashGiven() throws {
        let stream = try decode(AddonStream.self, #"{"url":"magnet:?xt=urn:btih:zzz","infoHash":"AAA"}"#)
        #expect(stream.infoHash == "aaa")
        #expect(stream.url?.scheme == "magnet")
    }

    @Test func magnetURIUsesFilenameAndTrackers() throws {
        let stream = AddonStream(
            infoHash: "abc",
            sources: ["tracker:udp://t.example:80/announce", "dht:abc"],
            behaviorHints: StreamBehaviorHints(filename: "My Movie.mkv")
        )
        let uri = try #require(stream.magnetURI)
        #expect(uri.hasPrefix("magnet:?xt=urn:btih:abc&dn=My%20Movie.mkv&tr="))
        let parsed = try #require(URL(string: uri))
        #expect(Magnet.infoHash(from: parsed) == "abc")
        #expect(Magnet.trackers(from: parsed) == ["udp://t.example:80/announce"])
        #expect(AddonStream(url: URL(string: "https://a.example")).magnetURI == nil)
    }

    @Test func magnetURIFallsBackToDefaultTrackers() throws {
        let uri = try #require(AddonStream(infoHash: "abc").magnetURI)
        let parsed = try #require(URL(string: uri))
        #expect(Magnet.trackers(from: parsed) == Magnet.defaultTrackers)
        #expect(!uri.contains("dn="))
    }

    @Test func roundTrips() throws {
        let stream = AddonStream(
            url: URL(string: "https://a.example/v.mp4"), ytId: "y", infoHash: "abc", fileIdx: 2,
            externalUrl: URL(string: "https://a.example/ext"), name: "N", title: "T", description: "D",
            sources: ["tracker:udp://t.example:1"], subtitles: [Subtitle(id: "s", url: URL(string: "https://a.example/s.srt")!, lang: "eng")],
            behaviorHints: StreamBehaviorHints(notWebReady: true, bingeGroup: "g", filename: "f", videoSize: 9, videoHash: "h", requestHeaders: ["A": "B"])
        )
        #expect(try roundTrip(stream) == stream)
    }

    @Test func behaviorHintsRoundTripCountryWhitelist() throws {
        let hints = StreamBehaviorHints(countryWhitelist: ["us"])
        let decoded = try roundTrip(hints)
        #expect(decoded == hints)
    }

    @Test func behaviorHintsEncodeOmitsEmptyHeaders() throws {
        let json = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(StreamBehaviorHints()))
        #expect(json == .object(["notWebReady": .bool(false)]))
    }
}

@Suite struct SubtitleTests {
    @Test func languageFallbacks() throws {
        #expect(try decode(Subtitle.self, #"{"url":"https://a.example/1.srt","language":"fre"}"#).lang == "fre")
        #expect(try decode(Subtitle.self, #"{"url":"https://a.example/1.srt","label":"English"}"#).lang == "English")
        #expect(try decode(Subtitle.self, #"{"url":"https://a.example/1.srt"}"#).lang == "und")
        #expect(try decode(Subtitle.self, #"{"url":"https://a.example/1.srt","lang":"eng","language":"fre"}"#).lang == "eng")
    }

    @Test func idFallsBackToURLAndAcceptsNumbers() throws {
        #expect(try decode(Subtitle.self, #"{"url":"https://a.example/1.srt"}"#).id == "https://a.example/1.srt")
        #expect(try decode(Subtitle.self, #"{"url":"https://a.example/1.srt","id":42}"#).id == "42")
    }

    @Test func missingURLThrows() {
        #expect(throws: DecodingError.self) { try decode(Subtitle.self, #"{"id":"1","lang":"eng"}"#) }
        #expect(throws: DecodingError.self) { try decode(Subtitle.self, #"{"url":""}"#) }
    }

    @Test func roundTrips() throws {
        let subtitle = Subtitle(id: "x", url: URL(string: "https://a.example/x.vtt")!, lang: "spa")
        #expect(try roundTrip(subtitle) == subtitle)
    }
}

@Suite struct MagnetTests {
    @Test func uriEncodesNameAndTrackers() throws {
        let uri = Magnet.uri(infoHash: "abc", name: "A & B", trackers: ["udp://t.example:1/announce?x=1&y=2"])
        let parsed = try #require(URL(string: uri))
        let items = URLComponents(string: "x:" + uri.dropFirst("magnet:".count))?.queryItems ?? []
        #expect(items.first { $0.name == "dn" }?.value == "A & B")
        #expect(Magnet.trackers(from: parsed) == ["udp://t.example:1/announce?x=1&y=2"])
        #expect(Magnet.infoHash(from: parsed) == "abc")
    }

    @Test func infoHashRequiresBtih() {
        #expect(Magnet.infoHash(from: URL(string: "magnet:?xt=urn:sha1:abc")!) == nil)
        #expect(Magnet.infoHash(from: URL(string: "magnet:?dn=x")!) == nil)
        #expect(Magnet.infoHash(from: URL(string: "magnet:")!) == nil)
        #expect(Magnet.infoHash(from: URL(string: "magnet:?xt=URN:BTIH:ABC")!) == "abc")
    }

    @Test func trackersWithoutQuery() {
        #expect(Magnet.trackers(from: URL(string: "magnet:")!).isEmpty)
    }
}
