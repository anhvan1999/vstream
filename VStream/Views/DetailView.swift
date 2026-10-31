import AddonKit
import SwiftUI
import VStreamCore

struct DetailView: View {
    @Environment(AppModel.self) private var app
    var route: MetaRoute

    @State private var meta: MetaDetail?
    @State private var error: String?
    @State private var season: Int?
    @State private var streamTarget: StreamTarget?

    struct StreamTarget: Hashable {
        var video: Video?
        var id: String
    }

    var body: some View {
        Group {
            if let meta {
                content(meta)
            } else if let error {
                EmptyStateView(title: "Couldn't load", symbol: "exclamationmark.triangle", message: error)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(meta?.name ?? route.preview?.name ?? "")
        #if os(macOS)
        .inspector(isPresented: showsStreams) {
            if let meta, let target = streamTarget {
                StreamListView(meta: meta, video: target.video, videoID: target.id) { streamTarget = nil }
                    .inspectorColumnWidth(min: 360, ideal: 420, max: 560)
                    .id(target)
            }
        }
        #else
        // A sheet on iPhone/iPad: an inspector there wraps the page in a container that keeps the
        // bar area, leaving a band above the artwork.
        .sheet(isPresented: showsStreams) {
            if let meta, let target = streamTarget {
                StreamListView(meta: meta, video: target.video, videoID: target.id) { streamTarget = nil }
                    .presentationDetents([.medium, .large])
                    .presentationBackground(.regularMaterial)
                    .id(target)
            }
        }
        #endif
        .task(id: route) { await load() }
    }

    private var showsStreams: Binding<Bool> {
        Binding(get: { streamTarget != nil }, set: { if !$0 { streamTarget = nil } })
    }

    private func load() async {
        do {
            let detail = try await app.content.meta(type: route.type, id: route.id, addons: app.addons.enabled)
            app.library.registerVideos(of: detail)
            meta = detail
            let resume = app.library.items[detail.id]?.state.videoId
            let resumeSeason = resume.flatMap { id in detail.videos.first { $0.id == id }?.season }
            season = resumeSeason ?? detail.seasons.first
        } catch {
            if let preview = route.preview {
                meta = MetaDetail(preview: preview)
            } else {
                self.error = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private func content(_ meta: MetaDetail) -> some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Movies fill exactly one screen; series leave the episode list peeking in.
                    header(meta)
                        .frame(minHeight: proxy.size.height * (meta.isSeriesLike ? 0.78 : 1), alignment: .bottomLeading)
                    if meta.isSeriesLike {
                        episodes(meta)
                            .padding(.horizontal, 36)
                            .padding(.top, 8)
                            .padding(.bottom, 40)
                    }
                }
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
            #if os(iOS)
            // The artwork runs up under the floating tab bar; the soft edge would paint a pale
            // band there instead.
            .scrollEdgeEffectHidden(true, for: .top)
            #endif
        }
        .ignoresSafeArea(edges: .top)
        // Outermost, so the artwork also fills the bar area on iPad, where the scroll view is laid
        // out below the tab strip.
        .background { backdrop(meta) }
    }

    /// Full-page artwork pinned behind the scrolling content.
    private func backdrop(_ meta: MetaDetail) -> some View {
        Color.clear
            .overlay { RemoteImage(url: meta.preview.background ?? meta.preview.poster) }
            .clipped()
            .overlay {
                // Left-side shade keeps the title and description readable on bright artwork.
                LinearGradient(colors: [.black.opacity(0.75), .black.opacity(0.35), .clear], startPoint: .leading, endPoint: UnitPoint(x: 0.75, y: 0.5))
            }
            .overlay {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black.opacity(0.25), location: 0.45),
                        .init(color: Color.windowBackground.opacity(meta.isSeriesLike ? 0.92 : 0.8), location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            // Every edge: the artwork itself runs under the sidebar (not just a mirrored blur of it).
            .ignoresSafeArea()
    }

    private func header(_ meta: MetaDetail) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let logo = meta.preview.logo {
                RemoteImage(url: logo, contentMode: .fit)
                    .frame(maxWidth: 420, maxHeight: 130, alignment: .leading)
            } else {
                Text(meta.name).font(.system(size: 40, weight: .bold))
            }
            HStack(spacing: 12) {
                if let release = meta.preview.releaseInfo { Text(release) }
                if let runtime = meta.preview.runtime { Text(runtime) }
                if let rating = meta.preview.imdbRating { Label(rating, systemImage: "star.fill").foregroundStyle(.yellow) }
                if !meta.preview.genres.isEmpty { Text(meta.preview.genres.prefix(3).joined(separator: " · ")) }
            }
            .font(.callout.weight(.medium))
            if let description = meta.preview.description {
                Text(description)
                    .lineLimit(5)
                    .frame(maxWidth: 640, alignment: .leading)
                    .foregroundStyle(.white.opacity(0.88))
            }
            if !meta.cast.isEmpty {
                Text("Starring \(meta.cast.prefix(4).joined(separator: ", "))")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.7))
            }
            if !meta.director.isEmpty {
                Text("Directed by \(meta.director.prefix(2).joined(separator: ", "))")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.7))
            }
            actions(meta)
                .padding(.top, 6)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 36)
        .padding(.bottom, 36)
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.colorScheme, .dark)
    }

    private func actions(_ meta: MetaDetail) -> some View {
        let target = playTarget(meta)
        let inLibrary = app.library.isInLibrary(meta.id)
        return GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                Button {
                    streamTarget = target.map { StreamTarget(video: $0.video, id: $0.id) }
                } label: {
                    Label(target?.label ?? "Play", systemImage: "play.fill").padding(.horizontal, 8)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.extraLarge)
                .disabled(target == nil)
                .keyboardShortcut(.defaultAction)

                Button {
                    app.library.toggleLibrary(meta.preview)
                } label: {
                    Label(inLibrary ? "In Library" : "Library", systemImage: inLibrary ? "checkmark" : "plus")
                }
                .buttonStyle(.glass)
                .controlSize(.extraLarge)

                if let trailer = meta.trailers.first, let url = URL(string: "https://www.youtube.com/watch?v=\(trailer.source)") {
                    Link(destination: url) { Label("Trailer", systemImage: "film") }
                        .buttonStyle(.glass)
                        .controlSize(.extraLarge)
                }
                if meta.type == "movie" {
                    let watched = app.library.isWatched(itemID: meta.id, videoID: meta.id)
                    Button {
                        app.library.setWatched(meta: meta.preview, videoID: meta.id, !watched)
                    } label: {
                        Label(watched ? "Watched" : "Mark Watched", systemImage: watched ? "eye.fill" : "eye")
                    }
                    .buttonStyle(.glass)
                    .controlSize(.extraLarge)
                }
            }
        }
    }

    private struct PlayTarget {
        var video: Video?
        var id: String
        var label: String
    }

    private func playTarget(_ meta: MetaDetail) -> PlayTarget? {
        if !meta.isSeriesLike {
            let resume = app.library.resumePosition(itemID: meta.id, videoID: meta.id)
            return PlayTarget(video: nil, id: meta.id, label: resume == nil ? "Play" : "Resume")
        }
        let watched = app.library.watched[meta.id] ?? []
        if let current = app.library.items[meta.id]?.state.videoId, let video = meta.videos.first(where: { $0.id == current }) {
            let resuming = app.library.resumePosition(itemID: meta.id, videoID: current) != nil
            return PlayTarget(video: video, id: video.id, label: "\(resuming ? "Resume" : "Play") \(video.episodeLabel ?? "")")
        }
        guard let video = NextEpisode.firstUnwatched(in: meta, watched: watched) ?? meta.videos.first else { return nil }
        return PlayTarget(video: video, id: video.id, label: "Play \(video.episodeLabel ?? "")")
    }

    private func episodes(_ meta: MetaDetail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Episodes").font(.title2.weight(.semibold))
                Spacer()
                Picker("Season", selection: $season) {
                    ForEach(meta.seasons, id: \.self) { number in
                        Text(number == 0 ? "Specials" : "Season \(number)").tag(Optional(number))
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)

            LazyVStack(spacing: 2) {
                ForEach(meta.videos(inSeason: season ?? 1)) { video in
                    EpisodeRow(meta: meta, video: video, isSelected: streamTarget?.id == video.id) {
                        streamTarget = StreamTarget(video: video, id: video.id)
                    }
                }
            }
        }
        .padding(14)
        // One calm surface for the whole list so rows don't sit directly on busy artwork.
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.08)))
        .environment(\.colorScheme, .dark)
    }
}

