import AddonKit
import Foundation
import Testing
@testable import StremioAPI

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(json.utf8))
}

private func item(duration: UInt64 = 0, offset: UInt64 = 0) -> LibraryItem {
    var item = LibraryItem(meta: MetaPreview(id: "tt1", type: "movie", name: "One"))
    item.state.duration = duration
    item.state.timeOffset = offset
    return item
}

@Suite struct LibraryItemTests {
    @Test func initFromMeta() {
        let now = Date(timeIntervalSince1970: 1_000)
        let meta = MetaPreview(id: "tt1", type: "series", name: "One", poster: URL(string: "https://a.example/p.jpg"), posterShape: .landscape)
        let item = LibraryItem(meta: meta, now: now)
        #expect(item.id == "tt1")
        #expect(item.name == "One")
        #expect(item.type == "series")
        #expect(item.poster == meta.poster)
        #expect(item.posterShape == .landscape)
        #expect(item.removed)
        #expect(item.temp)
        #expect(item.ctime == now)
        #expect(item.mtime == now)
        #expect(item.state == LibraryItemState())
        #expect(item.behaviorHints == nil)
        #expect(!item.isInLibrary)
    }

    @Test func decodesStremioItem() throws {
        let item = try decode(LibraryItem.self, """
        {"_id":"tt0903747","name":"Breaking Bad","type":"series","poster":"https://a.example/p.jpg","posterShape":"poster",
         "removed":false,"temp":false,"_ctime":"2023-05-01T12:00:00.123Z","_mtime":"2024-01-02T03:04:05Z",
         "state":{"lastWatched":"2024-01-02T03:00:00.000Z","timeWatched":1200.0,"timeOffset":600000,"overallTimeWatched":9999,
                  "timesWatched":2,"flaggedWatched":1,"duration":2700000,"video_id":"tt0903747:1:1",
                  "watched":"tt0903747:1:1:1:eJxjBAAAAgAB","noNotif":true},
         "behaviorHints":{"defaultVideoId":null,"featuredVideoId":null,"hasScheduledVideos":false}}
        """)
        #expect(item.id == "tt0903747")
        #expect(item.name == "Breaking Bad")
        #expect(item.posterShape == .poster)
        #expect(item.isInLibrary)
        #expect(item.ctime == Date(timeIntervalSince1970: 1_682_942_400.123))
        #expect(item.mtime == Date(timeIntervalSince1970: 1_704_164_645))
        #expect(item.state.lastWatched == Date(timeIntervalSince1970: 1_704_164_400))
        #expect(item.state.timeWatched == 1200)
        #expect(item.state.timeOffset == 600_000)
        #expect(item.state.overallTimeWatched == 9999)
        #expect(item.state.timesWatched == 2)
        #expect(item.state.flaggedWatched == 1)
        #expect(item.state.duration == 2_700_000)
        #expect(item.state.videoId == "tt0903747:1:1")
        #expect(item.state.watched == "tt0903747:1:1:1:eJxjBAAAAgAB")
        #expect(item.state.noNotif)
        #expect(item.behaviorHints?["hasScheduledVideos"] == .bool(false))
        #expect(item.progress == 600_000.0 / 2_700_000.0)
    }

    @Test func decodesMinimalItemWithDefaults() throws {
        let item = try decode(LibraryItem.self, #"{"_id":"x","type":"movie","poster":"","posterShape":"weird","removed":"yes","state":[]}"#)
        #expect(item.name == "")
        #expect(item.poster == nil)
        #expect(item.posterShape == .poster)
        #expect(!item.removed)
        #expect(!item.temp)
        #expect(item.ctime == nil)
        #expect(item.mtime == .distantPast)
        #expect(item.state == LibraryItemState())
        #expect(item.behaviorHints == nil)
        #expect(item.isInLibrary)
    }

    @Test func requiresIdAndType() {
        #expect(throws: DecodingError.self) { try decode(LibraryItem.self, #"{"type":"movie"}"#) }
        #expect(throws: DecodingError.self) { try decode(LibraryItem.self, #"{"_id":"x"}"#) }
    }

    @Test func encodesStremioShape() throws {
        var item = LibraryItem(meta: MetaPreview(id: "tt1", type: "movie", name: "One"), now: Date(timeIntervalSince1970: 0))
        item.ctime = nil
        let json = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(item))
        #expect(json["_id"] == .string("tt1"))
        #expect(json["poster"] == .string(""))
        #expect(json["posterShape"] == .string("poster"))
        #expect(json["_ctime"] == nil)
        #expect(json["_mtime"] == .string("1970-01-01T00:00:00.000Z"))
        #expect(json["behaviorHints"] == .object([:]))
        #expect(json["state"]?["video_id"] == .string(""))
        #expect(json["state"]?["watched"] == .string(""))
        #expect(json["state"]?["lastWatched"] == nil)
        #expect(json["state"]?["noNotif"] == .bool(false))
    }

