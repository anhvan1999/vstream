import AddonKit
import SwiftUI
import VStreamCore

struct HomeView: View {
    @Environment(AppModel.self) private var app
    @State private var hero: MetaPreview?

    private var rows: [CatalogRow] {
        ContentService.homeRows(app.addons.enabled, includeAdult: app.settings.settings.showAdultCatalogs)
            .filter { !app.settings.settings.hiddenHomeRows.contains($0.id) }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 30) {
                if let hero {
                    HeroBanner(meta: hero)
                } else {
                    ScreenHeader(title: "Home")
                }
                ContinueWatchingShelf()
                ForEach(rows) { row in
                    CatalogShelf(row: row) { metas in
                        if hero == nil, let first = metas.first(where: { $0.background != nil }) {
                            hero = first
                        }
                    }
                }
                if rows.isEmpty {
                    EmptyStateView(title: "No catalogs", symbol: "puzzlepiece.extension", message: "Install an addon with catalogs, such as Cinemeta.")
                        .padding(.top, 80)
                }
            }
            .padding(.bottom, 40)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .ignoresSafeArea(edges: hero == nil ? [] : .top)
        .navigationTitle("Home")
    }
}

struct HeroBanner: View {
    @Environment(AppModel.self) private var app
    var meta: MetaPreview

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RemoteImage(url: meta.background)
                .frame(height: 460)
                .frame(maxWidth: .infinity)
                .clipped()
                .backgroundExtensionEffect()
                .overlay {
                    LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black.opacity(0.35), location: 0.55), .init(color: Color(nsColor: .windowBackgroundColor), location: 1)], startPoint: .top, endPoint: .bottom)
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
                ForEach(entries) { entry in
                    Button {
                        app.path.append(MetaRoute(type: entry.item.type, id: entry.item.id, preview: nil))
                    } label: {
                        PosterCard(
                            title: entry.item.name,
                            poster: entry.item.poster,
                            width: 150,
                            subtitle: label(for: entry),
                            progress: entry.isNextUp ? nil : entry.item.progress
                        )
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Remove from Continue Watching", systemImage: "xmark") {
                            app.library.removeFromContinueWatching(entry.item.id)
                        }
                    }
                }
            }
        }
    }

    private func label(for entry: ContinueWatchingEntry) -> String? {
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

    var body: some View {
        Group {
            if !metas.isEmpty || !failed {
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
                onLoaded(page.metas)
            } catch {
                failed = true
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
