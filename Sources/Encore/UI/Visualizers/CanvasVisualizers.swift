import AppKit
import SwiftUI

/// Plain RGB triple used for fast colour interpolation inside `Canvas`.
struct RGB: Equatable {
    var r: Double, g: Double, b: Double

    init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }

    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
        r = Double(ns.redComponent); g = Double(ns.greenComponent); b = Double(ns.blueComponent)
    }

    func color(_ opacity: Double = 1) -> Color { Color(.sRGB, red: r, green: g, blue: b, opacity: opacity) }

    static func mix(_ a: RGB, _ b: RGB, _ t: Double) -> RGB {
        RGB(r: a.r + (b.r - a.r) * t, g: a.g + (b.g - a.g) * t, b: a.b + (b.b - a.b) * t)
    }
}

/// Per-view animation state: eased palette, particles and ridge history.
@MainActor
final class CanvasVizState {
    var colors: [RGB] = ArtworkPalette.brand.gradient.map(RGB.init)
    private var target: [RGB] = ArtworkPalette.brand.gradient.map(RGB.init)
    private var lastPalette: ArtworkPalette = .brand
    private var last = CACurrentMediaTime()
    private(set) var dt: Double = 1.0 / 60

    struct Particle { var a: Double; var r: Double; var s: Double; var c: Double; var z: Double }
    var particles: [Particle] = []
    var ridge: [[Float]] = []
    private var ridgeClock: Double = 0

    func step(palette: ArtworkPalette, engine: VisualizerEngine) {
        let now = CACurrentMediaTime()
        dt = min(0.1, max(0, now - last))
        last = now
        if palette != lastPalette { lastPalette = palette; target = palette.gradient.map(RGB.init) }
        let k = 1 - exp(-dt * 3)
        for i in 0..<3 { colors[i] = RGB.mix(colors[i], target[i], k) }
        ridgeClock += dt
        if ridgeClock > 0.055 {
            ridgeClock = 0
            ridge.append(engine.bands)
            if ridge.count > 40 { ridge.removeFirst() }
        }
    }

    /// Smoothly cycles through the three palette colours (0…1 wraps).
    func at(_ f: Double) -> RGB {
        let t = f - floor(f), s = t * 3
        let i = Int(s) % 3, j = (i + 1) % 3
        return RGB.mix(colors[i], colors[j], s - floor(s))
    }
}

/// Draws the 2D visualisers into a SwiftUI `GraphicsContext`.
@MainActor
enum CanvasPainter {

    // MARK: Halo — artwork ringed by radial bars, an echo ring and orbiting sparks.

