import SwiftUI

/// The native layer of Night Drive: the car cruising down the road (the road,
/// sunset and streetlights are rendered by the Metal scene underneath) and a
/// vintage car radio showing the song with old-school LED EQ bars.
struct DriveOverlay: View {
    var compact = false
    @Environment(AppModel.self) private var model

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .top) {
                TimelineView(.animation) { timeline in
                    Canvas { ctx, canvasSize in
                        _ = timeline.date
                        model.visualizer.tick()
                        let e = model.visualizer
                        let carWidth = min(canvasSize.width * 0.19, canvasSize.height * 0.32)
                        let t = timeline.date.timeIntervalSinceReferenceDate
                        CarPainter.draw(&ctx, center: CGPoint(x: canvasSize.width / 2, y: canvasSize.height * 0.64),
                                        width: carWidth, bass: Double(e.bassNorm), beat: Double(e.beat),
                                        sway: sin(t * 0.37) * 0.6 + sin(t * 0.13) * 0.4,
                                        paint: model.player.palette)
                    }
                }
                .allowsHitTesting(false)

                if !compact {
                    RetroRadio()
                        .frame(width: min(520, max(340, size.width * 0.42)))
                        .padding(.top, max(64, size.height * 0.09))
                }
            }
            .frame(width: size.width, height: size.height)
        }
    }
}

// MARK: - Car

