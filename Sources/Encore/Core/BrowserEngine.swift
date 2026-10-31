import AppKit
import Observation
import WebKit

/// Destinations shown in the sidebar.
enum Destination: String, CaseIterable, Identifiable, Hashable {
    case nowPlaying, home, subscriptions, explore, history, watchLater, liked, playlists

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nowPlaying: return "Now Playing"
        case .home: return "Home"
        case .subscriptions: return "Subscriptions"
        case .explore: return "Explore"
        case .history: return "History"
        case .watchLater: return "Watch Later"
        case .liked: return "Liked Videos"
        case .playlists: return "Playlists"
        }
    }

    var symbol: String {
        switch self {
        case .nowPlaying: return "waveform.circle.fill"
        case .home: return "house.fill"
        case .subscriptions: return "play.square.stack.fill"
        case .explore: return "safari.fill"
        case .history: return "clock.arrow.circlepath"
        case .watchLater: return "clock.fill"
        case .liked: return "hand.thumbsup.fill"
        case .playlists: return "music.note.list"
        }
    }

    var url: URL? {
        let base = "https://www.youtube.com"
        switch self {
        case .nowPlaying: return nil
        case .home: return URL(string: base + "/")
        case .subscriptions: return URL(string: base + "/feed/subscriptions")
        case .explore: return URL(string: base + "/feed/explore")
        case .history: return URL(string: base + "/feed/history")
        case .watchLater: return URL(string: base + "/playlist?list=WL")
        case .liked: return URL(string: base + "/playlist?list=LL")
        case .playlists: return URL(string: base + "/feed/playlists")
        }
    }

    var shortcut: Character? {
        switch self {
        case .nowPlaying: return "0"
        case .home: return "1"
        case .subscriptions: return "2"
        case .explore: return "3"
        case .history: return "4"
        case .watchLater: return "5"
        case .liked: return "6"
        case .playlists: return "7"
        }
    }

    static let browse: [Destination] = [.home, .subscriptions, .explore]
    static let library: [Destination] = [.history, .watchLater, .liked, .playlists]
}

/// Owns the browsing web view: YouTube's feeds, search, channels and
/// playlists. It never plays media; video clicks are forwarded to the player.
@MainActor
@Observable
final class BrowserEngine: NSObject {
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var isLoading = false
    private(set) var pageTitle = ""
    private(set) var isSignedIn = false
    private(set) var avatarURL: URL?

    let webView: WKWebView
    @ObservationIgnored var onPlayRequest: (@MainActor (URL) -> Void)?
    private let settings: AppSettings
    private let proxy: ScriptMessageProxy
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var lastPlay: (key: String, at: Date)?
    @ObservationIgnored private var didInitialLoad = false

    init(settings: AppSettings) {
        self.settings = settings
        let proxy = ScriptMessageProxy()
        self.proxy = proxy
        let initial = "window.__encoreInitialClean = \(settings.cleanYouTubeChrome);"
        let config = WebKitFactory.makeConfiguration(
            scripts: [Scripts.baseStyle, initial, Scripts.browser],
            handler: proxy,
            backgroundPlayback: false
        )
        webView = WebKitFactory.makeWebView(configuration: config)
        super.init()
        proxy.onMessage = { [weak self] body in self?.receive(body) }
        webView.navigationDelegate = self
        webView.uiDelegate = self
        observe()
        WebViewParking.shared.park(webView)
        refreshSignInState()
    }

    func loadInitialIfNeeded() {
        guard !didInitialLoad else { return }
        didInitialLoad = true
        go(to: .home)
    }

    func go(to destination: Destination) {
        guard let url = destination.url else { return }
        didInitialLoad = true
        load(url)
    }

    func load(_ url: URL) {
        didInitialLoad = true
        webView.load(URLRequest(url: url))
    }

    func search(_ query: String) {
        var c = URLComponents(string: "https://www.youtube.com/results")!
        c.queryItems = [URLQueryItem(name: "search_query", value: query)]
        if let url = c.url { load(url) }
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload() { webView.reload() }

    func signIn() {
        let next = "https://www.youtube.com/signin?action_handle_signin=true&app=desktop&next=https%3A%2F%2Fwww.youtube.com%2F"
        var c = URLComponents(string: "https://accounts.google.com/ServiceLogin")!
        c.queryItems = [
            URLQueryItem(name: "service", value: "youtube"),
            URLQueryItem(name: "uilel", value: "3"),
            URLQueryItem(name: "passive", value: "true"),
            URLQueryItem(name: "continue", value: next),
        ]
        if let url = c.url { load(url) }
    }

    func signOut() {
        let store = WebKitFactory.dataStore
        store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { [weak self] records in
            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: records) {
                Task { @MainActor in
                    self?.isSignedIn = false
                    self?.avatarURL = nil
                    self?.go(to: .home)
                }
            }
        }
    }

