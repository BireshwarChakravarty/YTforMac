import SwiftUI

/// The immersive audio-mode screen: ambient artwork glow, a full-bleed
/// visualiser and large transport controls.
struct NowPlayingView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.player
        ZStack {
            AmbientBackground()

            if player.hasMedia {
                VisualizerView(style: model.settings.visualizerStyle)
                    .id(model.settings.visualizerStyle)
                    .transition(.opacity)
                    .mask(
                        LinearGradient(stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black, location: model.settings.visualizerStyle.isGPU ? 0.72 : 0.8),
                            .init(color: .black.opacity(model.settings.visualizerStyle.isGPU ? 0.25 : 0.6), location: 1),
                        ], startPoint: .top, endPoint: .bottom)
                    )
                    .ignoresSafeArea()

                if let error = player.playerError, !model.visualizer.forceDemo {
                    PlayerProblemCard(message: error)
                        .transition(.scale(scale: 0.95).combined(with: .opacity))
                }

                VStack(spacing: 0) {
                    HStack(alignment: .top, spacing: 8) {
                        VisualizerPicker()
                        AudioSourceBadge()
                        if model.settings.visualizerStyle.isLyrics { LyricsInfoChip() }
                        Spacer()
                        SleepChip()
                        ChaptersChip()
                        UpNextChip()
                    }
                    .padding(18)
                    if model.settings.visualizerStyle.isLyrics {
                        LyricsStage(style: model.settings.visualizerStyle)
                            .id(model.settings.visualizerStyle)
                    } else {
                        Spacer()
                    }
                    bottomPanel
                }
            } else {
                EmptyNowPlaying()
            }
        }
        .animation(.easeInOut(duration: 0.4), value: model.settings.visualizerStyle)
    }

    private var bottomPanel: some View {
        let player = model.player
        return VStack(spacing: 18) {
            HStack(alignment: .bottom, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                  if model.settings.visualizerStyle != .drive && model.settings.visualizerStyle != .singAlong {
                    StatusPill().fixedSize()
                    Text(player.title.isEmpty ? "Loading…" : player.title)
                        .font(Theme.Fonts.display(28))
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        .shadow(color: .black.opacity(0.4), radius: 10)
                    if !player.author.isEmpty || player.isAd {
                        Text(player.isAd ? "Advertisement" : player.author)
                            .font(Theme.Fonts.title(15))
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .lineLimit(1)
                    }
                  }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

                HStack(spacing: 4) {
                    IconButton(symbol: "arrow.up.left.and.arrow.down.right", size: 14, help: "Full-screen visualiser (\u{21E7}\u{2318}F)") { model.toggleImmersive() }
                    IconButton(symbol: "pip.enter", size: 14, help: "Mini player") { MiniPlayerController.shared.toggle() }
                    IconButton(symbol: "link", size: 14, help: "Copy link") { model.copyCurrentLink() }
                    VolumeControl(width: 100).padding(.leading, 6)
                }
                .fixedSize()
            }

            VStack(spacing: 12) {
                ScrubberView()
                TransportControls(size: .large, showSkips: true)
            }
            .frame(maxWidth: 560)
        }
        .padding(.horizontal, 36)
        .padding(.bottom, 26)
        .padding(.top, model.settings.visualizerStyle.isLyrics ? 16 : 70)
        .background(
            LinearGradient(colors: [.clear, Theme.Palette.background.opacity(0.8)], startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
        )
    }
}

/// "Audio only · 1080p stream", "Ad", "Live".
struct StatusPill: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.player
        let text: String = {
            if player.isAd { return "Ad playing · skips when allowed" }
            if player.isLive { return "Live" }
            if model.settings.mode == .audio {
                if model.settings.audioModeQuality == .tiny { return "Audio only · data saver" }
                return player.currentQuality.isEmpty ? "Audio only · full quality" : "Audio only · \(player.currentQuality) stream"
            }
            return "Now playing"
        }()
        HStack(spacing: 6) {
            if player.isPlaying { EqualizerGlyph(color: player.isAd ? .yellow : player.palette.primary) }
            Text(text.uppercased())
        }
        .font(.system(size: 10.5, weight: .heavy, design: .rounded))
        .tracking(0.8)
        .foregroundStyle(Theme.Palette.textSecondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(.white.opacity(0.08)).overlay(Capsule().strokeBorder(Theme.Palette.stroke)))
    }
}

