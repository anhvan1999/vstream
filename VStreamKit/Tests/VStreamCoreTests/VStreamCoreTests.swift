import AddonKit
import DebridKit
import Foundation
import StremioAPI
import Testing
@testable import VStreamCore

private struct MockDebrid: DebridProvider {
    let service = DebridService.torbox
    var result: Result<DebridLink, DebridError>

    func validate() async throws -> Bool { true }
    func cachedHashes(_ hashes: [String]) async throws -> Set<String>? { [] }
    func resolve(_ request: DebridRequest) async throws -> DebridLink { try result.get() }
    func startDownload(_ request: DebridRequest) async throws { await downloads.add(request.infoHash) }
    let downloads = Downloads()
}

private actor Downloads {
    var hashes: [String] = []
    func add(_ hash: String) { hashes.append(hash) }
}

@Suite struct ResolverTests {
    let torrent = AddonStream(infoHash: "abcdef0123456789abcdef0123456789abcdef01", fileIdx: 1)

    @Test func directURLKeepsHeaders() async throws {
        let stream = AddonStream(url: URL(string: "https://cdn.example/v.mkv")!, behaviorHints: .init(requestHeaders: ["Referer": "x"]))
        let outcome = try await StreamResolver(debrid: nil, mode: .automatic).resolve(stream, context: .init())
        guard case let .play(playback) = outcome else { Issue.record("expected play"); return }
        #expect(playback.source == .direct)
        #expect(playback.headers == ["Referer": "x"])
    }

    @Test func torrentUsesDebridWhenCached() async throws {
        let link = DebridLink(url: URL(string: "https://tb.example/file.mkv")!, filename: "file.mkv", size: 1)
        let resolver = StreamResolver(debrid: MockDebrid(result: .success(link)), mode: .automatic)
        guard case let .play(playback) = try await resolver.resolve(torrent, context: .init()) else { Issue.record("expected play"); return }
        #expect(playback.source == .debrid(.torbox))
        #expect(playback.url == link.url)
    }

    @Test func debridOnlyQueuesUncachedTorrent() async {
        let debrid = MockDebrid(result: .failure(.notCached))
        let resolver = StreamResolver(debrid: debrid, mode: .debridOnly, addsUncachedToDebrid: true)
        await #expect(throws: ResolveError.self) { try await resolver.resolve(torrent, context: .init()) }
        #expect(await debrid.downloads.hashes == [torrent.infoHash])
    }

    @Test func debridOnlyReportsExpiredKey() async {
        let resolver = StreamResolver(debrid: MockDebrid(result: .failure(.invalidKey)), mode: .debridOnly, addsUncachedToDebrid: true)
        await #expect(throws: DebridError.self) { try await resolver.resolve(torrent, context: .init()) }
    }

    @Test func parsesTorrentioDebridLinks() throws {
        let url = URL(string: "https://torrentio.strem.fun/resolve/torbox/KEY/DD9D6B21CDE411A1AB590D83746858CF5F91081E/Show.S02E07.mkv/6/Show.S02E07.mkv")!
        let link = try #require(AddonDebridLink(url))
        #expect(link.service == .torbox)
        #expect(link.infoHash == "dd9d6b21cde411a1ab590d83746858cf5f91081e")
        #expect(link.fileIndex == 6)
        #expect(link.filename == "Show.S02E07.mkv")
        #expect(AddonDebridLink(URL(string: "https://cdn.example/resolve/movie.mkv")!) == nil)
        #expect(AddonDebridLink(URL(string: "https://cdn.example/v.mkv")!) == nil)
    }

    @Test func debridOnlyFailsWhenNotCached() async {
        let resolver = StreamResolver(debrid: MockDebrid(result: .failure(.notCached)), mode: .debridOnly)
        await #expect(throws: DebridError.self) { try await resolver.resolve(torrent, context: .init()) }
    }

    @Test func debridOnlyWithoutProviderAsksForSetup() async {
        let resolver = StreamResolver(debrid: nil, mode: .debridOnly)
        await #expect(throws: ResolveError.self) { try await resolver.resolve(torrent, context: .init()) }
    }

    @Test func youtubeOpensExternally() async throws {
        let outcome = try await StreamResolver(debrid: nil, mode: .automatic).resolve(AddonStream(ytId: "dQw4w9WgXcQ"), context: .init())
        guard case let .openExternally(url) = outcome else { Issue.record("expected external"); return }
        #expect(url.absoluteString.contains("dQw4w9WgXcQ"))
    }

    @Test func episodeContextParsesSeriesIDs() {
        #expect(EpisodeContext(videoID: "tt0903747:2:5") == EpisodeContext(season: 2, episode: 5))
        #expect(EpisodeContext(videoID: "kitsu:1:3:4") == EpisodeContext(season: 3, episode: 4))
        #expect(EpisodeContext(videoID: "tt0816692") == EpisodeContext())
    }
}

@Suite struct FileSelectorTests {
    let files = [
        DebridFile(id: "1", path: "Show/Sample/sample.mkv", size: 10),
        DebridFile(id: "2", path: "Show/Show.S01E01.1080p.mkv", size: 1_000),
        DebridFile(id: "3", path: "Show/Show.S01E02.1080p.mkv", size: 1_100),
        DebridFile(id: "4", path: "Show/Show.S01E10.1080p.mkv", size: 1_200),
        DebridFile(id: "5", path: "Show/readme.nfo", size: 1),
    ]