    static func halo(_ ctx: inout GraphicsContext, size: CGSize, engine e: VisualizerEngine, state s: CanvasVizState,
                     artwork: NSImage?, time t: Double, compact: Bool) {
        let w = size.width, h = size.height
        let cx = w / 2, cy = compact ? h / 2 : h * 0.42
        let base = min(w, h) * (compact ? 0.24 : 0.17)
        let R = base * (1 + Double(e.bass) * 0.07)
        let rot = e.phase * 0.12

        var glowCtx = ctx
        glowCtx.blendMode = .plusLighter
        glowCtx.fill(Path(CGRect(origin: .zero, size: size)), with: .radialGradient(
            Gradient(stops: [
                .init(color: s.colors[1].color(0.22 + Double(e.bass) * 0.25), location: 0),
                .init(color: s.colors[2].color(0.08), location: 0.45),
                .init(color: .clear, location: 1),
            ]), center: CGPoint(x: cx, y: cy), startRadius: R * 0.6, endRadius: R * 3.2))

        let count = 144
        let vals = e.resampled(count / 2 + 1)
        for pass in 0..<2 {
            for i in 0..<count {
                let k = i <= count / 2 ? i : count - i
                let v = Double(vals[k])
                let a = -Double.pi / 2 + rot + Double(i) / Double(count) * .pi * 2
                let r0 = R + 10, len = 4 + v * base * 1.15
                var p = Path()
                p.move(to: CGPoint(x: cx + cos(a) * r0, y: cy + sin(a) * r0))
                p.addLine(to: CGPoint(x: cx + cos(a) * (r0 + len), y: cy + sin(a) * (r0 + len)))
                let c = s.at(Double(i) / Double(count) + e.phase * 0.05)
                glowCtx.stroke(p, with: .color(c.color(pass == 0 ? 0.14 : 0.92)),
                               style: StrokeStyle(lineWidth: pass == 0 ? 7 : 2.4, lineCap: .round))
            }
        }

        // Inner echo ring.
        var echo = Path()
        for i in 0...count {
            let k = i <= count / 2 ? i : count - i
            let v = Double(vals[k])
            let a = -Double.pi / 2 - rot * 0.6 + Double(i) / Double(count) * .pi * 2
            let r = R - 14 - v * base * 0.18
            let pt = CGPoint(x: cx + cos(a) * r, y: cy + sin(a) * r)
            i == 0 ? echo.move(to: pt) : echo.addLine(to: pt)
        }
        glowCtx.stroke(echo, with: .color(s.colors[0].color(0.35)), lineWidth: 1.5)

        // Orbiting sparks with tails.
        if !compact {
            for sIdx in 0..<3 {
                let a0 = t * (0.4 + Double(sIdx) * 0.17) + Double(sIdx) * 2.1
                let rr = R * (1.95 + Double(sIdx) * 0.22 + Double(e.bass) * 0.2)
                for k in 0..<14 {
                    let aa = a0 - Double(k) * 0.035
                    let rad = 2.2 * (1 - Double(k) / 16)
                    let rect = CGRect(x: cx + cos(aa) * rr - rad, y: cy + sin(aa) * rr - rad, width: rad * 2, height: rad * 2)
                    glowCtx.fill(Path(ellipseIn: rect), with: .color(s.at(Double(sIdx) / 3).color((1 - Double(k) / 14) * 0.55)))
                }
            }
        }

        // Artwork disc.
        let disc = CGRect(x: cx - R, y: cy - R, width: R * 2, height: R * 2)
        ctx.drawLayer { layer in
            layer.addFilter(.shadow(color: .black.opacity(0.55), radius: 30))
            layer.fill(Path(ellipseIn: disc), with: .color(.black))
        }
        ctx.drawLayer { layer in
            layer.clip(to: Path(ellipseIn: disc))
            if let artwork {
                let ih = R * 2, iw = ih * max(1, artwork.size.width / max(1, artwork.size.height))
                layer.draw(Image(nsImage: artwork), in: CGRect(x: cx - iw / 2, y: cy - ih / 2, width: iw, height: ih))
            } else {
                layer.fill(Path(disc), with: .linearGradient(Gradient(colors: s.colors.map { $0.color() }),
                                                            startPoint: disc.origin, endPoint: CGPoint(x: disc.maxX, y: disc.maxY)))
            }
            layer.fill(Path(disc), with: .radialGradient(
                Gradient(colors: [.white.opacity(0.12), .black.opacity(0.25)]),
                center: CGPoint(x: cx - R * 0.3, y: cy - R * 0.4), startRadius: R * 0.1, endRadius: R))
        }
        let rim = Gradient(colors: [s.colors[0].color(), s.colors[1].color(), s.colors[2].color(), s.colors[0].color()])
        ctx.stroke(Path(ellipseIn: disc.insetBy(dx: -1.5, dy: -1.5)),
                   with: .conicGradient(rim, center: CGPoint(x: cx, y: cy), angle: .radians(e.phase * 0.8)),
                   lineWidth: 3)
    }

    // MARK: Spectrum — mirrored capsule bars with glow, reflections and falling peaks.

    struct SpectrumOptions {
        var count = 76
        var baseline: CGFloat? = nil
        var maxHeight: CGFloat? = nil
        var padding: CGFloat? = nil
        var gap: CGFloat = 4
        var mini = false
        var reflect = true
        var peaks = true
    }

    static func spectrum(_ ctx: inout GraphicsContext, size: CGSize, engine e: VisualizerEngine, state s: CanvasVizState,
                         options o: SpectrumOptions = .init()) {
        let w = size.width, h = size.height
        let mid = o.baseline ?? h * 0.5
        let maxH = o.maxHeight ?? h * 0.34
        let pad = o.padding ?? w * 0.08
        let span = w - pad * 2
        let bw = max(1, span / CGFloat(o.count) - o.gap)
        let vals = e.resampled(o.count, mirrored: true)

        if !o.mini {
            var glow = ctx
            glow.blendMode = .plusLighter
            glow.fill(Path(CGRect(origin: .zero, size: size)), with: .radialGradient(
                Gradient(colors: [s.colors[1].color(0.18 + Double(e.bass) * 0.2), .clear]),
                center: CGPoint(x: w / 2, y: mid), startRadius: 10, endRadius: w * 0.5))
        }
        for i in 0..<o.count {
            let v = max(0.02, CGFloat(vals[i]))
            let bh = max(bw, v * maxH)
            let x = pad + CGFloat(i) * (bw + o.gap) + o.gap / 2
            let edge = abs(Double(i) / Double(max(1, o.count - 1)) * 2 - 1)
            let shading = GraphicsContext.Shading.linearGradient(
                Gradient(colors: [s.at(0.34 + edge * 0.6 + e.phase * 0.02).color(), s.colors[0].color()]),
                startPoint: CGPoint(x: x, y: mid - bh), endPoint: CGPoint(x: x, y: mid))
            if !o.mini {
                var halo = ctx
                halo.opacity = 0.22
                halo.fill(Path(roundedRect: CGRect(x: x - 2, y: mid - bh - 2, width: bw + 4, height: bh + 4), cornerRadius: (bw + 4) / 2), with: shading)
            }
            ctx.fill(Path(roundedRect: CGRect(x: x, y: mid - bh, width: bw, height: bh), cornerRadius: bw / 2), with: shading)
            if o.reflect {
                let rh = bh * 0.55
                ctx.fill(Path(roundedRect: CGRect(x: x, y: mid + 4, width: bw, height: rh), cornerRadius: bw / 2),
                         with: .linearGradient(Gradient(colors: [s.colors[0].color(0.32), s.colors[0].color(0)]),
                                               startPoint: CGPoint(x: x, y: mid + 4), endPoint: CGPoint(x: x, y: mid + 4 + rh)))
            }
            if o.peaks {
                let k = Int((edge * Double(VisualizerEngine.bandCount - 1)).rounded())
                let pk = CGFloat(e.peaks[k]) * maxH
                ctx.fill(Path(roundedRect: CGRect(x: x, y: mid - max(bh, pk) - 7, width: bw, height: 3), cornerRadius: 1.5),
                         with: .color(.white.opacity(0.85)))
            }
        }
    }

