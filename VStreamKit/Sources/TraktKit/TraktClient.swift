import Foundation

public struct TraktCredentials: Sendable, Hashable {
    public var clientID: String
    public var clientSecret: String

    public init(clientID: String, clientSecret: String) {
        self.clientID = clientID
        self.clientSecret = clientSecret
    }
}

public struct TraktToken: Codable, Sendable, Hashable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date

    public var isExpired: Bool { expiresAt <= Date().addingTimeInterval(60) }
}

public struct TraktDeviceCode: Decodable, Sendable, Hashable {
    public var deviceCode: String
    public var userCode: String
    public var verificationURL: URL
    public var expiresIn: Int
    public var interval: Int

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code", userCode = "user_code", verificationURL = "verification_url"
        case expiresIn = "expires_in", interval
    }
}

public enum TraktError: Error, LocalizedError, Sendable {
    case notAuthorized
    case expiredCode
    case denied
    case http(Int)

    public var errorDescription: String? {
        switch self {
        case .notAuthorized: "Trakt is not connected"
        case .expiredCode: "The Trakt code expired, try again"
        case .denied: "Trakt authorization was denied"
        case let .http(status): "Trakt returned HTTP \(status)"
        }
    }
}

/// What is being scrobbled / marked. Trakt identifies items by IMDb id here.
public enum TraktItem: Sendable, Hashable {
    case movie(imdb: String)
    case episode(showIMDB: String, season: Int, episode: Int)

    var scrobbleBody: [String: Any] {
        switch self {
        case let .movie(imdb):
            ["movie": ["ids": ["imdb": imdb]]]
        case let .episode(show, season, episode):
            ["show": ["ids": ["imdb": show]], "episode": ["season": season, "number": episode]]
        }
    }
}

public struct TraktWatchedMovie: Sendable, Hashable {
    public var imdb: String
    public var lastWatchedAt: Date?
}

public struct TraktWatchedShow: Sendable, Hashable {
    public var imdb: String
    /// `season -> episodes`
    public var episodes: [Int: Set<Int>]
    public var lastWatchedAt: Date?
}

public struct TraktListItem: Sendable, Hashable {
    public enum Kind: String, Sendable { case movie, show }
    public var kind: Kind
    public var imdb: String
    public var title: String
    public var year: Int?
}

public struct TraktPlayback: Sendable, Hashable {
    public var item: TraktItem
    /// 0...100
    public var progress: Double
    public var pausedAt: Date?
}

