import AddonKit
import Foundation
import Testing
import TestSupport
@testable import StremioAPI

private let base = URL(string: "https://api.example")!

private func client(_ http: MockHTTP) -> StremioAPIClient {
    StremioAPIClient(baseURL: base, session: http.session)
}

@Suite struct StremioAPIClientTests {
    @Test func defaultBaseURL() {
        #expect(StremioAPIClient().baseURL.absoluteString == "https://api.strem.io")
    }

    @Test func login() async throws {
        let http = MockHTTP(MockHTTP.routes(["/api/login": .json(["result": [
            "authKey": "key-1",
            "user": ["_id": "u1", "email": "a@b.c", "fullname": "Ann", "avatar": "https://a.example/me.png"],
        ]])]))
        let session = try await client(http).login(email: "a@b.c", password: "pw")
        #expect(session.authKey == "key-1")
        #expect(session.user.id == "u1")
        #expect(session.user.email == "a@b.c")
        #expect(session.user.fullname == "Ann")
        #expect(session.user.avatar?.absoluteString == "https://a.example/me.png")

        let request = try #require(http.requests.first)
        #expect(request.method == "POST")
        #expect(request.path == "/api/login")
        #expect(request.headers["Content-Type"] == "application/json")
        let body = try #require(request.json)
        #expect(body["type"] as? String == "Login")
        #expect(body["email"] as? String == "a@b.c")
        #expect(body["password"] as? String == "pw")
        #expect(body["facebook"] as? Bool == false)
    }

