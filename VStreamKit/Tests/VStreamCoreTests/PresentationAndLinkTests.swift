import AddonKit
import Foundation
import Testing
@testable import VStreamCore

/// Entries copied from `Tests/AddonKitTests/Fixtures/torrentio-streams.json` (Interstellar).
private enum Torrentio {
    static let remuxDV = AddonStream(
        name: "Torrentio\n4k DV | HDR10+",
        title: "Interstellar 2014 2160p PROPER IMAX REMUX DV HDR10+ TrueHD 7.1 Atmos-jennaortegaUHD\n👤 248 💾 95.63 GB ⚙️ TorrentGalaxy",
        behaviorHints: .init(filename: "Interstellar.2014.2160p.PROPER.IMAX.REMUX.DV.HDR10+.TrueHD.7.1.Atmos-jennaortegaUHD.mkv")
    )
    static let rutracker = AddonStream(
        name: "Torrentio\n4k HDR",
        title: "Интерстеллар / Interstellar [2014 UHD BDRemux 2160p HDR10] [IMAX] Dub + MVO + 2x AVO + 2x VO + Original (Eng) + Sub (Rus Eng)\n👤 223 💾 89.56 GB ⚙️ Rutracker\n🇬🇧 / 🇷🇺",
        behaviorHints: .init(filename: "Интерстеллар.2014.UHD.Blu-Ray.Remux.2160p.mkv")
    )
    static let rarbg = AddonStream(
        name: "Torrentio\n4k HDR",
        title: "Interstellar.2014.2160p.UHD.BluRay.x265.10bit.HDR.DTS-HD.MA.5.1-TERMiNAL\n👤 159 💾 33.34 GB ⚙️ RARBG",
        behaviorHints: .init(filename: "interstellar.2014.2160p.uhd.bluray.x265-terminal.mkv")
    )
    static let noFilename = AddonStream(
        name: "Torrentio\n4k DV | HDR",
        title: "Interstellar (2014)(CZ/EN)[2160p][HDR/DV][HEVC]\n👤 51 💾 7.4 GB ⚙️ EXT\n🇬🇧 / 🇨🇿"
    )
    static let yify = AddonStream(
        name: "Torrentio\n1080p",
        title: "Interstellar (2014) (2014) 1080p BrRip x264 - YIFY\n👤 1110 💾 2.26 GB ⚙️ ThePirateBay",
        behaviorHints: .init(filename: "Interstellar.2014.2014.1080p.BluRay.x264.YIFY.mp4")
    )
    static let pack720 = AddonStream(
        name: "Torrentio\n720p",
        title: "Dual Japanese dubbed English movies super pack\nInterstellar.2014.720p.BluRay.x264(DUAL En-Ja)/Interstellar.2014.720p.BluRay.x264(DUAL En-Ja).mkv\n👤 242 💾 1.21 GB ⚙️ 1337x\nDual Audio / 🇬🇧 / 🇯🇵",
        behaviorHints: .init(filename: "Interstellar.2014.720p.BluRay.x264(DUAL En-Ja).mkv")
    )
    static let dvd = AddonStream(
        name: "Torrentio\nDVD",
        title: "0peliculas series\nInterstellar.DVD.XviD.[www.DivxTotaL.com].avi\n👤 57 💾 2.06 GB ⚙️ Wolfmax4k\n🇪🇸",
        behaviorHints: .init(filename: "Interstellar.DVD.XviD.[www.DivxTotaL.com].avi")
    )
    static let hdrip = AddonStream(
        name: "Torrentio\nHDRip",
        title: "Интерстеллар / Interstellar [2014 HDRip] [IMAX Edition] DVO (Tantuki Production) + Original Eng\n👤 127 💾 2.85 GB ⚙️ Rutracker\n🇬🇧 / 🇷🇺",
        behaviorHints: .init(filename: "Interstellar [2014 HDRip].avi")
    )
}

@Suite struct StreamPresentationTests {
    @Test func remuxWithDolbyVision() {
        let p = StreamPresentation(Torrentio.remuxDV)
        #expect(p.quality == "2160p")
        #expect(p.tags == ["DV", "HDR10+", "REMUX", "Atmos", "TrueHD", "IMAX"])
        #expect(!p.tags.contains("HDR10"))
        
        #expect(p.size == "95.63 GB")
        #expect(p.seeders == "248")
        #expect(p.source == "TorrentGalaxy")
        #expect(p.sourceLabel == "Torrentio · 4k DV | HDR10+")
        #expect(p.title == Torrentio.remuxDV.behaviorHints.filename)
        #expect(p.extras == nil)
    }

    @Test func rutrackerKeepsLanguageExtras() {
        let p = StreamPresentation(Torrentio.rutracker)
        #expect(p.quality == "2160p")
        #expect(p.tags == ["HDR10", "REMUX", "IMAX"], "HDR10 hides the plain HDR tag")
        #expect(p.size == "89.56 GB")
        #expect(p.seeders == "223")
        #expect(p.source == "Rutracker")
        #expect(p.extras == "🇬🇧 / 🇷🇺")
    }

