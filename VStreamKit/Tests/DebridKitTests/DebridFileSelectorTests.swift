import Foundation
import Testing
@testable import DebridKit

private func file(_ id: String, _ path: String, _ size: Int64) -> DebridFile { DebridFile(id: id, path: path, size: size) }
private func request(filename: String? = nil, fileIndex: Int? = nil, season: Int? = nil, episode: Int? = nil) -> DebridRequest {
    DebridRequest(infoHash: "HASH", magnet: "magnet:?xt=urn:btih:hash", filename: filename, fileIndex: fileIndex, season: season, episode: episode)
}

@Suite struct DebridFileSelectorTests {
    let pack = [
        file("0", "Show/Show.S01E01.1080p.mkv", 900),
        file("1", "Show/Show.S01E02.1080p.mkv", 800),
        file("2", "Show/Show.S01E02.sample.mkv", 10),
        file("3", "Show/Show.S01E12.1080p.mkv", 950),
        file("4", "Show/Extras/Behind the Scenes.mkv", 2000),
        file("5", "Show/Show.nfo", 5000),
    ]

    @Test func largestVideoWithoutHints() {
        #expect(DebridFileSelector.select(pack, request: request())?.id == "4")
    }

    @Test func noVideoFiles() {
        #expect(DebridFileSelector.select([file("0", "a.nfo", 1), file("1", "b.srt", 2)], request: request()) == nil)
        #expect(DebridFileSelector.select([], request: request()) == nil)
    }

    @Test func episodeMatchIgnoresSampleAndExtras() {
        #expect(DebridFileSelector.select(pack, request: request(season: 1, episode: 2))?.id == "1")
        #expect(DebridFileSelector.select(pack, request: request(season: 1, episode: 12))?.id == "3")
    }

    @Test func episodeMatchBeatsFileIndex() {
        #expect(DebridFileSelector.select(pack, request: request(fileIndex: 0, season: 1, episode: 2))?.id == "1")
    }

    @Test func fileIndexWhenNoEpisodeMatches() {
        #expect(DebridFileSelector.select(pack, request: request(fileIndex: 0, season: 5, episode: 5))?.id == "0")
        #expect(DebridFileSelector.select(pack, request: request(fileIndex: 0))?.id == "0")
        // Out of range or not a video → largest video.
        #expect(DebridFileSelector.select(pack, request: request(fileIndex: 99))?.id == "4")
        #expect(DebridFileSelector.select(pack, request: request(fileIndex: 5))?.id == "4")
    }

    @Test func exactFilenameWins() {
        #expect(DebridFileSelector.select(pack, request: request(filename: "Show.S01E01.1080p.mkv", season: 1, episode: 2))?.id == "0")
        #expect(DebridFileSelector.select(pack, request: request(filename: "show.s01e12.1080p.MKV"))?.id == "3")
        #expect(DebridFileSelector.select(pack, request: request(filename: "/Show/Show.S01E02.1080p.mkv"))?.id == "1")
        #expect(DebridFileSelector.select(pack, request: request(filename: "Extras/Behind the Scenes.mkv"))?.id == "4")
    }

    @Test func duplicateFilenamesPickLargest() {
        let files = [file("a", "CD1/movie.mkv", 1), file("b", "CD2/movie.mkv", 3), file("c", "other.mkv", 9)]
        #expect(DebridFileSelector.select(files, request: request(filename: "movie.mkv"))?.id == "b")
    }

    @Test func unknownFilenameFallsThrough() {
        #expect(DebridFileSelector.select(pack, request: request(filename: "missing.mkv", season: 1, episode: 1))?.id == "0")
        #expect(DebridFileSelector.select(pack, request: request(filename: "  "))?.id == "4")
    }