/// A sports car seen from behind, drawn with vector paths (geometry in units of the car's width).
@MainActor
enum CarPainter {
    static func draw(_ ctx: inout GraphicsContext, center: CGPoint, width s: CGFloat,
                     bass: Double, beat: Double, sway: Double, paint palette: ArtworkPalette) {
        let lift = -bass * 0.008 * s
        var g = ctx
        g.translateBy(x: center.x, y: center.y + lift)
        g.rotate(by: .radians(sway * 0.02))

        func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: -y * s) }
        /// Each element: (x, y) for a line, or (x, y, c1x, c1y, c2x, c2y) for a cubic curve to (x, y).
        func shape(_ pts: [[CGFloat]]) -> Path {
            var path = Path()
            for (i, p) in pts.enumerated() {
                if p.count == 2 {
                    i == 0 ? path.move(to: P(p[0], p[1])) : path.addLine(to: P(p[0], p[1]))
                } else {
                    path.addCurve(to: P(p[0], p[1]), control1: P(p[2], p[3]), control2: P(p[4], p[5]))
                }
            }
            path.closeSubpath()
            return path
        }
        func rrect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> Path {
            Path(roundedRect: CGRect(x: x * s, y: -y * s, width: w * s, height: h * s), cornerRadius: r * s)
        }

        // Paint colour: a deep, glossy version of the artwork's primary colour.
        let base = RGB(palette.primary)
        let paint = RGB.mix(base, RGB(r: 0.12, g: 0.02, b: 0.08), 0.55)
        let paintHi = RGB.mix(base, RGB(r: 1, g: 1, b: 1), 0.05)

        // Ground shadow
        g.drawLayer { l in
            l.addFilter(.blur(radius: 0.03 * s))
            l.fill(Path(ellipseIn: CGRect(x: -0.6 * s, y: -0.04 * s, width: 1.2 * s, height: 0.1 * s)), with: .color(.black.opacity(0.75)))
        }
        // Tyres
        for x: CGFloat in [-0.49, 0.33] {
            g.fill(Path(roundedRect: CGRect(x: x * s, y: -0.19 * s, width: 0.16 * s, height: 0.19 * s), cornerRadius: 0.025 * s), with: .color(Color(red: 0.03, green: 0.024, blue: 0.045)))
        }
        // Lower body with wide hips
        let body = shape([[-0.5, 0.1], [-0.53, 0.24, -0.52, 0.16, -0.53, 0.2], [-0.47, 0.5, -0.53, 0.38, -0.5, 0.46],
                          [-0.3, 0.6, -0.44, 0.55, -0.37, 0.59], [0.3, 0.6], [0.47, 0.5, 0.37, 0.59, 0.44, 0.55],
                          [0.53, 0.24, 0.5, 0.46, 0.53, 0.38], [0.5, 0.1, 0.53, 0.2, 0.52, 0.16]])
        g.fill(body, with: .linearGradient(Gradient(stops: [
            .init(color: paintHi.color(), location: 0), .init(color: paint.color(), location: 0.45),
            .init(color: Color(red: 0.035, green: 0.024, blue: 0.06), location: 1),
        ]), startPoint: P(0, 0.62), endPoint: P(0, 0)))
        // Sunset reflection on the shoulders
        g.fill(shape([[-0.47, 0.5], [-0.3, 0.6, -0.44, 0.55, -0.37, 0.59], [0.3, 0.6], [0.47, 0.5, 0.37, 0.59, 0.44, 0.55], [0.44, 0.47], [-0.44, 0.47]]),
               with: .linearGradient(Gradient(colors: [Color(red: 1, green: 0.47, blue: 0.63).opacity(0), Color(red: 1, green: 0.55, blue: 0.67).opacity(0.35), Color(red: 1, green: 0.47, blue: 0.63).opacity(0)]),
                                     startPoint: P(0, 0.6), endPoint: P(0, 0.45)))
        // Cabin and rear window
        g.fill(shape([[-0.33, 0.6], [-0.24, 0.83, -0.31, 0.72, -0.28, 0.8], [0.24, 0.83, -0.1, 0.87, 0.1, 0.87], [0.33, 0.6, 0.28, 0.8, 0.31, 0.72]]),
               with: .color(paint.color()))
        g.fill(shape([[-0.28, 0.62], [-0.21, 0.79, -0.26, 0.71, -0.24, 0.77], [0.21, 0.79, -0.08, 0.83, 0.08, 0.83], [0.28, 0.62, 0.24, 0.77, 0.26, 0.71]]),
               with: .linearGradient(Gradient(colors: [Color(red: 0.16, green: 0.06, blue: 0.21), Color(red: 0.045, green: 0.027, blue: 0.08), Color(red: 0.08, green: 0.035, blue: 0.11)]),
                                     startPoint: P(0, 0.86), endPoint: P(0, 0.6)))
        var glint = Path()
        glint.move(to: P(-0.15, 0.66)); glint.addLine(to: P(-0.05, 0.8))
        g.stroke(glint, with: .color(Color(red: 1, green: 0.6, blue: 0.8).opacity(0.25)), lineWidth: 0.004 * s)
        // Spoiler
        let dark = Color(red: 0.05, green: 0.035, blue: 0.07)
        g.fill(rrect(-0.46, 0.635, 0.92, 0.03, 0.01), with: .color(dark))
        g.fill(Path(CGRect(x: -0.3 * s, y: -0.61 * s, width: 0.025 * s, height: 0.03 * s)), with: .color(dark))
        g.fill(Path(CGRect(x: 0.275 * s, y: -0.61 * s, width: 0.025 * s, height: 0.03 * s)), with: .color(dark))
        // Full-width tail-light bar, glowing with the bass
        let tl = 0.75 + 0.6 * bass + 0.4 * beat
        let red = Color(red: 1, green: 0.16, blue: 0.24)
        g.drawLayer { l in
            l.addFilter(.shadow(color: red.opacity(0.95), radius: 0.03 * s * tl))
            l.opacity = min(1, 0.6 + 0.4 * tl)
            l.fill(rrect(-0.47, 0.47, 0.94, 0.028, 0.014), with: .linearGradient(
                Gradient(colors: [red, Color(red: 1, green: 0.42, blue: 0.42), red]), startPoint: P(-0.5, 0), endPoint: P(0.5, 0)))
        }
        for x: CGFloat in [-0.48, 0.36] {
            g.fill(rrect(x, 0.475, 0.12, 0.045, 0.015), with: .color(Color(red: 1, green: 0.24, blue: 0.27).opacity(min(1, 0.7 + 0.3 * tl))))
        }
        // Plate
        g.fill(rrect(-0.09, 0.36, 0.18, 0.06, 0.008), with: .color(Color(red: 0.91, green: 0.89, blue: 0.94)))
        g.draw(Text("ENCORE").font(.system(size: 0.042 * s, weight: .bold, design: .rounded)).foregroundColor(Color(red: 0.1, green: 0.08, blue: 0.14)),
               at: P(0, 0.33))
        // Diffuser and exhausts (they flare on beats)
        g.fill(shape([[-0.36, 0.08], [-0.3, 0.2], [0.3, 0.2], [0.36, 0.08]]), with: .color(Color(red: 0.024, green: 0.02, blue: 0.035)))
        for fx: CGFloat in [-0.18, -0.06, 0.06, 0.18] {
            var fin = Path(); fin.move(to: P(fx, 0.09)); fin.addLine(to: P(fx, 0.19))
            g.stroke(fin, with: .color(.white.opacity(0.06)), lineWidth: 0.006 * s)
        }
        for sx: CGFloat in [-1, 1] {
            g.fill(Path(ellipseIn: CGRect(x: (sx * 0.26 - 0.035) * s, y: (-0.13 - 0.026) * s, width: 0.07 * s, height: 0.052 * s)),
                   with: .color(Color(red: 0.74, green: 0.71, blue: 0.78)))
            g.fill(Path(ellipseIn: CGRect(x: (sx * 0.26 - 0.024) * s, y: (-0.13 - 0.017) * s, width: 0.048 * s, height: 0.034 * s)),
                   with: .color(Color(red: (40 + 200 * beat) / 255, green: (20 + 80 * beat) / 255, blue: 30 / 255)))
        }
        // Tail-light glow on the road
        g.drawLayer { l in
            l.blendMode = .plusLighter
            l.addFilter(.blur(radius: 0.03 * s))
            l.fill(Path(CGRect(x: -0.45 * s, y: 0.01 * s, width: 0.9 * s, height: 0.07 * s)), with: .color(red.opacity(0.18 * tl)))
        }
    }
}

