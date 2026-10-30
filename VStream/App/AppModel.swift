import AddonKit
import Foundation
import Observation
import VStreamCore

enum SidebarItem: String, Hashable, CaseIterable, Identifiable {
    case home, discover, library, search, playLink, addons

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .discover: "Discover"
        case .library: "Library"
        case .search: "Search"
        case .playLink: "Play Link"
        case .addons: "Addons"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house"
        case .discover: "safari"
        case .library: "books.vertical"
        case .search: "magnifyingglass"
        case .playLink: "link"
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
    /// A link or `.torrent` handed to the app (drop, Open With, magnet URL) for Play Link to open.
    var pendingLink: URL?
    /// Home's carousel titles, kept here so switching tabs doesn't rebuild an empty Home.
    var homeFeatured: [MetaPreview] = []
    var isImportingTorrent = false
    var playLinkFocusRequest = 0
    /// iPhone/iPad present Settings as a sheet (the Mac uses its Settings window).
    var showsSettings = false
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
        switch url.scheme {
        case "stremio":
            pendingAddonURL = url.absoluteString
            selection = .addons
        case "magnet", "file":
            path = []
            selection = .playLink
            pendingLink = url
        default:
            break
        }
    }

    /// Switches to Play Link and focuses its field (⌘L).
    func showPlayLink() {
        path = []
        selection = .playLink
        playLinkFocusRequest += 1
    }

    func play(meta: MetaDetail, video: Video?, stream: AddonStream, recordsProgress: Bool = true, torrentFile: Data? = nil) {
        playback?.close()
        playback = PlaybackSession(app: self, meta: meta, video: video, stream: stream, recordsProgress: recordsProgress, torrentFile: torrentFile)
    }

    func closePlayback() {
        playback?.close()
        playback = nil
    }

    var resolver: StreamResolver {
        StreamResolver(
            debrid: settings.debridProvider,
            mode: settings.settings.torrentMode,
            addsUncachedToDebrid: settings.settings.addUncachedToDebrid
        )
    }
}

struct AppAlert: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}