/// Blurred, slowly breathing artwork behind everything.
struct AmbientBackground: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.player
        // The artwork lives in an overlay so its aspect-fill size never affects layout.
        Theme.Palette.background
            .overlay {
                ZStack {
                    if let art = player.artwork {
                        Image(nsImage: art)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .scaleEffect(1.3)
                            .blur(radius: 80)
                            .saturation(1.5)
                            .opacity(0.55)
                            .transition(.opacity)
                            .id(player.videoId)
                    } else {
                        RadialGradient(colors: [player.palette.secondary.opacity(0.35), .clear], center: .top, startRadius: 0, endRadius: 600)
                    }
                }
            }
            .overlay {
                RadialGradient(colors: [Theme.Palette.background.opacity(0.1), Theme.Palette.background.opacity(0.85)],
                               center: UnitPoint(x: 0.5, y: 0.38), startRadius: 50, endRadius: 700)
            }
            .clipped()
            .animation(.easeInOut(duration: 0.8), value: player.videoId)
    }
}

/// A compact button that opens a grid of visualisers.
struct VisualizerPicker: View {
    @Environment(AppModel.self) private var model
    @State private var open = false

    var body: some View {
        let current = model.settings.visualizerStyle
        Button { open.toggle() } label: {
            HStack(spacing: 7) {
                Image(systemName: current.symbol)
                Text(current.title)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(open ? 180 : 0))
            }
            .font(Theme.Fonts.title(12.5))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .encoreGlass(cornerRadius: 12)
        .help("Choose a visualiser (\u{21E7}\u{2318}V cycles)")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VisualizerGrid { open = false }
                .environment(model)
        }
    }
}

private struct VisualizerGrid: View {
    var onPick: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        let current = model.settings.visualizerStyle
        VStack(alignment: .leading, spacing: 10) {
            Text("Visualiser").font(Theme.Fonts.title(13)).foregroundStyle(Theme.Palette.textSecondary)
            LazyVGrid(columns: [GridItem(.fixed(196), spacing: 8), GridItem(.fixed(196), spacing: 8)], spacing: 8) {
                ForEach(VisualizerStyle.allCases) { style in
                    Button {
                        withAnimation(.easeInOut(duration: 0.35)) { model.settings.visualizerStyle = style }
                        onPick()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: style.symbol)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Theme.signature)
                                .frame(width: 30, height: 30)
                                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.06)))
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 5) {
                                    Text(style.title).font(Theme.Fonts.title(13))
                                    if style.isGPU {
                                        Text(style.isLyrics ? "LYRICS" : "3D").font(.system(size: 8.5, weight: .heavy, design: .rounded))
                                            .padding(.horizontal, 4).padding(.vertical, 1)
                                            .background(Capsule().fill(.white.opacity(0.12)))
                                    }
                                }
                                Text(style.caption)
                                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                                    .foregroundStyle(Theme.Palette.textTertiary)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(style == current ? Color.white.opacity(0.12) : Color.white.opacity(0.03))
                                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(style == current ? Theme.Palette.magenta.opacity(0.6) : .clear, lineWidth: 1))
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .preferredColorScheme(.dark)
    }
}

