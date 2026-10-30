import AddonKit
import Foundation
import Testing
@testable import StremioAPI

@Suite struct WatchedBitfieldTests {
    let videoIDs: [String] = {
        let url = Bundle.module.url(forResource: "cyberpunk-meta", withExtension: "json", subdirectory: "Fixtures")!
        let meta = try! JSONDecoder().decode(MetaEnvelope.self, from: Data(contentsOf: url)).meta
        return WatchedBitfield.orderedVideoIDs(meta.videos)
    }()

    struct MetaEnvelope: Decodable { let meta: MetaDetail }

    @Test func decodesRealStremioValue() {
        // Taken from a synced library: anchored at S1E3 with 4 bits, i.e. one special before it.
        let watched = WatchedBitfield.decode("tt12590266:1:3:4:eJzjY2AAAAAtAA8=", videoIDs: videoIDs)
        #expect(watched.contains("tt12590266:1:1"))
        #expect(watched.contains("tt12590266:1:2"))
        #expect(watched.contains("tt12590266:1:3"))
        #expect(!watched.contains("tt12590266:1:4"))
    }

    @Test func roundTrips() throws {
        let watched: Set<String> = ["tt12590266:1:1", "tt12590266:1:5", "tt12590266:1:7"]
        let encoded = try #require(WatchedBitfield.encode(watched: watched, videoIDs: videoIDs))
        #expect(encoded.hasPrefix("tt12590266:1:7:"))
        #expect(WatchedBitfield.decode(encoded, videoIDs: videoIDs) == watched)
    }

    @Test func realignsWhenEpisodesWereAddedBeforeTheAnchor() throws {
        let encoded = try #require(WatchedBitfield.encode(watched: ["b", "c"], videoIDs: ["a", "b", "c"]))
        #expect(WatchedBitfield.decode(encoded, videoIDs: ["special", "a", "b", "c", "d"]) == ["b", "c"])
    }

    @Test func unknownAnchorYieldsNothing() {
        #expect(WatchedBitfield.decode("gone:3:eJzjY2AAAAAtAA8=", videoIDs: videoIDs).isEmpty)
        #expect(WatchedBitfield.decode("garbage", videoIDs: videoIDs).isEmpty)
    }
}
