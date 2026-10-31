import AppKit
import MediaPlayer

/// Bridges the player to macOS: keyboard media keys, headphone buttons,
/// Control Center's Now Playing widget and the Touch Bar.
///
/// The key detail is that Encore *stays* the "now playing" app while paused:
/// it keeps publishing a paused `MPNowPlayingInfoCenter` state instead of
/// clearing it, so the next press of ⏯ is routed back here even when Encore
/// has no visible windows. This is exactly what a Safari tab fails to do.
@MainActor
final class NowPlayingCenter {
    private let player: PlayerEngine
    private let center = MPRemoteCommandCenter.shared()
    private let info = MPNowPlayingInfoCenter.default()
    private var activity: NSObjectProtocol?
    private var lastArtworkId = ""
    private var cachedArtwork: MPMediaItemArtwork?

    init(player: PlayerEngine) {
        self.player = player
        registerCommands()
    }

    private func registerCommands() {
        func bind(_ command: MPRemoteCommand, _ action: RemoteCommand) {
            command.isEnabled = true
            command.addTarget { [weak self] _ in
                guard let self else { return .commandFailed }
                guard self.player.hasMedia else { return .noActionableNowPlayingItem }
                self.player.handleRemote(action)
                return .success
            }
        }
        bind(center.playCommand, .play)
        bind(center.pauseCommand, .pause)
        bind(center.togglePlayPauseCommand, .toggle)
        bind(center.nextTrackCommand, .next)
        bind(center.previousTrackCommand, .previous)

        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self.player.handleRemote(.seek(event.positionTime))
            return .success
        }

        // Keep next/previous as the Control Center buttons.
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
        center.stopCommand.isEnabled = true
        center.stopCommand.addTarget { [weak self] _ in
            self?.player.pause()
            return .success
        }
    }

    /// Call whenever player state changes.
    func update() {
        guard player.hasMedia else {
            info.nowPlayingInfo = nil
            info.playbackState = .stopped
            endActivity()
            return
        }

        var dict: [String: Any] = [
            MPMediaItemPropertyTitle: player.title.isEmpty ? "YouTube" : player.title,
            MPMediaItemPropertyArtist: player.isAd ? "Advertisement" : player.author,
            MPMediaItemPropertyAlbumTitle: "Encore",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player.position(),
            MPNowPlayingInfoPropertyPlaybackRate: player.isPlaying ? player.rate : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyIsLiveStream: player.isLive,
            MPNowPlayingInfoPropertyExternalContentIdentifier: player.videoId,
        ]
        if player.duration > 0, !player.isLive {
            dict[MPMediaItemPropertyPlaybackDuration] = player.duration
        }
        if let artwork = artwork() {
            dict[MPMediaItemPropertyArtwork] = artwork
        }
        info.nowPlayingInfo = dict
        info.playbackState = player.isPlaying ? .playing : .paused

        player.isPlaying ? beginActivity() : endActivity()
    }

    private func artwork() -> MPMediaItemArtwork? {
        guard let image = player.artwork else { return nil }
        if lastArtworkId == player.videoId, let cachedArtwork { return cachedArtwork }
        let art = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        lastArtworkId = player.videoId
        cachedArtwork = art
        return art
    }

    /// Prevents App Nap from throttling the app while audio is playing, without
    /// keeping the Mac awake.
    private func beginActivity() {
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Encore is playing media"
        )
    }

    private func endActivity() {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }
}
