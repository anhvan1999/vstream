import AddonKit
import Foundation
import Observation
import OSLog
import StremioAPI
import TraktKit

@MainActor
@Observable
public final class TraktAccount {
    public private(set) var isConnected = false
    public private(set) var isWaitingForBrowser = false
    public private(set) var isSyncing = false
    public private(set) var lastError: String?
    /// Trakt lists for Home, loaded here (not by the views) so scrolling can't cancel them.
    public private(set) var lists: [List: [MetaPreview]] = [:]
    @ObservationIgnored private var listsTask: Task<Void, Never>?
    private nonisolated static let log = Logger(subsystem: "com.vstream.app", category: "trakt")

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private var client: TraktClient?
    @ObservationIgnored private var authTask: Task<Void, Never>?

    public init(settings: SettingsStore, library: LibraryStore) {
        self.settings = settings
        self.library = library
        isConnected = Keychain.value(TraktToken.self, for: "trakt.token") != nil
        library.onWatched = { [weak self] item, videoID in
            self?.pushHistory(item: item, videoID: videoID)
        }
        library.onLibraryToggle = { [weak self] item, added in
            self?.pushWatchlist(item: item, added: added)
        }
    }

    public var hasCredentials: Bool {
        !settings.settings.traktClientID.isEmpty
    }

    private func makeClient() -> TraktClient? {
        guard hasCredentials else { return nil }
        if let client { return client }
        let credentials = TraktCredentials(clientID: settings.settings.traktClientID)
        let client = TraktClient(credentials: credentials, token: Keychain.value(TraktToken.self, for: "trakt.token")) { [weak self] token in
            Keychain.set(value: token, for: "trakt.token")
            Task { @MainActor in self?.isConnected = token != nil }
        }
        self.client = client
        return client
    }

    /// Authorization code + PKCE (public client, no secret): opens the browser and captures
    /// the redirect on `http://localhost:8765/trakt`.
    public func connect(openURL: @escaping @Sendable (URL) async -> Void) {
        guard let client = makeClient() else {
            lastError = "Add your Trakt client ID first"
            return
        }
        authTask?.cancel()
        lastError = nil
        isWaitingForBrowser = true
        authTask = Task {
            defer { isWaitingForBrowser = false }
            do {
                _ = try await client.authorizeInBrowser(openURL: openURL)
                isConnected = true
                await importHistory()
                refreshLists()
            } catch is CancellationError {
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    public func cancelConnect() {
        authTask?.cancel()
        isWaitingForBrowser = false
    }

    public func disconnect() async {
        await makeClient()?.signOut()
        client = nil
        isConnected = false
    }

    /// Credentials changed in Settings: rebuild the client on next use.
    public func credentialsChanged() {
        client = nil
    }

    /// Pulls watched history into the local watched sets.
    public func importHistory() async {
        guard isConnected, let client = makeClient(), !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            async let movies = client.watchedMovies()
            async let shows = client.watchedShows()
            var entries: [String: Set<String>] = [:]
            for movie in try await movies {
                entries[movie.imdb, default: []].insert(movie.imdb)
            }
            for show in try await shows {
                for (season, episodes) in show.episodes {
                    for episode in episodes {
                        entries[show.imdb, default: []].insert("\(show.imdb):\(season):\(episode)")
                    }
                }
            }
            library.importWatched(entries)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: Lists

    public enum List: String, CaseIterable, Sendable {
        case watchlist, recommendedMovies, recommendedShows

        public var title: String {
            switch self {
            case .watchlist: "Trakt Watchlist"
            case .recommendedMovies: "Recommended Movies · Trakt"
            case .recommendedShows: "Recommended Shows · Trakt"
            }
        }
    }

    /// Loads every list concurrently; failures leave that list as it was.
    public func refreshLists() {
        guard isConnected else { lists = [:]; return }
        listsTask?.cancel()
        listsTask = Task {
            await withTaskGroup(of: (List, [MetaPreview]?).self) { group in
                for list in List.allCases {
                    group.addTask {
                        do {
                            let items = try await self.items(list)
                            Self.log.notice("trakt \(list.rawValue, privacy: .public): \(items.count, privacy: .public) items")
                            return (list, items)
                        } catch {
                            Self.log.error("trakt \(list.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                            return (list, nil)
                        }
                    }
                }
                for await (list, items) in group {
                    if let items { lists[list] = items }
                }
            }
        }
    }

    /// A Trakt list as catalog items; artwork comes from Cinemeta's image CDN by IMDb id.
    public func items(_ list: List) async throws -> [MetaPreview] {
        guard isConnected, let client = makeClient() else { return [] }
        let entries: [TraktListItem] = switch list {
        case .watchlist: try await client.watchlist()
        case .recommendedMovies: try await client.recommendations(.movie)
        case .recommendedShows: try await client.recommendations(.show)
        }
        return entries.map { entry in
            MetaPreview(
                id: entry.imdb,
                type: entry.kind == .movie ? "movie" : "series",
                name: entry.title,
                poster: URL(string: "https://images.metahub.space/poster/medium/\(entry.imdb)/img"),
                releaseInfo: entry.year.map(String.init)
            )
        }
    }

    // MARK: Scrobbling

    public func scrobble(_ action: TraktClient.ScrobbleAction, type: String, videoID: String, progress: Double) {
        guard isConnected, let client = makeClient(), let item = Self.traktItem(type: type, videoID: videoID) else { return }
        Task { try? await client.scrobble(action, item: item, progress: progress * 100) }
    }

    private func pushHistory(item: LibraryItem, videoID: String) {
        guard isConnected, let client = makeClient(), let traktItem = Self.traktItem(type: item.type, videoID: videoID) else { return }
        Task { try? await client.addToHistory([traktItem]) }
    }

    private func pushWatchlist(item: LibraryItem, added: Bool) {
        guard isConnected, let client = makeClient(), item.id.hasPrefix("tt") else { return }
        let kind: TraktListItem.Kind = item.type == "movie" ? .movie : .show
        Task { try? await client.setWatchlist(kind, imdb: item.id, added: added) }
    }

    nonisolated static func traktItem(type: String, videoID: String) -> TraktItem? {
        let parts = videoID.split(separator: ":").map(String.init)
        guard let imdb = parts.first, imdb.hasPrefix("tt") else { return nil }
        if type == "movie" { return .movie(imdb: imdb) }
        guard parts.count >= 3, let season = Int(parts[1]), let episode = Int(parts[2]) else { return nil }
        return .episode(showIMDB: imdb, season: season, episode: episode)
    }
}
