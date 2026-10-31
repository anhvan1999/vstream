import Foundation
import Testing
import TestSupport
@testable import DebridKit

/// Mutable state shared with a mock handler.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func bump() { lock.withLock { count += 1 } }
}

func thrown(_ body: () async throws -> Void) async -> String? {
    do { try await body(); return nil } catch { return String(describing: error) }
}

private let magnet = "magnet:?xt=urn:btih:ABC&dn=Show S01"
private func episode(_ season: Int, _ episode: Int) -> DebridRequest {
    DebridRequest(infoHash: "ABC", magnet: magnet, season: season, episode: episode)
}

@Suite struct DebridHTTPTests {
    @Test func formRequest() async throws {
        let http = MockHTTP { _ in .json(["ok": true]) }
        let client = DebridHTTP(apiKey: "key", session: http.session)
        let object = try await client.jsonObject(URL(string: "https://x.test/a")!, method: "POST", form: [("magnet", "a b&c=d"), ("n", "1")])
        #expect(object["ok"] as? Bool == true)
        let request = try #require(http.requests.first)
        #expect(request.method == "POST")
        #expect(request.headers["Authorization"] == "Bearer key")
        #expect(request.headers["Accept"] == "application/json")
        #expect(request.headers["Content-Type"] == "application/x-www-form-urlencoded")
        #expect(request.bodyString == "magnet=a%20b%26c%3Dd&n=1")
        #expect(request.form == ["magnet": "a b&c=d", "n": "1"])
    }

    @Test func jsonRequest() async throws {
        let http = MockHTTP { _ in .json([1, 2]) }
        let object = try await DebridHTTP(apiKey: "k", session: http.session).jsonObject(URL(string: "https://x.test")!, method: "PUT", json: ["hashes": ["a"]])
        #expect(object.isEmpty)
        #expect(http.requests.first?.headers["Content-Type"] == "application/json")
        #expect(http.requests.first?.json?["hashes"] as? [String] == ["a"])
    }

    @Test func multipartRequest() async throws {
        let http = MockHTTP { _ in .init(status: 204) }
        let data = try await DebridHTTP(apiKey: "k", session: http.session).request(URL(string: "https://x.test")!, method: "POST", multipart: [("magnet", "m:1"), ("flag", "true")])
        #expect(data.isEmpty)
        let request = try #require(http.requests.first)
        let contentType = try #require(request.headers["Content-Type"])
        #expect(contentType.hasPrefix("multipart/form-data; boundary=VStream-"))
        let boundary = String(contentType.split(separator: "=").last!)
        #expect(request.bodyString.hasSuffix("--\(boundary)--\r\n"))
        #expect(request.form == ["magnet": "m:1", "flag": "true"])
    }

    @Test func getHasNoBody() async throws {
        let http = MockHTTP { _ in .json([:]) }
        _ = try await DebridHTTP(apiKey: "k", session: http.session).request(URL(string: "https://x.test/q?a=1")!)
        #expect(http.requests.first?.method == "GET")
        #expect(http.requests.first?.headers["Content-Type"] == nil)
        #expect(http.requests.first?.body.isEmpty == true)
    }

