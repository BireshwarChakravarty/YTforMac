import SwiftUI

// MARK: - Glass

extension View {
    /// Liquid Glass on macOS 26+, frosted material before that.
    @ViewBuilder
    func encoreGlass(cornerRadius: CGFloat = 16, tint: Color? = nil) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            self.glassEffect(tint.map { Glass.regular.tint($0.opacity(0.25)) } ?? .regular,
                             in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self.glassCard(cornerRadius: cornerRadius)
        }
        #else
        self.glassCard(cornerRadius: cornerRadius)
        #endif
    }
}

// MARK: - Artwork

struct ArtworkView: View {
    let image: NSImage?
    var cornerRadius: CGFloat = 10
    var square = false

    @Environment(AppModel.self) private var model

    var body: some View {
        Color.clear
            .aspectRatio(square ? 1 : 16 / 9, contentMode: .fit)
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    LinearGradient(colors: model.player.palette.gradient, startPoint: .topLeading, endPoint: .bottomTrailing)
                        .overlay(Image(systemName: "music.note").font(.system(size: 18, weight: .bold)).foregroundStyle(.white.opacity(0.8)))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(.white.opacity(0.08)))
    }
}

// MARK: - Transport

struct TransportControls: View {
    enum Size { case large, medium, small }
    var size: Size = .large
    var showSkips = false

    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.player
        HStack(spacing: spacing) {
            if showSkips {
                IconButton(symbol: "gobackward.10", size: iconSize * 0.85, help: "Back \(Int(model.settings.skipInterval)) seconds") {
                    player.skip(by: -model.settings.skipInterval)
                }
            }
            IconButton(symbol: "backward.fill", size: iconSize, help: "Previous") { player.previous() }
            PlayPauseButton(diameter: playDiameter)
            IconButton(symbol: "forward.fill", size: iconSize, help: "Next") { player.next() }
            if showSkips {
                IconButton(symbol: "goforward.10", size: iconSize * 0.85, help: "Forward \(Int(model.settings.skipInterval)) seconds") {
                    player.skip(by: model.settings.skipInterval)
                }
            }
        }
        .disabled(!player.hasMedia)
        .opacity(player.hasMedia ? 1 : 0.45)
    }

    private var spacing: CGFloat { size == .large ? 22 : size == .medium ? 14 : 8 }
    private var iconSize: CGFloat { size == .large ? 22 : size == .medium ? 17 : 14 }
    private var playDiameter: CGFloat { size == .large ? 64 : size == .medium ? 46 : 34 }
}

struct PlayPauseButton: View {
    var diameter: CGFloat = 60
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        let player = model.player
        Button {
            player.togglePlayPause()
        } label: {
            ZStack {
                Circle()
                    .fill(.white)
                    .shadow(color: model.player.palette.secondary.opacity(0.55), radius: diameter * 0.45)
                    .shadow(color: .black.opacity(0.35), radius: 10, y: 6)
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: diameter * 0.38, weight: .black))
                    .foregroundStyle(Color(red: 0.07, green: 0.05, blue: 0.1))
                    .offset(x: player.isPlaying ? 0 : diameter * 0.03)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: diameter, height: diameter)
            .scaleEffect(hovering ? 1.05 : 1)
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { hovering = h } }
        .help(player.isPlaying ? "Pause" : "Play")
    }
}

