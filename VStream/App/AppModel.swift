import AddonKit
import Foundation
import Observation
import VStreamCore

enum SidebarItem: String, Hashable, CaseIterable, Identifiable {
    case home, discover, library, search, addons

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .discover: "Discover"
        case .library: "Library"
        case .search: "Search"
        case .addons: "Addons"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house"
        case .discover: "safari"
        case .library: "books.vertical"
        case .search: "magnifyingglass"
        case .addons: "puzzlepiece.extension"
        }
    }
}

/// Navigation target for a meta page.
struct MetaRoute: Hashable {
    var type: String
    var id: String
    var preview: MetaPreview?
}

@MainActor
@Observable
final class AppModel {
    let settings = SettingsStore()
    let addons = AddonStore()
    let library = LibraryStore()
    let content = ContentService()
    @ObservationIgnored private(set) lazy var stremio = StremioAccount(addons: addons, library: library)
    @ObservationIgnored private(set) lazy var trakt = TraktAccount(settings: settings, library: library)

    var selection: SidebarItem = .home
    var path: [MetaRoute] = []
    var searchText = ""
    var playback: PlaybackSession?
    var pendingAddonURL: String?
    var alert: AppAlert?

    init() {
        _ = stremio
        _ = trakt
    }

    func start() async {
        await addons.refreshManifests()
        await stremio.sync()
        await trakt.importHistory()
        trakt.refreshLists()
    }

    func open(_ meta: MetaPreview) {
        path.append(MetaRoute(type: meta.type, id: meta.id, preview: meta))
    }

    func handle(url: URL) {
        guard url.scheme == "stremio" else { return }
        pendingAddonURL = url.absoluteString
        selection = .addons
    }

    func play(meta: MetaDetail, video: Video?, stream: AddonStream, recordsProgress: Bool = true) {
        playback?.close()
        playback = PlaybackSession(app: self, meta: meta, video: video, stream: stream, recordsProgress: recordsProgress)
    }

    func closePlayback() {
        playback?.close()
        playback = nil
    }

    var resolver: StreamResolver {
        StreamResolver(debrid: settings.debridProvider, mode: settings.settings.torrentMode)
    }
}

struct AppAlert: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}
