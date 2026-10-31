import CryptoKit
import Foundation
import Testing
@testable import TorrentKit

/// Builds bencoded bytes by hand so tests control exactly what is hashed.
private indirect enum B {
    case int(Int64)
    case str(String)
    case raw([UInt8])
    case list([B])
    /// Keys are written in the given order (the parser doesn't require sorted keys).
    case dict([(String, B)])

    var bytes: [UInt8] {
        switch self {
        case let .int(value): Array("i\(value)e".utf8)
        case let .str(value): Array("\(value.utf8.count):".utf8) + Array(value.utf8)
        case let .raw(value): Array("\(value.count):".utf8) + value
        case let .list(items): [UInt8(ascii: "l")] + items.flatMap(\.bytes) + [UInt8(ascii: "e")]
        case let .dict(pairs): [UInt8(ascii: "d")] + pairs.flatMap { B.str($0.0).bytes + $0.1.bytes } + [UInt8(ascii: "e")]
        }
    }

    var data: Data { Data(bytes) }
}

private func sha1Hex(_ bytes: [UInt8]) -> String {
    Insecure.SHA1.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
}

@Suite struct TorrentMetainfoTests {
    @Test func singleFileTorrent() throws {
        let info = B.dict([("length", .int(1_234_567)), ("name", .str("Big Buck Bunny.mp4")), ("piece length", .int(262_144)), ("pieces", .raw([UInt8](repeating: 0xAB, count: 20)))])
        let torrent = B.dict([("announce", .str("udp://tracker.example:80/announce")), ("info", info)])
        let contents = try TorrentMetainfo.parse(torrent.data)
        #expect(contents.infoHash == sha1Hex(info.bytes))
        #expect(contents.infoHash.count == 40)
        #expect(contents.name == "Big Buck Bunny.mp4")
        #expect(contents.trackers == ["udp://tracker.example:80/announce"])
        #expect(contents.files == [TorrentFileEntry(index: 0, path: "Big Buck Bunny.mp4", size: 1_234_567)])
    }

