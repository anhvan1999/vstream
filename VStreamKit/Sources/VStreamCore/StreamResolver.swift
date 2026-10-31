import AddonKit
import DebridKit
import Foundation
import TorrentKit

public enum PlaybackSource: Sendable, Hashable {
    case direct
    case debrid(DebridService)
    case peerToPeer
}

public struct ResolvedPlayback: Sendable, Hashable {
    public var url: URL
    public var headers: [String: String]
    public var source: PlaybackSource
    public var filename: String?
}

public enum ResolveOutcome: Sendable {
    case play(ResolvedPlayback)
    case openExternally(URL)
}

public enum ResolvePhase: Sendable, Hashable {
    case resolvingDebrid(DebridService)
    /// Not cached: the torrent was sent to the debrid service to download for next time.
    case addedToDebrid(DebridService)
    /// The debrid service failed (expired key, outage, timeout); streaming peer-to-peer instead.
    case debridUnavailable(DebridService)
    case torrent(TorrentPhase)
}

public struct EpisodeContext: Sendable, Hashable {
    public var season: Int?
    public var episode: Int?

    public init(season: Int? = nil, episode: Int? = nil) {
        self.season = season
        self.episode = episode
    }

    public init(videoID: String) {
        // Stremio series ids look like `tt0903747:1:2`.
        let parts = videoID.split(separator: ":")
        if parts.count >= 3, let season = Int(parts[parts.count - 2]), let episode = Int(parts[parts.count - 1]) {
            self.init(season: season, episode: episode)
        } else {
            self.init()
        }
    }
}

public enum ResolveError: Error, LocalizedError, Sendable {
    case unplayable
    case debridRequired
    case queuedOnDebrid(DebridService)
    case addonDebridFailed(DebridService)

    public var errorDescription: String? {
        switch self {
        case .unplayable: "This stream has nothing playable"
        case .debridRequired: "Set up a debrid service in Settings, or allow P2P streaming"
        case let .addonDebridFailed(service): "\(service.displayName) couldn't serve this stream. Allow peer-to-peer in Settings → Debrid to fall back to the torrent."
        case let .queuedOnDebrid(service): "Not cached on \(service.displayName) yet. It was added to your account; play it again once it has downloaded."
        }
    }
}

/// Turns an addon `Stream` into something mpv can open. Order mirrors Nuvio's StreamDestination:
/// direct URL → torrent (debrid, then P2P) → YouTube / external link.
public struct StreamResolver: Sendable {
    public var debrid: (any DebridProvider)?
    public var mode: TorrentMode
    /// Send uncached torrents to the debrid service so the next play is instant.
    public var addsUncachedToDebrid: Bool
    public var torrent: TorrentStreamer

    public init(debrid: (any DebridProvider)?, mode: TorrentMode, addsUncachedToDebrid: Bool = false, torrent: TorrentStreamer = .shared) {
        self.debrid = debrid
        self.mode = mode
        self.addsUncachedToDebrid = addsUncachedToDebrid
        self.torrent = torrent
    }

