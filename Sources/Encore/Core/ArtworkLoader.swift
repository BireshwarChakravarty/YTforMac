import AppKit
import SwiftUI

/// Colours extracted from the current artwork; drives the ambient background
/// and the visualisers.
struct ArtworkPalette: Equatable {
    var primary: Color
    var secondary: Color
    var tertiary: Color
    var shadow: Color

    static let brand = ArtworkPalette(
        primary: Theme.Palette.coral,
        secondary: Theme.Palette.magenta,
        tertiary: Theme.Palette.violet,
        shadow: Color(red: 0.08, green: 0.03, blue: 0.12)
    )

    var gradient: [Color] { [primary, secondary, tertiary] }
}

struct ArtworkResult {
    let image: NSImage
    let palette: ArtworkPalette
}

/// Downloads YouTube thumbnails (best available resolution), crops the
/// letterboxing and extracts a vibrant palette. Results are cached in memory.
actor ArtworkLoader {
    static let shared = ArtworkLoader()

    private var cache: [String: ArtworkResult] = [:]
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.urlCache = URLCache(memoryCapacity: 32 << 20, diskCapacity: 128 << 20)
        return URLSession(configuration: config)
    }()

    func artwork(for videoId: String) async -> ArtworkResult? {
        if let hit = cache[videoId] { return hit }
        for name in ["maxresdefault", "sddefault", "hqdefault", "mqdefault"] {
            guard let url = URL(string: "https://i.ytimg.com/vi/\(videoId)/\(name).jpg") else { continue }
            guard let (data, response) = try? await session.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let image = NSImage(data: data),
                  let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  cg.width > 160 else { continue }
            let cropped = Self.cropLetterbox(cg)
            let result = ArtworkResult(
                image: NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height)),
                palette: Self.palette(from: cropped)
            )
            cache[videoId] = result
            if cache.count > 64 { cache.removeValue(forKey: cache.keys.first!) }
            return result
        }
        return nil
    }

    /// `hqdefault`/`sddefault` are 4:3 with black bars around 16:9 content.
    static func cropLetterbox(_ image: CGImage) -> CGImage {
        let w = image.width, h = image.height
        let ratio = Double(w) / Double(h)
        guard ratio < 1.6 else { return image }
        let contentHeight = Int(Double(w) * 9.0 / 16.0)
        let y = (h - contentHeight) / 2
        return image.cropping(to: CGRect(x: 0, y: y, width: w, height: contentHeight)) ?? image
    }

    /// A small hue-bucket quantiser that favours saturated, bright colours.
    static func palette(from image: CGImage) -> ArtworkPalette {
        let side = 32
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let ctx = CGContext(
            data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return .brand }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))

        struct Bucket { var weight = 0.0; var r = 0.0; var g = 0.0; var b = 0.0 }
        var buckets = [Bucket](repeating: Bucket(), count: 18)
        var avg = (r: 0.0, g: 0.0, b: 0.0)

        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[i]) / 255, g = Double(pixels[i + 1]) / 255, b = Double(pixels[i + 2]) / 255
            avg.r += r; avg.g += g; avg.b += b
            let (hue, sat, val) = rgbToHsv(r, g, b)
            guard val > 0.18, sat > 0.22 else { continue }
            let weight = sat * sat * val
            let index = min(17, Int(hue * 18))
            buckets[index].weight += weight
            buckets[index].r += r * weight
            buckets[index].g += g * weight
            buckets[index].b += b * weight
        }
        let count = Double(side * side)
        avg = (avg.r / count, avg.g / count, avg.b / count)

        let ranked = buckets.enumerated()
            .filter { $0.element.weight > 0.6 }
            .sorted { $0.element.weight > $1.element.weight }

        func color(_ bucket: Bucket) -> (Double, Double, Double) {
            (bucket.r / bucket.weight, bucket.g / bucket.weight, bucket.b / bucket.weight)
        }
        func vivid(_ c: (Double, Double, Double), minSat: Double = 0.55, minVal: Double = 0.85) -> Color {
            var (h, s, v) = rgbToHsv(c.0, c.1, c.2)
            s = max(s, minSat); v = max(v, minVal)
            h = h.truncatingRemainder(dividingBy: 1)
            return Color(hue: h, saturation: min(s, 0.95), brightness: min(v, 1))
        }
        func shifted(_ c: (Double, Double, Double), by delta: Double) -> Color {
            var (h, s, v) = rgbToHsv(c.0, c.1, c.2)
            h = (h + delta + 1).truncatingRemainder(dividingBy: 1)
            s = max(s, 0.6); v = max(v, 0.85)
            return Color(hue: h, saturation: min(s, 0.95), brightness: min(v, 1))
        }

        guard let first = ranked.first else { return .brand }
        let c1 = color(first.element)
        // Prefer a second colour whose hue is meaningfully different.
        let second = ranked.dropFirst().first { abs($0.offset - first.offset) >= 2 && abs($0.offset - first.offset) <= 16 }
        let c2 = second.map { color($0.element) }
        let third = ranked.dropFirst().first { $0.offset != first.offset && $0.offset != second?.offset }

        let (ah, asat, _) = rgbToHsv(avg.r, avg.g, avg.b)
        return ArtworkPalette(
            primary: vivid(c1),
            secondary: c2.map { vivid($0) } ?? shifted(c1, by: 0.08),
            tertiary: third.map { vivid(color($0.element)) } ?? shifted(c1, by: -0.1),
            shadow: Color(hue: ah, saturation: min(0.8, asat + 0.25), brightness: 0.14)
        )
    }

    static func rgbToHsv(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let maxC = max(r, g, b), minC = min(r, g, b), delta = maxC - minC
        var h = 0.0
        if delta > 0 {
            if maxC == r { h = ((g - b) / delta).truncatingRemainder(dividingBy: 6) }
            else if maxC == g { h = (b - r) / delta + 2 }
            else { h = (r - g) / delta + 4 }
            h /= 6
            if h < 0 { h += 1 }
        }
        return (h, maxC == 0 ? 0 : delta / maxC, maxC)
    }
}