struct IconButton: View {
    let symbol: String
    var size: CGFloat = 18
    var help: String = ""
    var tint: Color = .white
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(tint.opacity(hovering ? 1 : 0.82))
                .frame(width: size * 2, height: size * 2)
                .background(Circle().fill(.white.opacity(hovering ? 0.08 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}

// MARK: - Scrubber

struct ScrubberView: View {
    var compact = false
    var showsKnob = true

    @Environment(AppModel.self) private var model
    @State private var dragValue: Double?
    @State private var hovering = false

    var body: some View {
        let player = model.player
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !player.isPlaying || dragValue != nil)) { timeline in
            let duration = max(player.duration, 0.001)
            let position = dragValue ?? player.position(at: timeline.date)
            let fraction = player.isLive ? 1 : min(1, max(0, position / duration))
            HStack(spacing: compact ? 8 : 10) {
                Text(player.isAd ? "Ad" : formatTime(position))
                    .frame(width: compact ? 38 : 50, alignment: .leading)
                GeometryReader { geo in
                    let height: CGFloat = compact ? 4 : (hovering || dragValue != nil ? 7 : 5)
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.13))
                        Capsule()
                            .fill(LinearGradient(colors: player.isAd ? [.yellow, .orange] : player.palette.gradient,
                                                 startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(height, geo.size.width * fraction))
                            .shadow(color: player.palette.secondary.opacity(compact ? 0 : 0.7), radius: 8)
                        if showsKnob && !compact {
                            Circle()
                                .fill(.white)
                                .frame(width: 14, height: 14)
                                .shadow(color: .black.opacity(0.4), radius: 4, y: 1)
                                .offset(x: geo.size.width * fraction - 7)
                                .opacity(hovering || dragValue != nil ? 1 : 0.9)
                        }
                    }
                    .frame(height: height)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { g in
                                guard !player.isAd, !player.isLive else { return }
                                dragValue = min(1, max(0, g.location.x / geo.size.width)) * duration
                            }
                            .onEnded { _ in
                                if let v = dragValue { player.seek(to: v) }
                                dragValue = nil
                            }
                    )
                    .animation(.easeOut(duration: 0.15), value: hovering)
                }
                .frame(height: 16)
                .onHover { hovering = $0 }
                Text(player.isLive ? "LIVE" : formatTime(player.duration))
                    .foregroundStyle(player.isLive ? Theme.Palette.coral : Theme.Palette.textTertiary)
                    .frame(width: compact ? 38 : 50, alignment: .trailing)
            }
            .font(Theme.Fonts.mono(compact ? 10.5 : 12))
            .foregroundStyle(Theme.Palette.textTertiary)
        }
    }
}

// MARK: - Volume

struct VolumeControl: View {
    var width: CGFloat = 110
    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.player
        HStack(spacing: 8) {
            Button { player.toggleMute() } label: {
                Image(systemName: symbol(player))
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 18)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.Palette.textSecondary)
            .help(player.isMuted ? "Unmute" : "Mute")
            GeometryReader { geo in
                let f = player.isMuted ? 0 : player.volume / 100
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.13))
                    Capsule().fill(.white.opacity(0.8)).frame(width: max(5, geo.size.width * f))
                }
                .frame(height: 5)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    player.setVolume(min(1, max(0, g.location.x / geo.size.width)) * 100)
                })
            }
            .frame(width: width, height: 16)
        }
    }

    private func symbol(_ p: PlayerEngine) -> String {
        if p.isMuted || p.volume == 0 { return "speaker.slash.fill" }
        return p.volume < 34 ? "speaker.wave.1.fill" : p.volume < 67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
    }
}

// MARK: - Mode picker

struct ModePicker: View {
    var compact = false
    @Environment(AppModel.self) private var model
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(PlaybackMode.allCases) { mode in
                let on = model.settings.mode == mode
                Button { model.setMode(mode) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: mode.symbol).font(.system(size: compact ? 10 : 11, weight: .bold))
                        Text(mode.title).font(Theme.Fonts.title(compact ? 11.5 : 12.5))
                    }
                    .padding(.horizontal, compact ? 9 : 11)
                    .padding(.vertical, compact ? 4 : 5)
                    .foregroundStyle(on ? .white : Theme.Palette.textSecondary)
                    .background {
                        if on {
                            Capsule()
                                .fill(Theme.signature)
                                .shadow(color: Theme.Palette.magenta.opacity(0.4), radius: 8, y: 3)
                                .matchedGeometryEffect(id: "mode", in: ns)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(mode == .audio ? "Audio mode: hide the video and save data" : "Video mode")
            }
        }
        .padding(3)
        .background(Capsule().fill(.white.opacity(0.06)).overlay(Capsule().strokeBorder(Theme.Palette.stroke)))
    }
}

// MARK: - Live equaliser glyph

/// Four tiny bars that dance while something is playing (sidebar, lists).
struct EqualizerGlyph: View {
    var color: Color = Theme.Palette.magenta
    @Environment(AppModel.self) private var model

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !model.player.isPlaying)) { _ in
            let bands: [Float] = {
                model.visualizer.tick()
                return model.visualizer.bands
            }()
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Array([2, 9, 18, 30].enumerated()), id: \.offset) { _, i in
                    Capsule()
                        .fill(color)
                        .frame(width: 3, height: model.player.isPlaying ? 3 + CGFloat(bands[i]) * 10 : 3)
                }
            }
            .frame(height: 13, alignment: .bottom)
        }
    }
}
