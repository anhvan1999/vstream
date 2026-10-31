import AddonKit
import Foundation
import Testing
import TestSupport
@testable import VStreamCore

private func addon(
    _ host: String,
    id: String? = nil,
    types: [String] = ["movie", "series"],
    idPrefixes: [String] = [],
    resources: [ManifestResource] = [],
    catalogs: [ManifestCatalog] = [],
    adult: Bool = false
) -> AddonDescriptor {
    AddonDescriptor(
        manifest: Manifest(
            id: id ?? "org.\(host)",
            version: "1.0.0",
            name: host,
            types: types,
            idPrefixes: idPrefixes,
            resources: resources,
            catalogs: catalogs,
            behaviorHints: .init(adult: adult)
        ),
        transportUrl: URL(string: "https://\(host)/manifest.json")!
    )
}

private func metas(_ ids: String...) -> MockHTTP.Response {
    .json(["metas": ids.map { ["id": $0, "type": "movie", "name": "Name \($0)"] }])
}

@Suite struct CatalogRowTests {
    let popular = ManifestCatalog(type: "movie", id: "top", name: "Popular")
    let search = ManifestCatalog(type: "movie", id: "search", name: "Search", extra: [ManifestExtra(name: "search", isRequired: true)])
    let byGenre = ManifestCatalog(type: "series", id: "genre", name: "By genre", extra: [ManifestExtra(name: "genre", isRequired: true, options: ["Drama"])])
    let searchable = ManifestCatalog(type: "series", id: "top", name: "Popular Series", extra: [ManifestExtra(name: "search"), ManifestExtra(name: "skip")])
    let needsBoth = ManifestCatalog(type: "movie", id: "odd", name: "Odd", extra: [ManifestExtra(name: "search", isRequired: true), ManifestExtra(name: "genre", isRequired: true)])

    var cinemeta: AddonDescriptor { addon("cinemeta.example", catalogs: [popular, search, byGenre, searchable, needsBoth]) }
    var adult: AddonDescriptor { addon("adult.example", catalogs: [ManifestCatalog(type: "movie", id: "x", name: "X")], adult: true) }

    @Test func idAndTitle() {
        let row = CatalogRow(addon: cinemeta, catalog: popular)
        #expect(row.id == "org.cinemeta.example:movie:top")
        #expect(row.title == "Popular · Movie")
        #expect(CatalogRow(addon: cinemeta, catalog: searchable).title == "Popular Series", "type already in the name")
    }

    @Test func homeRowsAreBrowsableCatalogs() {
        let rows = ContentService.homeRows([cinemeta, adult], includeAdult: false)
        #expect(rows.map(\.catalog.id) == ["top", "top"])
        #expect(rows.map(\.catalog.type) == ["movie", "series"])
        let withAdult = ContentService.homeRows([cinemeta, adult], includeAdult: true)
        #expect(withAdult.map(\.id).last == "org.adult.example:movie:x")
        #expect(withAdult.count == 3)
    }

    @Test func discoverRowsAllowRequiredGenre() {
        let rows = ContentService.discoverRows([cinemeta])
        #expect(rows.map(\.catalog.id) == ["top", "genre", "top"])
    }
}

@Suite struct ContentServiceTests {
    let movies = ManifestCatalog(type: "movie", id: "top", name: "Popular", extra: [ManifestExtra(name: "search"), ManifestExtra(name: "genre", options: ["Drama"]), ManifestExtra(name: "skip")])

    @Test func pageBuildsExtraPathInProtocolOrder() async throws {
        let http = MockHTTP(MockHTTP.routes(["/catalog/movie/top.json": metas("tt1", "tt2", "tt1")]))
        let service = ContentService(client: AddonClient(session: http.session))
        let row = CatalogRow(addon: addon("catalog.example", catalogs: [movies]), catalog: movies)

        let page = try await service.page(row)
        #expect(page.metas.map(\.id) == ["tt1", "tt2"], "duplicates are dropped")
        #expect(page.rawCount == 3)
        #expect(http.requests.first?.url.absoluteString == "https://catalog.example/catalog/movie/top.json")

        _ = try? await service.page(row, skip: 100, genre: "Sci-Fi & Fantasy", search: "the office")
        let url = try #require(http.requests.last?.url.absoluteString)
        #expect(url == "https://catalog.example/catalog/movie/top/search=the%20office&genre=Sci-Fi%20%26%20Fantasy&skip=100.json")
    }

    @Test func pageSurfacesHTTPErrors() async {
        let http = MockHTTP { _ in .init(status: 503) }
        let service = ContentService(client: AddonClient(session: http.session))
        let row = CatalogRow(addon: addon("down.example", catalogs: [movies]), catalog: movies)
        await #expect(throws: AddonError.self) { try await service.page(row) }
    }

