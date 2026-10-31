import SwiftUI

/// The main window: sidebar, toolbar search, content and the player bar.
struct MainView: View {
    @Environment(AppModel.self) private var model
    @State private var suggester = SearchSuggester()
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 228, max: 280)
        } detail: {
            ContentArea()
                .toolbar { toolbarContent }
                .navigationTitle(title)
        }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search YouTube or paste a link")
        .searchSuggestions {
            ForEach(suggester.suggestions, id: \.self) { s in
                Label(s, systemImage: "magnifyingglass").searchCompletion(s)
            }
        }
        .onSubmit(of: .search) {
            model.submitSearch(model.searchText)
            suggester.clear()
        }
        .onChange(of: model.searchText) { _, text in suggester.update(text) }
        .background(Theme.Palette.background)
        .frame(minWidth: 940, minHeight: 600)
        .overlay(alignment: .top) { ToastView() }
    }

    private var title: String {
        switch model.destination {
        case .nowPlaying: return model.player.hasMedia ? model.player.title : "Now Playing"
        default: return model.browser.pageTitle.isEmpty ? model.destination.title : model.browser.pageTitle
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { goBack() } label: { Image(systemName: "chevron.left") }
                .help("Back")
                .disabled(!canGoBack)
            Button { goForward() } label: { Image(systemName: "chevron.right") }
                .help("Forward")
                .disabled(!canGoForward)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            ModePicker()
            if model.destination == .nowPlaying && model.settings.mode == .video && model.player.hasMedia {
                Button {
                    model.settings.cinemaLayout.toggle()
                    model.player.applyCinema()
                } label: {
                    Image(systemName: model.settings.cinemaLayout ? "rectangle.inset.filled" : "rectangle.split.2x1")
                }
                .help(model.settings.cinemaLayout ? "Show the full YouTube page (comments, description)" : "Cinema: video fills the window")
            }
            Button { MiniPlayerController.shared.toggle() } label: { Image(systemName: "pip.enter") }
                .help("Floating mini player")
        }
    }

    private var browsing: Bool { model.destination != .nowPlaying }
    private var canGoBack: Bool { browsing ? model.browser.canGoBack : model.player.webView.canGoBack }
    private var canGoForward: Bool { browsing ? model.browser.canGoForward : model.player.webView.canGoForward }
    private func goBack() { browsing ? model.browser.goBack() : model.player.webView.goBack() }
    private func goForward() { browsing ? model.browser.goForward() : model.player.webView.goForward() }
}

/// Keeps both web views mounted (so neither ever reloads) and layers the
/// native Now Playing screen on top when appropriate.
struct ContentArea: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.player
        let onNowPlaying = model.destination == .nowPlaying
        let showVideo = onNowPlaying && model.settings.mode == .video && player.hasMedia
        let showNowPlaying = onNowPlaying && !showVideo
        let showBrowser = !onNowPlaying
        let showBar = player.hasMedia && !showNowPlaying

        VStack(spacing: 0) {
            ZStack {
                Theme.Palette.background
                WebViewHost(webView: model.browser.webView)
                    .opacity(showBrowser ? 1 : 0)
                    .allowsHitTesting(showBrowser)
                WebViewHost(webView: player.webView)
                    .opacity(showVideo ? 1 : 0)
                    .allowsHitTesting(showVideo)
                if showBrowser && model.browser.isLoading {
                    LoadingBar().frame(maxHeight: .infinity, alignment: .top)
                }
                if showNowPlaying {
                    NowPlayingView().transition(.opacity)
                }
            }
            if showBar {
                PlayerBar()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: showNowPlaying)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: showBar)
    }
}

/// A slim indeterminate progress line under the toolbar.
struct LoadingBar: View {
    @State private var phase: CGFloat = -0.3
    var body: some View {
        GeometryReader { geo in
            Capsule()
                .fill(Theme.signature)
                .frame(width: geo.size.width * 0.3, height: 2)
                .offset(x: geo.size.width * phase)
                .onAppear {
                    withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: false)) { phase = 1.0 }
                }
        }
        .frame(height: 2)
        .allowsHitTesting(false)
    }
}

/// Transient confirmation (mode switch, visualiser change, clipboard).
struct ToastView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        if let toast = model.toast {
            HStack(spacing: 8) {
                Image(systemName: toast.symbol).foregroundStyle(Theme.Palette.magenta)
                Text(toast.text).font(Theme.Fonts.title(13))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .encoreGlass(cornerRadius: 20)
            .padding(.top, 14)
            .transition(.move(edge: .top).combined(with: .opacity))
            .id(toast.id)
            .allowsHitTesting(false)
        }
    }
}

/// YouTube search suggestions for the toolbar field.
@MainActor
@Observable
final class SearchSuggester {
    private(set) var suggestions: [String] = []
    @ObservationIgnored private var task: Task<Void, Never>?

    func clear() { task?.cancel(); suggestions = [] }

    func update(_ text: String) {
        task?.cancel()
        let query = text.trimmingCharacters(in: .whitespaces)
        guard query.count >= 2, AppModel.youtubeURL(in: query) == nil else { suggestions = []; return }
        task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            var c = URLComponents(string: "https://suggestqueries.google.com/complete/search")!
            c.queryItems = [.init(name: "client", value: "firefox"), .init(name: "ds", value: "yt"), .init(name: "q", value: query)]
            guard let url = c.url,
                  let (data, _) = try? await URLSession.shared.data(from: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
                  json.count > 1, let list = json[1] as? [String] else { return }
            guard !Task.isCancelled else { return }
            self?.suggestions = Array(list.prefix(8))
        }
    }
}
