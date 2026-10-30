import AppKit
import Foundation
import Observation

public struct MediaTrack: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable { case audio, sub, video }

    public var id: Int
    public var kind: Kind
    public var title: String?
    public var language: String?
    public var codec: String?
    public var channels: Int?
    public var isExternal: Bool
    public var isDefault: Bool

    public var displayName: String {
        var parts: [String] = []
        if let language { parts.append(Languages.name(for: language)) }
        if let title, !title.isEmpty, title != language { parts.append(title) }
        if let codec { parts.append(codec.uppercased()) }
        if let channels, channels > 0 { parts.append(channels == 6 ? "5.1" : channels == 8 ? "7.1" : "\(channels)ch") }
        if isExternal { parts.append("External") }
        return parts.isEmpty ? "Track \(id)" : parts.joined(separator: " · ")
    }
}

public struct Chapter: Hashable, Sendable {
    public var title: String
    public var time: Double
}

public struct ExternalSubtitle: Hashable, Sendable {
    public var url: URL
    public var language: String
    public var title: String

    public init(url: URL, language: String, title: String) {
        self.url = url
        self.language = language
        self.title = title
    }
}

public struct PlaybackRequest: Sendable {
    public var url: URL
    public var headers: [String: String]
    public var startTime: Double
    public var subtitles: [ExternalSubtitle]
    public var preferredAudioLanguages: [String]
    public var preferredSubtitleLanguages: [String]

    public init(
        url: URL,
        headers: [String: String] = [:],
        startTime: Double = 0,
        subtitles: [ExternalSubtitle] = [],
        preferredAudioLanguages: [String] = [],
        preferredSubtitleLanguages: [String] = []
    ) {
        self.url = url
        self.headers = headers
        self.startTime = startTime
        self.subtitles = subtitles
        self.preferredAudioLanguages = preferredAudioLanguages
        self.preferredSubtitleLanguages = preferredSubtitleLanguages
    }
}

/// SwiftUI-facing player state. Time updates are coalesced to ~4 Hz.
@MainActor
@Observable
public final class PlayerModel {
    public private(set) var isPaused = true
    public private(set) var isBuffering = false
    public private(set) var isLoading = false
    public private(set) var isEnded = false
    public private(set) var isSeeking = false
    public private(set) var position: Double = 0
    public private(set) var duration: Double = 0
    public private(set) var cachedUntil: Double = 0
    public private(set) var speed: Double = 1
    public private(set) var volume: Double = 100
    public private(set) var isMuted = false
    public private(set) var audioTracks: [MediaTrack] = []
    public private(set) var subtitleTracks: [MediaTrack] = []
    public private(set) var selectedAudioID: Int?
    public private(set) var selectedSubtitleID: Int?
    public private(set) var subtitleDelay: Double = 0
    public private(set) var chapters: [Chapter] = []
    public private(set) var hardwareDecoder: String?
    /// Display aspect ratio (width / height) of the current video.
    public private(set) var videoAspect: Double?
    public private(set) var errorMessage: String?

    public var isPlaying: Bool { !isPaused && !isEnded }
    public var progress: Double { duration > 0 ? min(position / duration, 1) : 0 }

    @ObservationIgnored private var controller: MPVController!
    @ObservationIgnored private var pending: PlaybackRequest?
    @ObservationIgnored private var current: PlaybackRequest?
    @ObservationIgnored private var surfaceReady = false
    @ObservationIgnored private var lastPublishedPosition: Double = -1
    /// The current subtitle line as plain text (text subtitles only).
    public private(set) var subtitleText = ""
    /// Plain text subtitles are drawn by the app in the macOS caption style (as the Apple TV app
    /// does) while mpv renders them invisibly. Bitmap (PGS/VobSub) and styled ASS subtitles stay
    /// with mpv.
    public private(set) var rendersSubtitlesInApp = false
    @ObservationIgnored private var lastLogLine: String?
    @ObservationIgnored private var fileLoaded = false
    /// Right after a seek mpv may still report the old time; ignore those so the UI doesn't jump back.
    @ObservationIgnored private var seekTarget: (seconds: Double, issuedAt: Date)?
    @ObservationIgnored public var onEnded: (() -> Void)?

    public init(hardwareDecoding: Bool = true, bufferMB: Int = 512) {
        controller = MPVController { [weak self] events in
            Task { @MainActor in self?.handle(events) }
        }
        controller.start(hardwareDecoding: hardwareDecoding, bufferMB: bufferMB)
        updateSubtitleRendering(force: true)
    }

