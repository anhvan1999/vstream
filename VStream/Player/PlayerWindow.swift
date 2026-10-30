import AddonKit
import PlayerKit
import SwiftUI
import TorrentKit
import VStreamCore

struct PlayerWindow: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            if let session = app.playback {
                PlayerScreen(session: session)
                    .id(session.id)
            } else {
                EmptyStateView(title: "Nothing playing", symbol: "play.rectangle", message: "Pick a stream from a title's page.")
            }
        }
        .frame(minWidth: 640, minHeight: 360)
        .background(.black)
        .onDisappear { app.closePlayback() }
    }
}

private struct PlayerScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismissWindow) private var dismissWindow
    let session: PlaybackSession

    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @FocusState private var focused: Bool

    private var player: PlayerModel { session.player }

    var body: some View {
        ZStack {
            Color.black
            MPVVideoView(model: player)
                .onTapGesture(count: 2) { toggleFullScreen() }
                .onTapGesture { player.togglePause() }

            statusOverlay

            if controlsVisible || !player.isPlaying {
                controls
                    .transition(.opacity)
            }

            if session.showNextUp, let next = session.nextVideo {
                NextUpCard(video: next, onPlay: session.playNext, onDismiss: session.dismissNextUp)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, 28)
                    .padding(.bottom, 120)
            }
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.2), value: controlsVisible)
        .onContinuousHover { phase in
            if case .active = phase { revealControls() }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear {
            focused = true
            revealControls()
        }
        .onKeyPress(.space) { player.togglePause(); revealControls(); return .handled }
        .onKeyPress(.leftArrow) { player.seek(by: -10); revealControls(); return .handled }
        .onKeyPress(.rightArrow) { player.seek(by: 10); revealControls(); return .handled }
        .onKeyPress(.upArrow) { player.adjustVolume(by: 5); revealControls(); return .handled }
        .onKeyPress(.downArrow) { player.adjustVolume(by: -5); revealControls(); return .handled }
        .onKeyPress(.escape) {
            if NSApp.keyWindow?.styleMask.contains(.fullScreen) == true { toggleFullScreen(); return .handled }
            return .ignored
        }
        .onKeyPress(characters: .init(charactersIn: "fmsan")) { press in
            switch press.characters {
            case "f": toggleFullScreen()
            case "m": player.toggleMute()
            case "s": cycle(player.subtitleTracks, selected: player.selectedSubtitleID, allowOff: true, select: player.selectSubtitle)
            case "a": cycle(player.audioTracks, selected: player.selectedAudioID, allowOff: false, select: player.selectAudio)
            case "n": session.playNext()
            default: return .ignored
            }
            revealControls()
            return .handled
        }
        .navigationTitle(session.title)
    }

    // MARK: Overlays

    @ViewBuilder private var statusOverlay: some View {
        switch session.stage {
        case let .resolving(message):
            LoadingCard(message: message, stats: session.torrentStats)
        case let .failed(message):
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.yellow)
                Text(message).multilineTextAlignment(.center).frame(maxWidth: 420)
                Button("Close") { dismissWindow(id: "player") }.buttonStyle(.glass)
            }
            .padding(28)
            .glassEffect(.regular, in: .rect(cornerRadius: 24))
        case .playing:
            if let error = player.errorMessage, !player.isLoading, player.duration == 0 {
                VStack(spacing: 14) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.yellow)
                    Text(error).multilineTextAlignment(.center).frame(maxWidth: 420)
                    Button("Retry") { player.retry() }.buttonStyle(.glass)
                }
                .padding(28)
                .glassEffect(.regular, in: .rect(cornerRadius: 24))
            } else if player.isLoading || player.isBuffering {
                LoadingCard(message: player.isLoading ? "Opening stream" : "Buffering", stats: session.torrentStats)
            }
        }
    }

    private var controls: some View {
        VStack {
            topBar
            Spacer()
            bottomBar
        }
        .padding(20)
        .environment(\.colorScheme, .dark)
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                dismissWindow(id: "player")
            } label: {
                Image(systemName: "chevron.backward").font(.title3.weight(.semibold)).frame(width: 32, height: 32)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.title).font(.headline)
                if let subtitle = session.subtitle {
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: .capsule)

            Spacer()

            if let stats = session.torrentStats {
                TorrentStatsChip(stats: stats)
            }
            if let source = session.source {
                SourceChip(source: source, hardwareDecoder: player.hardwareDecoder)
            }
        }
        .padding(.top, 18)
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            Timeline(player: player)
            HStack(spacing: 14) {
                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        iconButton("gobackward.10") { player.seek(by: -10) }
                        iconButton(player.isPlaying ? "pause.fill" : "play.fill", large: true) { player.togglePause() }
                        iconButton("goforward.10") { player.seek(by: 10) }
                        if session.nextVideo != nil {
                            iconButton("forward.end.fill") { session.playNext() }
                        }
                    }
                }
                Text("\(format(player.position)) / \(format(player.duration))")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                VolumeControl(player: player)
                speedMenu
                audioMenu
                subtitleMenu
                iconButton("arrow.up.left.and.arrow.down.right") { toggleFullScreen() }
            }
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
    }

    private func iconButton(_ symbol: String, large: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: { action(); revealControls() }) {
            Image(systemName: symbol)
                .font(large ? .title2 : .body)
                .frame(width: large ? 40 : 30, height: large ? 40 : 30)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
    }

    private var speedMenu: some View {
        Menu {
            ForEach([0.5, 0.75, 1, 1.25, 1.5, 2], id: \.self) { speed in
                Button {
                    player.setSpeed(speed)
                } label: {
                    if player.speed == speed { Label("\(speed.formatted())×", systemImage: "checkmark") } else { Text("\(speed.formatted())×") }
                }
            }
        } label: {
            Image(systemName: "gauge.with.dots.needle.67percent")
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .fixedSize()
        .help("Playback speed")
    }

    private var audioMenu: some View {
        Menu {
            ForEach(player.audioTracks) { track in
                Button {
                    player.selectAudio(track.id)
                } label: {
                    if player.selectedAudioID == track.id { Label(track.displayName, systemImage: "checkmark") } else { Text(track.displayName) }
                }
            }
        } label: {
            Image(systemName: "waveform")
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .fixedSize()
        .disabled(player.audioTracks.count < 2)
        .help("Audio track")
    }

    private var subtitleMenu: some View {
        Menu {
            Button {
                player.selectSubtitle(nil)
            } label: {
                if player.selectedSubtitleID == nil { Label("Off", systemImage: "checkmark") } else { Text("Off") }
            }
            Section("Tracks") {
                ForEach(player.subtitleTracks) { track in
                    Button {
                        player.selectSubtitle(track.id)
                    } label: {
                        if player.selectedSubtitleID == track.id { Label(track.displayName, systemImage: "checkmark") } else { Text(track.displayName) }
                    }
                }
            }
            Section("Delay") {
                Button("−0.5 s") { player.setSubtitleDelay(player.subtitleDelay - 0.5) }
                Button("+0.5 s") { player.setSubtitleDelay(player.subtitleDelay + 0.5) }
                Button("Reset (\(player.subtitleDelay.formatted()) s)") { player.setSubtitleDelay(0) }
            }
        } label: {
            Image(systemName: "captions.bubble")
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .fixedSize()
        .help("Subtitles")
    }

    // MARK: Helpers

    private func revealControls() {
        controlsVisible = true
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, player.isPlaying else { return }
            controlsVisible = false
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    private func toggleFullScreen() {
        NSApp.keyWindow?.toggleFullScreen(nil)
    }

    private func cycle(_ tracks: [MediaTrack], selected: Int?, allowOff: Bool, select: (Int?) -> Void) {
        var options: [Int?] = tracks.map(\.id)
        if allowOff { options.insert(nil, at: 0) }
        guard !options.isEmpty else { return }
        let index = options.firstIndex { $0 == selected } ?? -1
        select(options[(index + 1) % options.count])
    }

    private func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds)
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Scrubbable progress bar with buffered range and hover time preview.
private struct Timeline: View {
    let player: PlayerModel
    @State private var scrubbing: Double?
    @State private var hover: Double?

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let duration = max(player.duration, 0.001)
            let progress = (scrubbing ?? player.position) / duration
            let buffered = min(player.cachedUntil / duration, 1)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.18))
                Capsule().fill(.white.opacity(0.32)).frame(width: width * buffered)
                Capsule().fill(.tint).frame(width: max(width * progress, 0))
                ForEach(player.chapters, id: \.self) { chapter in
                    Rectangle().fill(.black.opacity(0.5)).frame(width: 2).offset(x: width * chapter.time / duration)
                }
                Circle()
                    .fill(.white)
                    .frame(width: scrubbing == nil ? 12 : 16)
                    .offset(x: width * progress - 6)
                    .shadow(radius: 3)
                if let hover {
                    Text(Self.format(hover * duration))
                        .font(.caption.monospacedDigit())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .glassEffect(.regular, in: .capsule)
                        .offset(x: min(max(width * hover - 24, 0), width - 56), y: -26)
                }
            }
            .frame(height: 6)
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in scrubbing = min(max(value.location.x / width, 0), 1) * duration }
                    .onEnded { _ in
                        if let scrubbing { player.seek(to: scrubbing) }
                        scrubbing = nil
                    }
            )
            .onContinuousHover { phase in
                if case let .active(location) = phase { hover = min(max(location.x / width, 0), 1) } else { hover = nil }
            }
        }
        .frame(height: 22)
    }

    static func format(_ seconds: Double) -> String {
        let total = Int(max(seconds, 0))
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60) : String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct VolumeControl: View {
    let player: PlayerModel

    var body: some View {
        HStack(spacing: 6) {
            Button {
                player.toggleMute()
            } label: {
                Image(systemName: player.isMuted || player.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .frame(width: 22)
            }
            .buttonStyle(.plain)
            Slider(value: Binding(get: { player.volume }, set: { player.setVolume($0) }), in: 0...100)
                .frame(width: 90)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
    }
}

private struct LoadingCard: View {
    var message: String
    var stats: TorrentStats?

    var body: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large)
            Text(message).font(.headline)
            if let stats {
                Text("\(stats.peers) peers · \(ByteCountFormatter.string(fromByteCount: Int64(stats.downloadRate), countStyle: .binary))/s")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 22)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .environment(\.colorScheme, .dark)
    }
}