private struct EpisodeRow: View {
    @Environment(AppModel.self) private var app
    var meta: MetaDetail
    var video: Video
    var isSelected: Bool
    var action: () -> Void
    @State private var isHovering = false

    private static let thumbnailSize = CGSize(width: 192, height: 108)

    var body: some View {
        let watched = app.library.isWatched(itemID: meta.id, videoID: video.id)
        let resume = app.library.resumePosition(itemID: meta.id, videoID: video.id)
        let duration = Double(app.library.items[meta.id]?.state.duration ?? 0) / 1000
        let progress = resume.flatMap { duration > 0 ? min($0 / duration, 1) : nil }

        Button(action: action) {
            HStack(alignment: .top, spacing: 16) {
                thumbnail(watched: watched, progress: progress)

                VStack(alignment: .leading, spacing: 5) {
                    caption(resume: resume, duration: duration)
                    Text(video.title.isEmpty ? "Episode \(video.episode ?? 0)" : video.title)
                        .font(.headline)
                        .lineLimit(1)
                    if let overview = video.overview {
                        Text(overview)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .frame(maxWidth: 680, alignment: .leading)
                    }
                }
                .padding(.top, 4)
                Spacer(minLength: 0)
            }
            .opacity(watched && progress == nil ? 0.6 : 1)
            .padding(10)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(.white.opacity(isSelected ? 0.12 : isHovering ? 0.07 : 0))
        }
        .onHover { isHovering = $0 }
        .contextMenu {
            Button(watched ? "Mark as Unwatched" : "Mark as Watched", systemImage: watched ? "eye.slash" : "eye") {
                app.library.setWatched(meta: meta.preview, videoID: video.id, !watched, nextVideoID: NextEpisode.after(video.id, in: meta)?.id)
            }
        }
    }

