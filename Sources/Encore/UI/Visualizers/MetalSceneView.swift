import MetalKit
import SwiftUI

/// The GPU-rendered visualiser scenes.
enum MetalScene: String {
    case aurora, silk, orb, tide

    var fragmentFunction: String {
        switch self {
        case .aurora: return "auroraFragment"
        case .silk: return "silkFragment"
        case .orb: return "orbFragment"
        case .tide: return "tideBackground"
        }
    }
}

/// Mirrors `struct Uniforms` in `MetalShaders.source` (112 bytes, 16-byte aligned vectors).
struct SceneUniforms {
    var res: SIMD2<Float> = .zero
    var time: Float = 0
    var bass: Float = 0
    var mid: Float = 0
    var treble: Float = 0
    var level: Float = 0
    var phase: Float = 0
    var scroll: Float = 0
    var dpr: Float = 1
    var pad0: Float = 0
    var pad1: Float = 0
    var p0: SIMD4<Float> = .zero
    var p1: SIMD4<Float> = .zero
    var p2: SIMD4<Float> = .zero
    var shadow: SIMD4<Float> = .zero
}

/// Shared Metal objects: the device, the runtime-compiled library and the
/// pipeline cache. Compiled once, lazily, on first use.
@MainActor
final class MetalContext {
    static let shared = MetalContext()

    let device: MTLDevice?
    let queue: MTLCommandQueue?
    private(set) var library: MTLLibrary?
    private(set) var compileError: String?
    private var pipelines: [String: MTLRenderPipelineState] = [:]

    private init() {
        device = MTLCreateSystemDefaultDevice()
        queue = device?.makeCommandQueue()
        guard let device else { compileError = "No Metal device"; return }
        do {
            let options = MTLCompileOptions()
            options.fastMathEnabled = true
            library = try device.makeLibrary(source: MetalShaders.source, options: options)
        } catch {
            compileError = error.localizedDescription
            NSLog("Encore: Metal shader compilation failed: \(error)")
        }
    }

    func pipeline(vertex: String, fragment: String, additive: Bool, format: MTLPixelFormat) -> MTLRenderPipelineState? {
        let key = "\(vertex)|\(fragment)|\(additive)|\(format.rawValue)"
        if let cached = pipelines[key] { return cached }
        guard let device, let library,
              let vfn = library.makeFunction(name: vertex),
              let ffn = library.makeFunction(name: fragment) else { return nil }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vfn
        desc.fragmentFunction = ffn
        let attachment = desc.colorAttachments[0]!
        attachment.pixelFormat = format
        if additive {
            attachment.isBlendingEnabled = true
            attachment.rgbBlendOperation = .add
            attachment.alphaBlendOperation = .add
            attachment.sourceRGBBlendFactor = .one
            attachment.destinationRGBBlendFactor = .one
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor = .one
        }
        do {
            let state = try device.makeRenderPipelineState(descriptor: desc)
            pipelines[key] = state
            return state
        } catch {
            NSLog("Encore: pipeline \(fragment) failed: \(error)")
            return nil
        }
    }
}

/// SwiftUI wrapper around an `MTKView` that renders one scene at the display's refresh rate.
struct MetalSceneView: NSViewRepresentable {
    let scene: MetalScene
    let visualizer: VisualizerEngine
    let palette: ArtworkPalette
    var maxPixelWidth: CGFloat = 1800

    func makeCoordinator() -> SceneRenderer {
        SceneRenderer(visualizer: visualizer)
    }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MetalContext.shared.device)
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0.03, green: 0.02, blue: 0.05, alpha: 1)
        view.preferredFramesPerSecond = 120
        view.framebufferOnly = true
        view.autoResizeDrawable = false
        view.layer?.isOpaque = true
        view.delegate = context.coordinator
        context.coordinator.maxPixelWidth = maxPixelWidth
        context.coordinator.configure(scene: scene, palette: palette)
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.maxPixelWidth = maxPixelWidth
        context.coordinator.configure(scene: scene, palette: palette)
    }

    static func dismantleNSView(_ view: MTKView, coordinator: SceneRenderer) {
        view.isPaused = true
        view.delegate = nil
    }
}

