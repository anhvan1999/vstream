import AddonKit
import DebridKit
import Foundation
import Testing
import TorrentKit
@testable import VStreamCore

@MainActor
@Suite struct LastStreamStoreTests {
    init() { TestStore.prepare() }

    let stream = AddonStream(infoHash: "abcdef0123456789abcdef0123456789abcdef01", fileIdx: 3, name: "Torrentio\n1080p", title: "Show.S01E02.mkv")

    @Test func remembersAndOverwrites() throws {
        let store = LastStreamStore(storageName: TestStore.uniqueName("last"))
        #expect(store.stream(for: "tt1") == nil)
        store.remember(itemID: "tt1", videoID: "tt1:1:2", stream: stream)
        let first = try #require(store.stream(for: "tt1"))
        #expect(first.videoID == "tt1:1:2")
        #expect(first.stream == stream)
        #expect(abs(first.playedAt.timeIntervalSinceNow) < 60)

        let direct = AddonStream(url: URL(string: "https://cdn.example/v.mkv")!)
        store.remember(itemID: "tt1", videoID: "tt1:1:3", stream: direct)
        #expect(store.stream(for: "tt1")?.videoID == "tt1:1:3")
        #expect(store.stream(for: "tt1")?.stream == direct)
    }

    @Test func forgetRemovesOnlyThatTitle() {
        let store = LastStreamStore(storageName: TestStore.uniqueName("last"))
        store.remember(itemID: "a", videoID: "a", stream: stream)
        store.remember(itemID: "b", videoID: "b", stream: stream)
        store.forget(itemID: "a")
        store.forget(itemID: "never-played")
        #expect(store.stream(for: "a") == nil)
        #expect(store.stream(for: "b") != nil)
    }