    /// `torrentFile` is the `.torrent` the stream's info hash came from (Play Link); P2P then adds
    /// the file itself instead of fetching metadata from peers.
    public func resolve(
        _ stream: AddonStream,
        context: EpisodeContext,
        torrentFile: Data? = nil,
        onPhase: @escaping @Sendable (ResolvePhase) -> Void = { _ in }
    ) async throws -> ResolveOutcome {
        if let url = stream.url {
            // A debrid link made by the addon's server (Torrentio's /resolve/…) is still a torrent:
            // P2P-only mode streams it directly, and Automatic falls back to it when the link fails.
            if let link = AddonDebridLink(url) {
                return try await resolve(link, stream: stream, onPhase: onPhase)
            }
            return .play(ResolvedPlayback(url: url, headers: stream.behaviorHints.requestHeaders, source: .direct, filename: stream.behaviorHints.filename))
        }

        if let infoHash = stream.infoHash, let magnet = stream.magnetURI {
            if let debrid, mode != .peerToPeerOnly {
                onPhase(.resolvingDebrid(debrid.service))
                let request = DebridRequest(
                    infoHash: infoHash,
                    magnet: magnet,
                    filename: stream.behaviorHints.filename,
                    fileIndex: stream.fileIdx,
                    season: context.season,
                    episode: context.episode
                )
                do {
                    // Bounded so a hung service still falls back to peer-to-peer.
                    let link = try await withTimeout(30) { try await debrid.resolve(request) }
                    return .play(ResolvedPlayback(url: link.url, headers: [:], source: .debrid(debrid.service), filename: link.filename))
                } catch DebridError.notCached where mode == .automatic {
                    // Stream peer-to-peer now; the debrid service downloads it meanwhile.
                    if addsUncachedToDebrid {
                        onPhase(.addedToDebrid(debrid.service))
                        Task.detached { try? await debrid.startDownload(request) }
                    }
                } catch DebridError.notCached where addsUncachedToDebrid {
                    try await debrid.startDownload(request)
                    throw ResolveError.queuedOnDebrid(debrid.service)
                } catch where mode == .automatic && !(error is CancellationError) {
                    // Debrid is optional in automatic mode: an expired key, an outage or a
                    // timeout falls back to peer-to-peer rather than failing playback.
                    onPhase(.debridUnavailable(debrid.service))
                }
            } else if mode == .debridOnly {
                throw ResolveError.debridRequired
            }

            let playback = try await torrent.prepare(
                source: torrentFile.map(TorrentSource.file) ?? .magnet(magnet),
                fileIndex: stream.fileIdx,
                filenameHint: stream.behaviorHints.filename
            ) { phase in onPhase(.torrent(phase)) }
            return .play(ResolvedPlayback(url: playback.url, headers: [:], source: .peerToPeer, filename: playback.fileName))
        }

        if let ytId = stream.ytId, let url = URL(string: "https://www.youtube.com/watch?v=\(ytId)") {
            return .openExternally(url)
        }
        if let url = stream.externalUrl {
            return .openExternally(url)
        }
        throw ResolveError.unplayable
    }
}

extension StreamResolver {
    private func resolve(
        _ link: AddonDebridLink,
        stream: AddonStream,
        onPhase: @escaping @Sendable (ResolvePhase) -> Void
    ) async throws -> ResolveOutcome {
        let filename = stream.behaviorHints.filename ?? link.filename
        let headers = stream.behaviorHints.requestHeaders
        if mode != .peerToPeerOnly {
            onPhase(.resolvingDebrid(link.service))
            switch await link.probe(headers: headers) {
            case let .playable(finalURL):
                return .play(ResolvedPlayback(url: finalURL, headers: headers, source: .debrid(link.service), filename: filename))
            case .failed where mode == .debridOnly:
                throw ResolveError.addonDebridFailed(link.service)
            case .failed:
                onPhase(.debridUnavailable(link.service))
            }
        }
        let magnet = Magnet.uri(infoHash: link.infoHash, name: filename, trackers: [])
        let playback = try await torrent.prepare(magnet: magnet, fileIndex: link.fileIndex, filenameHint: filename) { phase in
            onPhase(.torrent(phase))
        }
        return .play(ResolvedPlayback(url: playback.url, headers: [:], source: .peerToPeer, filename: playback.fileName))
    }
}

/// A debrid link produced by an addon's server, e.g. Torrentio's
/// `/resolve/{service}/{key}/{infoHash}/{name}/{fileIdx}/{filename}`, which redirects to the debrid
/// CDN. It carries the torrent it came from, so the app can stream that peer-to-peer instead.
public struct AddonDebridLink: Sendable, Hashable {
    public var url: URL
    public var service: DebridService
    public var infoHash: String
    public var fileIndex: Int?
    public var filename: String?

    public init?(_ url: URL) {
        let parts = url.path.split(separator: "/").map(String.init)
        guard let resolve = parts.firstIndex(of: "resolve"), parts.count > resolve + 3,
              let service = Self.service(parts[resolve + 1]) else { return nil }
        let hash = parts[resolve + 3].lowercased()
        guard hash.count == 40, hash.allSatisfy(\.isHexDigit) else { return nil }
        self.url = url
        self.service = service
        infoHash = hash
        fileIndex = parts.count > resolve + 5 ? Int(parts[resolve + 5]) : nil
        filename = parts.count > resolve + 6 ? parts[resolve + 6] : nil
    }

