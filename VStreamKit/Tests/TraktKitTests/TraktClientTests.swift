import Foundation
import Testing
import TestSupport
@testable import TraktKit

/// Collects the tokens passed to `onTokenRefresh`.
final class TokenLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [TraktToken?] = []
    var tokens: [TraktToken?] { lock.withLock { values } }
    func record(_ token: TraktToken?) { lock.withLock { values.append(token) } }
}

extension TraktToken {
    static let valid = TraktToken(accessToken: "access", refreshToken: "refresh", expiresAt: Date().addingTimeInterval(3600))
    static let expired = TraktToken(accessToken: "old", refreshToken: "refresh-old", expiresAt: Date().addingTimeInterval(30))
}

func tokenJSON(access: String = "new", refresh: String = "r2", createdAt: Double = Date().timeIntervalSince1970.rounded(), expiresIn: Double = 7_776_000) -> MockHTTP.Response {
    .json(["access_token": access, "refresh_token": refresh, "expires_in": expiresIn, "created_at": createdAt, "token_type": "bearer"])
}

func thrown(_ body: () async throws -> Void) async -> String? {
    do { try await body(); return nil } catch { return String(describing: error) }
}

private func makeClient(_ http: MockHTTP, token: TraktToken? = .valid, secret: String? = nil, log: TokenLog = TokenLog()) -> TraktClient {
    TraktClient(credentials: TraktCredentials(clientID: "client", clientSecret: secret), token: token, session: http.session) { log.record($0) }
}

@Suite struct TraktRequestTests {
    @Test func scrobbleMovieBuildsAuthorizedRequest() async throws {
        let http = MockHTTP { _ in .json([:], status: 201) }
        try await makeClient(http).scrobble(.start, item: .movie(imdb: "tt0111161"), progress: 42.5)

        let request = try #require(http.requests.first)
        #expect(request.url.absoluteString == "https://api.trakt.tv/scrobble/start")
        #expect(request.method == "POST")
        #expect(request.headers["trakt-api-key"] == "client")
        #expect(request.headers["trakt-api-version"] == "2")
        #expect(request.headers["Authorization"] == "Bearer access")
        #expect(request.headers["Content-Type"] == "application/json")
        let body = try #require(request.json)
        #expect(((body["movie"] as? [String: Any])?["ids"] as? [String: Any])?["imdb"] as? String == "tt0111161")
        #expect(body["progress"] as? Double == 42.5)
        #expect(body["show"] == nil)
    }

    @Test func scrobbleEpisodeClampsProgress() async throws {
        let http = MockHTTP { _ in .json([:]) }
        let client = makeClient(http)
        try await client.scrobble(.pause, item: .episode(showIMDB: "tt0903747", season: 2, episode: 5), progress: 150)
        try await client.scrobble(.stop, item: .episode(showIMDB: "tt0903747", season: 2, episode: 5), progress: -3)

        #expect(http.requests.map(\.path) == ["/scrobble/pause", "/scrobble/stop"])
        let body = try #require(http.requests[0].json)
        #expect(((body["show"] as? [String: Any])?["ids"] as? [String: Any])?["imdb"] as? String == "tt0903747")
        let episode = try #require(body["episode"] as? [String: Any])
        #expect(episode["season"] as? Int == 2)
        #expect(episode["number"] as? Int == 5)
        #expect(body["movie"] == nil)
        #expect(body["progress"] as? Double == 100)
        #expect(http.requests[1].json?["progress"] as? Double == 0)
    }

    @Test func withoutTokenNothingIsSent() async {
        let http = MockHTTP { _ in .json([:]) }
        let client = makeClient(http, token: nil)
        #expect(await client.isAuthorized == false)
        #expect(await thrown { _ = try await client.watchlist() } == "notAuthorized")
        #expect(await thrown { try await client.scrobble(.start, item: .movie(imdb: "tt1"), progress: 1) } == "notAuthorized")
        #expect(http.requests.isEmpty)
    }