    @Test func prunesTheOldestBeyondTheLimit() {
        let store = LastStreamStore(storageName: TestStore.uniqueName("last"))
        for index in 0..<205 {
            store.remember(itemID: "item\(index)", videoID: "v\(index)", stream: stream)
        }
        for index in 0..<5 { #expect(store.stream(for: "item\(index)") == nil, "item\(index) should be pruned") }
        for index in 5..<205 { #expect(store.stream(for: "item\(index)") != nil) }
    }

    @Test func persistsAcrossInstances() async throws {
        let name = TestStore.uniqueName("last")
        let store = LastStreamStore(storageName: name)
        store.remember(itemID: "a", videoID: "a:1:1", stream: stream)
        store.remember(itemID: "b", videoID: "b", stream: stream)
        store.forget(itemID: "b")
        let persisted = await eventually {
            let reloaded = LastStreamStore(storageName: name)
            return reloaded.stream(for: "a") != nil && reloaded.stream(for: "b") == nil
        }
        #expect(persisted)
        let reloaded = LastStreamStore(storageName: name)
        #expect(reloaded.stream(for: "a")?.videoID == "a:1:1")
        #expect(reloaded.stream(for: "a")?.stream.infoHash == stream.infoHash)
        #expect(reloaded.stream(for: "a")?.stream.fileIdx == 3)
    }

    @Test func freshStorageIsEmpty() {
        #expect(LastStreamStore(storageName: TestStore.uniqueName("last")).stream(for: "a") == nil)
    }
}

@Suite struct AppSettingsTests {
    private func decode(_ json: String) throws -> AppSettings {
        try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
    }

    @Test func emptyObjectGivesDefaults() throws {
        let settings = try decode("{}")
        #expect(settings == AppSettings())
        #expect(settings.debridService == nil)
        #expect(settings.torrentMode == .automatic)
        #expect(settings.addUncachedToDebrid)
        #expect(settings.torrent == TorrentSettings())
        #expect(settings.hardwareDecoding)
        #expect(settings.streamBufferMB == 512)
        #expect(settings.autoplayNextEpisode)
        #expect(settings.preferredAudioLanguages.isEmpty)
        #expect(settings.preferredSubtitleLanguages.isEmpty)
        #expect(!settings.showAdultCatalogs)
        #expect(settings.traktClientID == AppSettings.defaultTraktClientID)
        #expect(settings.hiddenHomeRows.isEmpty)
    }

    @Test func decodesEveryField() throws {
        let settings = try decode("""
        {
          "debridService": "torbox", "torrentMode": "peerToPeerOnly", "addUncachedToDebrid": false,
          "torrent": {"profile": "fast", "diskCacheGB": 20, "uploadEnabled": false},
          "hardwareDecoding": false, "streamBufferMB": 1024, "autoplayNextEpisode": false,
          "preferredAudioLanguages": ["jpn"], "preferredSubtitleLanguages": ["eng", "vie"],
          "showAdultCatalogs": true, "traktClientID": "my-client", "hiddenHomeRows": ["a:movie:top"]
        }
        """)
        #expect(settings.debridService == .torbox)
        #expect(settings.torrentMode == .peerToPeerOnly)
        #expect(!settings.addUncachedToDebrid)
        #expect(settings.torrent == TorrentSettings(profile: .fast, diskCacheGB: 20, uploadEnabled: false))
        #expect(!settings.hardwareDecoding)
        #expect(settings.streamBufferMB == 1024)
        #expect(!settings.autoplayNextEpisode)
        #expect(settings.preferredAudioLanguages == ["jpn"])
        #expect(settings.preferredSubtitleLanguages == ["eng", "vie"])
        #expect(settings.showAdultCatalogs)
        #expect(settings.traktClientID == "my-client")
        #expect(settings.hiddenHomeRows == ["a:movie:top"])
    }

    @Test func emptyTraktClientIDFallsBackToDefault() throws {
        #expect(try decode(#"{"traktClientID": ""}"#).traktClientID == AppSettings.defaultTraktClientID)
        #expect(try decode(#"{"traktClientID": 42}"#).traktClientID == AppSettings.defaultTraktClientID)
    }

    @Test func legacyKeysAreIgnored() throws {
        let settings = try decode("""
        {"subtitleStyle": {"size": 3, "color": "white"}, "playerEngine": "avplayer", "torrentMode": "debridOnly"}
        """)
        #expect(settings.torrentMode == .debridOnly)
        var expected = AppSettings()
        expected.torrentMode = .debridOnly
        #expect(settings == expected)
    }

    @Test func wrongTypesFallBackPerField() throws {
        let settings = try decode("""
        {"debridService": "alldebrid", "torrentMode": "warp", "streamBufferMB": "big", "hardwareDecoding": "yes",
         "torrent": {"profile": "ludicrous"}, "preferredAudioLanguages": "eng", "hiddenHomeRows": 5, "showAdultCatalogs": true}
        """)
        #expect(settings.debridService == nil)
        #expect(settings.torrentMode == .automatic)
        #expect(settings.streamBufferMB == 512)
        #expect(settings.hardwareDecoding)
        #expect(settings.torrent == TorrentSettings())
        #expect(settings.preferredAudioLanguages.isEmpty)
        #expect(settings.hiddenHomeRows.isEmpty)
        #expect(settings.showAdultCatalogs, "valid fields survive invalid neighbours")
    }

    @Test func notAnObjectThrows() {
        #expect(throws: DecodingError.self) { try decode("[]") }
    }

    @Test func roundTrips() throws {
        var settings = AppSettings()
        settings.debridService = .realDebrid
        settings.torrentMode = .debridOnly
        settings.addUncachedToDebrid = false
        settings.torrent = TorrentSettings(profile: .soft, diskCacheGB: 1, uploadEnabled: false)
        settings.hardwareDecoding = false
        settings.streamBufferMB = 64
        settings.autoplayNextEpisode = false
        settings.preferredAudioLanguages = ["eng"]
        settings.preferredSubtitleLanguages = ["vie"]
        settings.showAdultCatalogs = true
        settings.traktClientID = "custom"
        settings.hiddenHomeRows = ["x", "y"]
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(AppSettings.self, from: data) == settings)
        #expect(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(AppSettings())) == AppSettings())
    }

    @Test func torrentModeLabels() {
        #expect(TorrentMode.allCases == [.automatic, .debridOnly, .peerToPeerOnly])
        #expect(TorrentMode.allCases.map(\.id) == ["automatic", "debridOnly", "peerToPeerOnly"])
        #expect(Set(TorrentMode.allCases.map(\.title)).count == 3)
        #expect(TorrentMode.debridOnly.title == "Debrid only")
    }
}