/// Thin Trakt API client. Token storage and refresh scheduling are the caller's responsibility;
/// `onTokenRefresh` is invoked whenever a refreshed token should be persisted.
public actor TraktClient {
    public static let baseURL = URL(string: "https://api.trakt.tv")!

    private let credentials: TraktCredentials
    private let session: URLSession
    private var token: TraktToken?
    private let onTokenRefresh: @Sendable (TraktToken?) -> Void

    public init(
        credentials: TraktCredentials,
        token: TraktToken?,
        session: URLSession = .shared,
        onTokenRefresh: @escaping @Sendable (TraktToken?) -> Void
    ) {
        self.credentials = credentials
        self.token = token
        self.session = session
        self.onTokenRefresh = onTokenRefresh
    }

    public var isAuthorized: Bool { token != nil }

    // MARK: Device authorization

    public func requestDeviceCode() async throws -> TraktDeviceCode {
        let data = try await send("oauth/device/code", body: ["client_id": credentials.clientID], authorized: false)
        return try JSONDecoder().decode(TraktDeviceCode.self, from: data)
    }

    /// Polls until the user approves the code in the browser.
    public func pollForToken(_ code: TraktDeviceCode) async throws -> TraktToken {
        var interval = max(code.interval, 1)
        let deadline = Date().addingTimeInterval(TimeInterval(code.expiresIn))
        while Date() < deadline {
            try await Task.sleep(for: .seconds(interval))
            let (data, status) = try await raw("oauth/device/token", body: [
                "code": code.deviceCode,
                "client_id": credentials.clientID,
                "client_secret": credentials.clientSecret,
            ])
            switch status {
            case 200:
                let token = try decodeToken(data)
                self.token = token
                onTokenRefresh(token)
                return token
            case 400: continue // pending
            case 429: interval += 1
            case 404, 409, 410: throw TraktError.expiredCode
            case 418: throw TraktError.denied
            default: throw TraktError.http(status)
            }
        }
        throw TraktError.expiredCode
    }

    public func signOut() async {
        if let token {
            _ = try? await raw("oauth/revoke", body: [
                "token": token.accessToken,
                "client_id": credentials.clientID,
                "client_secret": credentials.clientSecret,
            ])
        }
        token = nil
        onTokenRefresh(nil)
    }

    // MARK: Scrobble

    public enum ScrobbleAction: String, Sendable { case start, pause, stop }

    public func scrobble(_ action: ScrobbleAction, item: TraktItem, progress: Double) async throws {
        var body = item.scrobbleBody
        body["progress"] = min(max(progress, 0), 100)
        _ = try await send("scrobble/\(action.rawValue)", body: body)
    }

    // MARK: Sync

    public func addToHistory(_ items: [TraktItem], watchedAt: Date = Date()) async throws {
        _ = try await send("sync/history", body: historyBody(items, watchedAt: watchedAt))
    }

    public func removeFromHistory(_ items: [TraktItem]) async throws {
        _ = try await send("sync/history/remove", body: historyBody(items, watchedAt: nil))
    }

    public func watchedMovies() async throws -> [TraktWatchedMovie] {
        let json = try await getJSON("sync/watched/movies") as? [[String: Any]] ?? []
        return json.compactMap { entry in
            guard let imdb = Self.imdb(entry["movie"]) else { return nil }
            return TraktWatchedMovie(imdb: imdb, lastWatchedAt: Self.date(entry["last_watched_at"]))
        }
    }

    public func watchedShows() async throws -> [TraktWatchedShow] {
        let json = try await getJSON("sync/watched/shows") as? [[String: Any]] ?? []
        return json.compactMap { entry in
            guard let imdb = Self.imdb(entry["show"]) else { return nil }
            var episodes: [Int: Set<Int>] = [:]
            for season in entry["seasons"] as? [[String: Any]] ?? [] {
                guard let number = season["number"] as? Int else { continue }
                let numbers = (season["episodes"] as? [[String: Any]] ?? []).compactMap { $0["number"] as? Int }
                episodes[number, default: []].formUnion(numbers)
            }
            return TraktWatchedShow(imdb: imdb, episodes: episodes, lastWatchedAt: Self.date(entry["last_watched_at"]))
        }
    }

    public func watchlist() async throws -> [TraktListItem] {
        let json = try await getJSON("sync/watchlist") as? [[String: Any]] ?? []
        return json.compactMap { entry in
            guard let type = entry["type"] as? String, let kind = TraktListItem.Kind(rawValue: type),
                  let object = entry[type] as? [String: Any], let imdb = Self.imdb(object) else { return nil }
            return TraktListItem(kind: kind, imdb: imdb, title: object["title"] as? String ?? "", year: object["year"] as? Int)
        }
    }

    public func setWatchlist(_ kind: TraktListItem.Kind, imdb: String, added: Bool) async throws {
        let key = kind == .movie ? "movies" : "shows"
        _ = try await send(added ? "sync/watchlist" : "sync/watchlist/remove", body: [key: [["ids": ["imdb": imdb]]]])
    }

    public func playback() async throws -> [TraktPlayback] {
        let json = try await getJSON("sync/playback") as? [[String: Any]] ?? []
        return json.compactMap { entry in
            let progress = entry["progress"] as? Double ?? 0
            let pausedAt = Self.date(entry["paused_at"])
            if let imdb = Self.imdb(entry["movie"]) {
                return TraktPlayback(item: .movie(imdb: imdb), progress: progress, pausedAt: pausedAt)
            }
            if let show = Self.imdb(entry["show"]), let episode = entry["episode"] as? [String: Any],
               let season = episode["season"] as? Int, let number = episode["number"] as? Int {
                return TraktPlayback(item: .episode(showIMDB: show, season: season, episode: number), progress: progress, pausedAt: pausedAt)
            }
            return nil
        }
    }

    // MARK: Transport

    private func historyBody(_ items: [TraktItem], watchedAt: Date?) -> [String: Any] {
        let timestamp = watchedAt.map { ISO8601DateFormatter().string(from: $0) }
        var movies: [[String: Any]] = []
        var shows: [String: [Int: [Int]]] = [:]
        for item in items {
            switch item {
            case let .movie(imdb):
                var movie: [String: Any] = ["ids": ["imdb": imdb]]
                if let timestamp { movie["watched_at"] = timestamp }
                movies.append(movie)
            case let .episode(show, season, episode):
                shows[show, default: [:]][season, default: []].append(episode)
            }
        }
        let showBodies: [[String: Any]] = shows.map { imdb, seasons in
            [
                "ids": ["imdb": imdb],
                "seasons": seasons.map { number, episodes in
                    [
                        "number": number,
                        "episodes": episodes.map { episode -> [String: Any] in
                            var body: [String: Any] = ["number": episode]
                            if let timestamp { body["watched_at"] = timestamp }
                            return body
                        },
                    ] as [String: Any]
                },
            ]
        }
        return ["movies": movies, "shows": showBodies]
    }

    private func getJSON(_ path: String) async throws -> Any {
        let request = try await authorizedRequest(path, method: "GET", body: nil)
        let (data, response) = try await session.data(for: request)
        try check(response)
        return try JSONSerialization.jsonObject(with: data)
    }

    private func send(_ path: String, body: [String: Any], authorized: Bool = true) async throws -> Data {
        let request: URLRequest
        if authorized {
            request = try await authorizedRequest(path, method: "POST", body: body)
        } else {
            request = try makeRequest(path, method: "POST", body: body)
        }
        let (data, response) = try await session.data(for: request)
        try check(response)
        return data
    }

    private func raw(_ path: String, body: [String: Any]) async throws -> (Data, Int) {
        let (data, response) = try await session.data(for: makeRequest(path, method: "POST", body: body))
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private func authorizedRequest(_ path: String, method: String, body: [String: Any]?) async throws -> URLRequest {
        guard var token else { throw TraktError.notAuthorized }
        if token.isExpired {
            token = try await refresh(token)
        }
        var request = try makeRequest(path, method: method, body: body)
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func refresh(_ token: TraktToken) async throws -> TraktToken {
        let (data, status) = try await raw("oauth/token", body: [
            "refresh_token": token.refreshToken,
            "client_id": credentials.clientID,
            "client_secret": credentials.clientSecret,
            "redirect_uri": "http://localhost",
            "grant_type": "refresh_token",
        ])
        guard status == 200 else {
            self.token = nil
            onTokenRefresh(nil)
            throw TraktError.notAuthorized
        }
        let refreshed = try decodeToken(data)
        self.token = refreshed
        onTokenRefresh(refreshed)
        return refreshed
    }

    private func makeRequest(_ path: String, method: String, body: [String: Any]?) throws -> URLRequest {
        var request = URLRequest(url: Self.baseURL.appending(path: path), timeoutInterval: 30)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2", forHTTPHeaderField: "trakt-api-version")
        request.setValue(credentials.clientID, forHTTPHeaderField: "trakt-api-key")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        return request
    }

    private func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if http.statusCode == 401 { throw TraktError.notAuthorized }
        guard (200..<300).contains(http.statusCode) else { throw TraktError.http(http.statusCode) }
    }

    private func decodeToken(_ data: Data) throws -> TraktToken {
        struct Response: Decodable {
            var access_token: String
            var refresh_token: String
            var expires_in: Double
            var created_at: Double
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        return TraktToken(
            accessToken: response.access_token,
            refreshToken: response.refresh_token,
            expiresAt: Date(timeIntervalSince1970: response.created_at + response.expires_in)
        )
    }

    private static func imdb(_ object: Any?) -> String? {
        ((object as? [String: Any])?["ids"] as? [String: Any])?["imdb"] as? String
    }

    private static func date(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}