    private static func service(_ name: String) -> DebridService? {
        switch name.lowercased() {
        case "torbox": .torbox
        case "realdebrid", "real-debrid": .realDebrid
        case "premiumize": .premiumize
        default: nil
        }
    }

    enum Probe: Sendable {
        case playable(URL)
        case failed
    }

    /// Follows the redirects for the first bytes only. A dead CDN, an HTTP error or one of the
    /// addon's placeholder videos (`/videos/failed_…`, `downloading…`) counts as failed.
    func probe(headers: [String: String], timeout: TimeInterval = 15) async -> Probe {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("bytes=0-1", forHTTPHeaderField: "Range")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let finalURL = http.url else { return .failed }
        let path = finalURL.path.lowercased()
        if path.contains("/videos/"), path.contains("failed") || path.contains("downloading") { return .failed }
        return .playable(finalURL)
    }
}

/// Parsed presentation of a Torrentio-style stream title for compact display.
public struct StreamPresentation: Sendable, Hashable {
    public var quality: String?
    public var tags: [String]
    public var size: String?
    public var seeders: String?
    public var source: String?
    /// The addon's own label, e.g. "[TB+] Torrentio · 4k DV" (from the multi-line `name`).
    public var sourceLabel: String?
    /// File or release name to headline the stream.
    public var title: String
    /// Leftover description lines such as "Dubbed / Dual Audio / 🇬🇧".
    public var extras: String?

    public init(_ stream: AddonStream) {
        let nameLines = (stream.name ?? "").split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        sourceLabel = nameLines.isEmpty ? nil : nameLines.joined(separator: " · ")
        let detailLines = (stream.details ?? "").split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let headline = stream.behaviorHints.filename ?? detailLines.first ?? nameLines.first ?? "Stream"
        title = headline
        let metaMarkers = ["👤", "💾", "⚙️"]
        extras = detailLines.dropFirst()
            .filter { line in !metaMarkers.contains { line.contains($0) } && line != headline }
            .last
        let text = [stream.name, stream.details].compactMap { $0 }.joined(separator: "\n")
        // Whole words only: "DVD"/"BLUDV" aren't Dolby Vision, "HDRip" isn't HDR, "Wolfmax4k" isn't 4K.
        quality = ["2160p", "4k", "1440p", "1080p", "720p", "480p"].first { Self.containsWord($0, in: text) }.map { $0 == "4k" ? "2160p" : $0 }
        var tags: [String] = []
        // REMUX is usually glued to its source ("BDRemux", "UHDRemux"), so it matches anywhere.
        let matches = { (tag: String) in
            tag == "REMUX" ? text.range(of: tag, options: .caseInsensitive) != nil : Self.containsWord(tag, in: text)
        }
        for tag in ["DV", "HDR10+", "HDR10", "HDR", "REMUX", "HEVC", "x265", "AV1", "Atmos", "TrueHD", "DTS-HD", "DTS", "IMAX"] where matches(tag) {
            // The most specific variant wins: HDR10+ over HDR10 over HDR, DTS-HD over DTS.
            if tag.hasPrefix("HDR"), tags.contains(where: { $0.hasPrefix("HDR") }) { continue }
            if tag == "DTS", tags.contains("DTS-HD") { continue }
            tags.append(tag)
        }
        self.tags = tags
        size = Self.capture(#"💾\s*([\d.,]+\s*[KMGT]B)"#, in: text) ?? Self.capture(#"([\d.,]+\s*[GM]B)"#, in: text)
        seeders = Self.capture(#"👤\s*(\d+)"#, in: text)
        source = Self.capture(#"⚙️\s*([^\n]+)"#, in: text)
    }

    private static func containsWord(_ word: String, in text: String) -> Bool {
        let pattern = "(?<![A-Za-z0-9])" + NSRegularExpression.escapedPattern(for: word) + "(?![A-Za-z0-9])"
        return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func capture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range]).trimmingCharacters(in: .whitespaces)
    }
}
