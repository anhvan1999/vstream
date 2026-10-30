import AddonKit
import AppKit
import Foundation
import Observation
import OSLog
import PlayerKit
import TorrentKit
import VStreamCore

enum PlaybackStage: Equatable {
    case resolving(String)
    case playing
    case failed(String)
}

/// One playback: resolve → play → record progress → offer the next episode.
@MainActor
@Observable
final class PlaybackSession: Identifiable {
    let id = UUID()
    let meta: MetaDetail
    private(set) var video: Video?
    private(set) var stream: AddonStream
    private(set) var stage: PlaybackStage = .resolving("Preparing")
    private(set) var source: PlaybackSource?
    private(set) var resolvedURL: URL?
    private(set) var torrentStats: TorrentStats?
    private(set) var addonSubtitles: [Subtitle] = []
    private(set) var nextVideo: Video?
    private(set) var showNextUp = false

    let player: PlayerModel
    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private let sleep = SleepAssertion()
    @ObservationIgnored private let nowPlaying = NowPlayingController()
    @ObservationIgnored private var lastRecordedAt = Date.distantPast
    @ObservationIgnored private var wasPlaying = false
    @ObservationIgnored private var nextUpDismissed = false

    @ObservationIgnored private let recordsProgress: Bool

    init(app: AppModel, meta: MetaDetail, video: Video?, stream: AddonStream, recordsProgress: Bool = true) {
        self.app = app
        self.recordsProgress = recordsProgress
        self.meta = meta
        self.video = video
        self.stream = stream
        player = PlayerModel(hardwareDecoding: app.settings.settings.hardwareDecoding, bufferMB: app.settings.settings.streamBufferMB)
        player.apply(app.settings.settings.subtitleStyle)
        player.onEnded = { [weak self] in self?.handleEnded() }
        app.library.registerVideos(of: meta)
        start()
    }

    var title: String { meta.name }

    var subtitle: String? {
        guard let video, let label = video.episodeLabel else { return nil }
        return video.title.isEmpty ? label : "\(label) · \(video.title)"
    }

    var videoID: String { video?.id ?? meta.id }

    // MARK: Lifecycle

    private static let log = Logger(subsystem: "com.vstream.app", category: "playback")

    private func start() {
        guard let app else { return }
        // Diagnostics only: no URLs or keys.
        Self.log.notice("""
        play \(self.meta.id, privacy: .public) video=\(self.videoID, privacy: .public) \
        stream name=\((self.stream.name ?? "-").replacingOccurrences(of: "\n", with: " "), privacy: .public) \
        hasURL=\(self.stream.url != nil, privacy: .public) host=\(self.stream.url?.host ?? "-", privacy: .public) \
        infoHash=\(self.stream.infoHash != nil, privacy: .public) fileIdx=\(self.stream.fileIdx ?? -1, privacy: .public)
        """)
        let resolver = app.resolver
        let stream = self.stream
        let context = EpisodeContext(videoID: videoID)
        let addons = app.addons.enabled
        let content = app.content
        let type = meta.type
        let videoID = self.videoID
        let resume = app.library.resumePosition(itemID: meta.id, videoID: videoID) ?? 0
        let preferences = app.settings.settings
        nextVideo = NextEpisode.after(videoID, in: meta)

        tasks.append(Task {
            do {
                let outcome = try await resolver.resolve(stream, context: context) { phase in
                    Task { @MainActor [weak self] in self?.stage = .resolving(Self.describe(phase)) }
                }
                switch outcome {
                case let .openExternally(url):
                    NSWorkspace.shared.open(url)
                    self.stage = .failed("Opened in your browser")
                case let .play(resolved):
                    Self.log.notice("resolved source=\(String(describing: resolved.source), privacy: .public) host=\(resolved.url.host ?? "-", privacy: .public)")
                    self.source = resolved.source
                    self.resolvedURL = resolved.url
                    self.player.load(PlaybackRequest(
                        url: resolved.url,
                        headers: resolved.headers,
                        startTime: resume,
                        preferredAudioLanguages: preferences.preferredAudioLanguages,
                        preferredSubtitleLanguages: preferences.preferredSubtitleLanguages
                    ))
                    self.stage = .playing
                    self.nowPlaying.attach(self.player, title: self.title, subtitle: self.subtitle)
                    self.startMonitoring(isTorrent: resolved.source == .peerToPeer)
                }
            } catch is CancellationError {
            } catch {
                self.stage = .failed(error.localizedDescription)
                #if DEBUG
                FileHandle.standardError.write(Data("[debug] failed: \(error)\n".utf8))
                #endif
            }
        })

        // Subtitles load in parallel and are attached whenever they arrive.
        tasks.append(Task {
            let subtitles = await content.subtitles(type: type, id: videoID, stream: stream, addons: addons)
            guard !Task.isCancelled else { return }
            self.addonSubtitles = subtitles
            self.player.addExternalSubtitles(subtitles.map {
                ExternalSubtitle(url: $0.url, language: $0.lang, title: Self.languageName($0.lang))
            })
        })
    }

