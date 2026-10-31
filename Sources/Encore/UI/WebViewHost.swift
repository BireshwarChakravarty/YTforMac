import SwiftUI
import WebKit

/// Displays one of the app-wide web views. Several hosts may exist for the
/// same web view (main window, mini player); the most recent one that is on
/// screen wins, and when none are, the view is parked so playback continues.
struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WebViewContainer {
        let container = WebViewContainer(frame: .zero)
        container.webView = webView
        WebViewParking.shared.register(container, for: webView)
        return container
    }

    func updateNSView(_ container: WebViewContainer, context: Context) {
        if container.webView !== webView {
            container.webView = webView
            WebViewParking.shared.register(container, for: webView)
        }
    }

    static func dismantleNSView(_ container: WebViewContainer, coordinator: ()) {
        guard let webView = container.webView else { return }
        WebViewParking.shared.unregister(container, for: webView)
    }
}