    @Test func roundTrips() throws {
        var item = LibraryItem(
            meta: MetaPreview(id: "tt1", type: "series", name: "One", poster: URL(string: "https://a.example/p.jpg"), posterShape: .square),
            now: Date(timeIntervalSince1970: 1_700_000_000.123)
        )
        item.removed = false
        item.temp = false
        item.mtime = Date(timeIntervalSince1970: 1_700_000_100.5)
        item.behaviorHints = .object(["defaultVideoId": .string("tt1:1:1")])
        item.state.lastWatched = Date(timeIntervalSince1970: 1_700_000_050.25)
        item.state.timeWatched = 1
        item.state.timeOffset = 2
        item.state.overallTimeWatched = 3
        item.state.timesWatched = 4
        item.state.flaggedWatched = 5
        item.state.duration = 6
        item.state.videoId = "tt1:1:1"
        item.state.watched = "tt1:1:1:1:abc"
        item.state.noNotif = true
        let decoded = try JSONDecoder().decode(LibraryItem.self, from: JSONEncoder().encode(item))
        #expect(decoded == item)
    }

    @Test func progress() {
        #expect(item().progress == 0)
        #expect(item(duration: 0, offset: 500).progress == 0)
        #expect(item(duration: 1000, offset: 250).progress == 0.25)
        #expect(item(duration: 1000, offset: 5000).progress == 1)
    }

    @Test func libraryFlags() {
        var value = item()
        #expect(!value.isInLibrary)
        value.temp = false
        #expect(!value.isInLibrary)
        value.removed = false
        #expect(value.isInLibrary)
        value.temp = true
        #expect(!value.isInLibrary)
    }

    @Test func shouldSync() {
        var value = item()
        #expect(!value.shouldSync)
        value.state.lastWatched = Date().addingTimeInterval(-86_400)
        #expect(value.shouldSync)
        value.state.lastWatched = Date().addingTimeInterval(-400 * 86_400)
        #expect(!value.shouldSync)
        value.removed = false
        value.temp = false
        #expect(value.shouldSync)
    }
}

@Suite struct LibraryItemStateTests {
    @Test func numbersAreLenient() throws {
        let state = try decode(LibraryItemState.self, """
        {"timeWatched":-5,"timeOffset":1500.9,"overallTimeWatched":"12","timesWatched":5e9,"flaggedWatched":-1.5,"duration":null}
        """)
        #expect(state.timeWatched == 0)
        #expect(state.timeOffset == 1500)
        #expect(state.overallTimeWatched == 0)
        #expect(state.timesWatched == UInt32.max)
        #expect(state.flaggedWatched == 0)
        #expect(state.duration == 0)
    }

    @Test func emptyStringsBecomeNil() throws {
        let state = try decode(LibraryItemState.self, #"{"video_id":"","watched":"","lastWatched":"","noNotif":"true"}"#)
        #expect(state.videoId == nil)
        #expect(state.watched == nil)
        #expect(state.lastWatched == nil)
        #expect(!state.noNotif)
    }

    @Test func emptyObject() throws {
        #expect(try decode(LibraryItemState.self, "{}") == LibraryItemState())
    }
}

@Suite struct StremioAPIDateTests {
    @Test func parse() {
        #expect(StremioAPIDate.parse(nil) == nil)
        #expect(StremioAPIDate.parse(.some(nil)) == nil)
        #expect(StremioAPIDate.parse("") == nil)
        #expect(StremioAPIDate.parse("not a date") == nil)
        #expect(StremioAPIDate.parse("2024-01-02T03:04:05Z") == Date(timeIntervalSince1970: 1_704_164_645))
        #expect(StremioAPIDate.parse("2024-01-02T03:04:05.678Z") == Date(timeIntervalSince1970: 1_704_164_645.678))
    }

    @Test func formatUsesMilliseconds() {
        #expect(StremioAPIDate.format(Date(timeIntervalSince1970: 1_704_164_645.678)) == "2024-01-02T03:04:05.678Z")
        #expect(StremioAPIDate.format(Date(timeIntervalSince1970: 0)) == "1970-01-01T00:00:00.000Z")
    }

    @Test func formatParseRoundTrip() {
        let date = Date(timeIntervalSince1970: 1_234_567_890.5)
        #expect(StremioAPIDate.parse(StremioAPIDate.format(date)) == date)
    }
}
