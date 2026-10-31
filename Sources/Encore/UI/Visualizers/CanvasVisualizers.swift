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

    // MARK: Halo — the artwork, ringed by soft liquid rings of light.

    static func halo(_ ctx: inout GraphicsContext, size: CGSize, engine e: VisualizerEngine, state s: CanvasVizState,
                     artwork: NSImage?, time t: Double, compact: Bool) {
        let w = size.width, h = size.height
        let cx = w / 2, cy = compact ? h / 2 : h * 0.43
        let base = min(w, h) * (compact ? 0.26 : 0.17)
        let R = base * (1 + Double(e.bass) * 0.05)
        let center = CGPoint(x: cx, y: cy)

        // Ambient bloom behind everything.
        var glow = ctx
        glow.blendMode = .plusLighter
        glow.fill(Path(CGRect(origin: .zero, size: size)), with: .radialGradient(
            Gradient(stops: [
                .init(color: s.colors[1].color(0.20 + Double(e.level) * 0.25), location: 0),
                .init(color: s.colors[2].color(0.07), location: 0.5),
                .init(color: .clear, location: 1),
            ]), center: center, startRadius: R * 0.5, endRadius: R * 3.6))

        // Three liquid rings, each a smooth closed curve whose radius follows the spectrum.
        let points = 120
        let vals = e.resampled(points / 2 + 1)
        func ring(_ k: Int) -> Path {
            let offset = R + 12 + Double(k) * (base * 0.16)
            let amp = base * (0.62 - Double(k) * 0.14)
            let spin = e.phase * (0.05 + Double(k) * 0.025) * (k % 2 == 0 ? 1 : -1)
            var pts: [CGPoint] = []
            for i in 0..<points {
                let idx = i <= points / 2 ? i : points - i
                let v = Double(vals[idx])
                let wobble = 0.06 * sin(Double(i) * 0.31 + t * (0.6 + Double(k) * 0.2))
                let r = offset + (v + wobble) * amp
                let a = -Double.pi / 2 + spin + Double(i) / Double(points) * .pi * 2
                pts.append(CGPoint(x: cx + cos(a) * r, y: cy + sin(a) * r))
            }
            var path = Path()
            let mid = { (p: CGPoint, q: CGPoint) in CGPoint(x: (p.x + q.x) / 2, y: (p.y + q.y) / 2) }
            path.move(to: mid(pts[points - 1], pts[0]))
            for i in 0..<points { path.addQuadCurve(to: mid(pts[i], pts[(i + 1) % points]), control: pts[i]) }
            path.closeSubpath()
            return path
        }
        let rings = (0..<3).map(ring)
        ctx.drawLayer { layer in
            layer.blendMode = .plusLighter
            layer.addFilter(.blur(radius: compact ? 6 : 14))
            for (k, path) in Array(rings.enumerated()).reversed() {
                layer.fill(path, with: .radialGradient(
                    Gradient(colors: [s.at(Double(k) * 0.3 + e.phase * 0.02).color(0), s.at(Double(k) * 0.3 + e.phase * 0.02).color(0.5)]),
                    center: center, startRadius: R, endRadius: R + base * 1.2))
            }
        }
        var lines = ctx
        lines.blendMode = .plusLighter
        for (k, path) in rings.enumerated() {
            let c = s.at(Double(k) * 0.3 + e.phase * 0.02)
            lines.stroke(path, with: .color(c.color(0.75 - Double(k) * 0.18)), lineWidth: compact ? 1.2 : 1.6)
        }

        // Artwork disc.
        let disc = CGRect(x: cx - R, y: cy - R, width: R * 2, height: R * 2)
        ctx.drawLayer { layer in
            layer.addFilter(.shadow(color: .black.opacity(0.5), radius: 26))
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
                Gradient(colors: [.white.opacity(0.10), .black.opacity(0.22)]),
                center: CGPoint(x: cx - R * 0.3, y: cy - R * 0.4), startRadius: R * 0.1, endRadius: R))
        }
        ctx.stroke(Path(ellipseIn: disc.insetBy(dx: -1, dy: -1)), with: .color(.white.opacity(0.18)), lineWidth: 1)
    }

    // MARK: Spectrum — a smooth, mirrored waveform of rounded bars with a soft glow.

    struct SpectrumOptions {
        var count = 76
        var baseline: CGFloat? = nil
        var maxHeight: CGFloat? = nil
        var padding: CGFloat? = nil
        var gap: CGFloat = 4
        var mini = false
        var reflect = true
        var peaks = true
        var mirroredVertical = false
    }

    static func spectrum(_ ctx: inout GraphicsContext, size: CGSize, engine e: VisualizerEngine, state s: CanvasVizState,
                         options o: SpectrumOptions = .init()) {
        let w = size.width, h = size.height
        let mid = o.baseline ?? h * 0.45
        let maxH = o.maxHeight ?? h * (o.mirroredVertical ? 0.24 : 0.34)
        let pad = o.padding ?? w * 0.1
        let span = w - pad * 2
        let bw = max(1, span / CGFloat(o.count) - o.gap)
        let vals = e.resampled(o.count, mirrored: true)

        func bars() -> [(CGRect, Double)] {
            (0..<o.count).map { i in
                let v = CGFloat(vals[i])
                let bh = max(bw * (o.mirroredVertical ? 0.6 : 1), v * maxH)
                let x = pad + CGFloat(i) * (bw + o.gap) + o.gap / 2
                let edge = abs(Double(i) / Double(max(1, o.count - 1)) * 2 - 1)
                let rect = o.mirroredVertical
                    ? CGRect(x: x, y: mid - bh, width: bw, height: bh * 2)
                    : CGRect(x: x, y: mid - bh, width: bw, height: bh)
                return (rect, edge)
            }
        }
        let shapes = bars()
        func shading(_ rect: CGRect, _ edge: Double) -> GraphicsContext.Shading {
            let top = s.at(0.34 + edge * 0.55 + e.phase * 0.015).color()
            let bottom = s.colors[0].color()
            return .linearGradient(Gradient(colors: o.mirroredVertical ? [top, bottom, top] : [top, bottom]),
                                   startPoint: CGPoint(x: rect.minX, y: rect.minY), endPoint: CGPoint(x: rect.minX, y: rect.maxY))
        }

        if !o.mini {
            var bloom = ctx
            bloom.blendMode = .plusLighter
            bloom.fill(Path(CGRect(origin: .zero, size: size)), with: .radialGradient(
                Gradient(colors: [s.colors[1].color(0.16 + Double(e.level) * 0.22), .clear]),
                center: CGPoint(x: w / 2, y: mid), startRadius: 10, endRadius: w * 0.55))
            // Soft glow pass.
            ctx.drawLayer { layer in
                layer.blendMode = .plusLighter
                layer.addFilter(.blur(radius: 12))
                layer.opacity = 0.7
                for (rect, edge) in shapes {
                    layer.fill(Path(roundedRect: rect, cornerRadius: bw / 2), with: shading(rect, edge))
                }
            }
        }
        for (rect, edge) in shapes {
            ctx.fill(Path(roundedRect: rect, cornerRadius: bw / 2), with: shading(rect, edge))
            if o.reflect && !o.mirroredVertical {
                let rh = rect.height * 0.5
                ctx.fill(Path(roundedRect: CGRect(x: rect.minX, y: mid + 4, width: bw, height: rh), cornerRadius: bw / 2),
                         with: .linearGradient(Gradient(colors: [s.colors[0].color(0.3), s.colors[0].color(0)]),
                                               startPoint: CGPoint(x: rect.minX, y: mid + 4), endPoint: CGPoint(x: rect.minX, y: mid + 4 + rh)))
            }
            if o.peaks && !o.mirroredVertical {
                let k = Int((edge * Double(VisualizerEngine.bandCount - 1)).rounded())
                let pk = CGFloat(e.peaks[k]) * maxH
                ctx.fill(Path(roundedRect: CGRect(x: rect.minX, y: mid - max(rect.height, pk) - 6, width: bw, height: 2), cornerRadius: 1),
                         with: .color(.white.opacity(0.45)))
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
                    .init(color: c.color(0.2), location: 0.45),
                    .init(color: c.color(0.3), location: 0.62),
                    .init(color: c.color(0), location: 1),
                ]), startPoint: CGPoint(x: 0, y: cy - amp), endPoint: CGPoint(x: 0, y: cy + amp * 0.6)))
            var crest = Path()
            smooth(&crest, top, move: true)
            g.stroke(crest, with: .color(c.color(0.55)), lineWidth: 1.2)
        }
        g.fill(Path(CGRect(x: 0, y: cy - 1, width: w, height: 2)), with: .linearGradient(
            Gradient(colors: [.clear, .white.opacity(0.05 + Double(e.level) * 0.12), .clear]),
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
