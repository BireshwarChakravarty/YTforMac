import AppKit
import Observation
import WebKit

/// Owns the dedicated playback web view and mirrors YouTube's player state.
///
/// There is exactly one player for the lifetime of the app. It is never torn
/// down when windows close, which is what lets media keys resume playback at
/// any time without bringing a window forward.
@MainActor
@Observable
final class PlayerEngine: NSObject {

    // MARK: Observable state

    private(set) var videoId: String = ""
    private(set) var title: String = ""
    private(set) var author: String = ""
    private(set) var duration: Double = 0
    private(set) var isPlaying = false
    private(set) var isBuffering = false
    private(set) var isAd = false
    private(set) var isLive = false
    private(set) var rate: Double = 1
    private(set) var volume: Double = 100
    private(set) var isMuted = false
    private(set) var playlistId: String = ""
    private(set) var currentURL: URL?
    private(set) var artwork: NSImage?
    private(set) var palette: ArtworkPalette = .brand
    /// A playability problem reported by YouTube (sign-in wall, unavailable video…).
    private(set) var playerError: String?
    /// The quality YouTube is currently streaming, e.g. "1080p" or "4K".
    private(set) var currentQuality: String = ""

    /// Position anchor used to interpolate a smooth playhead between updates.
    private(set) var anchorTime: Double = 0
    private(set) var anchorDate = Date()

    var hasMedia: Bool { !videoId.isEmpty }

    /// Current playhead, interpolated from the last reported position.
    func position(at date: Date = Date()) -> Double {
        guard isPlaying, !isBuffering else { return anchorTime }
        let t = anchorTime + date.timeIntervalSince(anchorDate) * rate
        return duration > 0 ? min(t, duration) : t
    }

    // MARK: Collaborators

    let webView: WKWebView
    @ObservationIgnored var onBrowseRequest: (@MainActor (URL) -> Void)?
    @ObservationIgnored var onStateChange: (@MainActor () -> Void)?
    /// Called when the number of on-screen visualisers changes between zero and non-zero.
    @ObservationIgnored var onVisualizerDemand: (@MainActor (Bool) -> Void)?
    private let settings: AppSettings
    @ObservationIgnored private var lastTransport: (kind: String, at: Date) = ("", .distantPast)
    @ObservationIgnored private var artworkTask: Task<Void, Never>?
    @ObservationIgnored private var lastSaved = Date.distantPast
    @ObservationIgnored private var visualizerDemand = 0
    private let proxy: ScriptMessageProxy

    init(settings: AppSettings) {
        self.settings = settings
        let proxy = ScriptMessageProxy()
        self.proxy = proxy
        let config = WebKitFactory.makeConfiguration(
            scripts: [Scripts.visibilitySpoof, Scripts.baseStyle, PlayerEngine.initialSettingsScript(settings), Scripts.player],
            handler: proxy,
            backgroundPlayback: true
        )
        webView = WebKitFactory.makeWebView(configuration: config)
        super.init()
        proxy.onMessage = { [weak self] body in self?.receive(body) }
        webView.navigationDelegate = self
        webView.uiDelegate = self
        volume = settings.lastVolume
        WebViewParking.shared.park(webView)
    }

    private static func initialSettingsScript(_ s: AppSettings) -> String {
        let quality = s.effectiveQuality.rawValue
        return """
        window.__encoreInitial = {
          autoSkipAds: \(s.autoSkipAds),
          dismissStillWatching: \(s.dismissStillWatching),
          cinema: \(s.cinemaLayout),
          quality: '\(quality)'
        };
        """
    }

    // MARK: Loading

    /// Starts playing a YouTube URL (watch, shorts, live, youtu.be or playlist).
    func load(_ url: URL, holdAutoplay: Bool = false) {
        guard let normalized = Self.normalize(url) else { return }
        var target = normalized
        if holdAutoplay, var components = URLComponents(url: normalized, resolvingAgainstBaseURL: false) {
            components.fragment = "encore-hold"
            target = components.url ?? normalized
        }
        currentURL = normalized
        if videoId.isEmpty, let id = Self.videoId(from: normalized) {
            // Optimistic metadata so the UI reacts instantly.
            videoId = id
            loadArtwork(for: id)
        }
        webView.load(URLRequest(url: target))
    }