    @Test func loginAPIError() async {
        let http = MockHTTP { _ in .json(["error": ["message": "Wrong passphrase", "code": 3]]) }
        let error = await #expect(throws: StremioAPIError.self) {
            try await client(http).login(email: "a@b.c", password: "bad")
        }
        #expect(error?.code == 3)
        #expect(error?.message == "Wrong passphrase")
        #expect(error?.errorDescription == "Wrong passphrase")
    }

    @Test func errorWinsOverResult() async {
        let http = MockHTTP { _ in .json(["result": ["success": true], "error": ["message": "Session expired", "code": 1]]) }
        let error = await #expect(throws: StremioAPIError.self) { try await client(http).logout(authKey: "k") }
        #expect(error?.code == 1)
    }

    @Test(arguments: [#"{"result":null}"#, "{}"])
    func emptyResult(body: String) async {
        let http = MockHTTP { _ in .json(string: body) }
        let error = await #expect(throws: StremioAPIError.self) { try await client(http).user(authKey: "k") }
        #expect(error?.code == -1)
        #expect(error?.message == "Empty response from Stremio API")
    }

    @Test func nonJSONResponseThrows() async {
        let http = MockHTTP { _ in .init(status: 502, body: Data("<html>Bad gateway</html>".utf8)) }
        await #expect(throws: DecodingError.self) { try await client(http).user(authKey: "k") }
    }

    @Test func transportErrorThrows() async {
        let http = MockHTTP { _ in throw URLError(.timedOut) }
        await #expect(throws: URLError.self) { try await client(http).logout(authKey: "k") }
    }

    @Test func logout() async throws {
        let http = MockHTTP { _ in .json(["result": ["success": true]]) }
        try await client(http).logout(authKey: "key-1")
        let request = try #require(http.requests.first)
        #expect(request.path == "/api/logout")
        let body = try #require(request.json)
        #expect(body["type"] as? String == "Logout")
        #expect(body["authKey"] as? String == "key-1")
    }

    @Test func getUserIsLenient() async throws {
        let http = MockHTTP { _ in .json(["result": ["_id": 5, "avatar": ""]]) }
        let user = try await client(http).user(authKey: "key-1")
        #expect(user.id == "")
        #expect(user.email == "")
        #expect(user.fullname == nil)
        #expect(user.avatar == nil)
        let request = try #require(http.requests.first)
        #expect(request.path == "/api/getUser")
        #expect(request.json?["type"] as? String == "GetUser")
        #expect(request.json?["authKey"] as? String == "key-1")
    }

    @Test func userRoundTripsThroughSession() throws {
        let json = #"{"authKey":"k","user":{"_id":"u","email":"e","fullname":"F","avatar":"https://a.example/x.png"}}"#
        let session = try JSONDecoder().decode(StremioSession.self, from: Data(json.utf8))
        #expect(try JSONDecoder().decode(StremioSession.self, from: JSONEncoder().encode(session)) == session)
    }

    @Test func addonCollectionGet() async throws {
        let http = MockHTTP { _ in
            .json(["result": [
                "addons": [
                    ["manifest": ["id": "com.linvo.cinemeta", "name": "Cinemeta", "version": "3.0.0"],
                     "transportUrl": "https://v3-cinemeta.strem.io/manifest.json",
                     "flags": ["official": true, "protected": true]],
                    ["transportUrl": "https://broken.example/manifest.json"],
                    ["manifest": ["id": "org.x"], "transportUrl": "https://x.example/manifest.json"],
                ],
                "lastModified": "2024-03-01T10:20:30.400Z",
            ]])
        }
        let collection = try await client(http).addonCollection(authKey: "key-1")
        #expect(collection.addons.map(\.manifest.id) == ["com.linvo.cinemeta", "org.x"])
        #expect(collection.addons.first?.flags == .init(official: true, protected: true))
        #expect(collection.addons.last?.flags == .init())
        #expect(collection.lastModified == Date(timeIntervalSince1970: 1_709_288_430.4))

        let request = try #require(http.requests.first)
        #expect(request.path == "/api/addonCollectionGet")
        let body = try #require(request.json)
        #expect(body["type"] as? String == "AddonCollectionGet")
        #expect(body["authKey"] as? String == "key-1")
        #expect(body["update"] as? Bool == true)
    }

    @Test func addonCollectionWithoutLastModified() async throws {
        let http = MockHTTP { _ in .json(["result": ["addons": []]]) }
        let collection = try await client(http).addonCollection(authKey: "k")
        #expect(collection.addons.isEmpty)
        #expect(collection.lastModified == nil)
    }

    @Test func addonCollectionSetSendsDescriptorsWithRawManifest() async throws {
        let http = MockHTTP { _ in .json(["result": ["success": true]]) }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(#"{"id":"org.x","name":"X","custom":"kept"}"#.utf8))
        let addons = [
            AddonDescriptor(manifest: manifest, transportUrl: URL(string: "https://x.example/manifest.json")!, flags: .init(official: true)),
        ]
        try await client(http).setAddonCollection(authKey: "key-1", addons: addons)

        let request = try #require(http.requests.first)
        #expect(request.path == "/api/addonCollectionSet")
        let body = try #require(request.json)
        #expect(body["type"] as? String == "AddonCollectionSet")
        #expect(body["authKey"] as? String == "key-1")
        let sent = try #require(body["addons"] as? [[String: Any]])
        #expect(sent.count == 1)
        #expect(sent[0]["transportUrl"] as? String == "https://x.example/manifest.json")
        let sentManifest = try #require(sent[0]["manifest"] as? [String: Any])
        #expect(sentManifest["id"] as? String == "org.x")
        #expect(sentManifest["custom"] as? String == "kept")
        let flags = try #require(sent[0]["flags"] as? [String: Any])
        #expect(flags["official"] as? Bool == true)
        #expect(flags["protected"] as? Bool == false)
    }

    @Test func libraryMeta() async throws {
        let http = MockHTTP { _ in
            .json(["result": [
                ["tt1", 1_700_000_000_000],
                ["tt2", 1_700_000_000_500.0],
                [42, 1000],
                ["tt3", "not a number"],
                ["only-id"],
                ["tt4", 1, "extra"],
            ]])
        }
        let meta = try await client(http).libraryMeta(authKey: "key-1")
        #expect(meta == [
            "tt1": Date(timeIntervalSince1970: 1_700_000_000),
            "tt2": Date(timeIntervalSince1970: 1_700_000_000.5),
            "42": Date(timeIntervalSince1970: 1),
        ])
        let request = try #require(http.requests.first)
        #expect(request.path == "/api/datastoreMeta")
        let body = try #require(request.json)
        #expect(body["authKey"] as? String == "key-1")
        #expect(body["collection"] as? String == "libraryItem")
        #expect(body["type"] == nil)
    }

    @Test func libraryItemsSendsIdsAndDropsBadItems() async throws {
        let http = MockHTTP { _ in
            .json(["result": [
                ["_id": "tt1", "name": "One", "type": "movie", "_mtime": "2024-01-01T00:00:00.000Z"],
                ["name": "no id"],
                ["_id": "tt2", "type": "series", "removed": true, "temp": false],
            ]])
        }
        let items = try await client(http).libraryItems(authKey: "key-1", ids: ["tt1", "tt2"])
        #expect(items.map(\.id) == ["tt1", "tt2"])
        #expect(items[1].removed)

        let body = try #require(http.requests.first?.json)
        #expect(http.requests.first?.path == "/api/datastoreGet")
        #expect(body["collection"] as? String == "libraryItem")
        #expect(body["ids"] as? [String] == ["tt1", "tt2"])
        #expect(body["all"] as? Bool == false)
    }

    @Test func libraryItemsAll() async throws {
        let http = MockHTTP { _ in .json(["result": []]) }
        let items = try await client(http).libraryItems(authKey: "k", all: true)
        #expect(items.isEmpty)
        let body = try #require(http.requests.first?.json)
        #expect(body["ids"] as? [String] == [])
        #expect(body["all"] as? Bool == true)
    }

    @Test func putLibraryItems() async throws {
        let http = MockHTTP { _ in .json(["result": ["success": true]]) }
        var item = LibraryItem(meta: MetaPreview(id: "tt1", type: "movie", name: "One"), now: Date(timeIntervalSince1970: 1_700_000_000))
        item.removed = false
        item.state.timeOffset = 5000
        item.state.videoId = "tt1"
        try await client(http).putLibraryItems(authKey: "key-1", [item])

        let request = try #require(http.requests.first)
        #expect(request.path == "/api/datastorePut")
        let body = try #require(request.json)
        #expect(body["authKey"] as? String == "key-1")
        #expect(body["collection"] as? String == "libraryItem")
        let changes = try #require(body["changes"] as? [[String: Any]])
        #expect(changes.count == 1)
        #expect(changes[0]["_id"] as? String == "tt1")
        #expect(changes[0]["_mtime"] as? String == "2023-11-14T22:13:20.000Z")
        #expect(changes[0]["removed"] as? Bool == false)
        #expect(changes[0]["temp"] as? Bool == true)
        let state = try #require(changes[0]["state"] as? [String: Any])
        #expect(state["timeOffset"] as? Int == 5000)
        #expect(state["video_id"] as? String == "tt1")
    }

    @Test func putNothingSkipsRequest() async throws {
        let http = MockHTTP { _ in Issue.record("unexpected request"); return .json([:]) }
        try await client(http).putLibraryItems(authKey: "k", [])
        #expect(http.requests.isEmpty)
    }

    @Test func baseURLWithPath() async throws {
        let http = MockHTTP { _ in .json(["result": ["success": true]]) }
        try await StremioAPIClient(baseURL: URL(string: "https://proxy.example/stremio")!, session: http.session).logout(authKey: "k")
        #expect(http.requests.first?.url.absoluteString == "https://proxy.example/stremio/api/logout")
    }
}