    func applyCleanChrome() {
        webView.evaluateJavaScript("window.__encore && window.__encore.setClean(\(settings.cleanYouTubeChrome))")
    }

    private func observe() {
        observations = [
            webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] web, _ in
                MainActor.assumeIsolated { self?.canGoBack = web.canGoBack }
            },
            webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] web, _ in
                MainActor.assumeIsolated { self?.canGoForward = web.canGoForward }
            },
            webView.observe(\.isLoading, options: [.initial, .new]) { [weak self] web, _ in
                MainActor.assumeIsolated { self?.isLoading = web.isLoading }
            },
            webView.observe(\.title, options: [.new]) { [weak self] web, _ in
                MainActor.assumeIsolated {
                    self?.pageTitle = (web.title ?? "").replacingOccurrences(of: " - YouTube", with: "")
                }
            },
            // Safety net: if the SPA router still reached a watch page, hand it
            // to the player and step back.
            webView.observe(\.url, options: [.new]) { [weak self] web, _ in
                MainActor.assumeIsolated {
                    guard let self, let url = web.url, PlayerEngine.isPlayable(url),
                          url.path != "/playlist" else { return }
                    self.requestPlay(url)
                    if web.canGoBack { web.goBack() } else { self.go(to: .home) }
                }
            },
        ]
    }

    private func requestPlay(_ url: URL) {
        let key = PlayerEngine.videoId(from: url) ?? url.absoluteString
        if let last = lastPlay, last.key == key, Date().timeIntervalSince(last.at) < 2 { return }
        lastPlay = (key, Date())
        onPlayRequest?(url)
    }

    private func receive(_ body: [String: Any]) {
        switch body["type"] as? String {
        case "play":
            if let s = body["url"] as? String, let url = URL(string: s) { requestPlay(url) }
        case "avatar":
            if let s = body["url"] as? String, let url = URL(string: s) {
                avatarURL = url
                isSignedIn = true
            }
        default:
            break
        }
    }

    func refreshSignInState() {
        WebKitFactory.dataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            let signedIn = cookies.contains { $0.name == "SAPISID" || $0.name == "__Secure-3PAPISID" }
            Task { @MainActor in self?.isSignedIn = signedIn }
        }
    }
}

extension BrowserEngine: WKNavigationDelegate, WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .allow }
        guard navigationAction.targetFrame?.isMainFrame != false else { return .allow }
        if PlayerEngine.isPlayable(url), url.path != "/playlist" {
            requestPlay(url)
            return .cancel
        }
        let host = url.host?.lowercased() ?? ""
        if host.hasSuffix("youtube.com"), url.path == "/redirect" {
            NSWorkspace.shared.open(Self.unwrapRedirect(url))
            return .cancel
        }
        let internal = host.hasSuffix("youtube.com") || host.hasSuffix("google.com") || host.hasSuffix("youtube-nocookie.com")
            || host.hasSuffix("gstatic.com") || host.hasSuffix("googleusercontent.com") || host.isEmpty
        if !internal, navigationAction.navigationType == .linkActivated {
            // Outbound links (descriptions, about pages) open in the default browser.
            NSWorkspace.shared.open(url)
            return .cancel
        }
        return .allow
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        refreshSignInState()
        applyCleanChrome()
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard let url = navigationAction.request.url else { return nil }
        if PlayerEngine.isPlayable(url) {
            requestPlay(url)
        } else if url.host?.hasSuffix("youtube.com") == true {
            load(url)
        } else {
            NSWorkspace.shared.open(Self.unwrapRedirect(url))
        }
        return nil
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    /// youtube.com/redirect?q=<target> → <target>
    static func unwrapRedirect(_ url: URL) -> URL {
        guard url.path == "/redirect",
              let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "q" })?.value,
              let target = URL(string: q) else { return url }
        return target
    }
}