    func restoreLastSession() {
        guard settings.resumeOnLaunch, let string = settings.lastURL, var components = URLComponents(string: string) else { return }
        let position = Int(settings.lastPosition)
        var items = (components.queryItems ?? []).filter { $0.name != "t" }
        if position > 5 { items.append(URLQueryItem(name: "t", value: "\(position)s")) }
        components.queryItems = items
        if let url = components.url { load(url, holdAutoplay: true) }
    }

    /// Converts any supported YouTube URL into a canonical watch URL.
    static func normalize(_ url: URL) -> URL? {
        guard let host = url.host?.lowercased() else { return nil }
        if host == "youtu.be" {
            let id = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !id.isEmpty else { return nil }
            var c = URLComponents(string: "https://www.youtube.com/watch")!
            var items = [URLQueryItem(name: "v", value: id)]
            items += URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.filter { $0.name != "v" } ?? []
            c.queryItems = items
            return c.url
        }
        guard host.hasSuffix("youtube.com") else { return nil }
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
        c?.scheme = "https"
        c?.host = "www.youtube.com"
        if url.path.hasPrefix("/playlist"), let list = c?.queryItems?.first(where: { $0.name == "list" })?.value {
            var w = URLComponents(string: "https://www.youtube.com/watch")!
            w.queryItems = [URLQueryItem(name: "list", value: list)]
            return w.url
        }
        return c?.url
    }

    static func videoId(from url: URL) -> String? {
        let c = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if let v = c?.queryItems?.first(where: { $0.name == "v" })?.value, !v.isEmpty { return v }
        let parts = url.path.split(separator: "/")
        if parts.count >= 2, ["shorts", "live", "embed"].contains(parts[0]) { return String(parts[1]) }
        if url.host == "youtu.be", let first = parts.first { return String(first) }
        return nil
    }

