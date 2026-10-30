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

    public var errorDescription: String? {
        switch self {
        case .unplayable: "This stream has nothing playable"
        case .debridRequired: "Set up a debrid service in Settings, or allow P2P streaming"
        }
    }
}

/// Turns an addon `Stream` into something mpv can open. Order mirrors Nuvio's StreamDestination:
/// direct URL → torrent (debrid, then P2P) → YouTube / external link.
public struct StreamResolver: Sendable {
    public var debrid: (any DebridProvider)?
    public var mode: TorrentMode
    public var torrent: TorrentStreamer

    public init(debrid: (any DebridProvider)?, mode: TorrentMode, torrent: TorrentStreamer = .shared) {
        self.debrid = debrid
        self.mode = mode
        self.torrent = torrent
    }

    public func resolve(
        _ stream: AddonStream,
        context: EpisodeContext,
        onPhase: @escaping @Sendable (ResolvePhase) -> Void = { _ in }
    ) async throws -> ResolveOutcome {
        if let url = stream.url {
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
                    let link = try await debrid.resolve(request)
                    return .play(ResolvedPlayback(url: link.url, headers: [:], source: .debrid(debrid.service), filename: link.filename))
                } catch DebridError.notCached where mode == .automatic {
                    // Fall through to peer-to-peer.
                }
            } else if mode == .debridOnly {
                throw ResolveError.debridRequired
            }

            let playback = try await torrent.prepare(
                magnet: magnet,
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

/// Parsed presentation of a Torrentio-style stream title for compact display.
public struct StreamPresentation: Sendable, Hashable {
    public var quality: String?
    public var tags: [String]
    public var size: String?
    public var seeders: String?
    public var source: String?

    public init(_ stream: AddonStream) {
        let text = [stream.name, stream.details].compactMap { $0 }.joined(separator: "\n")
        let lower = text.lowercased()
        quality = ["2160p", "4k", "1440p", "1080p", "720p", "480p"].first { lower.contains($0) }.map { $0 == "4k" ? "2160p" : $0 }
        var tags: [String] = []
        for tag in ["DV", "HDR10+", "HDR10", "HDR", "REMUX", "HEVC", "x265", "AV1", "Atmos", "TrueHD", "DTS-HD", "DTS", "IMAX"] where text.range(of: tag, options: .caseInsensitive) != nil {
            if tag == "HDR", tags.contains(where: { $0.hasPrefix("HDR") }) { continue }
            if tag == "DTS", tags.contains("DTS-HD") { continue }
            tags.append(tag)
        }
        self.tags = tags
        size = Self.capture(#"💾\s*([\d.,]+\s*[KMGT]B)"#, in: text) ?? Self.capture(#"([\d.,]+\s*[GM]B)"#, in: text)
        seeders = Self.capture(#"👤\s*(\d+)"#, in: text)
        source = Self.capture(#"⚙️\s*([^\n]+)"#, in: text)
    }

    private static func capture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range]).trimmingCharacters(in: .whitespaces)
    }
}
