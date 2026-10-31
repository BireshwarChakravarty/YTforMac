import SwiftUI

/// The lyrics layer for the Lyric Pop and Sing-Along visualisers. It sits
/// between the top controls and the transport panel of the Now Playing screen,
/// over a GPU backdrop.
struct LyricsStage: View {
    let style: VisualizerStyle
    @Environment(AppModel.self) private var model

    var body: some View {
        let lyrics = model.lyrics
        Group {
            if model.player.isAd && lyrics.demoStart == nil {
                LyricsMessage(symbol: "megaphone.fill", title: "Lyrics will continue after the ad")
            } else {
                switch lyrics.state {
                case .idle, .searching:
                    LyricsMessage(symbol: "text.magnifyingglass", title: "Finding lyrics\u{2026}", pulsing: true)
                case .synced:
                    if style == .singAlong { SingAlongView() } else { LyricPopView() }
                case .plain(let lines):
                    PlainLyricsView(lines: lines)
                case .instrumental:
                    LyricsMessage(symbol: "pianokeys", title: "Instrumental", subtitle: "Sit back and enjoy the music.")
                case .notFound:
                    LyricsMessage(symbol: "quote.bubble", title: "No synced lyrics for this one",
                                  subtitle: "The visuals keep dancing anyway.", retry: { lyrics.retry() })
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { model.refreshLyrics() }
        .onChange(of: model.player.videoId) { model.refreshLyrics() }
        .onChange(of: model.player.title) { model.refreshLyrics() }
    }
}

// MARK: - Lyric Pop

/// Kinetic typography: each word bursts in as it's sung (scale, blur and a
/// little tilt, with a spring overshoot); the sung word glows in the artwork's
/// colours and the whole line throbs on the beat. Finished lines float away.
struct LyricPopView: View {
    var compact = false
    @Environment(AppModel.self) private var model

    var body: some View {
        let lyrics = model.lyrics
        TimelineView(.animation) { timeline in
            GeometryReader { geo in
                let t = lyrics.time(at: timeline.date)
                let lines = lyrics.lines
                let index = lyrics.currentIndex(at: t)
                let base = compact ? min(26, geo.size.width * 0.07) : max(28, min(68, min(geo.size.width * 0.06, geo.size.height * 0.13)))
                ZStack {
                    if let i = index {
                        let line = lines[i]
                        // The previous line drifts up and dissolves.
                        if i > 0, t - line.start < 0.5, !lines[i - 1].text.isEmpty {
                            let age = t - line.start
                            PopLine(line: lines[i - 1], time: .infinity, fontSize: base, maxWidth: geo.size.width * 0.84, compact: compact)
                                .opacity(max(0, 1 - age * 2.4))
                                .blur(radius: age * 18)
                                .scaleEffect(1 + age * 0.25)
                                .offset(y: -age * base * 2.2)
                        }
                        if line.text.isEmpty {
                            BreakDots(progress: nextProgress(lines, i, t), beat: Double(model.visualizer.beat))
                        } else {
                            PopLine(line: line, time: t, fontSize: base, maxWidth: geo.size.width * 0.84, compact: compact)
                                .scaleEffect(1 + Double(model.visualizer.beat) * 0.035)
                        }
                        if !compact, i + 1 < lines.count, !lines[i + 1].text.isEmpty {
                            Text(lines[i + 1].text)
                                .font(.system(size: base * 0.36, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.32))
                                .lineLimit(1)
                                .frame(maxWidth: geo.size.width * 0.7)
                                .offset(y: base * 2.1)
                                .blur(radius: 0.4)
                        }
                    } else if let first = lines.first {
                        // Before the first line: a countdown.
                        BreakDots(progress: max(0, min(1, 1 - (first.start - t) / max(first.start, 1))), beat: Double(model.visualizer.beat))
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .allowsHitTesting(false)
    }

    private func nextProgress(_ lines: [LyricLine], _ i: Int, _ t: Double) -> Double {
        guard i + 1 < lines.count else { return 0 }
        let span = lines[i + 1].start - lines[i].start
        return max(0, min(1, (t - lines[i].start) / max(span, 0.1)))
    }
}

/// One line of Lyric Pop, laid out word by word.
private struct PopLine: View {
    let line: LyricLine
    let time: Double
    let fontSize: CGFloat
    let maxWidth: CGFloat
    var compact = false
    @Environment(AppModel.self) private var model

    var body: some View {
        let palette = model.settings.visualizerColors == .artwork ? model.player.palette : .brand
        let words = line.words.isEmpty ? [LyricLine.Word(text: line.text, start: line.start, end: line.end)] : line.words
        let size = line.text.count > 42 ? fontSize * 0.78 : fontSize
        FlowLayout(spacing: size * 0.28, lineSpacing: size * 0.08) {
            ForEach(Array(words.enumerated()), id: \.offset) { i, word in
                let age = time - word.start + 0.06
                let active = time >= word.start && time < word.end
                let seed = Double((line.id * 31 + i * 17) % 13) / 13 - 0.5
                let emphasis = (word.text.count >= 6 || i == words.count - 1) ? 1.14 : 1.0
                Text(word.text)
                    .font(.system(size: size * emphasis, weight: .heavy, design: .rounded))
                    .foregroundStyle(active
                        ? AnyShapeStyle(LinearGradient(colors: [.white, .white, palette.primary], startPoint: .top, endPoint: .bottom))
                        : AnyShapeStyle(Color.white.opacity(0.94)))
                    .shadow(color: (active ? palette.primary : palette.secondary).opacity(active ? 0.9 : 0.45), radius: active ? size * 0.35 : size * 0.18)
                    .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
                    .modifier(PopIn(age: age, tilt: seed * 7, compact: compact))
            }
        }
        .frame(maxWidth: maxWidth)
        .multilineTextAlignment(.center)
    }
}

/// The burst-in animation as a pure function of the word's age, so it stays
/// perfectly in sync with the music (no implicit animations to drift).
private struct PopIn: ViewModifier {
    let age: Double
    let tilt: Double
    var compact = false

    func body(content: Content) -> some View {
        if age < 0 {
            content.opacity(compact ? 0.18 : 0).scaleEffect(0.6)
        } else {
            let age = min(age, 10)
            let spring = 1 - 0.65 * exp(-age * 9) * cos(age * 15)
            content
                .scaleEffect(spring)
                .opacity(min(1, age * 7))
                .blur(radius: max(0, 10 * (1 - age * 6)))
                .rotationEffect(.degrees(tilt * exp(-age * 5)))
                .offset(y: 22 * exp(-age * 10))
        }
    }
}

/// "• • •" shown during instrumental breaks, filling up towards the next line.
private struct BreakDots: View {
    let progress: Double
    let beat: Double
    @Environment(AppModel.self) private var model

    var body: some View {
        let palette = model.player.palette
        HStack(spacing: 14) {
            ForEach(0..<3, id: \.self) { i in
                let lit = progress * 3 - Double(i)
                Circle()
                    .fill(Color.white.opacity(0.25 + 0.75 * max(0, min(1, lit))))
                    .frame(width: 14, height: 14)
                    .scaleEffect(1 + 0.25 * beat + (lit > 0 && lit < 1 ? 0.2 : 0))
                    .shadow(color: palette.primary.opacity(max(0, min(1, lit))), radius: 10)
            }
        }
    }
}

// MARK: - Sing-Along

/// Scrolling karaoke: the artwork on the left, lyrics on the right. The sung
/// line is large and fills word by word; the others are dim and soft. Click a
/// line to jump there.
struct SingAlongView: View {
    @Environment(AppModel.self) private var model
    @State private var index: Int?

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width > 760
            HStack(alignment: .center, spacing: wide ? 44 : 0) {
                if wide {
                    SingAlongCover()
                        .frame(width: min(320, geo.size.width * 0.3))
                }
                lyricsColumn(height: geo.size.height, fontSize: wide ? min(38, geo.size.width * 0.032) : min(34, geo.size.width * 0.05))
            }
            .padding(.horizontal, wide ? 56 : 28)
        }
        .task {
            while !Task.isCancelled {
                let i = model.lyrics.currentIndex(at: model.lyrics.time())
                if i != index { index = i }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func lyricsColumn(height: CGFloat, fontSize: CGFloat) -> some View {
        let lines = model.lyrics.lines
        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: fontSize * 0.75) {
                    Color.clear.frame(height: height * 0.32)
                    ForEach(lines) { line in
                        SingAlongLine(line: line, distance: line.id - (index ?? -1), fontSize: fontSize)
                            .id(line.id)
                            .onTapGesture { model.player.seek(to: line.start + model.lyrics.offset + 0.05) }
                    }
                    Color.clear.frame(height: height * 0.6)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollDisabled(false)
            .mask(LinearGradient(stops: [
                .init(color: .clear, location: 0), .init(color: .black, location: 0.16),
                .init(color: .black, location: 0.8), .init(color: .clear, location: 1),
            ], startPoint: .top, endPoint: .bottom))
            .onChange(of: index) { _, new in
                guard let new else { return }
                withAnimation(.spring(response: 0.7, dampingFraction: 0.86)) {
                    proxy.scrollTo(new, anchor: UnitPoint(x: 0, y: 0.34))
                }
            }
            .onAppear {
                if let index { proxy.scrollTo(index, anchor: UnitPoint(x: 0, y: 0.34)) }
            }
        }
    }
}

private struct SingAlongLine: View {
    let line: LyricLine
    let distance: Int
    let fontSize: CGFloat
    @Environment(AppModel.self) private var model

    var body: some View {
        let d = abs(distance)
        Group {
            if line.text.isEmpty {
                if distance == 0 {
                    TimelineView(.animation(minimumInterval: 1 / 30)) { _ in
                        BreakDots(progress: breakProgress, beat: Double(model.visualizer.beat))
                    }
                    .frame(height: fontSize * 1.2)
                } else {
                    Text("\u{2022} \u{2022} \u{2022}")
                        .font(.system(size: fontSize * 0.7, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white.opacity(0.25))
                }
            } else if distance == 0 {
                TimelineView(.animation(minimumInterval: 1 / 60)) { timeline in
                    Text(attributed(at: model.lyrics.time(at: timeline.date)))
                        .font(.system(size: fontSize, weight: .heavy, design: .rounded))
                        .shadow(color: model.player.palette.primary.opacity(0.55), radius: 18)
                }
            } else {
                Text(line.text)
                    .font(.system(size: fontSize, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white.opacity(distance < 0 ? 0.42 : max(0.16, 0.5 - Double(d) * 0.06)))
            }
        }
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .scaleEffect(distance == 0 ? 1 : 0.93, anchor: .leading)
        .blur(radius: distance == 0 ? 0 : min(4, Double(d) * 0.9))
        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: distance)
        .contentShape(Rectangle())
        .help("Jump to this line")
    }

    private var breakProgress: Double {
        let lines = model.lyrics.lines
        let t = model.lyrics.time()
        guard line.id + 1 < lines.count else { return 0 }
        let span = lines[line.id + 1].start - line.start
        return max(0, min(1, (t - line.start) / max(span, 0.1)))
    }

    /// Words already sung are white; the word being sung brightens as it goes.
    private func attributed(at t: Double) -> AttributedString {
        var out = AttributedString()
        let words = line.words.isEmpty ? [LyricLine.Word(text: line.text, start: line.start, end: line.end)] : line.words
        for (i, w) in words.enumerated() {
            let p = max(0, min(1, (t - w.start) / max(0.05, w.end - w.start)))
            var part = AttributedString(w.text + (i < words.count - 1 ? " " : ""))
            part.foregroundColor = Color.white.opacity(0.36 + 0.64 * p)
            out += part
        }
        return out
    }
}

/// Artwork card with the title, shown beside the Sing-Along lyrics.
private struct SingAlongCover: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.player
        VStack(alignment: .leading, spacing: 14) {
            // A square card; wide video thumbnails are cropped to fit.
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if let art = player.artwork {
                        Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        LinearGradient(colors: player.palette.gradient, startPoint: .topLeading, endPoint: .bottomTrailing)
                            .overlay(Image(systemName: "music.note").font(.system(size: 54, weight: .bold)).foregroundStyle(.white.opacity(0.8)))
                    }
                }
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: player.palette.shadow.opacity(0.8), radius: 30, y: 14)
            .shadow(color: player.palette.primary.opacity(0.25), radius: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text(player.title.isEmpty ? "Encore" : player.title)
                    .font(Theme.Fonts.display(20))
                    .lineLimit(2)
                Text(player.author)
                    .font(Theme.Fonts.title(14))
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - Plain lyrics, messages and the info chip

/// Lyrics without timings: a slow, gentle scroll.
private struct PlainLyricsView: View {
    let lines: [String]

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 10) {
                Text("UNSYNCED LYRICS")
                    .font(.system(size: 10.5, weight: .heavy, design: .rounded))
                    .tracking(1)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .padding(.bottom, 8)
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.vertical, 40)
            .frame(maxWidth: .infinity)
        }
        .mask(LinearGradient(stops: [
            .init(color: .clear, location: 0), .init(color: .black, location: 0.12),
            .init(color: .black, location: 0.85), .init(color: .clear, location: 1),
        ], startPoint: .top, endPoint: .bottom))
    }
}

private struct LyricsMessage: View {
    let symbol: String
    let title: String
    var subtitle: String?
    var pulsing = false
    var retry: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(Theme.signature)
                .symbolEffect(.pulse, isActive: pulsing)
            Text(title).font(Theme.Fonts.display(20))
            if let subtitle {
                Text(subtitle).font(Theme.Fonts.body(13.5)).foregroundStyle(Theme.Palette.textSecondary)
            }
            if let retry {
                Button("Try Again", action: retry).buttonStyle(.bordered).padding(.top, 4)
            }
        }
        .padding(26)
        .encoreGlass(cornerRadius: 20)
    }
}

/// Top-bar chip for lyrics styles: where the lyrics came from, plus a timing
/// nudge for when they run early or late.
struct LyricsInfoChip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let lyrics = model.lyrics
        if let source = lyrics.source {
            HStack(spacing: 6) {
                Image(systemName: "quote.bubble.fill").foregroundStyle(model.player.palette.primary)
                Text(source == .demo ? "Sample lyrics" : "Lyrics \u{00B7} \(source.rawValue)")
                    .font(.system(size: 11.5, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.Palette.textSecondary)
                Divider().frame(height: 12)
                Button { lyrics.offset -= 0.25 } label: { Image(systemName: "minus") }
                    .help("Show lyrics earlier")
                Text(String(format: "%+.2fs", lyrics.offset))
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(lyrics.offset == 0 ? Theme.Palette.textTertiary : .white)
                    .onTapGesture { lyrics.offset = 0 }
                Button { lyrics.offset += 0.25 } label: { Image(systemName: "plus") }
                    .help("Show lyrics later")
            }
            .buttonStyle(.plain)
            .font(.system(size: 10, weight: .bold))
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(Capsule().fill(.black.opacity(0.28)).overlay(Capsule().strokeBorder(Theme.Palette.stroke)))
            .fixedSize()
        }
    }
}

// MARK: - Flow layout

/// Wraps its children like words in a paragraph, centring each row.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: min(width, proposal.width ?? width), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(width: bounds.width, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX + (bounds.width - row.width) / 2
            for i in row.items {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            let extra = rows[rows.count - 1].items.isEmpty ? size.width : size.width + spacing
            if rows[rows.count - 1].width + extra > width, !rows[rows.count - 1].items.isEmpty {
                rows.append(Row())
            }
            let row = rows.count - 1
            rows[row].width += rows[row].items.isEmpty ? size.width : size.width + spacing
            rows[row].height = max(rows[row].height, size.height)
            rows[row].items.append(i)
        }
        return rows
    }
}
