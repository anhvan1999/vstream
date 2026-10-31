import AddonKit
import Nuke
import SwiftUI
import VStreamCore

struct HomeView: View {
    @Environment(AppModel.self) private var app
    private var featured: [MetaPreview] { app.homeFeatured }
    @State private var overscroll: CGFloat = 0

    private var rows: [CatalogRow] {
        ContentService.homeRows(app.addons.enabled, includeAdult: app.settings.settings.showAdultCatalogs)
            .filter { !app.settings.settings.hiddenHomeRows.contains($0.id) }
    }

    var body: some View {
        ScrollView {
            // The hero sits outside the lazy stack: swapping it in for the header inside a
            // LazyVStack wasn't laid out until the next scroll.
            VStack(alignment: .leading, spacing: 30) {
                if !featured.isEmpty {
                    HeroCarousel(items: featured, overscroll: overscroll)
                } else {
                    ScreenHeader(title: "Home")
                }
                LazyVStack(alignment: .leading, spacing: 30) {
                    ContinueWatchingShelf()
                    if app.trakt.isConnected {
                        ForEach(TraktAccount.List.allCases, id: \.self) { list in
                            TraktShelf(list: list)
                        }
                    }
                    ForEach(rows) { row in
                        CatalogShelf(row: row) { metas in
                            if featured.isEmpty {
                                app.homeFeatured = Array(metas.filter { $0.background != nil }.prefix(8))
                            }
                        }
                    }
                    if rows.isEmpty {
                        EmptyStateView(title: "No catalogs", symbol: "puzzlepiece.extension", message: "Install an addon with catalogs, such as Cinemeta.")
                            .padding(.top, 80)
                    }
                }
            }
            .padding(.bottom, 40)
        }
        #if os(iOS)
        .scrollEdgeEffectStyle(.soft, for: .top)
        #endif
        // No title-bar backdrop on the Mac's Home: the hero owns the top of the window.
        // Clamped at 0, so normal scrolling doesn't update state.
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            max(0, -(geometry.contentOffset.y + geometry.contentInsets.top))
        } action: { _, pull in
            overscroll = pull
        }
        #if os(iOS)
        // With the hero, the artwork runs up under the floating tab bar (no pale edge band).
        .scrollEdgeEffectHidden(!featured.isEmpty, for: .top)
        #endif
        .ignoresSafeArea(edges: featured.isEmpty ? [] : .top)
        .navigationTitle("Home")
    }
}

/// Featured titles that rotate every 8 seconds (paused while hovered), with glass arrows and
/// page dots.
struct HeroCarousel: View {
    var items: [MetaPreview]
    var overscroll: CGFloat = 0
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    @State private var index = 0
    @State private var isHovering = false
    private let prefetcher = ImagePrefetcher()

    var body: some View {
        ZStack {
            HeroBanner(meta: items[index], overscroll: overscroll)
                .id(items[index].id)
                .transition(.opacity)
        }
        .animation(.easeInOut(duration: 0.6), value: index)
        .overlay {
            if isHovering && items.count > 1 {
                HStack {
                    arrow("chevron.left") { step(-1) }
                    Spacer()
                    arrow("chevron.right") { step(1) }
                }
                .padding(.horizontal, 20)
                .transition(.opacity)
            }
        }
        .overlay(alignment: isCompact ? .bottom : .bottomTrailing) {
            if items.count > 1 {
                HStack(spacing: 7) {
                    ForEach(items.indices, id: \.self) { position in
                        Capsule()
                            .fill(.white.opacity(position == index ? 0.95 : 0.4))
                            .frame(width: position == index ? 20 : 7, height: 7)
                            .contentShape(.rect)
                            .onTapGesture { index = position }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .glassEffect(.regular, in: .capsule)
                // iPhone: centred under the buttons, which span the narrow screen.
                .padding(.trailing, isCompact ? 0 : 36)
                .padding(.bottom, isCompact ? 6 : 40)
                .animation(.spring(duration: 0.35), value: index)
            }
        }
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.2), value: isHovering)
        .task(id: items.map(\.id)) {
            prefetcher.startPrefetching(with: items.compactMap(\.background) + items.compactMap(\.logo))
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(8))
                if !isHovering, !Task.isCancelled { step(1) }
            }
        }
        .environment(\.colorScheme, .dark)
    }

    private var isCompact: Bool {
        #if os(iOS)
        horizontalSizeClass == .compact
        #else
        false
        #endif
    }

    private func step(_ delta: Int) {
        index = (index + delta + items.count) % items.count
    }

    private func arrow(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.title2.weight(.semibold)).frame(width: 44, height: 44)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
    }
}