/// Shown when nothing has been played yet.
struct EmptyNowPlaying: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 18) {
            EncoreMark()
                .frame(width: 96, height: 96)
                .shadow(color: Theme.Palette.magenta.opacity(0.5), radius: 30)
            Text("Nothing playing yet")
                .font(Theme.Fonts.display(26))
            Text("Pick something from your feed, search, or paste a YouTube link.\nMedia keys will control it even with every window closed.")
                .font(Theme.Fonts.body(14))
                .foregroundStyle(Theme.Palette.textSecondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                Button { model.select(.home) } label: {
                    Label("Browse Home", systemImage: "house.fill").padding(.horizontal, 6)
                }
                .buttonStyle(GradientButtonStyle())
                Button { model.playFromClipboard() } label: {
                    Label("Play copied link", systemImage: "doc.on.clipboard").padding(.horizontal, 6)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
        .padding(40)
    }
}

struct GradientButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Fonts.title(13.5))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(Theme.signature))
            .shadow(color: Theme.Palette.magenta.opacity(0.35), radius: 10, y: 4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

/// The Encore logo mark (play triangle + two sound arcs), drawn natively.
/// Encore's mark: a play button inside a loop that comes round again (an
/// encore). Drawn from the app icon's geometry (design/AppIcon.html, 1024 px).
enum EncoreMarkGeometry {
    /// The loop's centre line (stroke it 74 units wide, round caps).
    static func loop(_ p: (Double, Double) -> CGPoint, _ s: Double) -> Path {
        var path = Path()
        path.addArc(center: p(512, 516), radius: 252 * s, startAngle: .degrees(28), endAngle: .degrees(312), clockwise: false)
        return path
    }
    static func arrow(_ p: (Double, Double) -> CGPoint) -> Path {
        var path = Path()
        path.move(to: p(721.5, 271.4)); path.addLine(to: p(741.6, 383.6)); path.addLine(to: p(627.8, 375.4)); path.closeSubpath()
        return path
    }
    static func play(_ p: (Double, Double) -> CGPoint) -> Path {
        var path = Path()
        path.move(to: p(462, 398)); path.addLine(to: p(632, 504)); path.addLine(to: p(462, 610)); path.closeSubpath()
        return path
    }
    /// Maps the mark's 1024-unit space into `size`, fitted and centred.
    static func mapping(_ size: CGSize) -> (s: Double, p: (Double, Double) -> CGPoint) {
        let s = min(size.width, size.height) / 600
        let ox = size.width / 2 - 507 * s, oy = size.height / 2 - 518 * s
        return (s, { x, y in CGPoint(x: ox + x * s, y: oy + y * s) })
    }
}

struct EncoreMark: View {
    var body: some View {
        Canvas { ctx, size in
            let (s, p) = EncoreMarkGeometry.mapping(size)
            let ring = GraphicsContext.Shading.linearGradient(
                Gradient(colors: [Color(red: 1, green: 0.6, blue: 0.32), Color(red: 1, green: 0.24, blue: 0.55), Color(red: 0.54, green: 0.36, blue: 1)]),
                startPoint: p(260, 780), endPoint: p(760, 260))
            ctx.stroke(EncoreMarkGeometry.loop(p, s), with: ring, style: StrokeStyle(lineWidth: 74 * s, lineCap: .round))
            let arrow = EncoreMarkGeometry.arrow(p)
            let violet = Color(red: 0.56, green: 0.38, blue: 1)
            ctx.fill(arrow, with: .color(violet))
            ctx.stroke(arrow, with: .color(violet), style: StrokeStyle(lineWidth: 22 * s, lineJoin: .round))
            let play = EncoreMarkGeometry.play(p)
            let white = GraphicsContext.Shading.linearGradient(Gradient(colors: [.white, Color(red: 1, green: 0.82, blue: 0.9)]),
                                                                startPoint: p(460, 400), endPoint: p(630, 610))
            ctx.fill(play, with: white)
            ctx.stroke(play, with: white, style: StrokeStyle(lineWidth: 26 * s, lineJoin: .round))
        }
    }
}

/// The current chapter; opens the full list to jump around.
struct ChaptersChip: View {
    @Environment(AppModel.self) private var model
    @State private var showing = false

    var body: some View {
        let extras = model.extras
        if !extras.chapters.isEmpty {
            TimelineView(.periodic(from: .now, by: 1)) { tl in
                let now = model.player.position(at: tl.date)
                let current = extras.currentChapter(at: now)
                Button { showing.toggle() } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "list.bullet.rectangle").foregroundStyle(model.player.palette.primary)
                        Text(current?.title ?? "Chapters").font(Theme.Fonts.title(12)).lineLimit(1)
                            .frame(maxWidth: 220, alignment: .leading)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .encoreGlass(cornerRadius: 12)
                }
                .buttonStyle(.plain)
                .help("Chapters (Shift-Command-arrows to move between them)")
                .popover(isPresented: $showing, arrowEdge: .bottom) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(extras.chapters) { c in
                                Button { extras.seek(to: c); showing = false } label: {
                                    HStack(spacing: 10) {
                                        Text(PlaybackExtras.clock(c.start)).monospacedDigit().foregroundStyle(.secondary)
                                            .frame(width: 58, alignment: .trailing)
                                        Text(c.title).lineLimit(2).multilineTextAlignment(.leading)
                                        Spacer(minLength: 0)
                                    }
                                    .font(.system(size: 13, weight: c == current ? .semibold : .regular))
                                    .padding(.vertical, 6).padding(.horizontal, 10)
                                    .background(c == current ? model.player.palette.primary.opacity(0.18) : .clear,
                                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(8)
                    }
                    .frame(width: 340, height: min(420, CGFloat(extras.chapters.count) * 34 + 20))
                }
            }
        }
    }
}

/// The sleep timer's countdown; click to turn it off.
struct SleepChip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let extras = model.extras
        if extras.sleep != .off {
            TimelineView(.periodic(from: .now, by: 1)) { tl in
                Button { extras.setSleep(minutes: nil) } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "moon.zzz.fill").foregroundStyle(Theme.Palette.violet)
                        Text(extras.sleepRemaining(now: tl.date).map { PlaybackExtras.clock($0) } ?? "End of video")
                            .font(Theme.Fonts.title(12)).monospacedDigit()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .encoreGlass(cornerRadius: 12)
                }
                .buttonStyle(.plain)
                .help("Sleep timer: click to turn off")
            }
        }
    }
}

