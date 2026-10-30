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
    var onClose: () -> Void = {}

    @State private var groups: [DisplayGroup] = []
    @State private var isLoading = true
    @State private var quality: String?
    @State private var addonFilter: String?
    @State private var cached: Set<String> = []

    private static let qualities: [(value: String, label: String)] = [("2160p", "4K"), ("1080p", "1080p"), ("720p", "720p"), ("480p", "480p")]

    private var visibleGroups: [DisplayGroup] {
        groups
            .filter { addonFilter == nil || $0.id == addonFilter }
            .map { group in
                guard let quality else { return group }
                return DisplayGroup(id: group.id, addon: group.addon, streams: group.streams.filter { $0.presentation.quality == quality }, error: group.error)
            }
            .filter { !$0.streams.isEmpty || ($0.error != nil && addonFilter == $0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            addonChips
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8, pinnedViews: []) {
                    ForEach(visibleGroups) { group in
                        if addonFilter == nil {
                            Text(group.addon.manifest.name.uppercased())
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 4)
                                .padding(.top, 10)
                        }
                        if let error = group.error, group.streams.isEmpty {
                            Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(group.streams) { item in
                            StreamCard(
                                stream: item.stream,
                                presentation: item.presentation,
                                addonName: group.addon.manifest.name,
                                isCached: item.stream.infoHash.map(cached.contains) ?? false
                            ) { play(item.stream) }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 16)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .overlay {
                if isLoading && groups.allSatisfy(\.streams.isEmpty) {
                    ProgressView("Finding streams…")
                } else if !isLoading && visibleGroups.allSatisfy(\.streams.isEmpty) {
                    EmptyStateView(title: "No streams", symbol: "antenna.radiowaves.left.and.right.slash",
                                   message: quality != nil ? "Nothing in this quality. Try another filter." : "Install a stream addon (for example Torrentio) to watch this.")
                }
            }
        }
        .task(id: videoID) { await load() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                if let label = video?.episodeLabel {
                    Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                Text(video.map { $0.title.isEmpty ? meta.name : $0.title } ?? meta.name)
                    .font(.headline)
                    .lineLimit(1)
            }
            Spacer()
            Menu {
                Picker("Quality", selection: $quality) {
                    Text("Any quality").tag(String?.none)
                    ForEach(Self.qualities, id: \.value) { Text($0.label).tag(Optional($0.value)) }
                }
                .pickerStyle(.inline)
            } label: {
                Label(Self.qualities.first { $0.value == quality }?.label ?? "Any quality", systemImage: "line.3.horizontal.decrease")
                    .font(.caption.weight(.medium))
            }
            .menuStyle(.button)
            .buttonStyle(.glass)
            .controlSize(.small)
            .fixedSize()

            Button(action: onClose) {
                Image(systemName: "xmark").font(.caption.weight(.bold)).frame(width: 18, height: 18)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.small)
            .keyboardShortcut(.cancelAction)
            .help("Close")
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    /// One chip per addon that returned (or is returning) streams, like Stremio and Nuvio.
    private var addonChips: some View {
        ScrollView(.horizontal) {
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    chip("All", count: groups.reduce(0) { $0 + $1.streams.count }, selected: addonFilter == nil) { addonFilter = nil }
                    ForEach(groups.filter { !$0.streams.isEmpty }) { group in
                        chip(group.addon.manifest.name, count: group.streams.count, selected: addonFilter == group.id) {
                            addonFilter = addonFilter == group.id ? nil : group.id
                        }
                    }
                    if isLoading {
                        ProgressView().controlSize(.small).padding(.horizontal, 6)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
            }
        }
        .scrollIndicators(.never)
        .padding(.bottom, 6)
    }

    private func chip(_ title: String, count: Int, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title).lineLimit(1)
                Text("\(count)").foregroundStyle(selected ? .white.opacity(0.8) : .secondary)
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 4)
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

private struct StreamCard: View {
    var stream: AddonStream
    var presentation: StreamPresentation
    var addonName: String
    var isCached: Bool
    var action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Text(presentation.sourceLabel ?? addonName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if stream.isTorrent {
                        Image(systemName: isCached ? "bolt.fill" : "arrow.down.circle")
                            .font(.caption)
                            .foregroundStyle(isCached ? .yellow : .secondary)
                            .help(isCached ? "Cached on your debrid service" : "Torrent (peer-to-peer)")
                    }
                }

                Text(presentation.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                if presentation.quality != nil || !presentation.tags.isEmpty {
                    HStack(spacing: 4) {
                        if let quality = presentation.quality {
                            badge(quality == "2160p" ? "4K" : quality, prominent: true)
                        }
                        ForEach(presentation.tags.prefix(4), id: \.self) { badge($0, prominent: false) }
                    }
                }

                let meta = [presentation.size, presentation.seeders.map { "\($0) seeds" }, presentation.source].compactMap { $0 }
                if !meta.isEmpty || presentation.extras != nil {
                    VStack(alignment: .leading, spacing: 2) {
                        if !meta.isEmpty { Text(meta.joined(separator: "  ·  ")) }
                        if let extras = presentation.extras { Text(extras).lineLimit(1) }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(isHovering ? 0.1 : 0.05), in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(isHovering ? 0.15 : 0.06)))
            .contentShape(.rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottomTrailing) {
            if isHovering {
                Menu {
                    StreamLinkMenuItems(stream: stream, play: action)
                } label: {
                    Image(systemName: "ellipsis").font(.caption.weight(.bold)).frame(width: 22, height: 22)
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.small)
                .fixedSize()
                .padding(8)
                .help("More")
            }
        }
        .contextMenu { StreamLinkMenuItems(stream: stream, play: action) }
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }

    private func badge(_ text: String, prominent: Bool) -> some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(prominent ? .white : .secondary)
            .background(prominent ? AnyShapeStyle(Color.accentColor.opacity(0.75)) : AnyShapeStyle(.white.opacity(0.08)), in: .capsule)
    }
}
