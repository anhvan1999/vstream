import Foundation
import IOKit.pwr_mgt
import MediaPlayer

/// Keeps the display awake while video plays.
@MainActor
public final class SleepAssertion {
    private var assertionID: IOPMAssertionID = 0
    private var isHeld = false

    public init() {}

    public func hold(_ hold: Bool) {
        if hold, !isHeld {
            isHeld = IOPMAssertionCreateWithName(
                kIOPMAssertionTypeNoDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "VStream playback" as CFString,
                &assertionID
            ) == kIOReturnSuccess
        } else if !hold, isHeld {
            IOPMAssertionRelease(assertionID)
            isHeld = false
        }
    }

    isolated deinit {
        hold(false)
    }
}

/// Now Playing info and media keys / Control Center transport.
@MainActor
public final class NowPlayingController {
    private weak var model: PlayerModel?
    private var targets: [Any] = []

    public init() {}

    public func attach(_ model: PlayerModel, title: String, subtitle: String?) {
        self.model = model
        let center = MPRemoteCommandCenter.shared()
        detachTargets()
        targets = [
            center.togglePlayPauseCommand.addTarget { [weak model] _ in model?.togglePause(); return .success },
            center.playCommand.addTarget { [weak model] _ in model?.setPaused(false); return .success },
            center.pauseCommand.addTarget { [weak model] _ in model?.setPaused(true); return .success },
            center.skipForwardCommand.addTarget { [weak model] _ in model?.seek(by: 10); return .success },
            center.skipBackwardCommand.addTarget { [weak model] _ in model?.seek(by: -10); return .success },
            center.changePlaybackPositionCommand.addTarget { [weak model] event in
                guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
                model?.seek(to: event.positionTime)
                return .success
            },
        ]
        var info: [String: Any] = [MPMediaItemPropertyTitle: title, MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue]
        if let subtitle { info[MPMediaItemPropertyArtist] = subtitle }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    public func update() {
        guard let model, var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPMediaItemPropertyPlaybackDuration] = model.duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = model.position
        info[MPNowPlayingInfoPropertyPlaybackRate] = model.isPlaying ? model.speed : 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = model.isPlaying ? .playing : .paused
    }

    public func detach() {
        detachTargets()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    private func detachTargets() {
        let center = MPRemoteCommandCenter.shared()
        for command in [center.togglePlayPauseCommand, center.playCommand, center.pauseCommand, center.skipForwardCommand, center.skipBackwardCommand, center.changePlaybackPositionCommand] {
            command.removeTarget(nil)
        }
        targets = []
    }
}
