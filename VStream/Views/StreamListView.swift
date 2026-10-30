import AddonKit
import DebridKit
import SwiftUI
import VStreamCore

/// A stream with its parsed title, computed once when results arrive (addons can return 1000+).
private struct DisplayStream: Identifiable {
    let id: Int
    let stream: AddonStream
    let presentation: StreamPresentation
}

private struct DisplayGroup: Identifiable {
    let id: String
    let addon: AddonDescriptor
    let streams: [DisplayStream]
    let error: String?
}

struct StreamListView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    var meta: MetaDetail
    var video: Video?
    var videoID: String

    @State private var groups: [DisplayGroup] = []
    @State private var isLoading = true
    @State private var quality: String?
    @State private var cached: Set<String> = []

    private static let qualities = ["2160p", "1080p", "720p", "480p"]

    private var filtered: [DisplayGroup] {
        guard let quality else { return groups }
        return groups.map { group in
            DisplayGroup(id: group.id, addon: group.addon, streams: group.streams.filter { $0.presentation.quality == quality }, error: group.error)
        }
        .filter { !$0.streams.isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text(video.map { "\($0.episodeLabel ?? "") \($0.title)" } ?? meta.name)
                    .font(.headline)
                    .lineLimit(1)
                GlassEffectContainer(spacing: 6) {
                    HStack(spacing: 6) {
                        chip("All", selected: quality == nil) { quality = nil }
                        ForEach(Self.qualities, id: \.self) { value in
                            chip(value == "2160p" ? "4K" : value, selected: quality == value) { quality = value }
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)

            List {
                ForEach(filtered) { group in
                    Section {
                        if let error = group.error, group.streams.isEmpty {
                            Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(group.streams) { item in
                            StreamRow(stream: item.stream, presentation: item.presentation,
                                      isCached: item.stream.infoHash.map(cached.contains) ?? false) {
                                play(item.stream)
                            }
                        }
                    } header: {
                        HStack {
                            Text(group.addon.manifest.name)
                            Spacer()
                            Text("\(group.streams.count)").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .overlay {
                if isLoading && groups.allSatisfy(\.streams.isEmpty) {
                    ProgressView("Finding streams…")
                } else if !isLoading && filtered.allSatisfy(\.streams.isEmpty) {
                    EmptyStateView(title: "No streams", symbol: "antenna.radiowaves.left.and.right.slash",
                                   message: "Install a stream addon (for example Torrentio) to watch this.")
                }
            }
        }
        .task(id: videoID) { await load() }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.caption.weight(.semibold)).padding(.horizontal, 4)
        }
        .buttonStyle(.glass)
        .tint(selected ? .accentColor : nil)
        .controlSize(.small)
    }

    private func load() async {
        groups = []
        isLoading = true
        let order = app.addons.enabled.map(\.id)
        for await group in app.content.streams(type: meta.type, id: videoID, addons: app.addons.enabled) {
            // Loopback addons (e.g. Stremio's "Local Files") need the Stremio desktop server; a
            // connection error from them is expected noise, not something to show.
            if group.streams.isEmpty, group.error != nil, Self.isLoopback(group.addon.transportUrl) { continue }
            let streams = await Task.detached(priority: .userInitiated) {
                group.streams.enumerated().map { DisplayStream(id: $0.offset, stream: $0.element, presentation: StreamPresentation($0.element)) }
            }.value
            groups.append(DisplayGroup(id: group.id, addon: group.addon, streams: streams, error: group.error))
            groups.sort { (order.firstIndex(of: $0.id) ?? .max) < (order.firstIndex(of: $1.id) ?? .max) }
        }
        isLoading = false
        await checkDebridCache()
    }

    private static func isLoopback(_ url: URL) -> Bool {
        ["127.0.0.1", "localhost", "::1"].contains(url.host ?? "")
    }

    private func checkDebridCache() async {
        guard let provider = app.settings.debridProvider else { return }
        let hashes = Array(Set(groups.flatMap(\.streams).compactMap(\.stream.infoHash))).prefix(100)
        guard !hashes.isEmpty else { return }
        if let result = try? await provider.cachedHashes(Array(hashes)) {
            cached = result
        }
    }

    private func play(_ stream: AddonStream) {
        app.play(meta: meta, video: video, stream: stream)
        openWindow(id: "player")
    }
}

private struct StreamRow: View {
    var stream: AddonStream
    var presentation: StreamPresentation
    var isCached: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                VStack(spacing: 4) {
                    Text(presentation.quality.map { $0 == "2160p" ? "4K" : $0 } ?? "SD")
                        .font(.caption.weight(.bold))
                        .frame(width: 48, height: 22)
                        .glassEffect(.regular.tint(qualityTint(presentation.quality)), in: .capsule)
                    Image(systemName: stream.isTorrent ? (isCached ? "bolt.fill" : "arrow.down.circle") : "link")
                        .font(.caption)
                        .foregroundStyle(isCached ? .yellow : .secondary)
                        .help(stream.isTorrent ? (isCached ? "Cached on debrid" : "Torrent") : "Direct link")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(stream.behaviorHints.filename ?? stream.details?.components(separatedBy: "\n").first ?? stream.name ?? "Stream")
                        .font(.callout.weight(.medium))
                        .lineLimit(2)
                    if !presentation.tags.isEmpty {
                        Text(presentation.tags.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 10) {
                        if let size = presentation.size { Label(size, systemImage: "internaldrive") }
                        if let seeders = presentation.seeders { Label(seeders, systemImage: "person.2") }
                        if let source = presentation.source { Text(source) }
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .labelStyle(.titleAndIcon)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func qualityTint(_ quality: String?) -> Color {
        switch quality {
        case "2160p": .purple.opacity(0.6)
        case "1080p": .blue.opacity(0.5)
        case "720p": .teal.opacity(0.4)
        default: .gray.opacity(0.3)
        }
    }
}