    static func isPlayable(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if host == "youtu.be" { return url.path.count > 1 }
        guard host.hasSuffix("youtube.com") else { return false }
        if url.path == "/watch" || url.path.hasPrefix("/shorts/") || url.path.hasPrefix("/live/") { return true }
        if url.path == "/playlist", URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: { $0.name == "list" }) == true {
            return true
        }
        return false
    }

    // MARK: Transport

    func play() { run("window.__encore && window.__encore.play()") }
    func pause() { run("window.__encore && window.__encore.pause()") }
    func togglePlayPause() { isPlaying ? pause() : play() }

    func next() { run("window.__encore && window.__encore.next()") }

    func previous() {
        webView.evaluateJavaScript("window.__encore ? window.__encore.previous() : 'history'") { [weak self] result, _ in
            guard let self else { return }
            if (result as? String) == "history" {
                if self.webView.canGoBack { self.webView.goBack() } else { self.seek(to: 0) }
            }
        }
    }

    func seek(to seconds: Double) {
        guard !isAd else { return }
        anchorTime = max(0, seconds)
        anchorDate = Date()
        run("window.__encore && window.__encore.seek(\(max(0, seconds)))")
    }

    func skip(by seconds: Double) { seek(to: position() + seconds) }

    func setVolume(_ value: Double) {
        volume = max(0, min(100, value))
        if volume > 0 { isMuted = false }
        settings.lastVolume = volume
        run("window.__encore && window.__encore.setVolume(\(Int(volume)))")
    }

    func toggleMute() {
        isMuted.toggle()
        run("window.__encore && window.__encore.setMuted(\(isMuted))")
    }

    func setRate(_ value: Double) { run("window.__encore && window.__encore.setRate(\(value))") }

    /// The current video's description (for chapters), once YouTube has it for this video.
    func videoDescription() async -> String? {
        let id = videoId
        let js = """
        (() => { try { const p = document.getElementById('movie_player');
          const r = p && p.getPlayerResponse && p.getPlayerResponse();
          if (r && r.videoDetails && r.videoDetails.videoId === '\(id)') return r.videoDetails.shortDescription || ''; } catch (e) {}
          return '__pending__'; })()
        """
        let result: String? = await withCheckedContinuation { cont in
            webView.evaluateJavaScript(js) { value, _ in cont.resume(returning: value as? String) }
        }
        return result == "__pending__" ? nil : result
    }

    /// Remote commands can arrive twice for one key press (once through
    /// `MPRemoteCommandCenter`, once through WebKit's media session). Collapse
    /// them so a press always acts exactly once.
    func handleRemote(_ command: RemoteCommand) {
        let kind: String
        switch command {
        case .play, .pause, .toggle: kind = "transport"
        case .next: kind = "next"
        case .previous: kind = "previous"
        case .seekForward, .seekBackward, .seek: kind = "seek-\(command)"
        }
        let now = Date()
        if lastTransport.kind == kind, now.timeIntervalSince(lastTransport.at) < 0.35 { return }
        lastTransport = (kind, now)

        switch command {
        case .play: play()
        case .pause: pause()
        case .toggle: togglePlayPause()
        case .next: next()
        case .previous: previous()
        case .seekForward: skip(by: settings.skipInterval)
        case .seekBackward: skip(by: -settings.skipInterval)
        case .seek(let t): seek(to: t)
        }
    }

    // MARK: Settings sync

    func applyQuality() { run("window.__encore && window.__encore.setQuality('\(settings.effectiveQuality.rawValue)')") }
    func applyCinema() { run("window.__encore && window.__encore.setCinema(\(settings.cinemaLayout))") }
    func applyAdSettings() {
        run("""
        window.__encore && (window.__encore.setAutoSkipAds(\(settings.autoSkipAds)),
                            window.__encore.setDismissStillWatching(\(settings.dismissStillWatching)))
        """)
    }

    /// Reference-counted: each visible visualiser asks for spectrum frames.
    func setVisualizerDemand(_ delta: Int) {
        visualizerDemand = max(0, visualizerDemand + delta)
        syncVisualizer()
    }

    private func syncVisualizer() {
        onVisualizerDemand?(visualizerDemand > 0)
    }

    func refreshVisualizerSource() { syncVisualizer() }

    // MARK: Internals

    private func run(_ js: String) {
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    private func receive(_ body: [String: Any]) {
        guard let type = body["type"] as? String else { return }
        switch type {
        case "state":
            apply(state: body)
        case "remote":
            if let name = body["command"] as? String {
                if name == "seekTo", let time = body["time"] as? Double {
                    handleRemote(.seek(time))
                } else if let command = RemoteCommand(name: name) {
                    handleRemote(command)
                }
            }
        case "browse":
            if let s = body["url"] as? String, let url = URL(string: s) { onBrowseRequest?(url) }
        case "ready":
            syncVisualizer()
            if settings.lastVolume < 100 { setVolume(settings.lastVolume) }
        case "vizStatus":
            break
        default:
            break
        }
    }

    private func apply(state s: [String: Any]) {
        let newId = s["videoId"] as? String ?? ""
        let changed = newId != videoId
        if changed { videoId = newId }

        let newTitle = (s["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !newTitle.isEmpty, newTitle != "YouTube", !newTitle.hasPrefix("- "), newTitle != title { title = newTitle }
        let q = VideoQuality.label(forYouTubeLevel: s["quality"] as? String ?? "")
        if q != currentQuality { currentQuality = q }
        let err = (s["error"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        if err != playerError { playerError = err }
        let newAuthor = s["author"] as? String ?? ""
        if !newAuthor.isEmpty, newAuthor != author { author = newAuthor }

        let playing = !(s["paused"] as? Bool ?? true)
        if playing != isPlaying { isPlaying = playing }
        let buffering = s["buffering"] as? Bool ?? false
        if buffering != isBuffering { isBuffering = buffering }
        let ad = s["isAd"] as? Bool ?? false
        if ad != isAd { isAd = ad }
        let live = s["isLive"] as? Bool ?? false
        if live != isLive { isLive = live }
        let newRate = (s["rate"] as? NSNumber)?.doubleValue ?? 1
        if newRate != rate { rate = newRate }
        let newDuration = (s["duration"] as? NSNumber)?.doubleValue ?? 0
        if abs(newDuration - duration) > 0.5 { duration = newDuration.isFinite ? newDuration : 0 }
        let newVolume = (s["volume"] as? NSNumber)?.doubleValue ?? volume
        if abs(newVolume - volume) >= 1 { volume = newVolume }
        let muted = s["muted"] as? Bool ?? false
        if muted != isMuted { isMuted = muted }
        let list = s["playlistId"] as? String ?? ""
        if list != playlistId { playlistId = list }
        if let u = s["url"] as? String, let url = URL(string: u), url != currentURL, PlayerEngine.isPlayable(url) {
            currentURL = url
        }

        let reported = (s["currentTime"] as? NSNumber)?.doubleValue ?? 0
        // Only re-anchor when the interpolated playhead drifted noticeably;
        // this keeps scrubbers silky instead of jittering on every update.
        if changed || !isPlaying || abs(position() - reported) > 0.35 {
            anchorTime = reported
            anchorDate = Date()
        }

        if changed {
            if newId.isEmpty {
                title = ""; author = ""; artwork = nil; palette = .brand
            } else {
                loadArtwork(for: newId)
            }
        }
        persistSession()
        onStateChange?()
    }

    private func persistSession() {
        guard hasMedia, !isAd, Date().timeIntervalSince(lastSaved) > 4 else { return }
        lastSaved = Date()
        if let currentURL {
            var c = URLComponents(url: currentURL, resolvingAgainstBaseURL: false)
            c?.fragment = nil
            let kept = c?.queryItems?.filter { $0.name != "t" }
            c?.queryItems = kept
            settings.lastURL = c?.url?.absoluteString
        }
        settings.lastPosition = position()
    }

    private func loadArtwork(for id: String) {
        artworkTask?.cancel()
        artworkTask = Task { [weak self] in
            let result = await ArtworkLoader.shared.artwork(for: id)
            guard !Task.isCancelled, let self, self.videoId == id else { return }
            self.artwork = result?.image
            self.palette = result?.palette ?? .brand
            self.onStateChange?()
        }
    }
}

// MARK: - Remote commands

enum RemoteCommand: Equatable, CustomStringConvertible {
    case play, pause, toggle, next, previous, seekForward, seekBackward
    case seek(Double)

    init?(name: String) {
        switch name {
        case "play": self = .play
        case "pause": self = .pause
        case "toggle": self = .toggle
        case "next": self = .next
        case "previous": self = .previous
        case "seekForward": self = .seekForward
        case "seekBackward": self = .seekBackward
        default: return nil
        }
    }

    var description: String {
        switch self {
        case .play: return "play"
        case .pause: return "pause"
        case .toggle: return "toggle"
        case .next: return "next"
        case .previous: return "previous"
        case .seekForward: return "forward"
        case .seekBackward: return "backward"
        case .seek: return "seek"
        }
    }
}

// MARK: - WebKit delegates

extension PlayerEngine: WKNavigationDelegate, WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .allow }
        if navigationAction.targetFrame?.isMainFrame == false || url.scheme == "about" || url.scheme == "blob" {
            return .allow
        }
        if PlayerEngine.isPlayable(url) || url.host?.hasSuffix("google.com") == true {
            return .allow
        }
        if let host = url.host?.lowercased(), host.hasSuffix("youtube.com") {
            // A non-video YouTube page: show it in the browser instead.
            onBrowseRequest?(url)
            return .cancel
        }
        if navigationAction.navigationType == .linkActivated {
            NSWorkspace.shared.open(url)
            return .cancel
        }
        return .allow
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url { NSWorkspace.shared.open(url) }
        return nil
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // WebKit crashed or was jettisoned: bring the last video back, paused.
        if let currentURL { load(currentURL, holdAutoplay: true) }
    }
}