    @Test func multiFileTorrentKeepsLibtorrentIndices() throws {
        let info = B.dict([
            ("name", .str("Show S01")),
            ("files", .list([
                .dict([("length", .int(100)), ("path", .list([.str("Sample"), .str("sample.mkv")]))]),
                .dict([("attr", .str("p")), ("length", .int(16)), ("path", .list([.str(".pad"), .str("16")]))]),
                .dict([("length", .int(2_000)), ("path", .list([.str("Show.S01E01.mkv")])), ("path.utf-8", .list([.str("Show.S01E01 – Pilot.mkv")]))]),
                .dict([("length", .int(-5)), ("path", .list([.str("Subs"), .str("en.srt")]))]),
            ])),
            ("piece length", .int(16_384)),
        ])
        let contents = try TorrentMetainfo.parse(B.dict([("info", info)]).data)
        #expect(contents.infoHash == sha1Hex(info.bytes))
        #expect(contents.trackers.isEmpty)
        #expect(contents.files.map(\.index) == [0, 1, 2, 3])
        #expect(contents.files.map(\.path) == [
            "Show S01/Sample/sample.mkv",
            "Show S01/.pad/16",
            "Show S01/Show.S01E01 – Pilot.mkv",
            "Show S01/Subs/en.srt",
        ])
        #expect(contents.files.map(\.size) == [100, 16, 2_000, 0], "negative lengths clamp to zero")
        #expect(contents.files.filter(\.isVideo).map(\.index) == [0, 2])
    }

    @Test func utf8NameWinsAndUnnamedSingleFileFallsBack() throws {
        let named = B.dict([("info", .dict([("length", .int(1)), ("name", .str("ascii")), ("name.utf-8", .str("Über.mkv"))]))])
        #expect(try TorrentMetainfo.parse(named.data).name == "Über.mkv")
        #expect(try TorrentMetainfo.parse(named.data).files.first?.path == "Über.mkv")

        let unnamed = B.dict([("info", .dict([("length", .int(7))]))])
        let contents = try TorrentMetainfo.parse(unnamed.data)
        #expect(contents.name == nil)
        #expect(contents.files == [TorrentFileEntry(index: 0, path: "file", size: 7)])

        let unnamedMulti = B.dict([("info", .dict([("files", .list([.dict([("length", .int(3)), ("path", .list([.str("a"), .str("b.mkv")]))])]))]))])
        #expect(try TorrentMetainfo.parse(unnamedMulti.data).files.first?.path == "a/b.mkv")
    }

    @Test func announceListIsFlattenedAndAnnounceDeduplicated() throws {
        let info = B.dict([("length", .int(1)), ("name", .str("x"))])
        let listed = B.dict([
            ("announce", .str("udp://b.example")),
            ("announce-list", .list([.list([.str("udp://a.example"), .str("udp://b.example")]), .list([.str("http://c.example/announce")]), .str("not-a-tier"), .list([.int(5)])])),
            ("info", info),
        ])
        #expect(try TorrentMetainfo.parse(listed.data).trackers == ["udp://a.example", "udp://b.example", "http://c.example/announce"])

        let separate = B.dict([
            ("announce", .str("udp://primary.example")),
            ("announce-list", .list([.list([.str("udp://a.example")])])),
            ("info", info),
        ])
        #expect(try TorrentMetainfo.parse(separate.data).trackers == ["udp://primary.example", "udp://a.example"])
    }

    @Test func infoHashCoversOnlyTheTopLevelInfoBytes() throws {
        // Byte-for-byte hashing: unsorted keys and unknown fields must be hashed as they appear.
        let info = B.dict([("zzz", .str("unknown field")), ("name", .str("a.mkv")), ("length", .int(42)), ("private", .int(1))])
        let decoy = B.dict([("info", .dict([("length", .int(1)), ("name", .str("decoy"))]))])
        let torrent = B.dict([("comment", decoy), ("created by", .str("test")), ("info", info), ("url-list", .list([.str("https://seed.example/a.mkv")]))])
        let contents = try TorrentMetainfo.parse(torrent.data)
        #expect(contents.infoHash == sha1Hex(info.bytes))
        #expect(contents.name == "a.mkv")
        #expect(contents.files.first?.size == 42)
    }

    @Test func knownInfoHash() throws {
        // d6:lengthi1e4:name1:ae → sha1 computed independently with `shasum`.
        let info = Array("d6:lengthi1e4:name1:ae".utf8)
        let data = Data("d4:info".utf8) + Data(info) + Data("e".utf8)
        #expect(try TorrentMetainfo.parse(data).infoHash == "8aa9d3c65b0164d222d9b2527a70f125668575ef")
        #expect(sha1Hex(info) == "8aa9d3c65b0164d222d9b2527a70f125668575ef")
    }

    @Test func entriesWithoutLengthOrPathAreSkipped() throws {
        let info = B.dict([("name", .str("d")), ("files", .list([
            .dict([("path", .list([.str("no-length.mkv")]))]),
            .dict([("length", .int(1)), ("path", .str("not-a-list"))]),
            .str("not-a-dict"),
            .dict([("length", .int(9)), ("path", .list([.str("ok.mkv"), .int(3)]))]),
        ]))])
        let contents = try TorrentMetainfo.parse(B.dict([("info", info)]).data)
        #expect(contents.files == [TorrentFileEntry(index: 0, path: "d/ok.mkv", size: 9)])
    }

    @Test func noFilesAtAll() throws {
        let contents = try TorrentMetainfo.parse(B.dict([("info", .dict([("name", .str("empty"))]))]).data)
        #expect(contents.files.isEmpty)
        #expect(contents.name == "empty")
    }

    static let invalidInputs: [(String, Data)] = [
        ("empty", Data()),
        ("integer root", B.int(42).data),
        ("list root", B.list([.str("info")]).data),
        ("no info", B.dict([("announce", .str("x"))]).data),
        ("info is a string", B.dict([("info", .str("nope"))]).data),
        ("info is a list", B.dict([("info", .list([]))]).data),
        ("truncated dict", Data("d4:info".utf8)),
        ("truncated nested", Data("d4:infod6:lengthi1e".utf8)),
        ("string past end", Data("d4:infod4:name99:abce".utf8)),
        ("negative string length", Data("d4:info-1:ae".utf8)),
        ("bad integer", Data("d4:infod6:lengthiabcee".utf8)),
        ("unterminated integer", Data("d4:infod6:lengthi12".utf8)),
        ("non-string key", Data("di1ei2ee".utf8)),
        ("garbage", Data("hello world".utf8)),
        ("bad length prefix", Data("d4:infod4:name3x:abcee".utf8)),
        ("deep nesting", Data(String(repeating: "l", count: 100).utf8) + Data(String(repeating: "e", count: 100).utf8)),
        ("deep nesting inside info", Data("d4:infod1:x".utf8) + Data(String(repeating: "l", count: 80).utf8) + Data(String(repeating: "e", count: 80).utf8) + Data("6:lengthi1eee".utf8)),
    ]

    @Test(arguments: invalidInputs)
    func invalidInputThrows(label: String, data: Data) {
        #expect(throws: TorrentMetainfoError.invalid, "\(label)") { try TorrentMetainfo.parse(data) }
    }

    @Test func moderateNestingIsFine() throws {
        let nested = String(repeating: "l", count: 30) + String(repeating: "e", count: 30)
        let data = Data("d4:infod1:x\(nested)6:lengthi5e4:name1:aee".utf8)
        #expect(try TorrentMetainfo.parse(data).files.first?.size == 5)
    }

    @Test func errorDescription() {
        #expect(TorrentMetainfoError.invalid.errorDescription == "This isn't a valid .torrent file")
    }
}

