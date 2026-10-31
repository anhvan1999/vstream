import AddonKit
import CryptoKit
import SwiftUI
import TorrentKit
import UniformTypeIdentifiers
import VStreamCore

/// Plays anything without an addon: a video URL (http, HLS, local file), a magnet link, an info
/// hash or a `.torrent` file — pasted, typed, dropped or opened from Finder.
struct PlayLinkView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @AppStorage("playLink.recent") private var recentStorage = "[]"

    @State private var input = ""
    @State private var phase: Phase = .idle
    @State private var isDropTargeted = false
    @State private var showsAllFiles = false
    @State private var work: Task<Void, Never>?
    @State private var lastOpened: (link: String, at: Date)?
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    /// iPhone: tighter card, smaller controls, no drag-and-drop hint.
    private var isCompact: Bool {
        #if os(iOS)
        horizontalSizeClass == .compact
        #else
        false
        #endif
    }
    @FocusState private var fieldFocused: Bool

    private enum Phase {
        case idle
        case working(String)
        case choosing(Pick)
        case failed(String)
    }

    /// A multi-file torrent waiting for the user to pick what to play.
    private struct Pick {
        var link: String
        var contents: TorrentContents
        var torrentFile: Data?
    }

    var body: some View {
        @Bindable var app = app
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ScreenHeader(title: "Play Link", subtitle: "Video URLs, magnet links and .torrent files")
                VStack(spacing: 28) {
                    inputCard
                    if case let .choosing(pick) = phase {
                        fileList(pick)
                    }
                    if !recents.isEmpty, !isChoosing {
                        recentList
                    }
                }
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, isCompact ? 16 : 28)
                .padding(.top, isCompact ? 8 : 24)
                .padding(.bottom, 40)
            }
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 22)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                    .background(Color.accentColor.opacity(0.08), in: .rect(cornerRadius: 22))
                    .overlay {
                        Label("Drop to play", systemImage: "arrow.down.circle.fill")
                            .font(.title2.weight(.semibold))
                            .padding(.horizontal, 22)
                            .padding(.vertical, 14)
                            .glassEffect(.regular, in: .capsule)
                    }
                    .padding(12)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            open(url.absoluteString)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .fileImporter(isPresented: $app.isImportingTorrent, allowedContentTypes: Self.importTypes) { result in
            if case let .success(url) = result { open(url.absoluteString) }
        }
        .navigationTitle("Play Link")
        .onAppear {
            // iPhone/iPad: don't pop the keyboard just for opening the tab.
            #if os(macOS)
            fieldFocused = true
            #endif
            consumePending()
        }
        .onChange(of: app.pendingLink) { consumePending() }
        .onChange(of: app.playLinkFocusRequest) { fieldFocused = true }
        .onDisappear { work?.cancel() }
    }

    private static let importTypes: [UTType] = [UTType(filenameExtension: "torrent") ?? .data, .movie, .video]

    private var isChoosing: Bool {
        if case .choosing = phase { return true }
        return false
    }

    // MARK: Input

    private var inputCard: some View {
        VStack(spacing: isCompact ? 14 : 18) {
            if !isCompact {
                Image(systemName: "play.rectangle.on.rectangle")
                    .font(.system(size: 38, weight: .regular))
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
            }
            VStack(spacing: 4) {
                Text("Paste a link to play").font(isCompact ? .headline : .title3.weight(.semibold))
                Text("http(s) video or HLS · magnet link · info hash · .torrent file")
                    .font(isCompact ? .footnote : .callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 10) {
                Image(systemName: "link").foregroundStyle(.secondary)
                TextField(isCompact ? "https://… or magnet:…" : "https://…  or  magnet:?xt=urn:btih:…", text: $input)
                    .textFieldStyle(.plain)
                    // The glass capsule is the field; no extra rectangle when it's focused.
                    .focusEffectDisabled()
                    #if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    #endif
                    .focused($fieldFocused)
                    .onSubmit { open(input) }
                    // A paste into the empty field plays right away; typing waits for Return.
                    .onChange(of: input) { old, new in
                        if old.isEmpty, new.count > 8, LinkInput(new) != nil { open(new) }
                    }
                if case .working = phase {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Play") { open(input) }
                        .buttonStyle(.glassProminent)
                        .controlSize(isCompact ? .small : .regular)
                        .disabled(LinkInput(input) == nil)
                }
            }
            .padding(.horizontal, isCompact ? 12 : 14)
            .padding(.vertical, isCompact ? 8 : 10)
            .glassEffect(.regular, in: .capsule)

            switch phase {
            case let .working(message):
                HStack(spacing: 10) {
                    Text(message).font(.callout).foregroundStyle(.secondary)
                    Button("Cancel") {
                        work?.cancel()
                        phase = .idle
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                }
            case let .failed(message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
            default:
                EmptyView()
            }

            HStack(spacing: 12) {
                Button(isCompact ? "Open .torrent File" : "Open Torrent File…", systemImage: "doc.badge.arrow.up") { app.isImportingTorrent = true }
                    .buttonStyle(.glass)
                    .controlSize(isCompact ? .small : .regular)
                if !isCompact {
                    Text("or drop a .torrent or video file anywhere in this window")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(isCompact ? 16 : 24)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: isCompact ? 20 : 24))
    }

    // MARK: File picker

    private func fileList(_ pick: Pick) -> some View {
        let videos = pick.contents.files.filter(\.isVideo)
        let files = (showsAllFiles || videos.isEmpty ? pick.contents.files : videos)
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(pick.contents.name ?? "Torrent").font(.headline).lineLimit(2)
                    Text("\(videos.count) video files · choose one to play")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !videos.isEmpty, videos.count < pick.contents.files.count {
                    Toggle("All files", isOn: $showsAllFiles)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                Button("Close", systemImage: "xmark") { phase = .idle }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .controlSize(.small)
            }
            LazyVStack(spacing: 6) {
                ForEach(files) { file in
                    FileRow(file: file) { play(pick, file: file) }
                }
            }
        }
    }

    private struct FileRow: View {
        var file: TorrentFileEntry
        var action: () -> Void
        @State private var isHovering = false

        var body: some View {
            Button(action: action) {
                HStack(spacing: 12) {
                    Image(systemName: file.isVideo ? "film" : "doc")
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.name).font(.callout.weight(.medium)).lineLimit(2)
                        let folder = (file.path as NSString).deletingLastPathComponent
                        if !folder.isEmpty {
                            Text(folder).font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    Spacer(minLength: 8)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Image(systemName: "play.fill")
                        .font(.caption)
                        .foregroundStyle(isHovering ? .primary : .tertiary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.white.opacity(isHovering ? 0.1 : 0.05), in: .rect(cornerRadius: 12))
                .contentShape(.rect(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
        }
    }

    // MARK: Recent

    private var recents: [String] {
        (try? JSONDecoder().decode([String].self, from: Data(recentStorage.utf8))) ?? []
    }

    private func remember(_ link: String) {
        let list = Array(([link] + recents.filter { $0 != link }).prefix(12))
        if let data = try? JSONEncoder().encode(list) {
            recentStorage = String(decoding: data, as: UTF8.self)
        }
        TorrentFileStore.prune(keeping: list)
    }

    private func forget(_ link: String) {
        let list = recents.filter { $0 != link }
        if let data = try? JSONEncoder().encode(list) {
            recentStorage = String(decoding: data, as: UTF8.self)
        }
        TorrentFileStore.prune(keeping: list)
    }

    private var recentList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recent").font(.headline)
                Spacer()
                Button("Clear") {
                    recentStorage = "[]"
                    TorrentFileStore.prune(keeping: [])
                }
                    .buttonStyle(.glass)
                    .controlSize(.small)
            }
            ForEach(recents, id: \.self) { link in
                if let input = LinkInput(link) {
                    RecentRow(input: input) { open(link) }
                        .contextMenu {
                            Button("Copy Link", systemImage: "doc.on.doc") {
                                Platform.copy(link)
                            }
                            Button("Remove", systemImage: "xmark") { forget(link) }
                        }
                }
            }
        }
    }

    private struct RecentRow: View {
        var input: LinkInput
        var action: () -> Void
        @State private var isHovering = false

        var body: some View {
            Button(action: action) {
                HStack(spacing: 12) {
                    Image(systemName: input.symbol).foregroundStyle(.secondary).frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(input.title).font(.callout.weight(.medium)).lineLimit(1)
                        Text(input.detail).font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.white.opacity(isHovering ? 0.1 : 0.05), in: .rect(cornerRadius: 12))
                .contentShape(.rect(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
        }
    }

    // MARK: Opening

    private func consumePending() {
        guard let url = app.pendingLink else { return }
        app.pendingLink = nil
        open(url.absoluteString)
    }

    private var usesDebrid: Bool {
        app.settings.debridProvider != nil && app.settings.settings.torrentMode != .peerToPeerOnly
    }

    private func open(_ text: String) {
        guard let link = LinkInput(text) else {
            phase = .failed("That doesn't look like a video URL, magnet link or .torrent file")
            return
        }
        // A paste can arrive as both a field change and a submit; open each link once.
        if lastOpened?.link == link.raw, Date().timeIntervalSince(lastOpened!.at) < 2 { return }
        lastOpened = (link.raw, Date())
        work?.cancel()
        showsAllFiles = false
        input = ""
        let raw = link.raw
        switch link {
        case let .addon(url):
            app.handle(url: url)
        case let .video(url):
            remember(raw)
            phase = .idle
            playVideo(url, title: link.title)
        case let .magnet(url):
            remember(raw)
            if usesDebrid {
                // The debrid service picks the file (largest video); no peer-to-peer lookup.
                phase = .idle
                let hash = Magnet.infoHash(from: url) ?? ""
                let contents = TorrentContents(infoHash: hash, name: link.title, trackers: Magnet.trackers(from: url), files: [])
                play(Pick(link: raw, contents: contents, torrentFile: nil), file: nil)
            } else {
                phase = .working("Fetching torrent info from peers…")
                work = Task {
                    do {
                        var contents = try await TorrentStreamer.shared.inspect(magnet: url.absoluteString)
                        contents.trackers = Magnet.trackers(from: url)
                        if contents.name == nil { contents.name = link.title }
                        guard !Task.isCancelled else { return }
                        choose(Pick(link: raw, contents: contents, torrentFile: nil))
                    } catch {
                        if !Task.isCancelled { phase = .failed(error.localizedDescription) }
                    }
                }
            }
        case let .torrentFile(url):
            remember(raw)
            phase = .working(url.isFileURL ? "Reading torrent file…" : "Downloading torrent file…")
            work = Task {
                do {
                    let data = try await Self.torrentData(url, link: raw)
                    let contents = try TorrentMetainfo.parse(data)
                    guard !Task.isCancelled else { return }
                    choose(Pick(link: raw, contents: contents, torrentFile: data))
                } catch {
                    if !Task.isCancelled { phase = .failed(error.localizedDescription) }
                }
            }
        }
    }

    /// Reads the `.torrent` and keeps a copy; if the original was deleted or the link expired,
    /// falls back to the copy kept when it was first opened.
    private static func torrentData(_ url: URL, link: String) async throws -> Data {
        do {
            let data = if url.isFileURL {
                // Files from the iOS document picker / Files app are security-scoped.
                try { () throws -> Data in
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    return try Data(contentsOf: url)
                }()
            } else {
                try await URLSession.shared.data(from: url).0
            }
            _ = try TorrentMetainfo.parse(data)
            TorrentFileStore.save(data, for: link)
            return data
        } catch {
            guard let copy = TorrentFileStore.load(link) else { throw error }
            return copy
        }
    }

    /// Plays a single video file directly; asks when there are several.
    private func choose(_ pick: Pick) {
        let videos = pick.contents.files.filter(\.isVideo)
        if videos.count == 1 {
            play(pick, file: videos[0])
        } else if videos.isEmpty, pick.contents.files.count == 1 {
            play(pick, file: pick.contents.files[0])
        } else if pick.contents.files.isEmpty {
            phase = .failed(TorrentError.noFiles.localizedDescription)
        } else {
            phase = .choosing(pick)
        }
    }

    private func play(_ pick: Pick, file: TorrentFileEntry?) {
        phase = .idle
        let stream = AddonStream(
            infoHash: pick.contents.infoHash,
            fileIdx: file?.index,
            name: "Play Link",
            sources: pick.contents.trackers.map { "tracker:\($0)" },
            behaviorHints: StreamBehaviorHints(filename: file?.name, videoSize: file.map { Int64($0.size) })
        )
        let title = file?.name ?? pick.contents.name ?? "Torrent"
        start(MetaPreview(id: "link:\(pick.contents.infoHash)", type: "movie", name: title), stream: stream, torrentFile: pick.torrentFile)
    }

    private func playVideo(_ url: URL, title: String) {
        let stream = AddonStream(url: url, name: "Play Link", behaviorHints: StreamBehaviorHints(filename: url.lastPathComponent))
        start(MetaPreview(id: "link:\(url.absoluteString)", type: "movie", name: title), stream: stream, torrentFile: nil)
    }

    private func start(_ preview: MetaPreview, stream: AddonStream, torrentFile: Data?) {
        // Not tied to a catalog title, so nothing goes to Continue Watching or Trakt.
        app.play(meta: MetaDetail(preview: preview), video: nil, stream: stream, recordsProgress: false, torrentFile: torrentFile)
        #if os(macOS)
        openWindow(id: "player")  // iPhone/iPad show the player as a cover when playback starts.
        #endif
    }
}

/// Copies of opened `.torrent` files, keyed by the link they were opened from, so Recent still
/// plays them after the original is deleted or its download link expires. Pruned with Recent.
enum TorrentFileStore {
    private static var directory: URL? {
        let base = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return base?.appending(path: "VStream/TorrentFiles", directoryHint: .isDirectory)
    }

    private static func file(for link: String) -> URL? {
        let key = SHA256.hash(data: Data(link.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory?.appending(path: "\(key).torrent")
    }

    static func save(_ data: Data, for link: String) {
        guard let directory, let file = file(for: link) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    static func load(_ link: String) -> Data? {
        file(for: link).flatMap { try? Data(contentsOf: $0) }
    }

    static func prune(keeping links: [String]) {
        guard let directory,
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        let kept = Set(links.compactMap { file(for: $0)?.lastPathComponent })
        for file in files where !kept.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

/// What a pasted or dropped string points at.
enum LinkInput {
    case video(URL)
    case magnet(URL)
    case torrentFile(URL)
    case addon(URL)

    init?(_ text: String) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        // A bare info hash (40 hex or 32 base32 characters).
        if value.range(of: #"^([0-9a-fA-F]{40}|[A-Za-z2-7]{32})$"#, options: .regularExpression) != nil,
           let url = URL(string: "magnet:?xt=urn:btih:\(value.lowercased())") {
            self = .magnet(url)
            return
        }
        let url: URL? = if value.hasPrefix("/") || value.hasPrefix("~") {
            URL(filePath: (value as NSString).expandingTildeInPath)
        } else {
            URL(string: value) ?? URL(string: value.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? "")
        }
        guard let url, let scheme = url.scheme?.lowercased() else { return nil }
        let isTorrent = url.pathExtension.lowercased() == "torrent"
        switch scheme {
        case "magnet" where Magnet.infoHash(from: url) != nil: self = .magnet(url)
        case "stremio": self = .addon(url)
        case "http", "https" where url.host != nil: self = isTorrent ? .torrentFile(url) : .video(url)
        case "file": self = isTorrent ? .torrentFile(url) : .video(url)
        default: return nil
        }
    }

    var raw: String {
        switch self {
        case let .video(url), let .magnet(url), let .torrentFile(url), let .addon(url): url.absoluteString
        }
    }

    var title: String {
        switch self {
        case let .magnet(url):
            let name = URLComponents(string: "x:" + url.absoluteString.drop { $0 != "?" })?.queryItems?.first { $0.name == "dn" }?.value
            return name ?? "Magnet \(Magnet.infoHash(from: url)?.prefix(8) ?? "")"
        case let .video(url), let .torrentFile(url), let .addon(url):
            let name = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
            return name.isEmpty || name == "/" ? (url.host ?? url.absoluteString) : name
        }
    }

    var detail: String {
        switch self {
        case let .magnet(url): Magnet.infoHash(from: url) ?? url.absoluteString
        case let .video(url), let .torrentFile(url), let .addon(url): url.isFileURL ? url.path : url.host ?? url.absoluteString
        }
    }

    var symbol: String {
        switch self {
        case .magnet: "link.badge.plus"
        case .torrentFile: "doc.zipper"
        case let .video(url): url.isFileURL ? "film" : "globe"
        case .addon: "puzzlepiece.extension"
        }
    }
}