    var layer: CAMetalLayer { controller.layer }

    // MARK: Loading

    public func load(_ request: PlaybackRequest) {
        errorMessage = nil
        lastLogLine = nil
        fileLoaded = false
        isLoading = true
        isEnded = false
        position = request.startTime
        duration = 0
        lastPublishedPosition = -1
        if surfaceReady {
            start(request)
        } else {
            pending = request
        }
    }

    /// Called by the video view once it has a real size; mpv's Vulkan swapchain needs one.
    func surfaceDidBecomeReady() {
        guard !surfaceReady else { return }
        surfaceReady = true
        if let pending {
            self.pending = nil
            start(pending)
        }
    }

    private func start(_ request: PlaybackRequest) {
        current = request
        controller.set("http-header-fields", list: request.headers.map { "\($0.key): \($0.value)" })
        if !request.preferredAudioLanguages.isEmpty {
            controller.set("alang", request.preferredAudioLanguages.joined(separator: ","))
        }
        if !request.preferredSubtitleLanguages.isEmpty {
            controller.set("slang", request.preferredSubtitleLanguages.joined(separator: ","))
        }
        var args = ["loadfile", request.url.isFileURL ? request.url.path : request.url.absoluteString, "replace", "-1"]
        if request.startTime > 1 {
            args.append("start=\(Int(request.startTime))")
        }
        controller.command(args)
        controller.set("pause", flag: false)
    }

    public func retry() {
        guard let current else { return }
        var request = current
        request.startTime = max(position, current.startTime)
        load(request)
    }

    public func stop() {
        controller.command(["stop"])
        controller.shutdown()
    }

    // MARK: Transport

    public func togglePause() { setPaused(!isPaused) }

    public func setPaused(_ paused: Bool) {
        if !paused, isEnded {
            seek(to: 0)
        }
        controller.set("pause", flag: paused)
    }

    public func seek(to seconds: Double) {
        position = max(0, min(seconds, duration > 0 ? duration : seconds))
        seekTarget = (position, Date())
        controller.command(["seek", String(format: "%.3f", position), "absolute+keyframes"])
    }

    public func seek(by seconds: Double) {
        position = max(0, position + seconds)
        seekTarget = (position, Date())
        controller.command(["seek", String(format: "%.3f", seconds), "relative+exact"])
    }

    public func setSpeed(_ value: Double) { controller.set("speed", double: value) }

    public func setVolume(_ value: Double) { controller.set("volume", double: min(max(value, 0), 130)) }

    public func adjustVolume(by delta: Double) { setVolume(volume + delta) }

    public func toggleMute() { controller.set("mute", flag: !isMuted) }

    // MARK: Tracks

    public func selectAudio(_ id: Int?) {
        controller.set("aid", id.map(String.init) ?? "no")
    }

    public func selectSubtitle(_ id: Int?) {
        controller.set("sid", id.map(String.init) ?? "no")
    }

    public func addSubtitle(_ subtitle: ExternalSubtitle, select: Bool) {
        controller.command(["sub-add", subtitle.url.absoluteString, select ? "select" : "auto", subtitle.title, subtitle.language])
    }

    /// Adds subtitles that arrive after loading started (e.g. from addons).
    public func addExternalSubtitles(_ subtitles: [ExternalSubtitle]) {
        guard !subtitles.isEmpty else { return }
        if pending != nil {
            pending?.subtitles += subtitles
            return
        }
        current?.subtitles += subtitles
        guard fileLoaded else { return }
        for subtitle in subtitles { addSubtitle(subtitle, select: false) }
        selectPreferredSubtitle()
    }

    public func setSubtitleDelay(_ seconds: Double) { controller.set("sub-delay", double: seconds) }

    /// Relative, so repeated key presses add up before the observed value catches up.
    public func adjustSubtitleDelay(by seconds: Double) { controller.command(["add", "sub-delay", String(seconds)]) }

    private static let mpvOnlySubtitleCodecs: Set<String> = [
        "ass", "ssa", "hdmv_pgs_subtitle", "pgssub", "dvd_subtitle", "dvdsub", "dvb_subtitle", "dvbsub", "xsub",
    ]

