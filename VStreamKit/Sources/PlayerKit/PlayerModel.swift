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
        if let language { parts.append(Locale.current.localizedString(forLanguageCode: language) ?? language) }
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

public struct SubtitleStyle: Codable, Hashable, Sendable {
    public var fontSize: Double
    public var textColor: String
    public var backgroundOpacity: Double
    public var borderSize: Double
    /// 0 (top) ... 100 (bottom); mpv default is 100.
    public var position: Double
    public var bold: Bool

    public init(fontSize: Double = 46, textColor: String = "#FFFFFF", backgroundOpacity: Double = 0, borderSize: Double = 2.5, position: Double = 96, bold: Bool = false) {
        self.fontSize = fontSize
        self.textColor = textColor
        self.backgroundOpacity = backgroundOpacity
        self.borderSize = borderSize
        self.position = position
        self.bold = bold
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
    public private(set) var errorMessage: String?

    public var isPlaying: Bool { !isPaused && !isEnded }
    public var progress: Double { duration > 0 ? min(position / duration, 1) : 0 }

    @ObservationIgnored private var controller: MPVController!
    @ObservationIgnored private var pending: PlaybackRequest?
    @ObservationIgnored private var current: PlaybackRequest?
    @ObservationIgnored private var surfaceReady = false
    @ObservationIgnored private var lastPublishedPosition: Double = -1
    @ObservationIgnored private var subtitleStyle = SubtitleStyle()
    @ObservationIgnored private var lastLogLine: String?
    @ObservationIgnored private var fileLoaded = false
    @ObservationIgnored public var onEnded: (() -> Void)?

    public init(hardwareDecoding: Bool = true) {
        controller = MPVController { [weak self] events in
            Task { @MainActor in self?.handle(events) }
        }
        controller.start(hardwareDecoding: hardwareDecoding)
        apply(subtitleStyle)
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
        var args = ["loadfile", request.url.absoluteString, "replace", "-1"]
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
        controller.command(["seek", String(format: "%.3f", position), "absolute+keyframes"])
    }

    public func seek(by seconds: Double) {
        position = max(0, position + seconds)
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

    public func apply(_ style: SubtitleStyle) {
        subtitleStyle = style
        controller.set("sub-font-size", double: style.fontSize)
        controller.set("sub-color", style.textColor)
        controller.set("sub-border-size", double: style.borderSize)
        controller.set("sub-pos", double: style.position)
        controller.set("sub-bold", flag: style.bold)
        let alpha = String(format: "%02X", Int(style.backgroundOpacity * 255))
        controller.set("sub-back-color", "#\(alpha)000000")
        controller.set("sub-border-style", style.backgroundOpacity > 0 ? "background-box" : "outline-and-shadow")
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
                case let ("sid", .int(id)): selectedSubtitleID = Int(id)
                case ("sid", .none), ("sid", .string): selectedSubtitleID = nil
                case let ("sub-delay", .double(value)): subtitleDelay = value
                case let ("hwdec-current", .string(value)): hardwareDecoder = value == "no" ? nil : value
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
            case let .chapters(list):
                chapters = list
            }
        }
    }

    private func selectPreferredSubtitle() {
        guard selectedSubtitleID == nil, let current, let preferred = current.preferredSubtitleLanguages.first,
              let subtitle = current.subtitles.first(where: { $0.language == preferred }) else { return }
        addSubtitle(subtitle, select: true)
    }

}
