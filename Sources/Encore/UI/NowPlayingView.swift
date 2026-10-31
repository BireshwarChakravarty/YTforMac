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
                    HStack(alignment: .top) {
                        VisualizerPicker()
                        Spacer()
                        UpNextChip()
                    }
                    .padding(18)
                    Spacer()
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
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

                HStack(spacing: 4) {
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
        .padding(.top, 70)
        .background(
            LinearGradient(colors: [.clear, Theme.Palette.background.opacity(0.8)], startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
        )
    }
}

/// "Audio only · 144p data saver", "Ad", "Live".
struct StatusPill: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.player
        let text: String = {
            if player.isAd { return "Ad playing · skips when allowed" }
            if player.isLive { return "Live" }
            if model.settings.mode == .audio {
                let q = model.settings.audioModeQuality
                return q == .auto ? "Audio only" : "Audio only · \(q.title) data saver"
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

/// Chip strip for choosing a visualiser.
struct VisualizerPicker: View {
    @Environment(AppModel.self) private var model
    @State private var expanded = false

    var body: some View {
        let current = model.settings.visualizerStyle
        HStack(spacing: 6) {
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { expanded.toggle() }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: current.symbol)
                    Text(current.title)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .font(Theme.Fonts.title(12.5))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Choose a visualiser (⌘⇧V cycles)")

            if expanded {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(VisualizerStyle.allCases) { style in
                            Button {
                                model.settings.visualizerStyle = style
                            } label: {
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 5) {
                                        Image(systemName: style.symbol).font(.system(size: 10, weight: .bold))
                                        Text(style.title).font(Theme.Fonts.title(12))
                                        if style.isGPU {
                                            Text("3D").font(.system(size: 8, weight: .black, design: .rounded))
                                                .padding(.horizontal, 3).padding(.vertical, 1)
                                                .background(Capsule().fill(Theme.signature))
                                        }
                                    }
                                    Text(style.caption).font(.system(size: 9.5, weight: .medium, design: .rounded))
                                        .foregroundStyle(Theme.Palette.textTertiary)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(style == current ? Color.white.opacity(0.14) : .clear))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.trailing, 6)
                }
                .frame(maxWidth: 640)
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .padding(3)
        .encoreGlass(cornerRadius: 13)
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
struct EncoreMark: View {
    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width, size.height) / 620
            let ox = (size.width - 620 * s) / 2 - 200 * s, oy = (size.height - 520 * s) / 2 - 260 * s
            func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: ox + x * s, y: oy + y * s) }
            let shading = GraphicsContext.Shading.linearGradient(
                Gradient(colors: [Color(red: 1, green: 0.48, blue: 0.35), Color(red: 0.94, green: 0.22, blue: 0.56), Color(red: 0.55, green: 0.33, blue: 1)]),
                startPoint: p(260, 300), endPoint: p(780, 740))
            var tri = Path()
            tri.move(to: p(290, 340)); tri.addLine(to: p(290, 684)); tri.addLine(to: p(560, 512)); tri.closeSubpath()
            ctx.fill(tri, with: shading)
            ctx.stroke(tri, with: shading, style: StrokeStyle(lineWidth: 64 * s, lineJoin: .round))
            var arc1 = Path()
            arc1.addArc(center: p(400, 512), radius: 260 * s, startAngle: .degrees(-38), endAngle: .degrees(38), clockwise: false)
            ctx.stroke(arc1, with: shading, style: StrokeStyle(lineWidth: 56 * s, lineCap: .round))
            var arc2 = Path()
            arc2.addArc(center: p(400, 512), radius: 350 * s, startAngle: .degrees(-38), endAngle: .degrees(38), clockwise: false)
            var faded = ctx
            faded.opacity = 0.55
            faded.stroke(arc2, with: shading, style: StrokeStyle(lineWidth: 56 * s, lineCap: .round))
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
