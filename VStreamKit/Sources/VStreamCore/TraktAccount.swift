import AddonKit
import Foundation
import Observation
import StremioAPI
import TraktKit

@MainActor
@Observable
public final class TraktAccount {
    public private(set) var isConnected = false
    public private(set) var pendingCode: TraktDeviceCode?
    public private(set) var isSyncing = false
    public private(set) var lastError: String?

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
        !settings.settings.traktClientID.isEmpty && !settings.traktClientSecret.isEmpty
    }

    private func makeClient() -> TraktClient? {
        guard hasCredentials else { return nil }
        if let client { return client }
        let credentials = TraktCredentials(clientID: settings.settings.traktClientID, clientSecret: settings.traktClientSecret)
        let client = TraktClient(credentials: credentials, token: Keychain.value(TraktToken.self, for: "trakt.token")) { [weak self] token in
            Keychain.set(value: token, for: "trakt.token")
            Task { @MainActor in self?.isConnected = token != nil }
        }
        self.client = client
        return client
    }

    /// Starts device authorization; `pendingCode` is shown to the user until approved.
    public func connect() {
        guard let client = makeClient() else {
            lastError = "Add your Trakt client ID and secret first"
            return
        }
        authTask?.cancel()
        authTask = Task {
            do {
                let code = try await client.requestDeviceCode()
                pendingCode = code
                _ = try await client.pollForToken(code)
                pendingCode = nil
                isConnected = true
                lastError = nil
                await importHistory()
            } catch is CancellationError {
                pendingCode = nil
            } catch {
                pendingCode = nil
                lastError = error.localizedDescription
            }
        }
    }

    public func cancelConnect() {
        authTask?.cancel()
        pendingCode = nil
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