    @Test(arguments: [
        (401, #"{"error":"bad_token"}"#, "invalidKey"),
        (403, "", "invalidKey"),
        (400, #"{"error":"wrong_parameter","detail":"d"}"#, #"api("wrong_parameter")"#),
        (404, #"{"detail":"Not here"}"#, #"api("Not here")"#),
        (500, #"{"message":"Server sad"}"#, #"api("Server sad")"#),
        (502, "<html>Bad gateway</html>", "http(502)"),
        (503, #"{"error":null,"code":1}"#, "http(503)"),
    ])
    func errors(status: Int, body: String, expected: String) async {
        let http = MockHTTP { _ in .json(string: body, status: status) }
        let client = DebridHTTP(apiKey: "k", session: http.session)
        #expect(await thrown { _ = try await client.request(URL(string: "https://x.test")!) } == expected)
    }

    @Test func invalidJSONBodyThrows() async {
        let http = MockHTTP { _ in .json(string: "not json") }
        let client = DebridHTTP(apiKey: "k", session: http.session)
        #expect(await thrown { _ = try await client.jsonObject(URL(string: "https://x.test")!) } != nil)
    }

    @Test func formEncoding() {
        #expect(DebridHTTP.formEncode("AZaz09-._*") == "AZaz09-._*")
        #expect(DebridHTTP.formEncode("a+b/c?d[]") == "a%2Bb%2Fc%3Fd%5B%5D")
        #expect(DebridHTTP.formEncode("magnet:?xt=urn") == "magnet%3A%3Fxt%3Durn")
    }
}

// MARK: - Real-Debrid

@Suite struct RealDebridTests {
    static var files: [[String: Any]] { [
        ["id": 1, "path": "/Show/Show.S01E01.mkv", "bytes": 100, "selected": 0],
        ["id": 2, "path": "/Show/Show.S01E02.mkv", "bytes": 200, "selected": 0],
        ["id": 3, "path": "/Show/Show.S01E02.sample.mkv", "bytes": 5, "selected": 0],
        ["id": 4, "path": "/Show/info.nfo", "bytes": 1, "selected": 0],
    ] }

    static func downloaded(selected: Set<Int>) -> [String: Any] {
        [
            "status": "downloaded",
            "files": files.map { file in file.merging(["selected": selected.contains(file["id"] as! Int) ? 1 : 0]) { $1 } },
            "links": selected.sorted().map { "https://real-debrid.com/d/link\($0)" },
        ]
    }

    /// addMagnet → waiting_files_selection until selectFiles, then `afterSelection`.
    static func handler(selected: Flag = Flag(), afterSelection: @escaping @Sendable (Int) -> [String: Any] = { _ in downloaded(selected: [1, 2]) }) -> MockHTTP.Handler {
        let polls = Flag()
        return { request in
            switch request.path {
            case let path where path.hasSuffix("/torrents/addMagnet"): return .json(["id": "T1", "uri": "https://api.real-debrid.com/rest/1.0/torrents/info/T1"], status: 201)
            case let path where path.hasSuffix("/torrents/selectFiles/T1"):
                selected.bump()
                return .init(status: 204)
            case let path where path.hasSuffix("/torrents/info/T1"):
                if selected.value == 0 { return .json(["status": "waiting_files_selection", "files": files, "links": [String]()]) }
                polls.bump()
                return .json(afterSelection(polls.value))
            case let path where path.hasSuffix("/unrestrict/link"):
                return .json(["download": "https://download.real-debrid.com/file.mkv", "filename": "Show.S01E02.mkv", "filesize": 200])
            case let path where path.contains("/torrents/delete/"): return .init(status: 204)
            default: return .init(status: 404)
            }
        }
    }

    @Test func validate() async throws {
        let ok = MockHTTP(MockHTTP.routes(["/user": .json(["id": 42, "username": "me"])]))
        #expect(try await RealDebridProvider(apiKey: "k", session: ok.session).validate())
        #expect(ok.requests.first?.url.absoluteString == "https://api.real-debrid.com/rest/1.0/user")
        #expect(ok.requests.first?.headers["Authorization"] == "Bearer k")
        let empty = MockHTTP { _ in .json([:]) }
        #expect(try await RealDebridProvider(apiKey: "k", session: empty.session).validate() == false)
        let rejected = MockHTTP { _ in .json(["error": "bad_token", "error_code": 8], status: 401) }
        #expect(await thrown { _ = try await RealDebridProvider(apiKey: "k", session: rejected.session).validate() } == "invalidKey")
    }

    @Test func cachedHashesIsUnknown() async throws {
        let http = MockHTTP { _ in .json([:]) }
        #expect(try await RealDebridProvider(apiKey: "k", session: http.session).cachedHashes(["a"]) == nil)
        #expect(http.requests.isEmpty)
    }

    @Test func resolveSelectsEpisodeAndUnrestricts() async throws {
        let http = MockHTTP(Self.handler())
        let link = try await RealDebridProvider(apiKey: "k", session: http.session).resolve(episode(1, 2))
        #expect(link == DebridLink(url: URL(string: "https://download.real-debrid.com/file.mkv")!, filename: "Show.S01E02.mkv", size: 200))
        #expect(http.requests.map(\.path) == [
            "/rest/1.0/torrents/addMagnet", "/rest/1.0/torrents/info/T1", "/rest/1.0/torrents/selectFiles/T1",
            "/rest/1.0/torrents/info/T1", "/rest/1.0/unrestrict/link",
        ])
        #expect(http.requests[0].form == ["magnet": magnet])
        #expect(http.requests[2].form == ["files": "2"])
        // File 2 is the second selected file, so its link is links[1].
        #expect(http.requests[4].form == ["link": "https://real-debrid.com/d/link2"])
    }

    @Test func resolvePollsUntilDownloaded() async throws {
        let http = MockHTTP(Self.handler { poll in
            poll == 1 ? ["status": "magnet_conversion", "files": Self.files] : Self.downloaded(selected: [2])
        })
        let link = try await RealDebridProvider(apiKey: "k", session: http.session).resolve(episode(1, 2))
        #expect(link.filename == "Show.S01E02.mkv")
        #expect(http.requests.filter { $0.path.hasSuffix("info/T1") }.count == 3)
        #expect(http.requests.last?.form["link"] == "https://real-debrid.com/d/link2")
    }

    @Test func resolveSkipsSelectionWhenAlreadyDownloaded() async throws {
        let http = MockHTTP { request in
            if request.path.hasSuffix("addMagnet") { return .json(["id": "T1"]) }
            if request.path.hasSuffix("info/T1") { return .json(Self.downloaded(selected: [2])) }
            if request.path.hasSuffix("unrestrict/link") { return .json(["download": "https://dl.test/f.mkv"]) }
            return .init(status: 404)
        }
        let link = try await RealDebridProvider(apiKey: "k", session: http.session).resolve(episode(1, 2))
        #expect(link == DebridLink(url: URL(string: "https://dl.test/f.mkv")!, filename: nil, size: nil))
        #expect(!http.requests.contains { $0.path.contains("selectFiles") })
    }

    @Test(arguments: ["downloading", "queued", "magnet_error", "error", "virus", "dead"])
    func uncachedStatusDeletesTorrent(status: String) async {
        let http = MockHTTP(Self.handler { _ in ["status": status, "files": Self.files] })
        #expect(await thrown { _ = try await RealDebridProvider(apiKey: "k", session: http.session).resolve(episode(1, 2)) } == "notCached")
        let delete = http.requests.last
        #expect(delete?.method == "DELETE")
        #expect(delete?.path == "/rest/1.0/torrents/delete/T1")
    }

    @Test func magnetErrorWhileWaitingForFiles() async {
        let http = MockHTTP { request in
            if request.path.hasSuffix("addMagnet") { return .json(["id": "T1"]) }
            if request.path.hasSuffix("info/T1") { return .json(["status": "magnet_error", "files": [Any]()]) }
            return .init(status: 204)
        }
        #expect(await thrown { _ = try await RealDebridProvider(apiKey: "k", session: http.session).resolve(episode(1, 2)) } == "notCached")
        #expect(http.requests.map(\.method) == ["POST", "GET", "DELETE"])
    }

    @Test func noVideoDeletesTorrent() async {
        let http = MockHTTP { request in
            if request.path.hasSuffix("addMagnet") { return .json(["id": "T1"]) }
            if request.path.hasSuffix("info/T1") { return .json(["status": "waiting_files_selection", "files": [["id": 1, "path": "/a.rar", "bytes": 9]]]) }
            return .init(status: 204)
        }
        #expect(await thrown { _ = try await RealDebridProvider(apiKey: "k", session: http.session).resolve(episode(1, 2)) } == "noPlayableFile")
        #expect(http.requests.last?.path == "/rest/1.0/torrents/delete/T1")
    }

    @Test func rejectedMagnet() async {
        let http = MockHTTP { _ in .json(["uri": "x"]) }
        #expect(await thrown { _ = try await RealDebridProvider(apiKey: "k", session: http.session).resolve(episode(1, 2)) } == #"api("Real-Debrid did not accept the magnet")"#)
        let invalid = MockHTTP { _ in .json(["error": "infringing_file"], status: 451) }
        #expect(await thrown { _ = try await RealDebridProvider(apiKey: "k", session: invalid.session).resolve(episode(1, 2)) } == #"api("infringing_file")"#)
    }

    @Test func missingLinkOrDownload() async {
        let noLinks = MockHTTP(Self.handler { _ in ["status": "downloaded", "files": Self.files, "links": [String]()] })
        #expect(await thrown { _ = try await RealDebridProvider(apiKey: "k", session: noLinks.session).resolve(episode(1, 2)) } == "noPlayableFile")

        let base = Self.handler()
        let noDownload = MockHTTP { request in
            request.path.hasSuffix("unrestrict/link") ? .json(["filename": "x"]) : try base(request)
        }
        #expect(await thrown { _ = try await RealDebridProvider(apiKey: "k", session: noDownload.session).resolve(episode(1, 2)) } == #"api("Real-Debrid did not return a download link")"#)
    }

    @Test func linkForUnselectedFile() async throws {
        // A torrent RD reports as downloaded with only file 1 selected; the requested episode is file 2.
        let http = MockHTTP { request in
            if request.path.hasSuffix("addMagnet") { return .json(["id": "T1"]) }
            if request.path.hasSuffix("info/T1") { return .json(Self.downloaded(selected: [1])) }
            if request.path.hasSuffix("unrestrict/link") { return .json(["download": "https://dl.test/f.mkv"]) }
            return .init(status: 204)
        }
        let result = await thrown { _ = try await RealDebridProvider(apiKey: "k", session: http.session).resolve(episode(1, 2)) }
        #expect(result == "noPlayableFile")
    }

    @Test func startDownloadSkipsExistingTorrent() async throws {
        let http = MockHTTP(MockHTTP.routes(["/torrents": .json([["id": "X", "hash": "abc"], ["id": "Y"]])]))
        try await RealDebridProvider(apiKey: "k", session: http.session).startDownload(episode(1, 2))
        #expect(http.requests.count == 1)
        #expect(http.requests[0].query == ["limit": "100"])
        #expect(http.requests[0].path == "/rest/1.0/torrents")
    }

    @Test func startDownloadSelectsMatchingFile() async throws {
        let selected = Flag()
        let base = Self.handler(selected: selected)
        let http = MockHTTP { request in
            request.path.hasSuffix("/rest/1.0/torrents") ? .json([["hash": "other"]]) : try base(request)
        }
        try await RealDebridProvider(apiKey: "k", session: http.session).startDownload(episode(1, 1))
        #expect(http.requests.map(\.path).map { $0.replacingOccurrences(of: "/rest/1.0/", with: "") } == ["torrents", "torrents/addMagnet", "torrents/info/T1", "torrents/selectFiles/T1"])
        #expect(http.requests.last?.form == ["files": "1"])
        #expect(selected.value == 1)
    }

    @Test func startDownloadSelectsAllWithoutVideo() async throws {
        let http = MockHTTP { request in
            if request.path.hasSuffix("/rest/1.0/torrents") { return .json(string: "not a list") }
            if request.path.hasSuffix("addMagnet") { return .json(["id": "T1"]) }
            if request.path.hasSuffix("info/T1") { return .json(["status": "waiting_files_selection", "files": [["id": 1, "path": "/a.rar", "bytes": 9]]]) }
            return .init(status: 204)
        }
        try await RealDebridProvider(apiKey: "k", session: http.session).startDownload(episode(1, 2))
        #expect(http.requests.last?.form == ["files": "all"])
    }

    @Test func startDownloadWithoutSelectionNeeded() async throws {
        let http = MockHTTP { request in
            if request.path.hasSuffix("/rest/1.0/torrents") { return .json([Any]()) }
            if request.path.hasSuffix("addMagnet") { return .json(["id": "T1"]) }
            return .json(["status": "downloading", "files": Self.files])
        }
        try await RealDebridProvider(apiKey: "k", session: http.session).startDownload(episode(1, 2))
        #expect(http.requests.count == 3)
        let rejected = MockHTTP { request in request.path.hasSuffix("/rest/1.0/torrents") ? .json([Any]()) : .json([:]) }
        #expect(await thrown { try await RealDebridProvider(apiKey: "k", session: rejected.session).startDownload(episode(1, 2)) } == #"api("Real-Debrid did not accept the magnet")"#)
    }
}

// MARK: - TorBox

@Suite struct TorboxTests {
    static var finished: [String: Any] { [
        "id": 7, "download_finished": true, "download_present": true,
        "files": [
            ["id": 0, "name": "Pack/Show.S01E01.mkv", "size": 10],
            ["id": 1, "name": "Pack/Show.S01E02.mkv", "size": 20],
            ["id": 2, "short_name": "Show.S01E03.mkv", "size": 30],
            ["name": "no id.mkv", "size": 99],
        ],
    ] }

    static func handler(create: MockHTTP.Response = .json(["success": true, "data": ["torrent_id": 7, "hash": "abc"]]), torrent: [String: Any] = finished, link: MockHTTP.Response = .json(["success": true, "data": "https://tb.test/dl/1"])) -> MockHTTP.Handler {
        MockHTTP.routes(["/torrents/createtorrent": create, "/torrents/mylist": .json(["success": true, "data": torrent]), "/torrents/requestdl": link])
    }

    @Test func validate() async throws {
        let http = MockHTTP(MockHTTP.routes(["/user/me": .json(["success": true, "data": ["email": "x"]])]))
        #expect(try await TorboxProvider(apiKey: "k", session: http.session).validate())
        #expect(http.requests.first?.url.absoluteString == "https://api.torbox.app/v1/api/user/me")
        let failed = MockHTTP { _ in .json(["success": false]) }
        #expect(try await TorboxProvider(apiKey: "k", session: failed.session).validate() == false)
    }

    @Test func cachedHashes() async throws {
        let http = MockHTTP { _ in .json(["success": true, "data": ["AAA": ["name": "x"], "ccc": ["name": "y"]]]) }
        let cached = try await TorboxProvider(apiKey: "k", session: http.session).cachedHashes(["AAA", "Bbb", "ccc"])
        #expect(cached == ["aaa", "ccc"])
        let request = try #require(http.requests.first)
        #expect(request.method == "POST")
        #expect(request.path == "/v1/api/torrents/checkcached")
        #expect(request.query == ["format": "object"])
        #expect(request.json?["hashes"] as? [String] == ["aaa", "bbb", "ccc"])
    }

    @Test func cachedHashesEdgeCases() async throws {
        let http = MockHTTP { _ in .json(["success": true, "data": [Any]()]) }
        let provider = TorboxProvider(apiKey: "k", session: http.session)
        #expect(try await provider.cachedHashes([]) == [])
        #expect(http.requests.isEmpty)
        #expect(try await provider.cachedHashes(["a"]) == [])
    }

    @Test func resolve() async throws {
        let http = MockHTTP(Self.handler())
        let link = try await TorboxProvider(apiKey: "secret", session: http.session).resolve(episode(1, 2))
        #expect(link == DebridLink(url: URL(string: "https://tb.test/dl/1")!, filename: "Show.S01E02.mkv", size: 20))
        #expect(http.requests.map(\.path) == ["/v1/api/torrents/createtorrent", "/v1/api/torrents/mylist", "/v1/api/torrents/requestdl"])
        #expect(http.requests[0].method == "POST")
        #expect(http.requests[0].form == ["magnet": magnet, "add_only_if_cached": "true", "allow_zip": "false"])
        #expect(http.requests[1].query == ["id": "7", "bypass_cache": "true"])
        #expect(http.requests[2].query == ["token": "secret", "torrent_id": "7", "file_id": "1", "zip_link": "false", "redirect": "false"])
        #expect(http.requests.allSatisfy { $0.headers["Authorization"] == "Bearer secret" })
    }

    @Test func resolveUsesShortNameAndIDFallback() async throws {
        let http = MockHTTP(Self.handler(create: .json(["success": true, "data": ["id": 9]])))
        let link = try await TorboxProvider(apiKey: "k", session: http.session).resolve(episode(1, 3))
        #expect(link.filename == "Show.S01E03.mkv")
        #expect(http.requests[1].query["id"] == "9")
        #expect(http.requests[2].query["file_id"] == "2")
    }

    @Test(arguments: [
        MockHTTP.Response.json(["success": false, "error": "DOWNLOAD_NOT_CACHED", "detail": "x"], status: 400),
        .json(["success": false, "detail": "Torrent is not cached"], status: 400),
        .json(["success": false, "error": "DOWNLOAD_NOT_CACHED", "detail": "Item is not cached"]),
        .json(["success": false, "error": NSNull(), "detail": "Not cached yet"]),
        .json(["success": true, "data": [String: Any]()]),
    ])
    func notCachedCreate(response: MockHTTP.Response) async {
        let http = MockHTTP(Self.handler(create: response))
        #expect(await thrown { _ = try await TorboxProvider(apiKey: "k", session: http.session).resolve(episode(1, 2)) } == "notCached")
        #expect(http.requests.count == 1)
    }

    @Test func otherCreateFailures() async {
        let body = MockHTTP(Self.handler(create: .json(["success": false, "error": "BOZO", "detail": "Bad magnet"])))
        #expect(await thrown { _ = try await TorboxProvider(apiKey: "k", session: body.session).resolve(episode(1, 2)) } == #"api("Bad magnet")"#)
        let bare = MockHTTP(Self.handler(create: .json(["success": false])))
        #expect(await thrown { _ = try await TorboxProvider(apiKey: "k", session: bare.session).resolve(episode(1, 2)) } == #"api("TorBox rejected the torrent")"#)
        let status = MockHTTP(Self.handler(create: .json(["error": "SERVER_ERROR"], status: 500)))
        #expect(await thrown { _ = try await TorboxProvider(apiKey: "k", session: status.session).resolve(episode(1, 2)) } == #"api("SERVER_ERROR")"#)
    }

    static var unfinished: [[String: Any]] {
        [
            ["download_finished": false, "download_present": true, "files": finished["files"]!],
            ["download_finished": true, "download_present": false, "files": finished["files"]!],
            ["download_finished": true, "files": [Any]()],
            [:],
        ]
    }

    @Test(arguments: 0..<4)
    func unfinishedTorrentIsNotCached(index: Int) async {
        let torrent = Self.unfinished[index]
        let http = MockHTTP(Self.handler(torrent: torrent))
        #expect(await thrown { _ = try await TorboxProvider(apiKey: "k", session: http.session).resolve(episode(1, 2)) } == "notCached")
        #expect(http.requests.count == 2)
    }

    @Test func noVideoAndMissingLink() async {
        let noVideo = MockHTTP(Self.handler(torrent: ["files": [["id": 0, "name": "a.rar", "size": 1]]]))
        #expect(await thrown { _ = try await TorboxProvider(apiKey: "k", session: noVideo.session).resolve(episode(1, 2)) } == "noPlayableFile")
        let noLink = MockHTTP(Self.handler(link: .json(["success": false, "detail": "Nope"])))
        #expect(await thrown { _ = try await TorboxProvider(apiKey: "k", session: noLink.session).resolve(episode(1, 2)) } == #"api("Nope")"#)
        let bare = MockHTTP(Self.handler(link: .json(["success": false])))
        #expect(await thrown { _ = try await TorboxProvider(apiKey: "k", session: bare.session).resolve(episode(1, 2)) } == #"api("TorBox did not return a link")"#)
    }

    @Test func startDownload() async throws {
        let http = MockHTTP { _ in .json(["success": true, "data": ["torrent_id": 1]]) }
        try await TorboxProvider(apiKey: "k", session: http.session).startDownload(episode(1, 2))
        #expect(http.requests.first?.form == ["magnet": magnet, "allow_zip": "false"])
        #expect(http.requests.first?.path == "/v1/api/torrents/createtorrent")
    }

    @Test(arguments: [
        MockHTTP.Response.json(["success": false, "detail": "You already have this torrent"]),
        .json(["success": false, "error": "ALREADY_QUEUED"], status: 400),
    ])
    func startDownloadIgnoresAlreadyAdded(response: MockHTTP.Response) async throws {
        let http = MockHTTP { _ in response }
        try await TorboxProvider(apiKey: "k", session: http.session).startDownload(episode(1, 2))
    }

    @Test func startDownloadReportsOtherErrors() async {
        let body = MockHTTP { _ in .json(["success": false, "detail": "Slots full"]) }
        #expect(await thrown { try await TorboxProvider(apiKey: "k", session: body.session).startDownload(episode(1, 2)) } == #"api("Slots full")"#)
        let bare = MockHTTP { _ in .json(["success": false]) }
        #expect(await thrown { try await TorboxProvider(apiKey: "k", session: bare.session).startDownload(episode(1, 2)) } == #"api("TorBox rejected the torrent")"#)
        let key = MockHTTP { _ in .init(status: 403) }
        #expect(await thrown { try await TorboxProvider(apiKey: "k", session: key.session).startDownload(episode(1, 2)) } == "invalidKey")
    }
}

// MARK: - Premiumize

@Suite struct PremiumizeTests {
    @Test func validate() async throws {
        let http = MockHTTP(MockHTTP.routes(["/account/info": .json(["status": "success", "customer_id": 1])]))
        #expect(try await PremiumizeProvider(apiKey: "k", session: http.session).validate())
        #expect(http.requests.first?.url.absoluteString == "https://www.premiumize.me/api/account/info")
        let failed = MockHTTP { _ in .json(["status": "error"]) }
        #expect(try await PremiumizeProvider(apiKey: "k", session: failed.session).validate() == false)
    }

    @Test func cachedHashes() async throws {
        let http = MockHTTP { _ in .json(["status": "success", "response": [true, false, true]]) }
        let provider = PremiumizeProvider(apiKey: "k", session: http.session)
        #expect(try await provider.cachedHashes(["AAA", "bbb", "Ccc"]) == ["aaa", "ccc"])
        let request = try #require(http.requests.first)
        #expect(request.path == "/api/cache/check")
        #expect(request.method == "POST")
        #expect(request.bodyString == "items%5B%5D=AAA&items%5B%5D=bbb&items%5B%5D=Ccc")
        #expect(try await provider.cachedHashes([]) == [])
        #expect(http.requests.count == 1)
    }

    @Test func cachedHashesShortResponse() async throws {
        let http = MockHTTP { _ in .json(["status": "success", "response": [true]]) }
        #expect(try await PremiumizeProvider(apiKey: "k", session: http.session).cachedHashes(["a", "b"]) == ["a"])
        let none = MockHTTP { _ in .json(["status": "error"]) }
        #expect(try await PremiumizeProvider(apiKey: "k", session: none.session).cachedHashes(["a"]) == [])
    }

    @Test func resolve() async throws {
        let http = MockHTTP { _ in
            .json(["status": "success", "content": [
                ["path": "Movie/sample.mkv", "size": 1, "link": "https://pm.test/sample"],
                ["size": 5, "link": "https://pm.test/nopath"],
                ["path": "Movie/Movie.2020.mkv", "size": 50, "link": "https://pm.test/movie"],
                ["path": "Movie/Movie.nfo", "size": 500, "link": "https://pm.test/nfo"],
            ]])
        }
        let link = try await PremiumizeProvider(apiKey: "k", session: http.session).resolve(DebridRequest(infoHash: "h", magnet: magnet))
        #expect(link == DebridLink(url: URL(string: "https://pm.test/movie")!, filename: "Movie.2020.mkv", size: 50))
        #expect(http.requests.first?.path == "/api/transfer/directdl")
        #expect(http.requests.first?.form == ["src": magnet])
    }

    @Test(arguments: [#"{"status":"error","message":"Not in cache"}"#, #"{"status":"error"}"#, #"{"status":"error","message":"Item not cached"}"#])
    func uncached(body: String) async {
        let http = MockHTTP { _ in .json(string: body) }
        #expect(await thrown { _ = try await PremiumizeProvider(apiKey: "k", session: http.session).resolve(episode(1, 2)) } == "notCached")
    }

    @Test func otherFailures() async {
        let message = MockHTTP { _ in .json(["status": "error", "message": "Invalid source"]) }
        #expect(await thrown { _ = try await PremiumizeProvider(apiKey: "k", session: message.session).resolve(episode(1, 2)) } == #"api("Invalid source")"#)
        let noVideo = MockHTTP { _ in .json(["status": "success", "content": [["path": "a.rar", "link": "https://x"]]]) }
        #expect(await thrown { _ = try await PremiumizeProvider(apiKey: "k", session: noVideo.session).resolve(episode(1, 2)) } == "noPlayableFile")
        let noLink = MockHTTP { _ in .json(["status": "success", "content": [["path": "a.mkv"]]]) }
        #expect(await thrown { _ = try await PremiumizeProvider(apiKey: "k", session: noLink.session).resolve(episode(1, 2)) } == "noPlayableFile")
    }

    @Test func startDownload() async throws {
        let http = MockHTTP { _ in .json(["status": "success", "id": "x"]) }
        try await PremiumizeProvider(apiKey: "k", session: http.session).startDownload(episode(1, 2))
        #expect(http.requests.first?.path == "/api/transfer/create")
        #expect(http.requests.first?.form == ["src": magnet])

        let failed = MockHTTP { _ in .json(["status": "error", "message": "Limit reached"]) }
        #expect(await thrown { try await PremiumizeProvider(apiKey: "k", session: failed.session).startDownload(episode(1, 2)) } == #"api("Limit reached")"#)
        let bare = MockHTTP { _ in .json(["status": "error"]) }
        #expect(await thrown { try await PremiumizeProvider(apiKey: "k", session: bare.session).startDownload(episode(1, 2)) } == #"api("Premiumize did not accept the torrent")"#)
    }
}