    @Test func statusErrors() async {
        let http = MockHTTP { request in
            request.path.hasSuffix("watchlist") ? MockHTTP.Response(status: 401) : MockHTTP.Response(status: 503)
        }
        let client = makeClient(http)
        #expect(await thrown { _ = try await client.watchlist() } == "notAuthorized")
        #expect(await thrown { _ = try await client.playback() } == "http(503)")
        #expect(await client.isAuthorized)
    }

    @Test func expiredTokenIsRefreshedBeforeRequest() async throws {
        let createdAt = Date().timeIntervalSince1970.rounded()
        let http = MockHTTP(MockHTTP.routes([
            "/oauth/token": tokenJSON(createdAt: createdAt),
            "/sync/watchlist": .json([Any]()),
        ]))
        let log = TokenLog()
        let client = makeClient(http, token: .expired, secret: "secret", log: log)
        _ = try await client.watchlist()
        _ = try await client.watchlist()

        #expect(http.requests.map(\.path) == ["/oauth/token", "/sync/watchlist", "/sync/watchlist"])
        let refresh = try #require(http.requests[0].json)
        #expect(refresh["grant_type"] as? String == "refresh_token")
        #expect(refresh["refresh_token"] as? String == "refresh-old")
        #expect(refresh["client_id"] as? String == "client")
        #expect(refresh["client_secret"] as? String == "secret")
        #expect(refresh["redirect_uri"] as? String == "http://localhost:8765/trakt")
        #expect(http.requests[0].headers["Authorization"] == nil)
        #expect(http.requests[1].headers["Authorization"] == "Bearer new")
        #expect(http.requests[2].headers["Authorization"] == "Bearer new")

        let token = try #require(log.tokens.first ?? nil)
        #expect(log.tokens.count == 1)
        #expect(token.accessToken == "new")
        #expect(token.refreshToken == "r2")
        #expect(token.expiresAt == Date(timeIntervalSince1970: createdAt + 7_776_000))
    }

    @Test func publicClientRefreshSendsNoSecret() async throws {
        let http = MockHTTP(MockHTTP.routes(["/oauth/token": tokenJSON(), "/sync/playback": .json([Any]())]))
        _ = try await makeClient(http, token: .expired).playback()
        #expect(http.requests.first?.json?.keys.contains("client_secret") == false)
    }

    @Test func failedRefreshSignsOut() async {
        let http = MockHTTP(MockHTTP.routes(["/oauth/token": .json(["error": "invalid_grant"], status: 400)]))
        let log = TokenLog()
        let client = makeClient(http, token: .expired, log: log)
        #expect(await thrown { _ = try await client.watchedMovies() } == "notAuthorized")
        #expect(await client.isAuthorized == false)
        #expect(log.tokens.count == 1)
        #expect(log.tokens.first! == nil)
        #expect(http.requests.map(\.path) == ["/oauth/token"])
    }

    @Test func addToHistoryGroupsEpisodesByShow() async throws {
        let http = MockHTTP { _ in .json([:], status: 201) }
        let watchedAt = Date(timeIntervalSince1970: 1_700_000_000)
        try await makeClient(http).addToHistory([
            .movie(imdb: "tt1"),
            .episode(showIMDB: "tt2", season: 1, episode: 1),
            .episode(showIMDB: "tt2", season: 1, episode: 2),
            .episode(showIMDB: "tt2", season: 3, episode: 7),
        ], watchedAt: watchedAt)

        let request = try #require(http.requests.first)
        #expect(request.path == "/sync/history")
        let body = try #require(request.json)
        let movies = try #require(body["movies"] as? [[String: Any]])
        #expect(movies.count == 1)
        #expect((movies[0]["ids"] as? [String: Any])?["imdb"] as? String == "tt1")
        #expect(movies[0]["watched_at"] as? String == "2023-11-14T22:13:20Z")
        let shows = try #require(body["shows"] as? [[String: Any]])
        #expect(shows.count == 1)
        #expect((shows[0]["ids"] as? [String: Any])?["imdb"] as? String == "tt2")
        let seasons = try #require(shows[0]["seasons"] as? [[String: Any]])
        let bySeason = Dictionary(uniqueKeysWithValues: seasons.map { ($0["number"] as! Int, $0["episodes"] as! [[String: Any]]) })
        #expect(Set(bySeason[1]!.map { $0["number"] as! Int }) == [1, 2])
        #expect(bySeason[3]!.map { $0["number"] as! Int } == [7])
        #expect(bySeason[3]![0]["watched_at"] as? String == "2023-11-14T22:13:20Z")
    }