private struct TorrentStatsChip: View {
    var stats: TorrentStats

    var body: some View {
        HStack(spacing: 10) {
            Label("\(stats.peers)", systemImage: "person.2.fill")
            Label(ByteCountFormatter.string(fromByteCount: Int64(stats.downloadRate), countStyle: .binary) + "/s", systemImage: "arrow.down")
            Text("\(Int(stats.fileProgress * 100))%")
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .glassEffect(.regular, in: .capsule)
    }
}

private struct SourceChip: View {
    var source: PlaybackSource
    var hardwareDecoder: String?

    var body: some View {
        HStack(spacing: 6) {
            switch source {
            case .direct: Label("Direct", systemImage: "link")
            case let .debrid(service): Label(service.displayName, systemImage: "bolt.fill")
            case .peerToPeer: Label("P2P", systemImage: "point.3.connected.trianglepath.dotted")
            }
            if hardwareDecoder != nil {
                Text("HW").font(.caption2.weight(.bold)).foregroundStyle(.green)
            }
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .glassEffect(.regular, in: .capsule)
    }
}

private struct NextUpCard: View {
    var video: Video
    var onPlay: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            RemoteImage(url: video.thumbnail)
                .frame(width: 128, height: 72)
                .clipShape(.rect(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
                Text("Up Next").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text("\(video.episodeLabel ?? "") \(video.title)").font(.headline).lineLimit(2)
                HStack {
                    Button("Play Now", action: onPlay).buttonStyle(.glassProminent)
                    Button("Dismiss", action: onDismiss).buttonStyle(.glass)
                }
                .controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 380)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .environment(\.colorScheme, .dark)
    }
}