    @Test func searchQueriesSearchableCatalogsAndKeepsOrder() async {
        let first = addon("a.example", catalogs: [
            ManifestCatalog(type: "movie", id: "top", name: "Movies", extra: [ManifestExtra(name: "search")]),
            ManifestCatalog(type: "movie", id: "plain", name: "Not searchable"),
            ManifestCatalog(type: "series", id: "top", name: "Series", extra: [ManifestExtra(name: "search", isRequired: true)]),
        ])
        let second = addon("b.example", catalogs: [
            ManifestCatalog(type: "movie", id: "empty", name: "Empty", extra: [ManifestExtra(name: "search")]),
            ManifestCatalog(type: "movie", id: "broken", name: "Broken", extra: [ManifestExtra(name: "search")]),
            ManifestCatalog(type: "movie", id: "genre", name: "Needs genre", extra: [ManifestExtra(name: "search"), ManifestExtra(name: "genre", isRequired: true)]),
            ManifestCatalog(type: "anime", id: "kitsu", name: "Kitsu", extra: [ManifestExtra(name: "search")]),
        ])
        let http = MockHTTP { request in
            switch (request.url.host, request.path) {
            case ("a.example", "/catalog/movie/top/search=dune.json"): metas("tt1")
            case ("a.example", "/catalog/series/top/search=dune.json"): metas("tt2", "tt3")
            case ("b.example", "/catalog/movie/empty/search=dune.json"): metas()
            case ("b.example", "/catalog/anime/kitsu/search=dune.json"): metas("kitsu:1")
            default: .init(status: 500)
            }
        }
        let results = await ContentService(client: AddonClient(session: http.session)).search("dune", addons: [first, second])
        #expect(results.map(\.id) == ["org.a.example:movie:top", "org.a.example:series:top", "org.b.example:anime:kitsu"])
        #expect(results.map { $0.metas.map(\.id) } == [["tt1"], ["tt2", "tt3"], ["kitsu:1"]])
        let paths = Set(http.requests.map { "\($0.url.host ?? "")\($0.path)" })
        #expect(paths.count == 5, "the plain and genre-required catalogs are never queried")
        #expect(!paths.contains { $0.contains("plain") || $0.contains("/genre/") })
    }

    @Test func searchWithNoAddonsIsEmpty() async {
        let http = MockHTTP { _ in .init(status: 500) }
        #expect(await ContentService(client: AddonClient(session: http.session)).search("x", addons: []).isEmpty)
        #expect(http.requests.isEmpty)
    }

    // MARK: Meta

    @Test func metaFallsBackAcrossAddonsInOrder() async throws {
        let metaResource = ManifestResource(name: "meta", types: ["series"], idPrefixes: ["tt"])
        let failing = addon("failing.example", resources: [metaResource])
        let catalogOnly = addon("catalog.example", resources: [ManifestResource(name: "catalog")])
        let otherPrefix = addon("kitsu.example", resources: [ManifestResource(name: "meta", types: ["series"], idPrefixes: ["kitsu:"])])
        let working = addon("working.example", resources: [metaResource])
        let http = MockHTTP { request in
            switch request.url.host {
            case "failing.example": .init(status: 500)
            case "working.example": .json(["meta": ["id": "tt0903747", "type": "series", "name": "Breaking Bad", "videos": [["id": "tt0903747:1:1", "season": 1, "episode": 1, "title": "Pilot"]]]])
            default: .json(["meta": ["id": "wrong", "type": "series", "name": "Wrong"]])
            }
        }
        let service = ContentService(client: AddonClient(session: http.session))
        let meta = try await service.meta(type: "series", id: "tt0903747", addons: [failing, catalogOnly, otherPrefix, working])
        #expect(meta.name == "Breaking Bad")
        #expect(meta.videos.map(\.id) == ["tt0903747:1:1"])
        #expect(http.requests.map(\.url.host) == ["failing.example", "working.example"])
        #expect(http.requests.last?.path == "/meta/series/tt0903747.json")
    }