    @Test func removeFromHistoryHasNoTimestamps() async throws {
        let http = MockHTTP { _ in .json([:]) }
        try await makeClient(http).removeFromHistory([.movie(imdb: "tt1"), .episode(showIMDB: "tt2", season: 1, episode: 4)])
        let request = try #require(http.requests.first)
        #expect(request.path == "/sync/history/remove")
        #expect(!request.bodyString.contains("watched_at"))
        let episode = ((((request.json?["shows"] as? [[String: Any]])?.first?["seasons"] as? [[String: Any]])?.first?["episodes"]) as? [[String: Any]])?.first
        #expect(episode?["number"] as? Int == 4)
    }

    @Test func setWatchlistBodies() async throws {
        let http = MockHTTP { _ in .json([:]) }
        let client = makeClient(http)
        try await client.setWatchlist(.movie, imdb: "tt1", added: true)
        try await client.setWatchlist(.show, imdb: "tt2", added: false)
        #expect(http.requests.map(\.path) == ["/sync/watchlist", "/sync/watchlist/remove"])
        #expect(((http.requests[0].json?["movies"] as? [[String: Any]])?.first?["ids"] as? [String: Any])?["imdb"] as? String == "tt1")
        #expect(((http.requests[1].json?["shows"] as? [[String: Any]])?.first?["ids"] as? [String: Any])?["imdb"] as? String == "tt2")
    }
}

@Suite struct TraktDecodingTests {
    @Test func watchedMovies() async throws {
        let http = MockHTTP(MockHTTP.routes(["/sync/watched/movies": .json([
            ["last_watched_at": "2024-01-02T03:04:05.000Z", "movie": ["title": "A", "ids": ["imdb": "tt1", "trakt": 1]]],
            ["last_watched_at": "2024-01-02T03:04:05Z", "movie": ["ids": ["imdb": "tt2"]]],
            ["movie": ["ids": ["trakt": 3]]],
        ])]))
        let movies = try await makeClient(http).watchedMovies()
        #expect(http.requests.first?.method == "GET")
        #expect(http.requests.first?.headers["Authorization"] == "Bearer access")
        #expect(movies.map(\.imdb) == ["tt1", "tt2"])
        let expected = Date(timeIntervalSince1970: 1_704_164_645)
        #expect(movies[0].lastWatchedAt == expected)
        #expect(movies[1].lastWatchedAt == expected)
    }

    @Test func watchedShows() async throws {
        let http = MockHTTP(MockHTTP.routes(["/sync/watched/shows": .json([
            [
                "last_watched_at": "2024-05-01T00:00:00.000Z",
                "show": ["ids": ["imdb": "tt9"]],
                "seasons": [
                    ["number": 1, "episodes": [["number": 1], ["number": 2]]],
                    ["number": 2, "episodes": [["number": 3]]],
                    ["episodes": [["number": 9]]],
                ],
            ],
            ["show": ["ids": ["tvdb": 5]], "seasons": [Any]()],
        ])]))
        let shows = try await makeClient(http).watchedShows()
        #expect(shows.count == 1)
        #expect(shows[0].imdb == "tt9")
        #expect(shows[0].episodes == [1: [1, 2], 2: [3]])
        #expect(shows[0].lastWatchedAt != nil)
    }

