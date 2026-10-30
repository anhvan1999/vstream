import AddonKit
import PlayerKit
import SwiftUI
import TorrentKit
import VStreamCore

struct PlayerWindow: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Group {
            if let session = app.playback {
                PlayerScreen(session: session)
                    .id(session.id)
            } else {
                EmptyStateView(title: "Nothing playing", symbol: "play.rectangle", message: "Pick a stream from a title's page.")
            }
        }
        #if os(macOS)
        .frame(minWidth: 640, minHeight: 360)
        #else
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        #endif
        .background(.black)
        // No toolbar here: leave the full-screen title bar to AppKit so its buttons stay usable.
        .fullScreenAllowed(true)
        .onDisappear { app.closePlayback() }
    }
}

private struct PlayerScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismissWindow) private var dismissWindow
    let session: PlaybackSession

    @State private var controlsVisible = true
    @State private var isFullScreen = false
    #if os(macOS)
    /// The player's own window; `NSApp.keyWindow` can be the full-screen title-bar window instead.
    @State private var hostWindow = WindowHandle()
    #endif
    @State private var isScrubbing = false
    @State private var showsSubtitles = false
    @State private var hideTask: Task<Void, Never>?
    @State private var toast: Toast?
    @State private var toastTask: Task<Void, Never>?
    @FocusState private var focused: Bool

    private var player: PlayerModel { session.player }

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()
            #if os(macOS)
            MPVVideoView(model: player)
                .onTapGesture(count: 2) { toggleFullScreen() }
                .onTapGesture { player.togglePause() }
            #else
            // Touch: tap shows/hides the controls; double-tap the left or right half to seek 10 s.
            GeometryReader { geometry in
                MPVVideoView(model: player)
                    .onTapGesture(count: 2) { location in
                        player.seek(by: location.x < geometry.size.width / 2 ? -10 : 10)
                        revealControls()
                    }
                    .onTapGesture {
                        if controlsVisible { controlsVisible = false } else { revealControls() }
                    }
            }
            .ignoresSafeArea()
            #endif

            if player.rendersSubtitlesInApp, !player.subtitleText.isEmpty {
                SubtitleOverlay(
                    text: player.subtitleText,
                    aspect: player.videoAspect,
                    liftedBy: controlsVisible || !player.isPlaying ? 150 : 0
                )
                .animation(.easeInOut(duration: 0.2), value: controlsVisible)
                .ignoresSafeArea()
            }

            statusOverlay

            if toast == .subtitleDelay {
                // Reads the live value so it follows mpv as the presses land.
                Text(String(format: "Subtitle delay %+.1f s", player.subtitleDelay))
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassEffect(.regular, in: .capsule)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 44)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }

            if controlsVisible || !player.isPlaying || !isReady {
                controls
                    // Animate only the fade: an ambient animation here also animated the scrubber
                    // when pressing it flipped controlsVisible in the same transaction.
                    .transition(.opacity.animation(.easeInOut(duration: 0.2)))
            }

            if session.showNextUp, let next = session.nextVideo {
                NextUpCard(video: next, onPlay: session.playNext, onDismiss: session.dismissNextUp)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, 28)
                    .padding(.bottom, 120)
            }
        }
        // The Mac draws everything edge to edge; on iPhone/iPad the controls stay clear of the
        // notch and home indicator while the picture fills the screen.
        #if os(macOS)
        .ignoresSafeArea()
        #endif
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
        // ←/→ 10 s, ⇧ 60 s, ⌥ 3 s.
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
            let step: Double = press.modifiers.contains(.shift) ? 60 : press.modifiers.contains(.option) ? 3 : 10
            player.seek(by: press.key == .leftArrow ? -step : step)
            revealControls()
            return .handled
        }
        .onKeyPress(.upArrow) { player.adjustVolume(by: 5); revealControls(); return .handled }
        .onKeyPress(.downArrow) { player.adjustVolume(by: -5); revealControls(); return .handled }
        .onKeyPress(.escape) {
            if isFullScreen { toggleFullScreen(); return .handled }
            return .ignored
        }
        // Subtitle delay, as in mpv: Z earlier, X later (±0.1 s; with ⇧ ±1 s).
        .onKeyPress(characters: .init(charactersIn: "zxZX")) { press in
            let step = press.characters == press.characters.uppercased() ? 1.0 : 0.1
            player.adjustSubtitleDelay(by: press.characters.lowercased() == "z" ? -step : step)
            showToast(.subtitleDelay)
            return .handled
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
        #if os(macOS)
        // Read from the window itself: this view is recreated per session, possibly while the
        // window is already full screen.
        .onFullScreenChange { fullScreen, window in
            isFullScreen = fullScreen
            hostWindow.window = window
            // Keyboard focus is lost across the full-screen transition; take it back so
            // Space/F/Esc keep working.
            focused = true
            if !fullScreen, let aspect = player.videoAspect { fitWindow(to: aspect) }
        }
        .onChange(of: player.videoAspect) { _, aspect in
            if let aspect, !isFullScreen { fitWindow(to: aspect) }
        }
        #endif
        // Dragging produces no hover events; keep the controls up while scrubbing.
        .onChange(of: isScrubbing) { revealControls() }
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
                Button("Close") { closePlayer() }.buttonStyle(.glass)
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

    /// Transport only makes sense once mpv has a file with a duration.
    private var isReady: Bool {
        session.stage == .playing && !player.isLoading && player.duration > 0
    }

    private var controls: some View {
        VStack(spacing: 0) {
            topBar
            Spacer()
            if isReady {
                bottomBar
                    .transition(.move(edge: .bottom).combined(with: .opacity).animation(.easeOut(duration: 0.25)))
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
        .background {
            // Soft scrims instead of glass slabs keep the picture visible.
            VStack {
                LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom).frame(height: 140)
                Spacer()
                if isReady {
                    LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom).frame(height: 200)
                }
            }
            .allowsHitTesting(false)
        }
        .environment(\.colorScheme, .dark)
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                closePlayer()
            } label: {
                Image(systemName: "chevron.backward").font(.body.weight(.semibold)).frame(width: 28, height: 28)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)

            VStack(alignment: .leading, spacing: 1) {
                Text(session.title).font(.headline)
                if let subtitle = session.subtitle {
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .shadow(color: .black.opacity(0.4), radius: 4)

            Spacer()

            if let stats = session.torrentStats {
                TorrentStatsChip(stats: stats)
            }
            if Self.supportsFullScreen, isFullScreen {
                Button {
                    toggleFullScreen()
                } label: {
                    Label("Exit Full Screen", systemImage: "arrow.down.right.and.arrow.up.left")
                        .font(.callout.weight(.medium))
                }
                .buttonStyle(.glass)
                .help("Exit full screen (Esc)")
            }
            if let source = session.source {
                SourceChip(source: source, hardwareDecoder: player.hardwareDecoder)
            }
        }
        .padding(.top, Self.supportsFullScreen ? (isFullScreen ? 16 : 38) : 8)
    }

    private var bottomBar: some View {
        VStack(spacing: 14) {
            Timeline(player: player, isScrubbing: $isScrubbing)

            ZStack {
                // Transport, centred.
                GlassEffectContainer(spacing: 4) {
                    HStack(spacing: 4) {
                        transportButton("gobackward.10", help: "Back 10 seconds") { player.seek(by: -10) }
                        transportButton(player.isPlaying ? "pause.fill" : "play.fill", large: true, help: "Play/Pause") { player.togglePause() }
                        transportButton("goforward.10", help: "Forward 10 seconds") { player.seek(by: 10) }
                    }
                    .padding(4)
                    .glassEffect(.regular, in: .capsule)
                }

                // Secondary actions, trailing.
                HStack(spacing: 2) {
                    Spacer()
                    HStack(spacing: 2) {
                        if session.nextVideo != nil {
                            toolButton("forward.end.fill", help: "Next episode") { session.playNext() }
                        }
                        subtitleMenu
                        if player.audioTracks.count > 1 { audioMenu }
                        moreMenu
                        if Self.supportsFullScreen {
                            toolButton(isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                                       help: isFullScreen ? "Exit full screen (Esc)" : "Full screen (F)") { toggleFullScreen() }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .glassEffect(.regular, in: .capsule)
                }
            }
        }
    }

    private func transportButton(_ symbol: String, large: Bool = false, help: String, action: @escaping () -> Void) -> some View {
        Button(action: { action(); revealControls() }) {
            Image(systemName: symbol)
                .font(large ? .title2.weight(.semibold) : .title3)
                .frame(width: large ? 46 : 38, height: large ? 46 : 38)
                .contentTransition(.symbolEffect(.replace))
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func toolButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: { action(); revealControls() }) {
            Image(systemName: symbol).font(.body).frame(width: 32, height: 32).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func menuLabel(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.body).frame(width: 32, height: 32).contentShape(.rect)
    }

    private var subtitleMenu: some View {
        Button {
            showsSubtitles.toggle()
            revealControls()
        } label: {
            menuLabel(player.selectedSubtitleID == nil ? "captions.bubble" : "captions.bubble.fill")
        }
        .buttonStyle(.plain)
        .help("Subtitles")
        .popover(isPresented: $showsSubtitles, arrowEdge: .top) {
            SubtitlePanel(player: player)
                .environment(app)
        }
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
            menuLabel("waveform")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .help("Audio")
    }

    /// Less frequent settings: speed and volume.
    private var moreMenu: some View {
        Menu {
            Picker("Speed", selection: Binding(get: { player.speed }, set: { player.setSpeed($0) })) {
                ForEach([0.5, 0.75, 1, 1.25, 1.5, 2], id: \.self) { Text("\($0.formatted())×").tag($0) }
            }
            Divider()
            if let link = session.shareableLink {
                Button("Copy Stream Link", systemImage: "link") { StreamLinks.copy(link) }
            }
            if session.stream.isTorrent, let hash = session.stream.infoHash {
                Button("Copy Info Hash", systemImage: "number") { StreamLinks.copy(hash) }
            }
            Divider()
            Button(player.isMuted ? "Unmute" : "Mute") { player.toggleMute() }
            Button("Volume Up (↑)") { player.adjustVolume(by: 10) }
            Button("Volume Down (↓)") { player.adjustVolume(by: -10) }
        } label: {
            menuLabel(player.isMuted ? "speaker.slash.fill" : "ellipsis")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .help("More")
    }

    // MARK: Helpers

    private enum Toast { case subtitleDelay }

    private func showToast(_ kind: Toast) {
        withAnimation(.easeOut(duration: 0.15)) { toast = kind }
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.25)) { toast = nil }
        }
    }

    private func revealControls() {
        controlsVisible = true
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, player.isPlaying, !isScrubbing, !showsSubtitles else { return }
            controlsVisible = false
            #if os(macOS)
            NSCursor.setHiddenUntilMouseMoves(true)
            #endif
        }
    }

    /// The Mac player is a window that can go full screen; iPhone/iPad always fill the screen.
    #if os(macOS)
    private static let supportsFullScreen = true
    #else
    private static let supportsFullScreen = false
    #endif

    private func closePlayer() {
        #if os(macOS)
        dismissWindow(id: "player")
        #else
        app.closePlayback()
        #endif
    }

    #if os(macOS)
    /// Matches the window to the video so it opens without black bars, and keeps that ratio
    /// while resizing. The width stays; the height follows (clamped to the screen).
    private func fitWindow(to aspect: Double) {
        guard let window = hostWindow.window, !window.styleMask.contains(.fullScreen) else { return }
        let ratio = NSSize(width: aspect, height: 1)
        window.contentAspectRatio = ratio
        var frame = window.frame
        let content = window.contentRect(forFrameRect: frame)
        let visible = window.screen?.visibleFrame ?? frame
        var width = content.width
        var height = (width / aspect).rounded()
        if height > visible.height * 0.95 {
            height = (visible.height * 0.95).rounded()
            width = (height * aspect).rounded()
        }
        guard abs(height - content.height) > 1 || abs(width - content.width) > 1 else { return }
        let newFrame = window.frameRect(forContentRect: NSRect(x: content.minX, y: content.maxY - height, width: width, height: height))
        frame = newFrame
        if frame.minY < visible.minY { frame.origin.y = visible.minY }
        window.setFrame(frame, display: true, animate: true)
    }

    private func toggleFullScreen() {
        let window = hostWindow.window ?? NSApp.keyWindow
        // AppKit ignores toggleFullScreen without .fullScreenPrimary, which SwiftUI may have dropped.
        window?.collectionBehavior.remove([.fullScreenNone, .fullScreenAuxiliary])
        window?.collectionBehavior.insert(.fullScreenPrimary)
        #if DEBUG
        FileHandle.standardError.write(Data("[debug] toggleFullScreen fs=\(window?.styleMask.contains(.fullScreen) ?? false) behavior=\(window?.collectionBehavior.rawValue ?? 0)\n".utf8))
        #endif
        window?.toggleFullScreen(nil)
    }
    #else
    private func toggleFullScreen() {}
    #endif

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

/// Scrubber in the style of the Apple TV app's Liquid Glass player: a rounded bar with the elapsed
/// and remaining times underneath. Hovering thickens the bar; dragging shows a large knob and a
/// glass time bubble above it.
private struct Timeline: View {
    let player: PlayerModel
    @Binding var isScrubbing: Bool
    @State private var scrubbing: Double?
    @State private var isHovering = false

    private static let knobSize: CGFloat = 22

    var body: some View {
        let duration = max(player.duration, 0.001)
        let current = scrubbing ?? player.position
        VStack(spacing: 6) {
            bar(duration: duration)
            HStack {
                Text(Self.format(current))
                Spacer()
                Text("−" + Self.format(max(player.duration - current, 0)))
            }
            .font(.caption.monospacedDigit().weight(.medium))
            .foregroundStyle(.white.opacity(0.8))
        }
    }

    private func bar(duration: Double) -> some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let progress = min(max((scrubbing ?? player.position) / duration, 0), 1)
            let buffered = min(max(player.cachedUntil / duration, 0), 1)
            let height: CGFloat = scrubbing != nil || isHovering ? 10 : 6
            // Fills are flat-ended rectangles clipped by the rounded track, so the played part
            // runs straight into the knob instead of ending in its own rounded cap.
            ZStack(alignment: .leading) {
                Rectangle().fill(.white.opacity(0.22))
                Rectangle().fill(.white.opacity(0.18)).frame(width: width * buffered)
                Rectangle().fill(.white).frame(width: width * progress)
            }
            // The played part follows the pointer exactly; never inherit an animation for it.
            .transaction(value: scrubbing) { $0.animation = nil }
            .frame(height: height)
            .clipShape(.capsule)
            .overlay(alignment: .leading) {
                // The positioning box always exists and only moves; the knob appears and
                // disappears inside it. (Transitioning an offset view scales the offset too,
                // so the knob flew in from, and back to, the start of the bar.)
                ZStack {
                    if let scrubbing {
                        ZStack {
                            Circle()
                                .fill(.white)
                                .frame(width: Self.knobSize, height: Self.knobSize)
                                .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
                            Text(Self.format(scrubbing))
                                .font(.callout.monospacedDigit().weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .glassEffect(.regular, in: .capsule)
                                .fixedSize()
                                .offset(y: -40)
                        }
                        .transition(.scale(scale: 0.6).combined(with: .opacity).animation(.easeOut(duration: 0.12)))
                    }
                }
                // Pinned to the knob's size (the bubble overflows) so its centre sits exactly
                // at the end of the played fill.
                .frame(width: Self.knobSize, height: Self.knobSize)
                .offset(x: width * progress - Self.knobSize / 2)
                .transaction(value: scrubbing) { $0.animation = nil }
            }
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        scrubbing = min(max(value.location.x / width, 0), 1) * duration
                        if !isScrubbing { isScrubbing = true }
                    }
                    .onEnded { _ in
                        if let scrubbing { player.seek(to: scrubbing) }
                        scrubbing = nil
                        isScrubbing = false
                    }
            )
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.15), value: isHovering)
        }
        .frame(height: Self.knobSize)
    }

    static func format(_ seconds: Double) -> String {
        let total = Int(max(seconds, 0))
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60) : String(format: "%d:%02d", total / 60, total % 60)
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

/// Weak reference to an AppKit window, held in SwiftUI state without triggering updates.
#if os(macOS)
final class WindowHandle {
    weak var window: NSWindow?
}
#endif

/// Plain-text subtitles in the macOS caption style (System Settings → Accessibility → Captions),
/// placed near the bottom of the picture like the Apple TV app.
private struct SubtitleOverlay: View {
    var text: String
    var aspect: Double?
    /// Raised above the controls while they're shown.
    var liftedBy: CGFloat = 0
    @State private var style = SystemCaptionStyle.current()

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let videoHeight = aspect.map { min(size.height, size.width / max($0, 0.1)) } ?? size.height
            let videoBottom = (size.height + videoHeight) / 2
            // A box from the top of the window down to the caption baseline, text at its bottom.
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                SystemCaptionText(text: text, style: style, videoHeight: videoHeight)
                    .frame(maxWidth: size.width * 0.9)
            }
            .frame(width: size.width, height: max(min(videoBottom - videoHeight * 0.06, size.height - liftedBy), 0))
        }
        .allowsHitTesting(false)
        .onReceive(NotificationCenter.default.publisher(for: SystemCaptionStyle.changed)) { _ in
            style = .current()
        }
    }
}