    @Test func dtsHDHidesDTS() {
        let p = StreamPresentation(Torrentio.rarbg)
        #expect(p.tags == ["HDR", "x265", "DTS-HD"])
        #expect(p.source == "RARBG")
        #expect(p.size == "33.34 GB")
        #expect(p.title == "interstellar.2014.2160p.uhd.bluray.x265-terminal.mkv")
    }

    @Test func titleFallsBackToFirstDetailLine() {
        let p = StreamPresentation(Torrentio.noFilename)
        #expect(p.title == "Interstellar (2014)(CZ/EN)[2160p][HDR/DV][HEVC]")
        #expect(p.tags == ["DV", "HDR", "HEVC"])
        #expect(p.size == "7.4 GB")
        #expect(p.extras == "🇬🇧 / 🇨🇿")
    }

    @Test func fullHDAndHDQualities() {
        let yify = StreamPresentation(Torrentio.yify)
        #expect(yify.quality == "1080p")
        #expect(yify.tags.isEmpty)
        #expect(yify.seeders == "1110")
        #expect(yify.source == "ThePirateBay")

        let pack = StreamPresentation(Torrentio.pack720)
        #expect(pack.quality == "720p")
        #expect(pack.title == "Interstellar.2014.720p.BluRay.x264(DUAL En-Ja).mkv")
        #expect(pack.extras == "Dual Audio / 🇬🇧 / 🇯🇵")
        #expect(pack.size == "1.21 GB")
    }

    @Test func fourKMeansTwentyOneSixty() {
        #expect(StreamPresentation(AddonStream(name: "Addon\n4K")).quality == "2160p")
        #expect(StreamPresentation(AddonStream(name: "Addon 1440p")).quality == "1440p")
        #expect(StreamPresentation(AddonStream(name: "Addon 480p")).quality == "480p")
        #expect(StreamPresentation(AddonStream(name: "Addon SD")).quality == nil)
    }

    @Test func sizeWithoutMarkerAndMissingFields() {
        let p = StreamPresentation(AddonStream(name: "Direct", description: "Movie 1.5 GB HEVC"))
        #expect(p.size == "1.5 GB")
        #expect(p.seeders == nil)
        #expect(p.source == nil)
        #expect(p.tags == ["HEVC"])
        #expect(p.title == "Movie 1.5 GB HEVC", "description is the newer name for title")
        #expect(p.sourceLabel == "Direct")
        #expect(StreamPresentation(AddonStream(name: "x", description: "750 MB")).size == "750 MB")
    }

    @Test func descriptionWinsOverTitle() {
        let p = StreamPresentation(AddonStream(title: "Old title", description: "New description\nextra line"))
        #expect(p.title == "New description")
        #expect(p.extras == "extra line")
    }

    @Test func emptyStreamIsLabelledGenerically() {
        let p = StreamPresentation(AddonStream())
        #expect(p.title == "Stream")
        #expect(p.sourceLabel == nil)
        #expect(p.extras == nil)
        #expect(p.quality == nil)
        #expect(p.tags.isEmpty)
        #expect(p.size == nil)
    }

    @Test func nameOnlyHeadline() {
        let p = StreamPresentation(AddonStream(name: "  \nYouTube\n  Trailer  "))
        #expect(p.title == "YouTube")
        #expect(p.sourceLabel == "YouTube · Trailer")
    }

    @Test func extrasSkipTheHeadlineRepeat() {
        let p = StreamPresentation(AddonStream(title: "Line A\nLine A"))
        #expect(p.extras == nil)
    }

    @Test func tagsMatchWholeWordsOnly() {
        // Substring matching reads "DVD"/"BLUDV" as Dolby Vision, "HDRip" as HDR and the source
        // "Wolfmax4k" as a 4K release.
        let dvd = StreamPresentation(Torrentio.dvd)
        #expect(!dvd.tags.contains("DV"))
        #expect(dvd.quality == nil)
        #expect(!StreamPresentation(Torrentio.hdrip).tags.contains("HDR"))
        #expect(!StreamPresentation(AddonStream(name: "Torrentio\n4k", title: "Interstelar 2014 4K Dual Áudio 5.1 WWW.BLUDV.COM")).tags.contains("DV"))
    }
}

@Suite struct LinkInputTests {
    let hash = "dd9d6b21cde411a1ab590d83746858cf5f91081e"

    @Test func httpVideo() throws {
        let input = try #require(LinkInput("  https://cdn.example/movies/My%20Movie.mkv \n"))
        guard case let .video(url) = input else { Issue.record("expected video, got \(input)"); return }
        #expect(url.host == "cdn.example")
        #expect(input.raw == "https://cdn.example/movies/My%20Movie.mkv")
        #expect(input.title == "My Movie.mkv")
        #expect(input.detail == "cdn.example")
        #expect(input.symbol == "globe")
    }