    @Test func picksEpisodeByPattern() {
        let request = DebridRequest(infoHash: "x", magnet: "m", season: 1, episode: 1)
        #expect(DebridFileSelector.select(files, request: request)?.id == "2")
    }

    @Test func filenameWins() {
        let request = DebridRequest(infoHash: "x", magnet: "m", filename: "show.s01e02.1080p.mkv", season: 1, episode: 1)
        #expect(DebridFileSelector.select(files, request: request)?.id == "3")
    }

    @Test func fallsBackToLargestVideo() {
        #expect(DebridFileSelector.select(files, request: DebridRequest(infoHash: "x", magnet: "m"))?.id == "4")
    }
}

@Suite struct PresentationTests {
    @Test func parsesTorrentioTitle() {
        let stream = AddonStream(
            name: "Torrentio\n4k DV | HDR10+",
            title: "Interstellar 2014 2160p REMUX DV HDR10+ TrueHD 7.1 Atmos\n👤 248 💾 95.63 GB ⚙️ TorrentGalaxy"
        )
        let presentation = StreamPresentation(stream)
        #expect(presentation.quality == "2160p")
        #expect(presentation.size == "95.63 GB")
        #expect(presentation.seeders == "248")
        #expect(presentation.source == "TorrentGalaxy")
        #expect(presentation.tags.contains("DV"))
        #expect(presentation.tags.contains("HDR10+"))
        #expect(!presentation.tags.contains("HDR"))
    }

    @Test func labelsTitleAndExtras() {
        let stream = AddonStream(
            name: "[TB+] Torrentio\n4k",
            title: "Cyberpunk.Edgerunners.S01E03.2160p.mkv\n👤 51 💾 2.23 GB ⚙️ Rutracker\nDubbed / Dual Audio"
        )
        let presentation = StreamPresentation(stream)
        #expect(presentation.sourceLabel == "[TB+] Torrentio · 4k")
        #expect(presentation.title == "Cyberpunk.Edgerunners.S01E03.2160p.mkv")
        #expect(presentation.extras == "Dubbed / Dual Audio")
        let named = StreamPresentation(AddonStream(name: "Direct", behaviorHints: .init(filename: "movie.mp4")))
        #expect(named.title == "movie.mp4")
        #expect(named.extras == nil)
    }

    @Test func traktItemMapping() {
        #expect(TraktAccount.traktItem(type: "movie", videoID: "tt0816692") == .movie(imdb: "tt0816692"))
        #expect(TraktAccount.traktItem(type: "series", videoID: "tt0903747:1:2") == .episode(showIMDB: "tt0903747", season: 1, episode: 2))
        #expect(TraktAccount.traktItem(type: "series", videoID: "kitsu:1") == nil)
    }
}

@MainActor
@Suite(.serialized) struct LibraryTests {
    let series = MetaPreview(id: "tt0903747", type: "series", name: "Breaking Bad")
    let movie = MetaPreview(id: "tt0816692", type: "movie", name: "Interstellar")

    @Test func partialProgressAppearsInContinueWatching() {
        let library = LibraryStore(storageName: "library-tests")
        library.reset()
        library.recordProgress(meta: movie, videoID: movie.id, position: 600, duration: 10_000, nextVideoID: nil)
        let entry = library.continueWatching.first
        #expect(entry?.item.id == movie.id)
        #expect(entry?.isNextUp == false)
        #expect(library.resumePosition(itemID: movie.id, videoID: movie.id) == 600)
        #expect(!library.isInLibrary(movie.id))
        library.reset()
    }

    @Test func finishingEpisodeQueuesNext() {
        let library = LibraryStore(storageName: "library-tests")
        library.reset()
        var watchedEvents: [String] = []
        library.onWatched = { _, videoID in watchedEvents.append(videoID) }
        library.recordProgress(meta: series, videoID: "tt0903747:1:1", position: 2_900, duration: 3_000, nextVideoID: "tt0903747:1:2")
        #expect(library.isWatched(itemID: series.id, videoID: "tt0903747:1:1"))
        #expect(watchedEvents == ["tt0903747:1:1"])
        let entry = library.continueWatching.first
        #expect(entry?.videoID == "tt0903747:1:2")
        #expect(entry?.isNextUp == true)
        library.reset()
    }

    @Test func shortClipsAreIgnored() {
        let library = LibraryStore(storageName: "library-tests")
        library.reset()
        library.recordProgress(meta: movie, videoID: movie.id, position: 30, duration: 90, nextVideoID: nil)
        #expect(library.continueWatching.isEmpty)
        library.reset()
    }

    @Test func mergeKeepsNewer() {
        let library = LibraryStore(storageName: "library-tests")
        library.reset()
        library.toggleLibrary(movie)
        var older = LibraryItem(meta: movie, now: Date(timeIntervalSince1970: 0))
        older.removed = true
        library.merge(remote: [older])
        #expect(library.isInLibrary(movie.id))
        var newer = older
        newer.mtime = Date().addingTimeInterval(60)
        library.merge(remote: [newer])
        #expect(!library.isInLibrary(movie.id))
        library.reset()
    }
}
