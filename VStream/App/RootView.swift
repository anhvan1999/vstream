import AddonKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif


    var body: some View {
        @Bindable var app = app
        layout
        #if os(macOS)
        .toolbar(removing: .sidebarToggle)
        // Clear at the top of a page (the Home hero and detail artwork run up under it); the
        // system fades its background in once content scrolls beneath it.
        .toolbarBackgroundVisibility(.automatic, for: .windowToolbar)
        .toolbar(removing: .title)
        // Only the player goes full screen; the green button zooms this window instead.
        .fullScreenAllowed(false)
        #else
        // iPhone/iPad have no player window: playback covers the screen.
        .fullScreenCover(item: Binding(get: { app.playback }, set: { if $0 == nil { app.closePlayback() } })) { _ in
            PlayerWindow().environment(app)
        }
        .sheet(isPresented: $app.showsSettings) {
            SettingsView().environment(app)
        }
        #endif
        .onChange(of: app.selection) { app.path = [] }
        // Torrents, magnets and video files dropped on any page open in Play Link (which has
        // its own drop target with a highlight).
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, url.scheme == "magnet" || url.isFileURL else { return false }
            app.handle(url: url)
            return true
        }
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
        // `VSTREAM_DEBUG_TAB=<home|search|discover|library|playLink|addons>` opens that tab.
        if let tab = ProcessInfo.processInfo.environment["VSTREAM_DEBUG_TAB"].flatMap(SidebarItem.init(rawValue:)) {
            app.selection = tab
        }
        // `VSTREAM_DEBUG_OPEN=<type>:<id>` opens a detail page, for screenshots.
        if let route = ProcessInfo.processInfo.environment["VSTREAM_DEBUG_OPEN"]?.split(separator: ":", maxSplits: 1), route.count == 2 {
            Task {
                try? await Task.sleep(for: .seconds(1))
                app.path = [MetaRoute(type: String(route[0]), id: String(route[1]))]
            }
        }
        guard let value = ProcessInfo.processInfo.environment["VSTREAM_DEBUG_PLAY"], let url = URL(string: value) else { return }
        let stream: AddonStream
        if url.scheme == "magnet", let hash = Magnet.infoHash(from: url) {
            stream = AddonStream(infoHash: hash, sources: Magnet.trackers(from: url).map { "tracker:\($0)" })
        } else {
            stream = AddonStream(url: url)
        }
        // `VSTREAM_DEBUG_META=<type>:<id>` borrows a real title's addon subtitles.
        let parts = ProcessInfo.processInfo.environment["VSTREAM_DEBUG_META"]?.split(separator: ":", maxSplits: 1).map(String.init)
        let preview = MetaPreview(id: parts?.last ?? "debug", type: parts?.first ?? "movie", name: "Debug playback")
        #if os(macOS)
        app.play(meta: MetaDetail(preview: preview), video: nil, stream: stream, recordsProgress: false)
        openWindow(id: "player")
        #else
        // Presenting the player cover before the first frame of the scene is dropped.
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            app.play(meta: MetaDetail(preview: preview), video: nil, stream: stream, recordsProgress: false)
        }
        #endif
    }
    #endif

    /// The Mac keeps its split view; iPhone/iPad use a sidebar-adaptable tab view, like the Apple
    /// TV app: a sidebar on iPad that collapses into a tab strip, a tab bar on iPhone.
    @ViewBuilder private var layout: some View {
        #if os(iOS)
        tabLayout
        #else
        NavigationSplitView { sidebar } detail: { detailStack(content) }
        #endif
    }

    private var sidebar: some View {
        List(selection: sidebarSelection) {
            ForEach([SidebarItem.home, .search, .discover, .library, .playLink, .addons]) { item in
                Label(item.title, systemImage: item.symbol).tag(item)
            }
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
        .safeAreaInset(edge: .bottom) { AccountBadge().padding(10) }
    }

    #if os(iOS)
    private var tabLayout: some View {
        TabView(selection: sidebarSelection) {
            ForEach([SidebarItem.home, .discover, .library, .playLink]) { item in
                Tab(item.title, systemImage: item.symbol, value: Optional(item)) {
                    detailStack(content(for: item))
                }
            }
            // iPad only: four tabs plus Search fill an iPhone tab bar (more would add "More"), so
            // there Addons is reached through Settings (⚙︎ on Library).
            if horizontalSizeClass != .compact {
                Tab(SidebarItem.addons.title, systemImage: SidebarItem.addons.symbol, value: Optional(SidebarItem.addons)) {
                    detailStack(content(for: .addons))
                }
            }
            // The system search tab: its own spot at the trailing end of the iPad strip (icon only)
            // and of the iPhone tab bar, "Search" with text in the sidebar.
            Tab(SidebarItem.search.title, systemImage: SidebarItem.search.symbol, value: Optional(SidebarItem.search), role: .search) {
                detailStack(content(for: .search))
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tabViewSidebarBottomBar { AccountBadge().padding(.horizontal, 4) }
    }
    #endif

    private func detailStack(_ page: some View) -> some View {
        @Bindable var app = app
        return NavigationStack(path: $app.path) {
            page
                #if os(iOS)
                // Pages draw their own headers and back button, as on the Mac; the bar only
                // shows on Search, where it hosts the search field.
                .toolbar(showsToolbar ? .visible : .hidden, for: .navigationBar)
                #endif
                .navigationDestination(for: MetaRoute.self) { route in
                    DetailView(route: route)
                        #if os(iOS)
                        .toolbar(.hidden, for: .navigationBar)
                        // No bar backgrounds behind the floating tab strip: the artwork runs up
                        // under it.
                        .toolbarBackgroundVisibility(.hidden, for: .navigationBar, .tabBar)
                        #endif
                }
        }
        .overlay(alignment: .topLeading) {
            if !app.path.isEmpty { BackButton() }
        }
    }

    /// Optional, as iOS lists require; deselection is ignored so a tab always stays selected.
    private var sidebarSelection: Binding<SidebarItem?> {
        Binding(get: { app.selection }, set: { if let item = $0 { app.selection = item } })
    }

    private var showsToolbar: Bool { app.selection == .search && app.path.isEmpty }

    private var content: some View { content(for: app.selection) }

    @ViewBuilder private func content(for item: SidebarItem) -> some View {
        switch item {
        case .home: HomeView()
        case .discover: DiscoverView()
        case .library: LibraryView()
        case .search: SearchView(query: app.searchText)
        case .playLink: PlayLinkView()
        case .addons: AddonsView()
        }
    }
}

/// Compact account status at the bottom of the sidebar.
private struct AccountBadge: View {
    @Environment(AppModel.self) private var app

    private var status: String {
        if app.stremio.isSyncing { return "Syncing…" }
        switch (app.stremio.isSignedIn, app.trakt.isConnected) {
        case (true, true): return "Stremio · Trakt"
        case (true, false): return "Stremio"
        case (false, true): return "Local library · Trakt"
        case (false, false): return "Local library"
        }
    }

    var body: some View {
        settingsButton {
            HStack(spacing: 8) {
                Image(systemName: app.stremio.isSignedIn ? "person.crop.circle.fill" : "person.crop.circle")
                    .font(.title3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.stremio.session?.user.email ?? "Not signed in")
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    Text(status)
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

    /// The Settings window on the Mac, a sheet on iPhone/iPad.
    @ViewBuilder
    private func settingsButton<Label: View>(@ViewBuilder label: () -> Label) -> some View {
        #if os(macOS)
        SettingsLink(label: label)
        #else
        Button(action: { app.showsSettings = true }, label: label)
        #endif
    }
}