struct HeroBanner: View {
    @Environment(AppModel.self) private var app
    var meta: MetaPreview
    /// How far the page is pulled down past its top (0 at rest).
    var overscroll: CGFloat = 0

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // A window-wide box sized by the window height; the artwork fills it and is cropped.
            // Sizing the filled image directly let it grow wider than the window in narrow
            // windows, pushing the right side (dots, arrow) off screen.
            Color.clear
                .frame(maxWidth: .infinity)
                .containerRelativeFrame(.vertical) { length, _ in max(length * 0.58, 420) }
                .overlay { RemoteImage(url: meta.background) }
                .clipped()
                .backgroundExtensionEffect()
                .overlay {
                    LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black.opacity(0.35), location: 0.55), .init(color: Color.windowBackground, location: 1)], startPoint: .top, endPoint: .bottom)
                }
                // Pulling past the top stretches the artwork upward (anchored at its bottom) instead
                // of uncovering an empty band above it while the scroll view bounces back.
                .visualEffect { [overscroll] content, proxy in
                    let height = max(proxy.size.height, 1)
                    return content.scaleEffect((height + overscroll) / height, anchor: .bottom)
                }

            VStack(alignment: .leading, spacing: 12) {
                if let logo = meta.logo {
                    RemoteImage(url: logo, contentMode: .fit)
                        .frame(maxWidth: 380, maxHeight: 120, alignment: .leading)
                } else {
                    Text(meta.name).font(.largeTitle.bold())
                }
                HStack(spacing: 10) {
                    if let year = meta.releaseInfo { Text(year) }
                    if let rating = meta.imdbRating { Label(rating, systemImage: "star.fill") }
                    if !meta.genres.isEmpty { Text(meta.genres.prefix(3).joined(separator: " · ")) }
                }
                .font(.callout)
                .foregroundStyle(.white.opacity(0.85))
                if let description = meta.description {
                    Text(description)
                        .font(.body)
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(3)
                        .frame(maxWidth: 560, alignment: .leading)
                }
                GlassEffectContainer(spacing: 12) {
                    HStack(spacing: 12) {
                        Button {
                            app.open(meta)
                        } label: {
                            Label("Watch", systemImage: "play.fill").padding(.horizontal, 6)
                        }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)

                        Button {
                            app.library.toggleLibrary(meta)
                        } label: {
                            Label(app.library.isInLibrary(meta.id) ? "In Library" : "Add to Library",
                                  systemImage: app.library.isInLibrary(meta.id) ? "checkmark" : "plus")
                        }
                        .buttonStyle(.glass)
                        .controlSize(.large)
                    }
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 36)
            .padding(.bottom, 36)
        }
        .environment(\.colorScheme, .dark)
    }
}

struct ContinueWatchingShelf: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let entries = app.library.continueWatching
        if !entries.isEmpty {
            Shelf(title: "Continue Watching") {
                NavigationLink("See All") { ContinueWatchingGridView() }
                    .buttonStyle(.glass)
                    .controlSize(.small)
            } content: {
                ForEach(entries) { ContinueWatchingCard(entry: $0) }
            }
        }
    }
}

/// Every title in progress, most recently watched first.
struct ContinueWatchingGridView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let entries = app.library.continueWatching
        ScrollView {
            ScreenHeader(title: "Continue Watching", subtitle: "\(entries.count) titles")
            PosterGrid(items: entries) { ContinueWatchingCard(entry: $0) }
        }
        .pageScrollEdge(titleBar: false)
        .overlay {
            if entries.isEmpty {
                EmptyStateView(title: "Nothing in progress", symbol: "play.circle", message: "Titles you start watching show up here.")
            }
        }
        .navigationTitle("Continue Watching")
    }
}