@Suite struct TorrentFileEntryTests {
    @Test(arguments: ["a.mkv", "dir/b.MP4", "c.m4v", "d.avi", "e.mov", "f.webm", "g.ts", "h.m2ts", "i.wmv", "j.flv", "k.mpg", "l.mpeg", "m.ogv"])
    func videoExtensions(path: String) {
        #expect(TorrentFileEntry(index: 0, path: path, size: 1).isVideo)
    }

    @Test(arguments: ["a.srt", "b.nfo", "c.mkv.part", "README", "d.mp3", "e.jpg", ".pad/16"])
    func nonVideo(path: String) {
        #expect(!TorrentFileEntry(index: 0, path: path, size: 1).isVideo)
    }

    @Test func nameAndID() {
        let entry = TorrentFileEntry(index: 7, path: "Show/Season 1/Show.S01E01.mkv", size: 99)
        #expect(entry.name == "Show.S01E01.mkv")
        #expect(entry.id == 7)
        #expect(TorrentFileEntry(index: 0, path: "flat.mkv", size: 0).name == "flat.mkv")
    }

    @Test func contentsInit() {
        let files = [TorrentFileEntry(index: 0, path: "a.mkv", size: 1)]
        let contents = TorrentContents(infoHash: "abc", name: "n", trackers: ["t"], files: files)
        #expect(contents.infoHash == "abc")
        #expect(contents.name == "n")
        #expect(contents.trackers == ["t"])
        #expect(contents.files == files)
        #expect(contents == TorrentContents(infoHash: "abc", name: "n", trackers: ["t"], files: files))
    }

    @Test func settingsAndErrors() {
        let settings = TorrentSettings()
        #expect(settings.profile == .balanced)
        #expect(settings.diskCacheGB == 5)
        #expect(settings.uploadEnabled)
        #expect(TorrentSettings.Profile.allCases == [.soft, .balanced, .fast])
        #expect(TorrentError.noFiles.errorDescription == "The torrent has no playable files")
        #expect(TorrentStats.zero.peers == 0)
        #expect(TorrentStats.zero.bufferProgress == 0)
    }
}
