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
        .inspector(isPresented: Binding(get: { streamTarget != nil }, set: { if !$0 { streamTarget = nil } })) {
            if let meta, let target = streamTarget {
                StreamListView(meta: meta, video: target.video, videoID: target.id)
                    .inspectorColumnWidth(min: 360, ideal: 420, max: 560)
                    .id(target)
            }
        }
        .task(id: route) { await load() }
    }

    private func load() async {
        do {
            let detail = try await app.content.meta(type: route.type, id: route.id, addons: app.addons.enabled)
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
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header(meta)
                if meta.isSeriesLike {
                    episodes(meta)
                        .padding(.horizontal, 36)
                        .padding(.top, 24)
                }
            }
            .padding(.bottom, 40)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .ignoresSafeArea(edges: .top)
    }

    private func header(_ meta: MetaDetail) -> some View {
        ZStack(alignment: .bottomLeading) {
            RemoteImage(url: meta.preview.background ?? meta.preview.poster)
                .frame(height: 520)
                .frame(maxWidth: .infinity)
                .clipped()
                .backgroundExtensionEffect()
                .overlay {
                    LinearGradient(colors: [.clear, .black.opacity(0.4), .black.opacity(0.92)], startPoint: .top, endPoint: .bottom)
                }

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
                        .lineLimit(4)
                        .frame(maxWidth: 640, alignment: .leading)
                        .foregroundStyle(.white.opacity(0.88))
                }
                if !meta.cast.isEmpty {
                    Text("Starring \(meta.cast.prefix(4).joined(separator: ", "))")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.7))
                }
                actions(meta)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 36)
            .padding(.bottom, 28)
        }
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
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Episodes").font(.title2.weight(.semibold))
                Spacer()
                Picker("Season", selection: $season) {
                    ForEach(meta.seasons, id: \.self) { number in
                        Text(number == 0 ? "Specials" : "Season \(number)").tag(Optional(number))
                    }
                }
                .fixedSize()
            }
            LazyVStack(spacing: 10) {
                ForEach(meta.videos(inSeason: season ?? 1)) { video in
                    EpisodeRow(meta: meta, video: video, isSelected: streamTarget?.id == video.id) {
                        streamTarget = StreamTarget(video: video, id: video.id)
                    }
                }
            }
        }
    }
}

private struct EpisodeRow: View {
    @Environment(AppModel.self) private var app
    var meta: MetaDetail
    var video: Video
    var isSelected: Bool
    var action: () -> Void
    @State private var isHovering = false

    var body: some View {
        let watched = app.library.isWatched(itemID: meta.id, videoID: video.id)
        let resume = app.library.resumePosition(itemID: meta.id, videoID: video.id)
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack(alignment: .bottom) {
                    RemoteImage(url: video.thumbnail ?? meta.preview.background)
                        .frame(width: 176, height: 99)
                    if let resume, let duration = app.library.items[meta.id]?.state.duration, duration > 0 {
                        ProgressView(value: min(resume * 1000 / Double(duration), 1)).padding(.horizontal, 6).padding(.bottom, 4)
                    }
                }
                .clipShape(.rect(cornerRadius: 10))
                .overlay(alignment: .topTrailing) {
                    if watched {
                        Image(systemName: "checkmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .green)
                            .padding(6)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(video.episode.map { "\($0). " } ?? "")\(video.title.isEmpty ? "Episode" : video.title)")
                        .font(.headline)
                        .lineLimit(1)
                    if let released = video.released {
                        Text(released, format: .dateTime.day().month().year())
                            .font(.caption)
                            .foregroundStyle(video.isReleased ? Color.secondary : Color.orange)
                    }
                    if let overview = video.overview {
                        Text(overview).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background {
            if isSelected || isHovering {
                RoundedRectangle(cornerRadius: 14).fill(.fill.tertiary)
            }
        }
        .onHover { isHovering = $0 }
        .contextMenu {
            Button(watched ? "Mark as Unwatched" : "Mark as Watched", systemImage: watched ? "eye.slash" : "eye") {
                app.library.setWatched(meta: meta.preview, videoID: video.id, !watched, nextVideoID: NextEpisode.after(video.id, in: meta)?.id)
            }
        }
    }
}
