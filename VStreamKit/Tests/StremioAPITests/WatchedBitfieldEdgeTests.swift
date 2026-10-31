import AddonKit
import Foundation
import Testing
@testable import StremioAPI

@Suite struct WatchedBitfieldEdgeTests {
    @Test func orderPutsMissingValuesFirst() {
        let videos = [
            Video(id: "s1e2", title: "", season: 1, episode: 2),
            Video(id: "s1e1-late", title: "", released: Date(timeIntervalSince1970: 200), season: 1, episode: 1),
            Video(id: "s1e1-early", title: "", released: Date(timeIntervalSince1970: 100), season: 1, episode: 1),
            Video(id: "s1e1-undated", title: "", season: 1, episode: 1),
            Video(id: "no-season", title: "", episode: 5),
            Video(id: "s0e1", title: "", season: 0, episode: 1),
        ]
        #expect(WatchedBitfield.orderedVideoIDs(videos) == ["no-season", "s0e1", "s1e1-undated", "s1e1-early", "s1e1-late", "s1e2"])
    }

    @Test func encodeEmptyList() {
        #expect(WatchedBitfield.encode(watched: ["a"], videoIDs: []) == nil)
    }

    @Test func encodeNothingWatchedAnchorsAtFirst() throws {
        let encoded = try #require(WatchedBitfield.encode(watched: [], videoIDs: ["a", "b"]))
        #expect(encoded.hasPrefix("a:1:"))
        #expect(WatchedBitfield.decode(encoded, videoIDs: ["a", "b"]).isEmpty)
    }

    @Test func roundTripsAcrossByteBoundaries() throws {
        let ids = (1...20).map { "v\($0)" }
        let watched: Set<String> = ["v1", "v8", "v9", "v16", "v17", "v20"]
        let encoded = try #require(WatchedBitfield.encode(watched: watched, videoIDs: ids))
        #expect(encoded.hasPrefix("v20:20:"))
        #expect(WatchedBitfield.decode(encoded, videoIDs: ids) == watched)
    }

    @Test func ignoresUnknownWatchedIds() throws {
        let encoded = try #require(WatchedBitfield.encode(watched: ["b", "zzz"], videoIDs: ["a", "b", "c"]))
        #expect(encoded.hasPrefix("b:2:"))
        #expect(WatchedBitfield.decode(encoded, videoIDs: ["a", "b", "c"]) == ["b"])
    }

    @Test func realignsWhenEpisodesWereRemovedBeforeTheAnchor() throws {
        let encoded = try #require(WatchedBitfield.encode(watched: ["b", "c"], videoIDs: ["a", "b", "c"]))
        #expect(WatchedBitfield.decode(encoded, videoIDs: ["b", "c", "d"]) == ["b", "c"])
    }

    @Test func newEpisodesAfterAnchorAreUnwatched() throws {
        let encoded = try #require(WatchedBitfield.encode(watched: ["a", "b"], videoIDs: ["a", "b"]))
        #expect(WatchedBitfield.decode(encoded, videoIDs: ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j"]) == ["a", "b"])
    }

    @Test(arguments: ["a:x:eJzjY2AAAAAtAA8=", "a:1:!!!", "a:1:AAAA", ":", "a:1"])
    func malformedInputs(serialized: String) {
        #expect(WatchedBitfield.decode(serialized, videoIDs: ["a", "b"]).isEmpty)
    }

    @Test func zlibRoundTrip() throws {
        let input = Data((0..<300).map { UInt8($0 % 7) })
        let deflated = try #require(WatchedBitfield.zlibDeflate(input))
        #expect(deflated.prefix(2) == Data([0x78, 0x9C]))
        #expect(WatchedBitfield.zlibInflate(deflated) == [UInt8](input))
    }

    @Test func zlibInflateRejectsShortOrCorrupt() {
        #expect(WatchedBitfield.zlibInflate(Data([0x78, 0x9C, 0, 0, 0, 0])) == nil)
        #expect(WatchedBitfield.zlibInflate(Data(repeating: 0xFF, count: 16)) == nil)
    }
}
