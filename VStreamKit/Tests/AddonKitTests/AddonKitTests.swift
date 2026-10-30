import Foundation
import Testing
@testable import AddonKit

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

@Suite struct ManifestURLTests {
    @Test(arguments: [
        ("stremio://v3-cinemeta.strem.io/manifest.json", "https://v3-cinemeta.strem.io/manifest.json"),
        ("v3-cinemeta.strem.io", "https://v3-cinemeta.strem.io/manifest.json"),
        ("https://torrentio.strem.fun/providers=yts/", "https://torrentio.strem.fun/providers=yts/manifest.json"),
        ("  https://a.example/x/manifest.json#config  ", "https://a.example/x/manifest.json"),
        ("https://a.example/manifest.json?token=abc", "https://a.example/manifest.json?token=abc"),
    ])
    func normalizes(input: String, expected: String) {
        #expect(AddonURL.normalizeManifestURL(input)?.absoluteString == expected)
    }

    @Test func rejectsGarbage() {
        #expect(AddonURL.normalizeManifestURL("   ") == nil)
        #expect(AddonURL.normalizeManifestURL("https://") == nil)
    }
}

@Suite struct ResourceURLTests {
    let transport = URL(string: "https://torrentio.strem.fun/providers=yts%7Ceztv/manifest.json")!

    @Test func streamURL() {
        let url = AddonURL.resource(transportURL: transport, resource: "stream", type: "series", id: "tt0903747:1:2")
        #expect(url?.absoluteString == "https://torrentio.strem.fun/providers=yts%7Ceztv/stream/series/tt0903747%3A1%3A2.json")
    }

    @Test func catalogExtrasKeepOrderAndEncode() {
        let url = AddonURL.resource(
            transportURL: URL(string: "https://v3-cinemeta.strem.io/manifest.json")!,
            resource: "catalog",
            type: "movie",
            id: "top",
            extra: [ExtraArgument("search", "the office & co"), ExtraArgument("skip", "100")]
        )
        #expect(url?.absoluteString == "https://v3-cinemeta.strem.io/catalog/movie/top/search=the%20office%20%26%20co&skip=100.json")
    }

    @Test func preservesManifestQuery() {
        let url = AddonURL.resource(
            transportURL: URL(string: "https://a.example/addon/manifest.json?key=1")!,
            resource: "meta",
            type: "movie",
            id: "tt1"
        )
        #expect(url?.absoluteString == "https://a.example/addon/meta/movie/tt1.json?key=1")
    }
}

@Suite struct ParsingTests {
    @Test func cinemetaManifest() throws {
        let manifest = try JSONDecoder().decode(Manifest.self, from: fixture("cinemeta-manifest"))
        #expect(manifest.id == "com.linvo.cinemeta")
        #expect(manifest.supports(resource: "meta", type: "movie", id: "tt0816692"))
        #expect(!manifest.supports(resource: "meta", type: "movie", id: "kitsu:1"))
        #expect(!manifest.supports(resource: "stream", type: "movie"))
        let top = try #require(manifest.catalogs.first { $0.type == "movie" && $0.id == "top" })
        #expect(top.isBrowsable)
        #expect(top.supportsPaging)
        #expect(manifest.catalogs.contains { $0.isSearchable })
        #expect(!top.genres.isEmpty)
    }

    @Test func manifestRoundTripsRawJSON() throws {
        let data = try fixture("torrentio-manifest")
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        let reencoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(manifest))
        let original = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(reencoded == original)
        #expect(manifest.supports(resource: "stream", type: "series", id: "tt0903747:1:1"))
        #expect(manifest.behaviorHints.configurable)
    }

    @Test func catalog() throws {
        let response = try JSONDecoder().decode(MetasResponse.self, from: fixture("cinemeta-catalog"))
        #expect(response.metas.count > 10)
        let first = try #require(response.metas.first)
        #expect(first.id.hasPrefix("tt"))
        #expect(first.poster != nil)
    }

    @Test func seriesMeta() throws {
        let meta = try JSONDecoder().decode(MetaResponse.self, from: fixture("cinemeta-meta-series")).meta
        #expect(meta.name == "Breaking Bad")
        #expect(meta.isSeriesLike)
        #expect(meta.seasons.first == 1)
        #expect(meta.seasons.last == 0)
        let episodes = meta.videos(inSeason: 1)
        #expect(episodes.first?.id == "tt0903747:1:1")
        let numbers = episodes.compactMap(\.episode)
        #expect(numbers == numbers.sorted())
        #expect(!meta.cast.isEmpty)
    }

    @Test func torrentioStreams() throws {
        let streams = try JSONDecoder().decode(StreamsResponse.self, from: fixture("torrentio-streams")).streams
        #expect(streams.count > 50)
        let stream = try #require(streams.first)
        #expect(stream.isTorrent)
        #expect(stream.infoHash?.count == 40)
        #expect(stream.behaviorHints.bingeGroup?.hasPrefix("torrentio") == true)
        let magnet = try #require(stream.magnetURI)
        #expect(magnet.hasPrefix("magnet:?xt=urn:btih:\(stream.infoHash!)"))
        #expect(magnet.contains("&tr="))
    }

    @Test func subtitles() throws {
        let subtitles = try JSONDecoder().decode(SubtitlesResponse.self, from: fixture("opensubtitles-subtitles")).subtitles
        #expect(subtitles.count > 10)
        #expect(subtitles.allSatisfy { !$0.lang.isEmpty })
    }

    @Test func lenientFields() throws {
        let json = """
        {"metas":[
          {"id":"a","type":"movie","name":"A","imdbRating":7.5,"releaseInfo":2014,"genres":"Drama, Sci-Fi"},
          {"id":"b"},
          {"id":"c","type":"movie","name":"C","posterShape":"landscape"}
        ]}
        """
        let metas = try JSONDecoder().decode(MetasResponse.self, from: Data(json.utf8)).metas
        #expect(metas.map(\.id) == ["a", "c"])
        #expect(metas[0].imdbRating == "7.5")
        #expect(metas[0].releaseInfo == "2014")
        #expect(metas[0].genres == ["Drama", "Sci-Fi"])
        #expect(metas[1].posterShape == .landscape)
    }

    @Test func magnetInURLBecomesTorrent() throws {
        let json = #"{"url":"magnet:?xt=urn:btih:ABCDEF0123456789ABCDEF0123456789ABCDEF01&tr=udp%3A%2F%2Ft.example%3A80","name":"x"}"#
        let stream = try JSONDecoder().decode(AddonStream.self, from: Data(json.utf8))
        #expect(stream.url == nil)
        #expect(stream.infoHash == "abcdef0123456789abcdef0123456789abcdef01")
        #expect(stream.trackers == ["udp://t.example:80"])
    }

    @Test func legacyCatalogExtras() throws {
        let json = #"{"type":"movie","id":"x","extraSupported":["search","genre"],"extraRequired":["search"]}"#
        let catalog = try JSONDecoder().decode(ManifestCatalog.self, from: Data(json.utf8))
        #expect(catalog.isSearchable)
        #expect(!catalog.isBrowsable)
    }
}
