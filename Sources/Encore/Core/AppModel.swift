import AppKit
import Observation
import SwiftUI

/// The root object: owns the engines and the cross-window UI state.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let settings = AppSettings.shared
    let player: PlayerEngine
    let browser: BrowserEngine
    let visualizer = VisualizerEngine()
    @ObservationIgnored private(set) var nowPlaying: NowPlayingCenter!

    /// The selected sidebar destination in the main window.
    var destination: Destination = .home
    /// Set to focus the toolbar search field.
    var searchText = ""
    var toast: Toast?

    @ObservationIgnored private var toastTask: Task<Void, Never>?

    private init() {
        player = PlayerEngine(settings: AppSettings.shared)
        browser = BrowserEngine(settings: AppSettings.shared)
        nowPlaying = NowPlayingCenter(player: player)

        player.onBrowseRequest = { [weak self] url in
            self?.browse(url)
        }
        player.onStateChange = { [weak self] in
            guard let self else { return }
            self.nowPlaying.update()
            self.visualizer.isPlaying = self.player.isPlaying
        }
        player.onVisualizerFrame = { [weak self] bands, level in
            self?.visualizer.ingest(bands: bands, level: level)
        }
        browser.onPlayRequest = { [weak self] url in
            self?.play(url)
        }
        visualizer.sensitivity = Float(settings.visualizerSensitivity)
    }

    func start() {
        applyAppearance()
        browser.loadInitialIfNeeded()
        player.restoreLastSession()
        if player.hasMedia { destination = .nowPlaying }
    }

    // MARK: Navigation

    func play(_ url: URL) {
        player.load(url)
        destination = .nowPlaying
    }

    func browse(_ url: URL) {
        browser.load(url)
        if destination == .nowPlaying { destination = .home }
    }

    func select(_ destination: Destination) {
        if destination != .nowPlaying, destination == self.destination {
            browser.go(to: destination) // re-selecting reloads the feed
        } else if destination != .nowPlaying {
            browser.go(to: destination)
        }
        self.destination = destination
    }

    /// Search field submit: plays links directly, searches otherwise.
    func submitSearch(_ text: String) {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        if let url = Self.youtubeURL(in: query) {
            if PlayerEngine.isPlayable(url) && url.path != "/playlist" { play(url) } else { browse(url) }
        } else {
            browser.search(query)
            destination = .home
        }
    }

    func playFromClipboard() {
        guard let string = NSPasteboard.general.string(forType: .string),
              let url = Self.youtubeURL(in: string), PlayerEngine.isPlayable(url) else {
            showToast("No YouTube link on the clipboard", symbol: "doc.on.clipboard")
            return
        }
        play(url)
        showToast("Playing link from clipboard", symbol: "link")
    }

    func copyCurrentLink() {
        guard player.hasMedia else { return }
        var link = "https://youtu.be/\(player.videoId)"
        let seconds = Int(player.position())
        if seconds > 5, !player.isLive { link += "?t=\(seconds)" }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link, forType: .string)
        showToast("Link copied", symbol: "link")
    }

    // MARK: Web navigation (acts on whichever page is showing)

    private var browsing: Bool { destination != .nowPlaying }
    func goBack() { if browsing { browser.goBack() } else { player.webView.goBack() } }
    func goForward() { if browsing { browser.goForward() } else { player.webView.goForward() } }
    func reload() { if browsing { browser.reload() } else { player.webView.reload() } }

    static func youtubeURL(in text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: candidate), let host = url.host?.lowercased(),
              host.hasSuffix("youtube.com") || host == "youtu.be" else { return nil }
        return url
    }

    // MARK: Mode

    func setMode(_ mode: PlaybackMode) {
        guard settings.mode != mode else { return }
        withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
            settings.mode = mode
        }
        player.applyQuality()
        showToast(mode == .audio ? "Audio mode · video paused to save data" : "Video mode",
                  symbol: mode.symbol)
    }

    func toggleMode() { setMode(settings.mode.toggled) }

    func cycleVisualizer() {
        settings.visualizerStyle = settings.visualizerStyle.next
        showToast(settings.visualizerStyle.title, symbol: settings.visualizerStyle.symbol)
    }

    // MARK: Appearance

    func applyAppearance() {
        NSApp.appearance = settings.appearance == .dark ? NSAppearance(named: .darkAqua) : nil
    }

    // MARK: Toasts

    struct Toast: Equatable, Identifiable {
        let id = UUID()
        let text: String
        let symbol: String
    }

    func showToast(_ text: String, symbol: String) {
        toastTask?.cancel()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { toast = Toast(text: text, symbol: symbol) }
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { self?.toast = nil }
        }
    }
}