    private func updateSubtitleRendering(force: Bool = false) {
        let codec = subtitleTracks.first { $0.id == selectedSubtitleID }?.codec?.lowercased()
        let inApp = selectedSubtitleID != nil && !(codec.map(Self.mpvOnlySubtitleCodecs.contains) ?? false)
        guard force || inApp != rendersSubtitlesInApp else { return }
        rendersSubtitlesInApp = inApp
        if inApp {
            // Still rendered by mpv (so `sub-text` and timing keep working), just fully transparent.
            controller.set("sub-color", "#00000000")
            controller.set("sub-border-size", double: 0)
            controller.set("sub-shadow-offset", double: 0)
            controller.set("sub-back-color", "#00000000")
            controller.set("sub-border-style", "outline-and-shadow")
        } else {
            // mpv's defaults, for the bitmap/ASS subtitles it draws itself.
            controller.set("sub-color", "#FFFFFFFF")
            controller.set("sub-border-size", double: 3)
            controller.set("sub-shadow-offset", double: 0)
            controller.set("sub-back-color", "#00000000")
        }
    }

    public func screenshot() { controller.command(["screenshot", "subtitles"]) }

    // MARK: Events

    private func handle(_ events: [MPVEvent]) {
        for event in events {
            switch event {
            case let .property(name, value):
                switch (name, value) {
                case let ("pause", .flag(flag)): isPaused = flag
                case let ("paused-for-cache", .flag(flag)): isBuffering = flag
                case let ("eof-reached", .flag(flag)):
                    if flag, !isEnded {
                        isEnded = true
                        onEnded?()
                    } else if !flag {
                        isEnded = false
                    }
                case let ("seeking", .flag(flag)): isSeeking = flag
                case let ("time-pos", .double(seconds)):
                    if let target = seekTarget {
                        if abs(seconds - target.seconds) > 2, Date().timeIntervalSince(target.issuedAt) < 1.5 { break }
                        seekTarget = nil
                    }
                    if abs(seconds - lastPublishedPosition) >= 0.25 || isSeeking {
                        lastPublishedPosition = seconds
                        position = seconds
                    }
                case let ("duration", .double(seconds)):
                    duration = seconds
                    if seconds > 0 { isLoading = false }
                case let ("demuxer-cache-time", .double(seconds)): cachedUntil = seconds
                case let ("speed", .double(value)): speed = value
                case let ("volume", .double(value)): volume = value
                case let ("mute", .flag(flag)): isMuted = flag
                case let ("aid", .int(id)): selectedAudioID = Int(id)
                case ("aid", .none), ("aid", .string): selectedAudioID = nil
                case let ("sid", .int(id)):
                    selectedSubtitleID = Int(id)
                    updateSubtitleRendering()
                case ("sid", .none), ("sid", .string):
                    selectedSubtitleID = nil
                    updateSubtitleRendering()
                case let ("sub-text", .string(text)): subtitleText = text
                case ("sub-text", .none): subtitleText = ""
                case let ("sub-delay", .double(value)): subtitleDelay = value
                case let ("hwdec-current", .string(value)): hardwareDecoder = value == "no" ? nil : value
                case let ("video-params/aspect", .double(value)) where value > 0.2 && value < 5:
                    if abs((videoAspect ?? 0) - value) > 0.01 { videoAspect = value }
                default: break
                }
            case .fileLoaded:
                fileLoaded = true
                isLoading = false
                errorMessage = nil
                for subtitle in current?.subtitles ?? [] {
                    addSubtitle(subtitle, select: false)
                }
                selectPreferredSubtitle()
            case .playbackRestart:
                isLoading = false
            case let .endFile(error):
                if let error {
                    isLoading = false
                    errorMessage = [error, lastLogLine].compactMap { $0 }.joined(separator: ": ")
                }
            case let .log(message):
                if !message.isEmpty { lastLogLine = message }
            case let .tracks(tracks):
                audioTracks = tracks.filter { $0.kind == .audio }
                subtitleTracks = tracks.filter { $0.kind == .sub }
                updateSubtitleRendering()
            case let .chapters(list):
                chapters = list
            }
        }
    }

    /// Addon subtitles arrive as unselected tracks; pick the first one in the preferred language
    /// unless mpv already selected an embedded match via `slang`.
    private func selectPreferredSubtitle() {
        guard selectedSubtitleID == nil, let current, !current.preferredSubtitleLanguages.isEmpty,
              let subtitle = current.subtitles.first(where: { Languages.matches($0.language, any: current.preferredSubtitleLanguages) })
        else { return }
        addSubtitle(subtitle, select: true)
    }

}
