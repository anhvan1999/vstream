import AddonKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        NavigationSplitView {
            List(selection: $app.selection) {
                Section {
                    ForEach([SidebarItem.home, .discover, .library]) { item in
                        Label(item.title, systemImage: item.symbol).tag(item)
                    }
                }
                Section("Manage") {
                    Label(SidebarItem.addons.title, systemImage: SidebarItem.addons.symbol).tag(SidebarItem.addons)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
            .safeAreaInset(edge: .bottom) { AccountBadge().padding(10) }
        } detail: {
            NavigationStack(path: $app.path) {
                content
                    .navigationDestination(for: MetaRoute.self) { route in
                        DetailView(route: route)
                    }
            }
        }
        .searchable(text: $app.searchText, placement: .sidebar, prompt: "Movies, shows, channels")
        .onSubmit(of: .search) {
            app.path = []
            app.selection = .search
        }
        .onChange(of: app.selection) { app.path = [] }
        #if DEBUG
        .task { debugAutoplay() }
        #endif
        .alert(item: $app.alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message))
        }
    }

    #if DEBUG
    @Environment(\.openWindow) private var openWindow

    /// `VSTREAM_DEBUG_PLAY=<url|magnet>` opens the player directly, for end-to-end checks.
    private func debugAutoplay() {
        guard let value = ProcessInfo.processInfo.environment["VSTREAM_DEBUG_PLAY"], let url = URL(string: value) else { return }
        let stream: AddonStream
        if url.scheme == "magnet", let hash = Magnet.infoHash(from: url) {
            stream = AddonStream(infoHash: hash, sources: Magnet.trackers(from: url).map { "tracker:\($0)" })
        } else {
            stream = AddonStream(url: url)
        }
        app.play(meta: MetaDetail(preview: MetaPreview(id: "debug", type: "movie", name: "Debug playback")), video: nil, stream: stream)
        openWindow(id: "player")
    }
    #endif

    @ViewBuilder private var content: some View {
        switch app.selection {
        case .home: HomeView()
        case .discover: DiscoverView()
        case .library: LibraryView()
        case .search: SearchView(query: app.searchText)
        case .addons: AddonsView()
        }
    }
}

/// Compact account status at the bottom of the sidebar.
private struct AccountBadge: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        SettingsLink {
            HStack(spacing: 8) {
                Image(systemName: app.stremio.isSignedIn ? "person.crop.circle.fill" : "person.crop.circle")
                    .font(.title3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.stremio.session?.user.email ?? "Not signed in")
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    Text(app.stremio.isSyncing ? "Syncing…" : app.trakt.isConnected ? "Stremio · Trakt" : "Local library")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 14))
    }
}