    @Test func watchlist() async throws {
        let http = MockHTTP(MockHTTP.routes(["/sync/watchlist": .json([
            ["type": "movie", "movie": ["title": "Heat", "year": 1995, "ids": ["imdb": "tt0113277"]]],
            ["type": "show", "show": ["ids": ["imdb": "tt2"]]],
            ["type": "season", "season": ["ids": ["imdb": "tt3"]]],
            ["type": "movie", "movie": ["title": "No ids"]],
        ])]))
        let items = try await makeClient(http).watchlist()
        #expect(items == [
            TraktListItem(kind: .movie, imdb: "tt0113277", title: "Heat", year: 1995),
            TraktListItem(kind: .show, imdb: "tt2", title: "", year: nil),
        ])
    }

    @Test func nonArrayResponseIsEmpty() async throws {
        let http = MockHTTP { _ in .json(["error": "x"]) }
        #expect(try await makeClient(http).watchlist().isEmpty)
    }

    @Test(arguments: [TraktListItem.Kind.movie, .show])
    func recommendations(kind: TraktListItem.Kind) async throws {
        let http = MockHTTP { _ in .json([["title": "Rec", "year": 2020, "ids": ["imdb": "tt5"]], ["title": "No imdb", "ids": [String: Any]()]]) }
        let items = try await makeClient(http).recommendations(kind, limit: 10)
        let request = try #require(http.requests.first)
        #expect(request.path == (kind == .movie ? "/recommendations/movies" : "/recommendations/shows"))
        #expect(request.query == ["limit": "10", "ignore_collected": "true"])
        #expect(items == [TraktListItem(kind: kind, imdb: "tt5", title: "Rec", year: 2020)])
    }

    @Test func playback() async throws {
        let http = MockHTTP(MockHTTP.routes(["/sync/playback": .json([
            ["progress": 12.5, "paused_at": "2024-01-02T03:04:05.000Z", "type": "movie", "movie": ["ids": ["imdb": "tt1"]]],
            ["progress": 80, "type": "episode", "show": ["ids": ["imdb": "tt2"]], "episode": ["season": 3, "number": 4]],
            ["progress": 50, "type": "episode", "show": ["ids": ["imdb": "tt3"]]],
            ["progress": 50],
        ])]))
        let entries = try await makeClient(http).playback()
        #expect(entries == [
            TraktPlayback(item: .movie(imdb: "tt1"), progress: 12.5, pausedAt: Date(timeIntervalSince1970: 1_704_164_645)),
            TraktPlayback(item: .episode(showIMDB: "tt2", season: 3, episode: 4), progress: 80, pausedAt: nil),
        ])
    }
}

@Suite struct TraktDeviceFlowTests {
    static func deviceCode(expiresIn: Int = 30, interval: Int = 0) -> TraktDeviceCode {
        TraktDeviceCode(deviceCode: "dev", userCode: "ABCD", verificationURL: URL(string: "https://trakt.tv/activate")!, expiresIn: expiresIn, interval: interval)
    }

    @Test func requestDeviceCodeIsUnauthenticated() async throws {
        let http = MockHTTP { _ in
            .json(["device_code": "dev", "user_code": "ABCD", "verification_url": "https://trakt.tv/activate", "expires_in": 600, "interval": 5])
        }
        let code = try await makeClient(http, token: nil).requestDeviceCode()
        #expect(code == Self.deviceCode(expiresIn: 600, interval: 5))
        let request = try #require(http.requests.first)
        #expect(request.path == "/oauth/device/code")
        #expect(request.headers["Authorization"] == nil)
        #expect(request.headers["trakt-api-key"] == "client")
        #expect(request.json?["client_id"] as? String == "client")
    }

    @Test func pollReturnsTokenOnApproval() async throws {
        let http = MockHTTP { _ in tokenJSON(access: "device-token") }
        let log = TokenLog()
        let client = makeClient(http, token: nil, secret: "s", log: log)
        let token = try await client.pollForToken(Self.deviceCode())
        #expect(token.accessToken == "device-token")
        #expect(await client.isAuthorized)
        #expect(log.tokens == [token])
        let body = try #require(http.requests.first?.json)
        #expect(http.requests.first?.path == "/oauth/device/token")
        #expect(body["code"] as? String == "dev")
        #expect(body["client_id"] as? String == "client")
        #expect(body["client_secret"] as? String == "s")
    }

