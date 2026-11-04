import SwiftUI

/// The main window: sidebar, toolbar search, content and the player bar.
struct MainView: View {
    @Environment(AppModel.self) private var model
    @State private var suggester = SearchSuggester()
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        Group {
            if model.immersive {
                ImmersiveView()
                    .ignoresSafeArea()
            } else {
                splitView
            }
        }
        // Set explicitly both ways: hiding it only inside the full-screen view
        // could leave the toolbar (and its Video / Audio switch) hidden after
        // leaving full screen.
        .toolbar(model.immersive ? .hidden : .visible, for: .windowToolbar)
        .frame(minWidth: 940, minHeight: 600)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            if model.immersive { withAnimation { model.immersive = false } }
        }
    }

    private var splitView: some View {
        @Bindable var model = model
        return NavigationSplitView(columnVisibility: $columnVisibility) {
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
            ModePicker().fixedSize()
            if model.player.hasMedia {
                QualityMenu()
            }
            Button { MiniPlayerController.shared.toggle() } label: { Image(systemName: "pip.enter") }
                .help("Floating mini player")
        }
    }

    private var browsing: Bool { model.destination != .nowPlaying }
    private var canGoBack: Bool { browsing ? model.browser.canGoBack : model.player.webView.canGoBack }
    private var canGoForward: Bool { browsing ? model.browser.canGoForward : model.player.webView.canGoForward }
    private func goBack() { model.goBack() }
    private func goForward() { model.goForward() }
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
                VStack(spacing: 0) {
                    WebViewHost(webView: player.webView)
                    if showVideo { VideoDetailsBar() }
                }
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

/// The bar under the video: a drop-down that reveals YouTube's description,
/// comments and up-next list, plus the current stream quality.
struct VideoDetailsBar: View {
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        let expanded = !model.settings.cinemaLayout
        let player = model.player
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { model.settings.cinemaLayout.toggle() }
            model.player.applyCinema()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .bold))
                    .rotationEffect(.degrees(expanded ? 180 : 0))
                Text(expanded ? "Hide details" : "Details, comments & up next")
                    .font(Theme.Fonts.title(12.5))
                Spacer()
                if !player.currentQuality.isEmpty {
                    Text(player.currentQuality)
                        .font(.system(size: 10.5, weight: .heavy, design: .rounded))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(.white.opacity(0.1)))
                        .help("YouTube is streaming this quality")
                }
            }
            .foregroundStyle(hovering ? Color.white : Theme.Palette.textSecondary)
            .padding(.horizontal, 16)
            .frame(height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color.black)
        .overlay(alignment: .top) { Rectangle().fill(Theme.Palette.stroke).frame(height: 1) }
        .onHover { hovering = $0 }
        .help(expanded ? "Show only the video" : "Show the description, comments and up-next list under the video")
    }
}

/// Toolbar drop-down for the streaming quality (for the current mode).
struct QualityMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let audio = model.settings.mode == .audio
        let current = audio ? model.settings.audioModeQuality : model.settings.videoQuality
        Menu {
            Section(audio ? "Audio mode stream" : "Video quality") {
                ForEach(VideoQuality.allCases) { q in
                    Button {
                        if audio { model.settings.audioModeQuality = q } else { model.settings.videoQuality = q }
                        model.player.applyQuality()
                    } label: {
                        if q == current { Label(q.title, systemImage: "checkmark") } else { Text(q.title) }
                    }
                }
            }
        } label: {
            Label(model.player.currentQuality.isEmpty ? "Quality" : model.player.currentQuality, systemImage: "sparkles.tv")
                .labelStyle(.titleAndIcon)
        }
        .fixedSize()
        .help("Streaming quality. \u{201C}Highest available\u{201D} is the default.")
    }
}


/// The full-screen visualiser: only the visuals. Moving the mouse brings up the
/// controls for a few seconds; Esc or ⇧⌘F leaves.
struct ImmersiveView: View {
    @Environment(AppModel.self) private var model
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        let style = model.settings.visualizerStyle
        let player = model.player
        ZStack {
            AmbientBackground()
            if player.hasMedia {
                VisualizerView(style: style)
                    .id(style)
                    .transition(.opacity)
                if style.isLyrics {
                    LyricsStage(style: style)
                        .padding(.vertical, 70)
                        .id(style)
                }
            } else {
                EmptyNowPlaying()
            }
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    VisualizerPicker()
                    if style.isLyrics { LyricsInfoChip() }
                    Spacer()
                    IconButton(symbol: "arrow.down.right.and.arrow.up.left", size: 15, help: "Exit full screen (Esc)") {
                        model.toggleImmersive()
                    }
                }
                .padding(24)
                Spacer()
                if player.hasMedia {
                    VStack(spacing: 12) {
                        if style != .drive {
                            Text(player.title)
                                .font(Theme.Fonts.display(22))
                                .lineLimit(1)
                                .shadow(color: .black.opacity(0.5), radius: 10)
                        }
                        ScrubberView()
                        TransportControls(size: .large, showSkips: true)
                    }
                    .frame(maxWidth: 560)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 18)
                    .background(
                        RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.black.opacity(0.35))
                            .blur(radius: 0.5)
                    )
                    .padding(.bottom, 34)
                }
            }
            .opacity(controlsVisible ? 1 : 0)
            .animation(.easeInOut(duration: 0.4), value: controlsVisible)
        }
        .background(Color.black)
        .onContinuousHover { phase in
            if case .active = phase { showControls() }
        }
        .onTapGesture { controlsVisible ? hideNow() : showControls() }
        .onExitCommand { model.toggleImmersive() }
        .onAppear { showControls() }
        .onDisappear { hideTask?.cancel(); NSCursor.setHiddenUntilMouseMoves(false) }
    }

    private func showControls() {
        controlsVisible = true
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.8))
            guard !Task.isCancelled else { return }
            hideNow()
        }
    }

    private func hideNow() {
        controlsVisible = false
        NSCursor.setHiddenUntilMouseMoves(true)
    }
}