    // MARK: Waves — layered aurora ribbons that swell with the music.

    static func waves(_ ctx: inout GraphicsContext, size: CGSize, engine e: VisualizerEngine, state s: CanvasVizState, time t: Double) {
        let w = size.width, h = size.height
        let cy = h * 0.44
        var g = ctx
        g.blendMode = .plusLighter
        let n = VisualizerEngine.bandCount
        for L in 0..<5 {
            let c = s.at(Double(L) / 5 + e.phase * 0.03)
            let amp = h * (0.1 + Double(L) * 0.025)
            var top: [CGPoint] = [], bottom: [CGPoint] = []
            var x: CGFloat = 0
            while x <= w {
                let u = Double(x / w)
                let env = pow(sin(.pi * u), 1.6)
                let bi = min(n - 1, Int(abs(u * 2 - 1) * Double(n - 1) * 0.7))
                let energy = Double(e.bands[bi]) * 0.7 + Double(e.level) * 0.5
                let sv = sin(u * (6 + Double(L) * 1.7) + t * (1.1 + Double(L) * 0.23) + Double(L)) * 0.6
                       + sin(u * (13 + Double(L) * 3) - t * (1.7 + Double(L) * 0.3)) * 0.4
                let y = sv * amp * env * (0.25 + energy * 1.4)
                top.append(CGPoint(x: x, y: cy - abs(y) - env * 3))
                bottom.append(CGPoint(x: x, y: cy + abs(y) * 0.55 + env * 2))
                x += 6
            }
            var ribbon = Path()
            smooth(&ribbon, top, move: true)
            smooth(&ribbon, bottom.reversed(), move: false)
            ribbon.closeSubpath()
            g.fill(ribbon, with: .linearGradient(
                Gradient(stops: [
                    .init(color: c.color(0), location: 0),
                    .init(color: c.color(0.32), location: 0.45),
                    .init(color: c.color(0.5), location: 0.62),
                    .init(color: c.color(0), location: 1),
                ]), startPoint: CGPoint(x: 0, y: cy - amp), endPoint: CGPoint(x: 0, y: cy + amp * 0.6)))
            var crest = Path()
            smooth(&crest, top, move: true)
            g.stroke(crest, with: .color(c.color(0.75)), lineWidth: 1.4)
        }
        g.fill(Path(CGRect(x: 0, y: cy - 1, width: w, height: 2)), with: .linearGradient(
            Gradient(colors: [.clear, .white.opacity(0.12 + Double(e.level) * 0.25), .clear]),
            startPoint: CGPoint(x: 0, y: cy), endPoint: CGPoint(x: w, y: cy)))
    }

    private static func smooth(_ path: inout Path, _ pts: [CGPoint], move: Bool) {
        guard let first = pts.first else { return }
        move ? path.move(to: first) : path.addLine(to: first)
        for i in 1..<pts.count {
            let p = pts[i - 1], q = pts[i]
            path.addQuadCurve(to: CGPoint(x: (p.x + q.x) / 2, y: (p.y + q.y) / 2), control: p)
        }
        if let last = pts.last { path.addLine(to: last) }
    }

    // MARK: Nebula — particles streaming out of a pulsing core.