// MARK: - Radio

/// A chrome-bezel car radio: a glowing VFD-style display scrolling the song,
/// and a 16-band segmented LED equaliser with peak holds.
struct RetroRadio: View {
    @Environment(AppModel.self) private var model
    @State private var meter = PeakMeter()

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = w * 0.2
            ZStack {
                RoundedRectangle(cornerRadius: h * 0.18, style: .continuous)
                    .fill(LinearGradient(stops: [
                        .init(color: Color(white: 0.86), location: 0), .init(color: Color(white: 0.56), location: 0.08),
                        .init(color: Color(red: 0.23, green: 0.21, blue: 0.26), location: 0.5),
                        .init(color: Color(white: 0.56), location: 0.92), .init(color: Color(white: 0.86), location: 1),
                    ], startPoint: .top, endPoint: .bottom))
                    .shadow(color: .black.opacity(0.6), radius: 18, y: 8)
                RoundedRectangle(cornerRadius: h * 0.12, style: .continuous)
                    .fill(Color(red: 0.08, green: 0.07, blue: 0.1))
                    .padding(h * 0.08)
                HStack(spacing: h * 0.12) {
                    knob(h)
                    display(h)
                    equaliser(h)
                    knob(h)
                }
                .padding(.horizontal, h * 0.2)
            }
            .frame(width: w, height: h)
        }
        .aspectRatio(5, contentMode: .fit)
    }

    private func knob(_ h: CGFloat) -> some View {
        Circle()
            .fill(RadialGradient(colors: [Color(white: 0.95), Color(white: 0.55), Color(white: 0.17)],
                                 center: UnitPoint(x: 0.35, y: 0.3), startRadius: 1, endRadius: h * 0.3))
            .overlay(Circle().strokeBorder(.black.opacity(0.5), lineWidth: 1))
            .frame(width: h * 0.48, height: h * 0.48)
    }

    private func display(_ h: CGFloat) -> some View {
        let player = model.player
        let text = "\(player.title.isEmpty ? "Encore" : player.title)   •   \(player.author.isEmpty ? "Now playing" : player.author)   •   "
        let glow = Color(red: 0.49, green: 1, blue: 0.88)
        return TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            GeometryReader { g in
                let fontSize = h * 0.25
                let charWidth = fontSize * 0.6
                let textWidth = CGFloat(text.count) * charWidth
                let offset = CGFloat((t * 38).truncatingRemainder(dividingBy: Double(max(textWidth, 1))))
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 4).fill(Color(red: 0.016, green: 0.067, blue: 0.06))
                    HStack(spacing: 0) {
                        Text(text).fixedSize()
                        Text(text).fixedSize()
                    }
                    .font(.system(size: fontSize, weight: .semibold, design: .monospaced))
                    .foregroundStyle(glow)
                    .shadow(color: glow.opacity(0.9), radius: 5)
                    .offset(x: 8 - offset, y: g.size.height * 0.16)
                    Text("FM 101.7   ST   \(formatTime(player.position(at: timeline.date)))")
                        .font(.system(size: h * 0.12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color(red: 0.25, green: 0.75, blue: 0.64))
                        .shadow(color: glow.opacity(0.5), radius: 3)
                        .offset(x: 8, y: g.size.height * 0.68)
                }
                .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
        .frame(height: h * 0.6)
        .clipped()
        .frame(maxWidth: .infinity)
        .layoutPriority(1)
    }

    private func equaliser(_ h: CGFloat) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
            Canvas { ctx, size in
                let e = model.visualizer
                e.tick()
                let bands = e.resampled(16)
                let now = timeline.date
                let dt = Float(min(0.1, now.timeIntervalSince(meter.lastTick)))
                meter.lastTick = now
                ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 4), with: .color(Color(red: 0.03, green: 0.025, blue: 0.035)))
                let segs = 10
                let bw = (size.width - 10) / 16, sh = (size.height - 8) / CGFloat(segs)
                var newPeaks = meter.peaks
                for b in 0..<16 {
                    let v = min(1, bands[b] * 1.1)
                    newPeaks[b] = max(v, newPeaks[b] - dt * 0.6)
                    let lit = Int((v * Float(segs)).rounded())
                    let pk = Int((newPeaks[b] * Float(segs)).rounded())
                    for sgi in 0..<segs {
                        let on = sgi < lit || sgi == pk - 1
                        let c: Color = sgi < 6 ? Color(red: 0.24, green: 1, blue: 0.47) : sgi < 8 ? Color(red: 1, green: 0.78, blue: 0.16) : Color(red: 1, green: 0.24, blue: 0.2)
                        let rect = CGRect(x: 5 + CGFloat(b) * bw + 1, y: size.height - 4 - CGFloat(sgi + 1) * sh + 1, width: bw - 2, height: sh - 2)
                        if on {
                            var lit = ctx
                            lit.addFilter(.shadow(color: c, radius: 3))
                            lit.fill(Path(rect), with: .color(c))
                        } else {
                            ctx.fill(Path(rect), with: .color(c.opacity(0.08)))
                        }
                    }
                }
                meter.peaks = newPeaks
            }
        }
        .frame(width: h * 1.9, height: h * 0.6)
    }
}

/// Peak-hold state for the radio's LED meter (a reference type, so updating it
/// while drawing doesn't invalidate the view).
final class PeakMeter {
    var peaks = [Float](repeating: 0, count: 16)
    var lastTick = Date()
}
