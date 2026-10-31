import AppKit
import WebKit

/// Builds the WebKit configuration shared by the player and browser views.
enum WebKitFactory {
    /// One persistent store so the sign-in cookie is shared by both views and
    /// survives relaunches.
    static let dataStore = WKWebsiteDataStore.default()

    /// A Safari version string that matches the running OS, so YouTube serves
    /// the same experience it serves Safari (and Google sign-in accepts it).
    static var safariVersionSuffix: String {
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        let version: String
        switch major {
        case 26...: version = "26.0"
        case 15: version = "18.6"
        default: version = "17.6"
        }
        return "Version/\(version) Safari/605.1.15"
    }

    static func makeConfiguration(
        scripts: [String],
        handler: WKScriptMessageHandler,
        backgroundPlayback: Bool
    ) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        config.applicationNameForUserAgent = safariVersionSuffix
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsAirPlayForMediaPlayback = true
        config.suppressesIncrementalRendering = false

        let prefs = WKPreferences()
        prefs.isElementFullscreenEnabled = true
        prefs.javaScriptCanOpenWindowsAutomatically = false
        if backgroundPlayback {
            // Never suspend or throttle the playback page when it is not visible.
            prefs.inactiveSchedulingPolicy = .none
        }
        config.preferences = prefs

        let pagePrefs = WKWebpagePreferences()
        pagePrefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = pagePrefs

        let controller = WKUserContentController()
        // The handler holds its owner weakly, so registering it directly is cycle-free.
        controller.add(handler, name: "encore")
        for source in scripts {
            controller.addUserScript(
                WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
            )
        }
        config.userContentController = controller
        return config
    }

    static func makeWebView(configuration: WKWebViewConfiguration) -> WKWebView {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720), configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = Theme.Palette.backgroundNS
        if #available(macOS 13.3, *) {
            #if DEBUG
            webView.isInspectable = true
            #endif
        }
        return webView
    }
}

/// Receives script messages and forwards their bodies on the main actor.
/// Holds its owner weakly so the content controller never retains an engine.
final class ScriptMessageProxy: NSObject, WKScriptMessageHandler {
    var onMessage: (@MainActor ([String: Any]) -> Void)?
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        MainActor.assumeIsolated { onMessage?(body) }
    }
}

/// Keeps web views alive and "on screen" while no window is showing them.
///
/// WebKit stops treating a view as visible once it leaves a window, so
/// detached views are parked in an invisible, click-through window. Playback
/// therefore continues no matter which Encore windows are open.
@MainActor
final class WebViewParking {
    static let shared = WebViewParking()

    private lazy var window: NSWindow = {
        let window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 1280, height: 720),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.level = .init(rawValue: Int(CGWindowLevelForKey(.minimumWindow)))
        window.collectionBehavior = [.stationary, .ignoresCycle, .transient, .canJoinAllSpaces]
        window.isExcludedFromWindowsMenu = true
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720))
        window.orderFrontRegardless()
        return window
    }()

    /// Hosts that currently want to display a given web view, most recent last.
    private var hosts: [ObjectIdentifier: [WeakHost]] = [:]

    func park(_ webView: WKWebView) {
        guard let content = window.contentView else { return }
        if webView.superview !== content {
            webView.removeFromSuperview()
            webView.frame = content.bounds
            webView.autoresizingMask = [.width, .height]
            content.addSubview(webView)
        }
    }

    func register(_ host: WebViewContainer, for webView: WKWebView) {
        var list = hosts[ObjectIdentifier(webView), default: []].filter { $0.value != nil && $0.value !== host }
        list.append(WeakHost(host))
        hosts[ObjectIdentifier(webView)] = list
        reconcile(webView)
    }

    func unregister(_ host: WebViewContainer, for webView: WKWebView) {
        hosts[ObjectIdentifier(webView)] = hosts[ObjectIdentifier(webView), default: []]
            .filter { $0.value != nil && $0.value !== host }
        reconcile(webView)
    }

    /// Puts the web view into the most recently registered host that is in a
    /// window, or parks it.
    func reconcile(_ webView: WKWebView) {
        let candidates = hosts[ObjectIdentifier(webView), default: []].compactMap(\.value)
        if let host = candidates.last(where: { $0.window != nil }) {
            host.adopt(webView)
        } else {
            park(webView)
        }
    }

    private final class WeakHost {
        weak var value: WebViewContainer?
        init(_ value: WebViewContainer) { self.value = value }
    }
}

/// An `NSView` that can adopt one of the shared web views.
final class WebViewContainer: NSView {
    weak var webView: WKWebView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func adopt(_ webView: WKWebView) {
        guard webView.superview !== self else { return }
        webView.removeFromSuperview()
        webView.frame = bounds
        webView.autoresizingMask = [.width, .height]
        addSubview(webView)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let webView else { return }
        MainActor.assumeIsolated {
            WebViewParking.shared.reconcile(webView)
        }
    }
}