/// Shows the playlist position / live state in the top-right corner.
struct UpNextChip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.player
        if !player.playlistId.isEmpty || player.isLive {
            HStack(spacing: 8) {
                Image(systemName: player.isLive ? "dot.radiowaves.left.and.right" : "music.note.list")
                    .foregroundStyle(player.isLive ? Theme.Palette.coral : player.palette.primary)
                Text(player.isLive ? "Live stream" : "Playing from a playlist")
                    .font(Theme.Fonts.title(12))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .encoreGlass(cornerRadius: 12)
        }
    }
}

/// Shown in audio mode when YouTube refuses to play (sign-in wall, region lock,
/// removed video), since the page itself is hidden.
struct PlayerProblemCard: View {
    let message: String
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.bubble.fill")
                .font(.system(size: 30))
                .foregroundStyle(Theme.signature)
            Text("YouTube needs your attention")
                .font(Theme.Fonts.display(20))
            Text("\u{201C}\(message)\u{201D}")
                .font(Theme.Fonts.body(14))
                .foregroundStyle(Theme.Palette.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            HStack(spacing: 10) {
                Button { model.setMode(.video) } label: { Label("Show Video Page", systemImage: "play.rectangle") }
                    .buttonStyle(GradientButtonStyle())
                if !model.browser.isSignedIn {
                    Button { model.destination = .home; model.browser.signIn() } label: { Label("Sign In", systemImage: "person.crop.circle") }
                        .buttonStyle(.bordered).controlSize(.large)
                }
                Button { model.player.webView.reload() } label: { Label("Retry", systemImage: "arrow.clockwise") }
                    .buttonStyle(.bordered).controlSize(.large)
            }
        }
        .padding(28)
        .encoreGlass(cornerRadius: 22)
        .shadow(color: .black.opacity(0.4), radius: 30, y: 10)
    }
}

/// Shows whether the visualiser is following the real audio ("Live audio")
/// or the tempo-matched simulation ("Simulated"), and why.
struct AudioSourceBadge: View {
    var compact = false
    @Environment(AppModel.self) private var model

    private enum State { case live, simulated(String?), needsPermission }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let state = currentState
            if model.player.hasMedia {
                Button {
                    if case .needsPermission = state { AudioTap.openPrivacySettings() }
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(color(state))
                            .frame(width: 7, height: 7)
                            .shadow(color: isLive(state) ? .green.opacity(0.8) : .clear, radius: 4)
                        Text(label(state))
                            .font(.system(size: compact ? 10 : 11.5, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                    .padding(.horizontal, compact ? 8 : 11)
                    .padding(.vertical, compact ? 4 : 7)
                    .background(Capsule().fill(.black.opacity(0.28)).overlay(Capsule().strokeBorder(Theme.Palette.stroke)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(help(state))
            }
        }
        .fixedSize()
    }

    private var currentState: State {
        let player = model.player
        let v = model.visualizer
        if v.isLive && player.isPlaying { return .live }
        if !player.isPlaying { return .simulated("paused") }
        if !model.settings.visualizerUsesAudio { return .simulated("turned off") }
        switch v.audioStatus {
        case .noPermission: return .needsPermission
        case .unsupported: return .simulated("needs macOS 14.2")
        case .failed: return .simulated("capture failed")
        default: return .simulated(nil)
        }
    }

    private func isLive(_ s: State) -> Bool { if case .live = s { return true }; return false }

    private func color(_ s: State) -> Color {
        switch s {
        case .live: return .green
        case .needsPermission: return .orange
        case .simulated(let r): return r == "paused" ? Theme.Palette.textTertiary : .orange
        }
    }

    private func label(_ s: State) -> String {
        switch s {
        case .live: return "Live audio"
        case .needsPermission: return compact ? "Allow audio access" : "Allow audio access…"
        case .simulated(let r): return r.map { "Simulated · \($0)" } ?? "Simulated"
        }
    }

    private func help(_ s: State) -> String {
        switch s {
        case .live: return "The visualiser is following the actual sound."
        case .needsPermission:
            return "macOS hasn't given Encore permission to listen to its own audio. Click to open System Settings → Privacy & Security → Screen & System Audio Recording, and turn on Encore under \u{201C}System Audio Recording Only\u{201D}."
        case .simulated:
            return "The visualiser is following a gentle simulation. It switches to the real sound automatically once audio is flowing."
        }
    }
}