/// A Continue Watching poster: plays the stream from last time (or the next episode from the
/// same release); titles without one open their page to pick a stream.
struct ContinueWatchingCard: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    var entry: ContinueWatchingEntry
    @State private var isResuming = false

    var body: some View {
        Button(action: resume) {
            PosterCard(
                title: entry.item.name,
                poster: entry.item.poster,
                width: 150,
                subtitle: label,
                progress: entry.isNextUp ? nil : entry.item.progress
            )
            .overlay {
                if isResuming {
                    ProgressView()
                        .controlSize(.large)
                        .frame(width: 150, height: 225)
                        .background(.black.opacity(0.35), in: .rect(cornerRadius: 12))
                        .frame(maxHeight: .infinity, alignment: .top)
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Details", systemImage: "info.circle", action: openDetails)
            Button("Remove from Continue Watching", systemImage: "xmark") {
                app.library.removeFromContinueWatching(entry.item.id)
            }
        }
    }

    private func resume() {
        guard !isResuming else { return }
        isResuming = true
        Task {
            defer { isResuming = false }
            if await app.resume(entry) {
                #if os(macOS)
                openWindow(id: "player")
                #endif
            } else {
                openDetails()
            }
        }
    }

    private func openDetails() {
        app.path.append(MetaRoute(type: entry.item.type, id: entry.item.id, preview: nil))
    }

    private var label: String? {
        let episode = entry.videoID.map(EpisodeContext.init(videoID:))
        if let season = episode?.season, let number = episode?.episode {
            return entry.isNextUp ? "Next: S\(season)E\(number)" : "S\(season)E\(number)"
        }
        let remaining = Double(entry.item.state.duration - min(entry.item.state.timeOffset, entry.item.state.duration)) / 60_000
        return remaining > 1 ? "\(Int(remaining)) min left" : nil
    }
}

struct CatalogShelf: View {
    @Environment(AppModel.self) private var app
    var row: CatalogRow
    var onLoaded: ([MetaPreview]) -> Void = { _ in }

    @State private var metas: [MetaPreview] = []
    @State private var failed = false
    @State private var loaded = false

    var body: some View {
        Group {
            // Hide rows that failed or came back empty (e.g. an expired list addon).
            if !metas.isEmpty || !(failed || loaded) {
                Shelf(title: row.title) {
                    NavigationLink("See All") { CatalogGridView(row: row) }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                } content: {
                    if metas.isEmpty {
                        ForEach(0..<8, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 12).fill(.quaternary)
                                .frame(width: 150, height: 225)
                        }
                    } else {
                        ForEach(metas.prefix(24)) { meta in
                            Button { app.open(meta) } label: {
                                PosterCard(title: meta.name, poster: meta.poster, shape: meta.posterShape,
                                           width: meta.posterShape == .landscape ? 260 : 150, subtitle: meta.releaseInfo)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .task(id: row.id) {
            do {
                let page = try await app.content.page(row)
                metas = page.metas
                loaded = true
                onLoaded(page.metas)
            } catch {
                failed = true
            }
        }
    }
}

/// A row fed by the user's own Trakt connection (independent of Stremio's Trakt addon).
/// Data lives in `TraktAccount.lists`; empty lists show nothing.
struct TraktShelf: View {
    @Environment(AppModel.self) private var app
    var list: TraktAccount.List

    var body: some View {
        if let metas = app.trakt.lists[list], !metas.isEmpty {
            Shelf(title: list.title) {
                NavigationLink("See All") { TraktListGridView(list: list) }
                    .buttonStyle(.glass)
                    .controlSize(.small)
            } content: {
                ForEach(metas) { meta in
                    Button { app.open(meta) } label: {
                        PosterCard(title: meta.name, poster: meta.poster, width: 150, subtitle: meta.releaseInfo)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// A whole Trakt list: up to 100 recommendations, or the complete watchlist.
struct TraktListGridView: View {
    @Environment(AppModel.self) private var app
    var list: TraktAccount.List
    @State private var metas: [MetaPreview]?
    @State private var error: String?

    var body: some View {
        ScrollView {
            ScreenHeader(title: list.title, subtitle: metas.map { "\($0.count) titles" })
            PosterGrid(items: metas ?? app.trakt.lists[list] ?? []) { meta in
                Button { app.open(meta) } label: {
                    PosterCard(title: meta.name, poster: meta.poster, width: 150, subtitle: meta.releaseInfo)
                }
                .buttonStyle(.plain)
            }
            if metas == nil, error == nil { ProgressView().padding() }
        }
        .pageScrollEdge(titleBar: false)
        .overlay {
            if let error, (metas ?? []).isEmpty {
                EmptyStateView(title: "Couldn't load", symbol: "exclamationmark.triangle", message: error)
            }
        }
        .navigationTitle(list.title)
        .task(id: list) {
            do {
                metas = try await app.trakt.items(list, limit: 100)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// "See all" with infinite paging: `skip += rawCount`, stop after 3 pages without new items.
struct CatalogGridView: View {
    @Environment(AppModel.self) private var app
    var row: CatalogRow
    var genre: String?
    /// Replaces the default title header (Discover passes its pickers here).
    var header: AnyView?

    @State private var metas: [MetaPreview] = []
    @State private var seen = Set<String>()
    @State private var skip = 0
    @State private var emptyPages = 0
    @State private var isLoading = false
    @State private var reachedEnd = false

    var body: some View {
        ScrollView {
            header ?? AnyView(ScreenHeader(title: row.catalog.name, subtitle: row.addon.manifest.name))
            PosterGrid(items: metas, minWidth: 150, onReachEnd: loadMore) { meta in
                Button { app.open(meta) } label: {
                    PosterCard(title: meta.name, poster: meta.poster, shape: meta.posterShape, width: 150, subtitle: meta.releaseInfo)
                }
                .buttonStyle(.plain)
            }
            if isLoading { ProgressView().padding() }
        }
        // Discover passes its pickers as the header (toolbar controls); See All only has a back button.
        .pageScrollEdge(titleBar: header != nil)
        .navigationTitle(row.catalog.name)
        .task(id: "\(row.id)|\(genre ?? "")") {
            metas = []
            seen = []
            skip = 0
            emptyPages = 0
            reachedEnd = false
            loadMore()
        }
    }

    private func loadMore() {
        guard !isLoading, !reachedEnd else { return }
        isLoading = true
        Task {
            defer { isLoading = false }
            guard let page = try? await app.content.page(row, skip: skip, genre: genre) else {
                reachedEnd = true
                return
            }
            let fresh = page.metas.filter { seen.insert("\($0.type):\($0.id)").inserted }
            metas += fresh
            skip += page.rawCount
            emptyPages = fresh.isEmpty ? emptyPages + 1 : 0
            let pageable = row.catalog.supportsPaging || page.rawCount >= 100
            reachedEnd = page.rawCount == 0 || !pageable || emptyPages >= 3
        }
    }
}