    static func nebula(_ ctx: inout GraphicsContext, size: CGSize, engine e: VisualizerEngine, state s: CanvasVizState) {
        let w = size.width, h = size.height
        let cx = w / 2, cy = h * 0.42, r0 = min(w, h) * 0.06
        let dt = s.dt
        if s.particles.count < 420 {
            for _ in 0..<(420 - s.particles.count) {
                s.particles.append(.init(a: .random(in: 0...(2 * .pi)), r: r0 * .random(in: 0.5...1.5),
                                         s: .random(in: 0.4...1.4), c: .random(in: 0...1), z: .random(in: 0...1)))
            }
        }
        var g = ctx
        g.blendMode = .plusLighter
        let n = VisualizerEngine.bandCount
        let limit = max(w, h) * 0.62
        for i in s.particles.indices {
            var p = s.particles[i]
            let band = Double(e.bands[Int(p.c * Double(n - 1) * 0.8)])
            p.r += (20 + p.s * 60) * (0.25 + Double(e.level) * 2.6 + band) * dt
            p.a += (0.15 + Double(e.bass) * 0.9) * dt * (p.z > 0.5 ? 1 : -1) * (40 / (p.r + 40))
            let life = 1 - p.r / limit
            if life <= 0 {
                p.r = r0 * .random(in: 0.4...1.2); p.a = .random(in: 0...(2 * .pi))
                s.particles[i] = p
                continue
            }
            s.particles[i] = p
            let x = cx + cos(p.a) * p.r, y = cy + sin(p.a) * p.r * 0.78
            let size = (0.8 + p.z * 1.8) * (1 + band)
            // Short motion streak instead of trails: cheap and crisp.
            let tail = min(18, (20 + p.s * 60) * (0.25 + Double(e.level) * 2.6 + band) * 0.05)
            var streak = Path()
            streak.move(to: CGPoint(x: x, y: y))
            streak.addLine(to: CGPoint(x: cx + cos(p.a) * (p.r - tail), y: cy + sin(p.a) * (p.r - tail) * 0.78))
            let color = s.at(p.c + e.phase * 0.04).color(min(1, life * 1.4) * (0.35 + band * 0.65))
            g.stroke(streak, with: .color(color), style: StrokeStyle(lineWidth: size, lineCap: .round))
        }
        let orbR = r0 * (1.6 + Double(e.bass) * 1.4)
        g.fill(Path(ellipseIn: CGRect(x: cx - orbR * 3, y: cy - orbR * 3, width: orbR * 6, height: orbR * 6)), with: .radialGradient(
            Gradient(stops: [
                .init(color: .white.opacity(0.95), location: 0),
                .init(color: s.colors[0].color(0.9), location: 0.12),
                .init(color: s.colors[1].color(0.35), location: 0.4),
                .init(color: .clear, location: 1),
            ]), center: CGPoint(x: cx, y: cy), startRadius: 0, endRadius: orbR * 3))
    }

    // MARK: Ridgeline — stacked spectrum lines receding into the distance.

    static func ridgeline(_ ctx: inout GraphicsContext, size: CGSize, engine e: VisualizerEngine, state s: CanvasVizState) {
        let rows = s.ridge.count
        guard rows > 1 else { return }
        let w = size.width, h = size.height
        let top = h * 0.1, bottom = h * 0.7, cx = w / 2
        let n = VisualizerEngine.bandCount
        let fill = Color(red: 0.035, green: 0.027, blue: 0.055).opacity(0.94)
        for r in 0..<rows {
            let spec = s.ridge[r]
            let depth = Double(r) / Double(rows - 1)
            let y0 = top + (bottom - top) * pow(depth, 1.25)
            let half = w * (0.18 + depth * 0.3), amp = h * (0.05 + depth * 0.17)
            var pts: [CGPoint] = []
            let m = 90
            for i in 0...m {
                let u = Double(i) / Double(m)
                let d = abs(u * 2 - 1)
                let bi = min(n - 1, Int(d * Double(n - 1)))
                let env = pow(cos(d * .pi / 2), 1.5)
                pts.append(CGPoint(x: cx - half + u * half * 2, y: y0 - Double(spec[bi]) * amp * (0.35 + env * 1.2)))
            }
            var area = Path()
            area.move(to: CGPoint(x: pts[0].x, y: y0 + 2))
            pts.forEach { area.addLine(to: $0) }
            area.addLine(to: CGPoint(x: pts[m].x, y: y0 + 2))
            area.closeSubpath()
            ctx.fill(area, with: .color(fill))
            var line = Path()
            line.addLines(pts)
            let c = s.at(depth * 0.9 + e.phase * 0.03)
            ctx.stroke(line, with: .color(c.color(0.15 + depth * 0.85)), lineWidth: 0.8 + depth * 1.8)
            if r == rows - 1 {
                var glow = ctx
                glow.blendMode = .plusLighter
                glow.stroke(line, with: .color(c.color(0.35)), lineWidth: 7)
            }
        }
    }
}
