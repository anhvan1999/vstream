import AddonKit
import StremioAPI
import SwiftUI
import VStreamCore

struct DiscoverView: View {
    @Environment(AppModel.self) private var app
    @State private var type = "movie"
    @State private var rowID: String?
    @State private var genre: String?

    private var rows: [CatalogRow] { ContentService.discoverRows(app.addons.enabled) }
    private var types: [String] { Array(Set(rows.map(\.catalog.type))).sorted { order($0) < order($1) } }
    private var rowsForType: [CatalogRow] { rows.filter { $0.catalog.type == type } }
    private var selectedRow: CatalogRow? { rowsForType.first { $0.id == rowID } ?? rowsForType.first }

    var body: some View {
        Group {
            if let row = selectedRow {
                CatalogGridView(row: row, genre: genre, header: AnyView(header))
                    .id("\(row.id)|\(genre ?? "")")
            } else {
                VStack {
                    header
                    EmptyStateView(title: "Nothing to discover", symbol: "safari", message: "Your addons don't provide browsable catalogs.")
                }
            }
        }
        .navigationTitle("Discover")
        .onChange(of: type) {
            rowID = nil
            genre = nil
        }
        .onAppear {
            if !types.contains(type), let first = types.first { type = first }
            if selectedRow?.catalog.extra(named: "genre")?.isRequired == true { genre = selectedRow?.catalog.genres.first }
        }
    }

    private var header: some View {
        ScreenHeader(title: "Discover") {
            Picker("Type", selection: $type) {
                ForEach(types, id: \.self) { Text($0.capitalized).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()

            Picker("Catalog", selection: Binding(get: { selectedRow?.id }, set: { rowID = $0; genre = nil })) {
                ForEach(rowsForType) { row in
                    Text("\(row.catalog.name) — \(row.addon.manifest.name)").tag(Optional(row.id))
                }
            }
            .fixedSize()

            if let genres = selectedRow?.catalog.genres, !genres.isEmpty {
                Picker("Genre", selection: $genre) {
                    if selectedRow?.catalog.extra(named: "genre")?.isRequired != true {
                        Text("All genres").tag(String?.none)
                    }
                    ForEach(genres, id: \.self) { Text($0).tag(Optional($0)) }
                }
                .fixedSize()
            }
        }
    }

    private func order(_ type: String) -> Int {
        ["movie", "series", "anime", "channel", "tv"].firstIndex(of: type) ?? 99
    }
}

struct SearchView: View {
    @Environment(AppModel.self) private var app
    #if os(macOS)
    private static let emptyPrompt = "Type a title in the search field above."
    #else
    private static let emptyPrompt = "Search every addon for movies, shows and channels."
    #endif
    var query: String
    @State private var results: [SearchResultGroup] = []
    @State private var isSearching = false

    var body: some View {
        content
            .modifier(ToolbarSearch())
            .navigationTitle("Search")
        .task(id: query) {
            let trimmed = query.trimmingCharacters(in: .whitespaces)
            guard trimmed.count >= 2 else { results = []; return }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            isSearching = true
            results = await app.content.search(trimmed, addons: app.addons.enabled)
            isSearching = false
        }
    }

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                ForEach(results) { group in
                    Shelf(title: group.row.title) {
                        Text(group.row.addon.manifest.name).font(.caption).foregroundStyle(.secondary)
                    } content: {
                        ForEach(group.metas) { meta in
                            Button { app.open(meta) } label: {
                                PosterCard(title: meta.name, poster: meta.poster, shape: meta.posterShape, width: 150, subtitle: meta.releaseInfo)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.vertical, 20)
        }
        // The toolbar stays clear until content scrolls beneath it, then picks up its glass.
        .scrollEdgeEffectStyle(.soft, for: .top)
        .overlay {
            if isSearching && results.isEmpty {
                ProgressView("Searching…")
            } else if !isSearching && results.isEmpty {
                EmptyStateView(
                    title: query.isEmpty ? "Search" : "No results",
                    symbol: "magnifyingglass",
                    message: query.isEmpty ? Self.emptyPrompt : "No addon found anything for “\(query)”."
                )
            }
        }
    }
}

/// The search field lives in the (otherwise invisible) toolbar.
private struct ToolbarSearch: ViewModifier {
    @Environment(AppModel.self) private var app
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        @Bindable var app = app
        content
        #if os(macOS)
            .toolbarBackgroundVisibility(.automatic, for: .windowToolbar)
        #endif
            #if os(macOS)
            .searchable(text: $app.searchText, placement: .toolbarPrincipal, prompt: "Movies, shows, channels")
            #else
            // The Search tab's own field (bottom bar on iPhone, top of the page on iPad).
            .searchable(text: $app.searchText, prompt: "Movies, shows, channels")
            #endif
            .searchFocused($focused)
            .onAppear { focused = true }
    }
}

struct LibraryView: View {
    @Environment(AppModel.self) private var app
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    @State private var filter = "all"
    @State private var sort = Sort.recent

    enum Sort: String, CaseIterable { case recent = "Recently Added", name = "Name", watched = "Last Watched" }

    private var items: [StremioAPI.LibraryItem] {
        var items = app.library.library.filter { filter == "all" || $0.type == filter }
        switch sort {
        case .recent: items.sort { ($0.ctime ?? $0.mtime) > ($1.ctime ?? $1.mtime) }
        case .name: items.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .watched: items.sort { ($0.state.lastWatched ?? .distantPast) > ($1.state.lastWatched ?? .distantPast) }
        }
        return items
    }

    var body: some View {
        ScrollView {
            ScreenHeader(title: "Library", subtitle: "\(items.count) items") {
                #if os(iOS)
                if horizontalSizeClass == .compact {
                    // iPhone: no sidebar account badge, so Settings (and Addons) open here; first, so it
                    // isn't scrolled off the end of the row.
                    Button("Settings", systemImage: "gearshape") { app.showsSettings = true }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.glass)
                }
                #endif
                Picker("Type", selection: $filter) {
                    Text("All").tag("all")
                    Text("Movies").tag("movie")
                    Text("Series").tag("series")
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Picker("Sort", selection: $sort) {
                    ForEach(Sort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .fixedSize()
            }
            PosterGrid(items: items) { item in
                Button {
                    app.path.append(MetaRoute(type: item.type, id: item.id, preview: nil))
                } label: {
                    PosterCard(title: item.name, poster: item.poster ?? Self.fallbackPoster(item.id), shape: item.posterShape, width: 150,
                               progress: item.state.timeOffset > 0 ? item.progress : nil)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Remove from Library", systemImage: "trash") {
                        app.library.toggleLibrary(MetaPreview(id: item.id, type: item.type, name: item.name, poster: item.poster))
                    }
                }
            }
        }
        .overlay {
            if items.isEmpty {
                EmptyStateView(title: "Your library is empty", symbol: "books.vertical", message: "Add movies and shows from their detail page.")
            }
        }
        .navigationTitle("Library")
    }

    /// Cinemeta's image CDN works for any IMDb id, which covers items imported without artwork.
    static func fallbackPoster(_ id: String) -> URL? {
        id.hasPrefix("tt") ? URL(string: "https://images.metahub.space/poster/medium/\(id)/img") : nil
    }
}