    @Test(arguments: [(418, "denied"), (410, "expiredCode"), (404, "expiredCode"), (409, "expiredCode"), (500, "http(500)")])
    func pollFailures(status: Int, expected: String) async {
        let http = MockHTTP { _ in MockHTTP.Response(status: status) }
        let client = makeClient(http, token: nil)
        #expect(await thrown { _ = try await client.pollForToken(Self.deviceCode()) } == expected)
        #expect(http.requests.count == 1)
    }

    @Test func pollGivesUpAfterExpiry() async {
        let http = MockHTTP { _ in MockHTTP.Response(status: 400) }
        let client = makeClient(http, token: nil)
        #expect(await thrown { _ = try await client.pollForToken(Self.deviceCode(expiresIn: 0)) } == "expiredCode")
        #expect(http.requests.isEmpty)
    }

    @Test func pendingKeepsPolling() async throws {
        let http = MockHTTP { _ in MockHTTP.Response(status: 400) }
        let client = makeClient(http, token: nil)
        #expect(await thrown { _ = try await client.pollForToken(Self.deviceCode(expiresIn: 2)) } == "expiredCode")
        #expect(http.requests.count >= 1)
    }

    @Test func signOutRevokesToken() async throws {
        let http = MockHTTP { _ in .json([:]) }
        let log = TokenLog()
        let client = makeClient(http, secret: "s", log: log)
        await client.signOut()
        #expect(await client.isAuthorized == false)
        #expect(log.tokens.count == 1 && log.tokens[0] == nil)
        let request = try #require(http.requests.first)
        #expect(request.path == "/oauth/revoke")
        #expect(request.json?["token"] as? String == "access")
        #expect(request.json?["client_secret"] as? String == "s")
        #expect(request.headers["Authorization"] == nil)

        await client.signOut()
        #expect(http.requests.count == 1)
        #expect(log.tokens.count == 2)
    }

    @Test func signOutSurvivesNetworkFailure() async {
        let http = MockHTTP { _ in throw URLError(.notConnectedToInternet) }
        let client = makeClient(http)
        await client.signOut()
        #expect(await client.isAuthorized == false)
    }
}

@Suite struct TraktModelTests {
    @Test func tokenExpiryHasOneMinuteMargin() {
        #expect(TraktToken.expired.isExpired)
        #expect(!TraktToken.valid.isExpired)
        #expect(TraktToken(accessToken: "", refreshToken: "", expiresAt: .distantPast).isExpired)
    }

    @Test func tokenIsCodable() throws {
        let data = try JSONEncoder().encode(TraktToken.valid)
        #expect(try JSONDecoder().decode(TraktToken.self, from: data) == .valid)
    }

    @Test func emptySecretIsPublicClient() {
        #expect(TraktCredentials(clientID: "id", clientSecret: "").clientSecret == nil)
        #expect(TraktCredentials(clientID: "id", clientSecret: "").signed(["x": 1]).count == 1)
    }

    @Test func pkceBase64URL() {
        #expect(PKCE.base64URL(Data([0xfb, 0xff, 0xfe])) == "-__-")
        #expect(PKCE.base64URL(Data([0x01])) == "AQ")
        let pkce = PKCE()
        #expect(pkce.challenge == PKCE(verifier: pkce.verifier).challenge)
        #expect(pkce.challenge.count == 43)
        #expect(PKCE().verifier != pkce.verifier)
    }