    /// Fixed-size artwork; progress and the watched mark are overlays so they can't change layout.
    private func thumbnail(watched: Bool, progress: Double?) -> some View {
        RemoteImage(url: video.thumbnail ?? meta.preview.background)
            .frame(width: Self.thumbnailSize.width, height: Self.thumbnailSize.height)
            .clipShape(.rect(cornerRadius: 10))
            .overlay(alignment: .bottom) {
                if let progress {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.black.opacity(0.45))
                            Capsule().fill(.white).frame(width: geometry.size.width * progress)
                        }
                    }
                    .frame(height: 4)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 7)
                }
            }
            .overlay(alignment: .topTrailing) {
                if watched && progress == nil {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .green)
                        .shadow(radius: 2)
                        .padding(6)
                }
            }
            .overlay {
                if isHovering {
                    Image(systemName: "play.fill")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .glassEffect(.regular, in: .circle)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.1)))
    }

    private func caption(resume: Double?, duration: Double) -> some View {
        HStack(spacing: 6) {
            if let episode = video.episode {
                Text("Episode \(episode)")
            }
            if let resume, duration > 0 {
                Text("·")
                Text("Continue · \(max(Int((duration - resume) / 60), 1)) min left")
                    .foregroundStyle(.tint)
            } else if let released = video.released {
                Text("·")
                Text(released, format: .dateTime.day().month(.abbreviated).year())
                    .foregroundStyle(video.isReleased ? Color.secondary : Color.orange)
            }
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
    }
}
