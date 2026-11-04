import AppKit
import MediaPlayer

/// Keeps Encore awake while it plays.
///
/// Control Center's Now Playing entry, the media keys and headphone buttons
/// are handled by the player page's own media session (WebKit publishes it for
/// Encore, and `Scripts` routes its buttons to the native transport). Encore
/// used to publish a second entry through `MPNowPlayingInfoCenter`, which made
/// it appear twice in Now Playing, the second one sometimes with the previous
/// video's artwork.
@MainActor
final class NowPlayingCenter {
    private let player: PlayerEngine
    private var activity: NSObjectProtocol?

    init(player: PlayerEngine) {
        self.player = player
        // Clear anything an earlier version published.
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    /// Call whenever player state changes.
    func update() {
        player.hasMedia && player.isPlaying ? beginActivity() : endActivity()
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