    @Test(arguments: [
        ("Show.S01E02.mkv", true), ("show s1e2 720p.mp4", true), ("Show.S01.E02.mkv", true), ("Show_S01-E02.avi", true),
        ("Show.1x02.mkv", true), ("Show.01x002.mkv", true), ("Show.S01E021.mkv", false), ("Show.S01E12.mkv", false),
        ("Show.S11E02.mkv", false), ("Show.21x02.mkv", false), ("ShowS01E02.mkv", false), ("Show.S01E02E03.mkv", true),
    ])
    func episodePattern(name: String, matches: Bool) throws {
        let pattern = try #require(DebridFileSelector.episodePattern(season: 1, episode: 2))
        #expect((name.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil) == matches)
    }

    @Test func episodePatternNeedsBoth() {
        #expect(DebridFileSelector.episodePattern(season: 1, episode: nil) == nil)
        #expect(DebridFileSelector.episodePattern(season: nil, episode: 1) == nil)
    }

    @Test func fileHelpers() {
        let windows = file("0", "  \\\\Season 1\\Ep.MKV", 1)
        #expect(windows.normalizedPath == "Season 1/Ep.MKV")
        #expect(windows.basename == "Ep.MKV")
        #expect(windows.isVideo)
        for ext in DebridFileSelector.videoExtensions { #expect(file("0", "x" + ext, 0).isVideo) }
        #expect(!file("0", "x.mkv.part", 0).isVideo)
        #expect(file("0", "/", 0).basename == "")
    }
}

@Suite struct DebridModelTests {
    @Test func serviceMetadata() {
        #expect(DebridService.allCases == [.realDebrid, .torbox, .premiumize])
        #expect(DebridService.allCases.map(\.displayName) == ["Real-Debrid", "TorBox", "Premiumize"])
        #expect(DebridService.allCases.map(\.shortName) == ["RD", "TB", "PM"])
        #expect(DebridService.allCases.map(\.id) == ["realDebrid", "torbox", "premiumize"])
        #expect(DebridService.realDebrid.apiKeyPage.absoluteString == "https://real-debrid.com/apitoken")
        #expect(DebridService.torbox.apiKeyPage.absoluteString == "https://torbox.app/settings")
        #expect(DebridService.premiumize.apiKeyPage.absoluteString == "https://www.premiumize.me/account")
    }

    @Test(arguments: DebridService.allCases)
    func providerFactory(service: DebridService) {
        #expect(service.provider(apiKey: "k").service == service)
    }

    @Test func serviceCodable() throws {
        let data = try JSONEncoder().encode([DebridService.torbox])
        #expect(String(decoding: data, as: UTF8.self) == #"["torbox"]"#)
        #expect(try JSONDecoder().decode([DebridService].self, from: data) == [.torbox])
    }

    @Test func requestLowercasesHash() {
        #expect(DebridRequest(infoHash: "ABCdef", magnet: "m").infoHash == "abcdef")
    }

    @Test func errorDescriptions() {
        #expect(DebridError.invalidKey.errorDescription == "The debrid API key was rejected")
        #expect(DebridError.notCached.errorDescription == "This torrent is not cached on your debrid service")
        #expect(DebridError.noPlayableFile.errorDescription == "No matching video file in this torrent")
        #expect(DebridError.api("boom").errorDescription == "boom")
        #expect(DebridError.http(500).errorDescription == "Debrid service returned HTTP 500")
    }

    @Test func dictionaryNumbers() {
        let json = try! JSONSerialization.jsonObject(with: Data(#"{"a": 5, "b": 7.9, "c": "3", "d": 9007199254740993}"#.utf8)) as! [String: Any]
        #expect(json.int64("a") == 5)
        #expect(json.int("b") == 7)
        #expect(json.int64("c") == nil)
        #expect(json.int64("missing") == nil)
        #expect(json.int64("d") == 9_007_199_254_740_993)
        let native: [String: Any] = ["i": 1, "l": Int64(2), "d": 3.5]
        #expect(native.int64("i") == 1 && native.int64("l") == 2 && native.int64("d") == 3)
    }
}