    @Test func metaThrowsLastErrorWhenAllFail() async {
        let http = MockHTTP { _ in .init(status: 404) }
        let service = ContentService(client: AddonClient(session: http.session))
        let broken = addon("broken.example", resources: [ManifestResource(name: "meta")])
        let error = await #expect(throws: AddonError.self) {
            try await service.meta(type: "movie", id: "tt1", addons: [broken])
        }
        guard case let .http(status, _)? = error else { Issue.record("expected HTTP error, got \(String(describing: error))"); return }
        #expect(status == 404)
    }

    @Test func metaWithoutCapableAddonIsUnsupported() async {
        let http = MockHTTP { _ in .init(status: 500) }
        let service = ContentService(client: AddonClient(session: http.session))
        let error = await #expect(throws: AddonError.self) {
            try await service.meta(type: "movie", id: "tt1", addons: [addon("x.example", resources: [ManifestResource(name: "stream")])])
        }
        guard case .unsupported? = error else { Issue.record("expected unsupported, got \(String(describing: error))"); return }
        #expect(http.requests.isEmpty)
    }

    // MARK: Streams

    @Test func streamsArriveGroupedPerAddon() async {
        let streamResource = ManifestResource(name: "stream")
        let torrentio = addon("torrentio.example", resources: [streamResource])
        let broken = addon("broken.example", resources: [streamResource])
        let moviesOnly = addon("movies.example", types: ["movie"], resources: [streamResource])
        let http = MockHTTP { request in
            switch request.url.host {
            case "torrentio.example": .json(["streams": [
                ["infoHash": "ABCDEF0123456789ABCDEF0123456789ABCDEF01", "fileIdx": 1, "name": "Torrentio\n1080p"],
                ["name": "nothing playable"],
                ["url": "https://cdn.example/v.mkv"],
            ]])
            default: .init(status: 500)
            }
        }
        let service = ContentService(client: AddonClient(session: http.session))
        var groups: [String: StreamGroup] = [:]
        for await group in service.streams(type: "series", id: "tt1:1:1", addons: [torrentio, broken, moviesOnly]) {
            groups[group.id] = group
        }
        #expect(groups.count == 2, "movies-only addon isn't asked for series")
        let ok = groups[torrentio.id]
        #expect(ok?.error == nil)
        #expect(ok?.streams.count == 2, "unplayable entries are filtered")
        #expect(ok?.streams.first?.infoHash == "abcdef0123456789abcdef0123456789abcdef01")
        #expect(groups[broken.id]?.streams.isEmpty == true)
        #expect(groups[broken.id]?.error?.contains("500") == true)
        #expect(http.requests.allSatisfy { $0.path == "/stream/series/tt1%3A1%3A1.json" || $0.path == "/stream/series/tt1:1:1.json" })
    }

    @Test func streamsWithoutCandidatesFinishImmediately() async {
        let http = MockHTTP { _ in .init(status: 500) }
        let service = ContentService(client: AddonClient(session: http.session))
        var count = 0
        for await _ in service.streams(type: "movie", id: "tt1", addons: []) { count += 1 }
        #expect(count == 0)
    }

    // MARK: Subtitles

    @Test func subtitlesMergeStreamAndAddonsWithoutDuplicates() async throws {
        let subtitleResource = ManifestResource(name: "subtitles")
        let openSubtitles = addon("os.example", resources: [subtitleResource])
        let other = addon("other.example", resources: [subtitleResource])
        let broken = addon("broken.example", resources: [subtitleResource])
        let unrelated = addon("unrelated.example", resources: [ManifestResource(name: "stream")])
        let http = MockHTTP { request in
            switch request.url.host {
            case "os.example": .json(["subtitles": [
                ["id": "dup", "url": "https://subs.example/embedded.srt", "lang": "eng"],
                ["id": "1", "url": "https://subs.example/1.srt", "lang": "vie"],
                ["id": "2", "url": "https://subs.example/1.srt", "lang": "vie"],
            ]])
            case "other.example": .json(["subtitles": [["url": "https://subs.example/2.srt", "language": "jpn"]]])
            default: .init(status: 500)
            }
        }
        let stream = AddonStream(
            infoHash: "abcdef0123456789abcdef0123456789abcdef01",
            subtitles: [Subtitle(id: "embedded", url: URL(string: "https://subs.example/embedded.srt")!, lang: "eng")],
            behaviorHints: .init(filename: "Show S01E01.mkv", videoSize: 123_456, videoHash: "8e245d9679d31e12")
        )
        let service = ContentService(client: AddonClient(session: http.session))
        let subtitles = await service.subtitles(type: "movie", id: "tt1", stream: stream, addons: [openSubtitles, other, broken, unrelated])

        #expect(subtitles.first?.id == "embedded", "the stream's own subtitles come first")
        #expect(subtitles.count == 3)
        #expect(Set(subtitles.map(\.url.absoluteString)) == ["https://subs.example/embedded.srt", "https://subs.example/1.srt", "https://subs.example/2.srt"])
        #expect(subtitles.first { $0.url.absoluteString.hasSuffix("2.srt") }?.lang == "jpn")

        #expect(http.requests.count == 3)
        let url = try #require(http.requests.first { $0.url.host == "os.example" }?.url.absoluteString)
        #expect(url == "https://os.example/subtitles/movie/tt1/videoHash=8e245d9679d31e12&videoSize=123456&filename=Show%20S01E01.mkv.json")
    }

    @Test func subtitlesWithoutStreamSendNoExtras() async throws {
        let http = MockHTTP { _ in .json(["subtitles": [["id": "1", "url": "https://subs.example/1.srt", "lang": "eng"]]]) }
        let os = addon("os.example", resources: [ManifestResource(name: "subtitles")])
        let subtitles = await ContentService(client: AddonClient(session: http.session)).subtitles(type: "movie", id: "tt1", stream: nil, addons: [os])
        #expect(subtitles.map(\.id) == ["1"])
        #expect(http.requests.first?.url.absoluteString == "https://os.example/subtitles/movie/tt1.json")
    }
}