    private func startMonitoring(isTorrent: Bool) {
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                self.tick()
                if isTorrent {
                    self.torrentStats = await TorrentStreamer.shared.stats()
                }
            }
        })
    }

    private func tick() {
        guard let app else { return }
        #if DEBUG
        if ProcessInfo.processInfo.environment["VSTREAM_DEBUG_PLAY"] != nil {
            FileHandle.standardError.write(Data("[debug] stage=\(stage) loading=\(player.isLoading) buffering=\(player.isBuffering) pos=\(Int(player.position)) dur=\(Int(player.duration)) hw=\(player.hardwareDecoder ?? "none") audio=\(player.audioTracks.count) subs=\(player.subtitleTracks.count) err=\(player.errorMessage ?? "-") peers=\(torrentStats?.peers ?? 0)\n".utf8))
        }
        #endif
        let playing = player.isPlaying
        sleep.hold(playing)
        nowPlaying.update()

        if playing != wasPlaying, player.duration > 0 {
            if recordsProgress {
                app.trakt.scrobble(playing ? .start : .pause, type: meta.type, videoID: videoID, progress: player.progress)
            }
            if !playing { record(force: true) }
            wasPlaying = playing
        }
        if playing, Date().timeIntervalSince(lastRecordedAt) >= 10 {
            record(force: false)
        }
        if nextVideo != nil, !nextUpDismissed, player.duration > 0 {
            showNextUp = player.duration - player.position < 40
        }
    }

    private func record(force: Bool) {
        guard recordsProgress, let app, player.duration > 0, force || player.isPlaying else { return }
        lastRecordedAt = Date()
        app.library.recordProgress(
            meta: meta.preview,
            videoID: videoID,
            position: player.position,
            duration: player.duration,
            nextVideoID: nextVideo?.id
        )
        app.stremio.scheduleLibraryPush()
    }

    private func handleEnded() {
        record(force: true)
        guard let app, nextVideo != nil, app.settings.settings.autoplayNextEpisode else { return }
        playNext()
    }

    /// Plays the next episode, preferring a stream from the same `bingeGroup`.
    func playNext() {
        guard let app, let next = nextVideo else { return }
        let bingeGroup = stream.behaviorHints.bingeGroup
        let addons = app.addons.enabled
        let content = app.content
        let type = meta.type
        let meta = self.meta
        stage = .resolving("Finding next episode")
        tasks.append(Task {
            var fallback: AddonStream?
            for await group in content.streams(type: type, id: next.id, addons: addons) {
                if let bingeGroup, let match = group.streams.first(where: { $0.behaviorHints.bingeGroup == bingeGroup }) {
                    app.play(meta: meta, video: next, stream: match)
                    return
                }
                if fallback == nil { fallback = group.streams.first }
            }
            if let fallback {
                app.play(meta: meta, video: next, stream: fallback)
            } else {
                self.stage = .failed("No streams found for the next episode")
            }
        })
    }

    /// Link for "Copy Stream Link": the URL being played, except for P2P where the loopback URL
    /// is useless elsewhere and the magnet is shared instead.
    var shareableLink: String? {
        if source == .peerToPeer { return stream.magnetURI }
        return resolvedURL?.absoluteString ?? StreamLinks.shareable(stream)
    }

    func dismissNextUp() {
        nextUpDismissed = true
        showNextUp = false
    }

    func close() {
        record(force: true)
        if recordsProgress, let app, player.duration > 0 {
            app.trakt.scrobble(.stop, type: meta.type, videoID: videoID, progress: player.progress)
        }
        tasks.forEach { $0.cancel() }
        tasks = []
        sleep.hold(false)
        nowPlaying.detach()
        player.stop()
        if source == .peerToPeer {
            Task { await TorrentStreamer.shared.stop() }
        }
    }

    // MARK: Helpers

    static func describe(_ phase: ResolvePhase) -> String {
        switch phase {
        case let .resolvingDebrid(service): "Resolving with \(service.displayName)"
        case .torrent(.startingEngine): "Starting torrent engine"
        case .torrent(.fetchingMetadata): "Fetching torrent metadata"
        case let .torrent(.preparingFile(name)): "Preparing \(name)"
        case .torrent(.buffering): "Buffering"
        }
    }

    static func languageName(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code) ?? code
    }
}