    @Test func hostOnlyURLIsTitledByHost() throws {
        for text in ["http://example.com", "http://example.com/"] {
            let input = try #require(LinkInput(text))
            #expect(input == .video(URL(string: text)!))
            #expect(input.title == "example.com")
        }
    }

    @Test func urlWithSpacesIsAccepted() throws {
        let input = try #require(LinkInput("https://cdn.example/my movie.mp4"))
        guard case .video = input else { Issue.record("expected video"); return }
        #expect(input.title == "my movie.mp4")
    }

    @Test func torrentURLs() throws {
        let input = try #require(LinkInput("https://yts.example/download/Movie.TORRENT"))
        #expect(input == .torrentFile(URL(string: "https://yts.example/download/Movie.TORRENT")!))
        #expect(input.symbol == "doc.zipper")
        #expect(input.title == "Movie.TORRENT")
        #expect(input.detail == "yts.example")
    }

    @Test func absoluteFilePaths() throws {
        let video = try #require(LinkInput("/Users/someone/Movies/a b.mkv"))
        #expect(video == .video(URL(filePath: "/Users/someone/Movies/a b.mkv")))
        #expect(video.title == "a b.mkv")
        #expect(video.detail == "/Users/someone/Movies/a b.mkv")
        #expect(video.symbol == "film")

        let torrent = try #require(LinkInput("/tmp/ubuntu.torrent"))
        #expect(torrent == .torrentFile(URL(filePath: "/tmp/ubuntu.torrent")))
        #expect(torrent.symbol == "doc.zipper")
    }

    @Test func tildePathsExpand() throws {
        let input = try #require(LinkInput("~/Downloads/show.torrent"))
        guard case let .torrentFile(url) = input else { Issue.record("expected torrent file"); return }
        #expect(url.isFileURL)
        #expect(url.path == NSHomeDirectory() + "/Downloads/show.torrent")
        #expect(input.detail == url.path)
    }

    @Test func fileURLs() throws {
        let input = try #require(LinkInput("file:///Volumes/Media/clip.mp4"))
        #expect(input == .video(URL(string: "file:///Volumes/Media/clip.mp4")!))
        #expect(input.detail == "/Volumes/Media/clip.mp4")
        #expect(input.symbol == "film")
        #expect(LinkInput("file:///Volumes/Media/x.torrent") == .torrentFile(URL(string: "file:///Volumes/Media/x.torrent")!))
    }

    @Test func magnetWithName() throws {
        let text = "magnet:?xt=urn:btih:\(hash.uppercased())&dn=Big%20Buck%20Bunny&tr=udp://tracker.example:80"
        let input = try #require(LinkInput(text))
        #expect(input == .magnet(URL(string: text)!))
        #expect(input.raw == text)
        #expect(input.title == "Big Buck Bunny")
        #expect(input.detail == hash)
        #expect(input.symbol == "link.badge.plus")
    }

    @Test func magnetWithoutName() throws {
        let input = try #require(LinkInput("magnet:?xt=urn:btih:\(hash)"))
        #expect(input.title == "Magnet dd9d6b21")
        #expect(input.detail == hash)
    }

    @Test func magnetWithoutHashIsRejected() {
        #expect(LinkInput("magnet:?dn=Something") == nil)
        #expect(LinkInput("magnet:?xt=urn:sha1:abc") == nil)
    }

    @Test func bareHexHash() throws {
        let input = try #require(LinkInput(hash.uppercased()))
        #expect(input == .magnet(URL(string: "magnet:?xt=urn:btih:\(hash)")!))
        #expect(input.raw == "magnet:?xt=urn:btih:\(hash)")
        #expect(input.title == "Magnet dd9d6b21")
    }

    @Test func bareBase32Hash() throws {
        let base32 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
        let input = try #require(LinkInput(base32))
        #expect(input == .magnet(URL(string: "magnet:?xt=urn:btih:\(base32.lowercased())")!))
        #expect(input.detail == base32.lowercased())
    }

    @Test func almostHashesAreNotHashes() {
        #expect(LinkInput(String(hash.dropLast())) == nil, "39 hex characters")
        #expect(LinkInput(hash + "0") == nil, "41 hex characters")
        #expect(LinkInput("ABCDEFGHIJKLMNOPQRSTUVWXYZ234561") == nil, "1 is not base32")
    }

    @Test func stremioAddonLinks() throws {
        let input = try #require(LinkInput("stremio://addon.example/config/manifest.json"))
        #expect(input == .addon(URL(string: "stremio://addon.example/config/manifest.json")!))
        #expect(input.title == "manifest.json")
        #expect(input.detail == "addon.example")
        #expect(input.symbol == "puzzlepiece.extension")
    }

    @Test(arguments: ["", "   \n", "hello world", "ftp://example.com/file.mkv", "mailto:me@example.com", "just-text", "https://"])
    func garbageIsRejected(text: String) {
        #expect(LinkInput(text) == nil)
    }

    @Test func webURLsNeedAHost() {
        #expect(LinkInput("https:///movie.mkv") == nil)
        #expect(LinkInput("http:///movie.mkv") == nil)
    }
}