    @Test func errorDescriptions() {
        #expect(TraktError.notAuthorized.errorDescription == "Trakt is not connected")
        #expect(TraktError.expiredCode.errorDescription == "The Trakt code expired, try again")
        #expect(TraktError.denied.errorDescription == "Trakt authorization was denied")
        #expect(TraktError.http(502).errorDescription == "Trakt returned HTTP 502")
        #expect(LoopbackError.timedOut.errorDescription == "Trakt sign-in timed out")
        #expect(LoopbackError.denied("nope").errorDescription == "Trakt sign-in failed: nope")
        #expect(LoopbackError.portUnavailable(1).errorDescription?.contains("Port 1 is in use") == true)
    }

    @Test func constants() {
        #expect(TraktClient.baseURL.absoluteString == "https://api.trakt.tv")
        #expect(TraktClient.redirectPort == 8765)
        #expect(TraktClient.redirectPath == "/trakt")
    }
}

/// Drives the real loopback server on port 8765: the "browser" is a URLSession request to
/// localhost made after `openURL` returns; the token endpoint is mocked.
@Suite(.serialized) struct TraktBrowserAuthorizationTests {
    private static func redirect(_ query: @escaping @Sendable ([String: String]) -> String) -> @Sendable (URL) async -> Void {
        { url in
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let params = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
            let target = URL(string: "http://localhost:8765/trakt?\(query(params))")!
            Task.detached {
                try? await Task.sleep(for: .milliseconds(300))
                _ = try? await URLSession.shared.data(from: target)
            }
        }
    }

    @Test func exchangesCodeWithPKCE() async throws {
        let http = MockHTTP(MockHTTP.routes(["/oauth/token": tokenJSON(access: "browser")]))
        let log = TokenLog()
        let opened = URLLog()
        let client = makeClient(http, token: nil, log: log)
        let token = try await client.authorizeInBrowser { url in
            opened.record(url)
            await Self.redirect { "code=the-code&state=\($0["state"]!)" }(url)
        }
        #expect(token.accessToken == "browser")
        #expect(await client.isAuthorized)
        #expect(log.tokens == [token])

        let authorize = try #require(opened.urls.first.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) })
        let params = Dictionary(uniqueKeysWithValues: (authorize.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(authorize.host == "trakt.tv")
        #expect(authorize.path == "/oauth/authorize")
        #expect(params["response_type"] == "code")
        #expect(params["client_id"] == "client")
        #expect(params["redirect_uri"] == "http://localhost:8765/trakt")
        #expect(params["code_challenge_method"] == "S256")

        let body = try #require(http.requests.first?.json)
        #expect(body["code"] as? String == "the-code")
        #expect(body["grant_type"] as? String == "authorization_code")
        #expect(body["redirect_uri"] as? String == "http://localhost:8765/trakt")
        #expect(body["client_secret"] == nil)
        let verifier = try #require(body["code_verifier"] as? String)
        #expect(PKCE(verifier: verifier).challenge == params["code_challenge"])
    }

    @Test func stateMismatchIsRejected() async {
        let http = MockHTTP { _ in tokenJSON() }
        let client = makeClient(http, token: nil)
        let error = await thrown { _ = try await client.authorizeInBrowser(openURL: Self.redirect { _ in "code=x&state=forged" }) }
        #expect(error == #"denied("state mismatch")"#)
        #expect(http.requests.isEmpty)
    }

    @Test func userDenialIsReported() async {
        let http = MockHTTP { _ in tokenJSON() }
        let client = makeClient(http, token: nil)
        let error = await thrown { _ = try await client.authorizeInBrowser(openURL: Self.redirect { "error=access_denied&state=\($0["state"]!)" }) }
        #expect(error == #"denied("access_denied")"#)
        #expect(await client.isAuthorized == false)
    }

    @Test func rejectedCodeExchange() async {
        let http = MockHTTP { _ in MockHTTP.Response(status: 401) }
        let client = makeClient(http, token: nil)
        let error = await thrown { _ = try await client.authorizeInBrowser(openURL: Self.redirect { "code=x&state=\($0["state"]!)" }) }
        #expect(error == "notAuthorized")
    }
}

final class URLLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [URL] = []
    var urls: [URL] { lock.withLock { values } }
    func record(_ url: URL) { lock.withLock { values.append(url) } }
}
