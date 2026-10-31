import Foundation
import Testing
import TestSupport
@testable import AddonKit

private func fixtureData(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

private func addon(_ transport: String = "https://addon.example/cfg=1/manifest.json") -> AddonDescriptor {
    AddonDescriptor(manifest: Manifest(id: "org.test", version: "1.0.0", name: "Test"), transportUrl: URL(string: transport)!)
}

@Suite struct AddonClientTests {
    @Test func fetchManifestNormalizesStremioScheme() async throws {
        let http = MockHTTP(MockHTTP.routes(["/manifest.json": .json(["id": "org.test", "name": "Test", "version": "2.0.0"])]))
        let client = AddonClient(session: http.session)
        let descriptor = try await client.fetchManifest(from: "stremio://addon.example/cfg=1/")
        #expect(descriptor.transportUrl.absoluteString == "https://addon.example/cfg=1/manifest.json")
        #expect(descriptor.manifest.version == "2.0.0")
        #expect(descriptor.flags == .init())
        let request = try #require(http.requests.first)
        #expect(request.method == "GET")
        #expect(request.path == "/cfg=1/manifest.json")
        #expect(request.headers["Accept"] == "application/json")
    }

    @Test func fetchManifestFromRealFixture() async throws {
        let body = try fixtureData("torrentio-manifest")
        let http = MockHTTP { _ in .init(body: body) }
        let descriptor = try await AddonClient(session: http.session).fetchManifest(from: "torrentio.strem.fun", bypassCache: true)
        #expect(descriptor.manifest.supports(resource: "stream", type: "movie", id: "tt0816692"))
        #expect(descriptor.id == "https://torrentio.strem.fun/manifest.json")
    }

    @Test func fetchManifestRejectsInvalidInput() async {
        let http = MockHTTP { _ in .json([:]) }
        let error = await #expect(throws: AddonError.self) {
            try await AddonClient(session: http.session).fetchManifest(from: "  ")
        }
        guard case let .invalidURL(input) = error else { Issue.record("wrong error \(String(describing: error))"); return }
        #expect(input == "  ")
        #expect(http.requests.isEmpty)
    }

    @Test func fetchManifestWithoutIdIsDecodingError() async {
        let http = MockHTTP { _ in .json(["name": "No id"]) }
        let error = await #expect(throws: AddonError.self) {
            try await AddonClient(session: http.session).fetchManifest(from: "https://addon.example")
        }
        guard case let .decoding(url, underlying) = error else { Issue.record("wrong error"); return }
        #expect(url.absoluteString == "https://addon.example/manifest.json")
        #expect(!underlying.isEmpty)
        #expect(error?.errorDescription?.hasPrefix("Could not read response from addon.example") == true)
    }

    @Test(arguments: [404, 500, 302])
    func httpErrorStatus(status: Int) async {
        let http = MockHTTP { _ in .init(status: status, body: Data("{}".utf8)) }
        let error = await #expect(throws: AddonError.self) {
            try await AddonClient(session: http.session).meta(addon(), type: "movie", id: "tt1")
        }
        guard case let .http(code, url) = error else { Issue.record("wrong error"); return }
        #expect(code == status)
        #expect(url.absoluteString == "https://addon.example/cfg=1/meta/movie/tt1.json")
        #expect(error?.errorDescription == "HTTP \(status) from addon.example")
    }

    @Test func catalogBuildsExtraPathAndDedupes() async throws {
        let http = MockHTTP { _ in
            .json(["metas": [
                ["id": "tt1", "type": "movie", "name": "One"],
                ["id": "tt1", "type": "movie", "name": "One again"],
                ["id": "tt1", "type": "series", "name": "Same id, other type"],
                ["name": "broken"],
                ["id": "tt2", "type": "movie", "name": "Two"],
            ]])
        }
        let page = try await AddonClient(session: http.session).catalog(
            addon(), type: "movie", id: "top", extra: [ExtraArgument("genre", "Sci-Fi"), ExtraArgument("skip", "100")]
        )
        #expect(page.metas.map(\.name) == ["One", "Same id, other type", "Two"])
        #expect(page.rawCount == 4)
        #expect(http.requests.first?.url.absoluteString == "https://addon.example/cfg=1/catalog/movie/top/genre=Sci-Fi&skip=100.json")
    }

    @Test func catalogFixture() async throws {
        let body = try fixtureData("cinemeta-catalog")
        let http = MockHTTP { _ in .init(body: body) }
        let page = try await AddonClient(session: http.session).catalog(addon(), type: "movie", id: "top")
        #expect(page.metas.count == 49)
        #expect(page.rawCount == 49)
        #expect(http.requests.first?.path == "/cfg=1/catalog/movie/top.json")
    }

    @Test func catalogWithoutMetasIsEmpty() async throws {
        let http = MockHTTP { _ in .json(["unexpected": true]) }
        let page = try await AddonClient(session: http.session).catalog(addon(), type: "movie", id: "top")
        #expect(page.metas.isEmpty)
        #expect(page.rawCount == 0)
    }

    @Test(arguments: [
        #"{"meta":{"id":"tt1","type":"movie","name":"Wrapped"}}"#,
        #"{"data":{"meta":{"id":"tt1","type":"movie","name":"Wrapped"}}}"#,
        #"{"data":{"id":"tt1","type":"movie","name":"Wrapped"}}"#,
        #"{"id":"tt1","type":"movie","name":"Wrapped"}"#,
    ])
    func metaAcceptsWrappedShapes(body: String) async throws {
        let http = MockHTTP { _ in .json(string: body) }
        let meta = try await AddonClient(session: http.session).meta(addon(), type: "movie", id: "tt1")
        #expect(meta.id == "tt1")
        #expect(meta.name == "Wrapped")
    }

    @Test func metaNullIsDecodingError() async {
        let http = MockHTTP { _ in .json(string: #"{"meta":null}"#) }
        await #expect(throws: AddonError.self) {
            try await AddonClient(session: http.session).meta(addon(), type: "movie", id: "tt1")
        }
    }

    @Test func metaSeriesFixture() async throws {
        let body = try fixtureData("cinemeta-meta-series")
        let http = MockHTTP { _ in .init(body: body) }
        let meta = try await AddonClient(session: http.session).meta(addon(), type: "series", id: "tt0903747")
        #expect(meta.name == "Breaking Bad")
        #expect(meta.videos == meta.videos.sorted())
    }

    @Test func streamsDropUnplayableAndEncodeId() async throws {
        let http = MockHTTP { _ in
            .json(["streams": [
                ["name": "no source"],
                ["url": "https://cdn.example/a.mp4", "name": "direct"],
                ["infoHash": "ABC", "name": "torrent"],
                ["ytId": "dQw4w9WgXcQ"],
                ["externalUrl": "https://example.com/watch"],
                "garbage",
            ]])
        }
        let streams = try await AddonClient(session: http.session).streams(addon(), type: "series", id: "tt1:2:3")
        #expect(streams.count == 4)
        #expect(streams.map(\.name) == ["direct", "torrent", nil, nil])
        #expect(http.requests.first?.url.absoluteString == "https://addon.example/cfg=1/stream/series/tt1%3A2%3A3.json")
    }

    @Test func streamsFixture() async throws {
        let body = try fixtureData("torrentio-streams")
        let http = MockHTTP { _ in .init(body: body) }
        let streams = try await AddonClient(session: http.session).streams(addon(), type: "movie", id: "tt0816692")
        #expect(streams.count == 154)
        #expect(streams.allSatisfy { $0.isTorrent })
    }

    @Test func subtitlesWithExtra() async throws {
        let body = try fixtureData("opensubtitles-subtitles")
        let http = MockHTTP { _ in .init(body: body) }
        let subtitles = try await AddonClient(session: http.session).subtitles(
            addon("https://opensubtitles-v3.strem.io/manifest.json"),
            type: "movie",
            id: "tt0816692",
            extra: [ExtraArgument("filename", "Interstellar 2014.mkv"), ExtraArgument("videoSize", "123")]
        )
        #expect(subtitles.first?.id == "5919226")
        #expect(subtitles.first?.lang == "pob")
        #expect(http.requests.first?.url.absoluteString
            == "https://opensubtitles-v3.strem.io/subtitles/movie/tt0816692/filename=Interstellar%202014.mkv&videoSize=123.json")
    }

    @Test func invalidJSONIsDecodingError() async {
        let http = MockHTTP { _ in .init(body: Data("<html>".utf8)) }
        let error = await #expect(throws: AddonError.self) {
            try await AddonClient(session: http.session).subtitles(addon(), type: "movie", id: "tt1")
        }
        guard case .decoding = error else { Issue.record("wrong error"); return }
    }

    @Test func transportErrorPropagates() async {
        let http = MockHTTP { _ in throw URLError(.notConnectedToInternet) }
        await #expect(throws: URLError.self) {
            try await AddonClient(session: http.session).meta(addon(), type: "movie", id: "tt1")
        }
    }

    @Test func coalescesIdenticalInFlightRequests() async throws {
        let http = MockHTTP { _ in
            Thread.sleep(forTimeInterval: 0.3)
            return .json(["meta": ["id": "tt1", "type": "movie", "name": "Slow"]])
        }
        let client = AddonClient(session: http.session)
        let descriptor = addon()
        async let first = client.meta(descriptor, type: "movie", id: "tt1")
        async let second = client.meta(descriptor, type: "movie", id: "tt1")
        let results = try await [first, second]
        #expect(results.map(\.name) == ["Slow", "Slow"])
        #expect(http.requests.count == 1)

        _ = try await client.meta(descriptor, type: "movie", id: "tt1")
        #expect(http.requests.count == 2)
    }

    @Test func coalescedFailureReachesEveryCaller() async {
        let http = MockHTTP { _ in
            Thread.sleep(forTimeInterval: 0.3)
            return .init(status: 503)
        }
        let client = AddonClient(session: http.session)
        let descriptor = addon()
        async let first: Result<MetaDetail, Error> = { do { return .success(try await client.meta(descriptor, type: "movie", id: "tt1")) } catch { return .failure(error) } }()
        async let second: Result<MetaDetail, Error> = { do { return .success(try await client.meta(descriptor, type: "movie", id: "tt1")) } catch { return .failure(error) } }()
        let results = await [first, second]
        for result in results {
            guard case let .failure(error as AddonError) = result, case .http(503, _) = error else {
                Issue.record("expected HTTP 503, got \(result)")
                continue
            }
        }
        #expect(http.requests.count == 1)
    }

    @Test func bypassCacheDoesNotCoalesce() async throws {
        let http = MockHTTP { _ in
            Thread.sleep(forTimeInterval: 0.2)
            return .json(["id": "org.test"])
        }
        let client = AddonClient(session: http.session)
        async let first = client.fetchManifest(from: "https://addon.example", bypassCache: true)
        async let second = client.fetchManifest(from: "https://addon.example", bypassCache: true)
        _ = try await [first, second]
        #expect(http.requests.count == 2)
    }

    @Test func differentURLsAreNotCoalesced() async throws {
        let http = MockHTTP { request in
            Thread.sleep(forTimeInterval: 0.1)
            let id = request.url.deletingPathExtension().lastPathComponent
            return .json(["meta": ["id": id, "type": "movie"]])
        }
        let client = AddonClient(session: http.session)
        async let a = client.meta(addon(), type: "movie", id: "a")
        async let b = client.meta(addon(), type: "movie", id: "b")
        let ids = try await [a, b].map(\.id)
        #expect(ids == ["a", "b"])
        #expect(http.requests.count == 2)
    }

    @Test func errorDescriptions() {
        #expect(AddonError.invalidURL("x").errorDescription == "Invalid addon URL: x")
        #expect(AddonError.unsupported(resource: "stream", addon: "Cinemeta").errorDescription == "Cinemeta does not provide stream")
        let noHost = URL(string: "file:///tmp/a.json")!
        #expect(AddonError.http(status: 500, url: noHost).errorDescription == "HTTP 500 from file:///tmp/a.json")
        #expect(AddonError.decoding(url: noHost, underlying: "bad").errorDescription == "Could not read response from addon: bad")
    }
}