/// Feeds the visualiser state into the shaders every frame.
final class SceneRenderer: NSObject, MTKViewDelegate {
    private let visualizer: VisualizerEngine
    private var scene: MetalScene = .aurora
    private var palette: ArtworkPalette = .brand
    private var colors: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) = (.zero, .zero, .zero, .zero)
    private var targetColors: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) = (.zero, .zero, .zero, .zero)
    var maxPixelWidth: CGFloat = 1800

    private var specTexture: MTLTexture?
    private var histTexture: MTLTexture?
    private var spectrum = [UInt8](repeating: 0, count: 64)
    private var history = [UInt8](repeating: 0, count: 64 * 64)
    private var scroll: Float = 0
    private var lastTime = CACurrentMediaTime()
    private let start = CACurrentMediaTime()

    init(visualizer: VisualizerEngine) {
        self.visualizer = visualizer
        super.init()
        MainActor.assumeIsolated {
            guard let device = MetalContext.shared.device else { return }
            let d1 = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: 64, height: 1, mipmapped: false)
            d1.usage = .shaderRead
            specTexture = device.makeTexture(descriptor: d1)
            let d2 = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: 64, height: 64, mipmapped: false)
            d2.usage = .shaderRead
            histTexture = device.makeTexture(descriptor: d2)
        }
        colors = Self.vectors(.brand)
        targetColors = colors
    }

    func configure(scene: MetalScene, palette: ArtworkPalette) {
        self.scene = scene
        if palette != self.palette {
            self.palette = palette
            targetColors = Self.vectors(palette)
        }
    }

    private static func vectors(_ p: ArtworkPalette) -> (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) {
        func v(_ c: Color) -> SIMD4<Float> {
            let ns = NSColor(c).usingColorSpace(.sRGB) ?? .white
            return SIMD4(Float(ns.redComponent), Float(ns.greenComponent), Float(ns.blueComponent), 1)
        }
        let shadow = mixVec(v(p.tertiary), SIMD4(0.024, 0.016, 0.047, 1), 0.88)
        return (v(p.primary), v(p.secondary), v(p.tertiary), shadow)
    }

    private static func mixVec(_ a: SIMD4<Float>, _ b: SIMD4<Float>, _ t: Float) -> SIMD4<Float> { a + (b - a) * t }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    private func updateDrawableSize(_ view: MTKView) {
        let scale = view.window?.backingScaleFactor ?? 2
        var w = view.bounds.width * scale, h = view.bounds.height * scale
        if w > maxPixelWidth { h *= maxPixelWidth / w; w = maxPixelWidth }
        let size = CGSize(width: max(1, w.rounded()), height: max(1, h.rounded()))
        if view.drawableSize != size { view.drawableSize = size }
    }

    func draw(in view: MTKView) {
        MainActor.assumeIsolated { render(view) }
    }

    @MainActor
    private func render(_ view: MTKView) {
        updateDrawableSize(view)
        let ctx = MetalContext.shared
        guard let queue = ctx.queue,
              let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }

        visualizer.tick()
        let now = CACurrentMediaTime()
        let dt = Float(min(0.1, now - lastTime))
        lastTime = now

        // Spectrum + scrolling history (newest row first, ~18 rows per second).
        let bands = visualizer.bands
        for i in 0..<64 {
            let x = Float(i) / 63 * Float(bands.count - 1)
            let i0 = Int(x), i1 = min(bands.count - 1, i0 + 1), f = x - Float(i0)
            spectrum[i] = UInt8(max(0, min(255, (bands[i0] * (1 - f) + bands[i1] * f) * 255)))
        }
        scroll += dt * 10   // calm: about ten history rows per second
        if scroll >= 1 {
            scroll = 0
            history.replaceSubrange(64..<(64 * 64), with: history[0..<(64 * 63)])
            history.replaceSubrange(0..<64, with: spectrum)
        }
        spectrum.withUnsafeBytes { raw in
            specTexture?.replace(region: MTLRegionMake2D(0, 0, 64, 1), mipmapLevel: 0, withBytes: raw.baseAddress!, bytesPerRow: 64)
        }
        history.withUnsafeBytes { raw in
            histTexture?.replace(region: MTLRegionMake2D(0, 0, 64, 64), mipmapLevel: 0, withBytes: raw.baseAddress!, bytesPerRow: 64)
        }

        // Ease palette changes so track switches cross-fade.
        let k = Float(1 - exp(-Double(dt) * 3))
        colors = (Self.mixVec(colors.0, targetColors.0, k), Self.mixVec(colors.1, targetColors.1, k),
                  Self.mixVec(colors.2, targetColors.2, k), Self.mixVec(colors.3, targetColors.3, k))

        let mid = (bands[20] + bands[26] + bands[32]) / 3
        let treble = (bands[42] + bands[48] + bands[54]) / 3
        let size = view.drawableSize
        var u = SceneUniforms()
        u.res = SIMD2(Float(size.width), Float(size.height))
        u.time = Float(now - start)
        u.bass = visualizer.bass
        u.mid = mid
        u.treble = treble
        u.level = visualizer.level
        u.phase = Float(visualizer.phase)
        u.scroll = scroll
        u.dpr = Float(size.width / max(1, view.bounds.width))
        u.p0 = colors.0; u.p1 = colors.1; u.p2 = colors.2; u.shadow = colors.3

        if let quad = ctx.pipeline(vertex: "quadVertex", fragment: scene.fragmentFunction, additive: false, format: view.colorPixelFormat) {
            encoder.setRenderPipelineState(quad)
            encoder.setFragmentBytes(&u, length: MemoryLayout<SceneUniforms>.stride, index: 0)
            encoder.setFragmentTexture(specTexture, index: 0)
            encoder.setFragmentTexture(histTexture, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        if scene == .tide,
           let points = ctx.pipeline(vertex: "tideVertex", fragment: "tideFragment", additive: true, format: view.colorPixelFormat) {
            encoder.setRenderPipelineState(points)
            encoder.setVertexBytes(&u, length: MemoryLayout<SceneUniforms>.stride, index: 0)
            encoder.setVertexTexture(histTexture, index: 1)
            encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: 220 * 110)
        }
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }
}
