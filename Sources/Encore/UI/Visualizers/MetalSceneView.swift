import MetalKit
import SwiftUI

/// The GPU-rendered visualiser scenes and how each one uses the pipeline.
enum MetalScene: String {
    case flow, cosmos, aurora, silk, halo, waves, drive, tide
    /// The quiet dusk behind Lyric Pop.
    case calm
    /// A dimmer, slower Silk: the backdrop for lyrics.
    case stage

    struct Config {
        var fragment: String?            // full-screen scene shader
        var background: String?          // drawn before particles
        var pointVertex: String?         // particle vertex shader
        var pointCount = 0
        var decay: Float = 0             // feedback: 0 = off
        var zoom: Float = 1
        var zoomBass: Float = 0
        var rot: Float = 0
        var warp: Float = 0
        var maxMode: Float = 0
        var threshold: Float = 0.6
        var bloom: Float = 0.8
        var exposure: Float = 1
    }

    /// Render-resolution cap. Soft, volumetric scenes look identical at a lower
    /// resolution and save a lot of GPU time.
    var maxPixelWidth: CGFloat {
        switch self {
        case .aurora: return 1200
        case .silk, .stage, .calm: return 1100
        case .drive: return 1500
        default: return 2000
        }
    }

    var config: Config {
        switch self {
        case .flow:
            return Config(fragment: "flowFragment", decay: 0.965, zoom: 1.012, zoomBass: 0.018, rot: 0.0045, warp: 0.9,
                          threshold: 0.6, bloom: 0.9, exposure: 1.0)
        case .cosmos:
            return Config(background: "cosmosBackground", pointVertex: "cosmosVertex", pointCount: 90_000,
                          decay: 0.55, maxMode: 1, threshold: 0.7, bloom: 0.9, exposure: 1.05)
        case .aurora:
            return Config(fragment: "auroraFragment", threshold: 0.75, bloom: 0.7, exposure: 1.0)
        case .silk:
            return Config(fragment: "silkFragment", threshold: 0.9, bloom: 0.5, exposure: 1.05)
        case .stage:
            return Config(fragment: "silkFragment", threshold: 1.2, bloom: 0.3, exposure: 0.5)
        case .halo:
            return Config(fragment: "haloFragment", decay: 0.9, zoom: 1.008, maxMode: 1,
                          threshold: 0.55, bloom: 0.9, exposure: 1.05)
        case .waves:
            return Config(fragment: "wavesFragment", threshold: 0.85, bloom: 0.6, exposure: 1.0)
        case .drive:
            return Config(fragment: "driveFragment", threshold: 0.75, bloom: 0.9, exposure: 1.05)
        case .calm:
            return Config(fragment: "calmFragment", threshold: 0.9, bloom: 0.5, exposure: 1.0)
        case .tide:
            return Config(background: "tideBackground", pointVertex: "tideVertex", pointCount: 220 * 110,
                          decay: 0.6, maxMode: 1, threshold: 0.6, bloom: 0.9, exposure: 1.1)
        }
    }
}

/// Mirrors `struct Uniforms` in `MetalShaders.source` (112 bytes).
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
    var beat: Float = 0
    var pad1: Float = 0
    var p0: SIMD4<Float> = .zero
    var p1: SIMD4<Float> = .zero
    var p2: SIMD4<Float> = .zero
    var shadow: SIMD4<Float> = .zero
}

/// Mirrors `struct PassParams` (48 bytes).
struct PassParams {
    var srcTexel: SIMD2<Float> = .zero
    var outSize: SIMD2<Float> = .zero
    var decay: Float = 0
    var zoom: Float = 1
    var rot: Float = 0
    var warp: Float = 0
    var maxMode: Float = 0
    var threshold: Float = 0.6
    var bloomAmt: Float = 0.8
    var exposure: Float = 1
}

/// Shared Metal objects: device, runtime-compiled library and pipeline cache.
@MainActor
final class MetalContext {
    static let shared = MetalContext()

    static let hdrFormat: MTLPixelFormat = .rgba16Float

    let device: MTLDevice?
    let queue: MTLCommandQueue?
    private(set) var library: MTLLibrary?
    private(set) var compileError: String?
    private var pipelines: [String: MTLRenderPipelineState] = [:]
    let textureLoader: MTKTextureLoader?

    private init() {
        device = MTLCreateSystemDefaultDevice()
        queue = device?.makeCommandQueue()
        textureLoader = device.map { MTKTextureLoader(device: $0) }
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

    /// Night Drive's painted Creta cabin and its mask (red: cabin, the rest is
    /// glass), bound at texture slots 3 and 4. Nil if they aren't bundled.
    private(set) lazy var nightDrive: [MTLTexture]? = {
        guard let loader = textureLoader else { return nil }
        let names = ["drive-cabin.jpg", "drive-masks2.png"]
        var textures: [MTLTexture] = []
        for name in names {
            let parts = name.split(separator: ".")
            guard let url = Bundle.main.url(forResource: String(parts[0]), withExtension: String(parts[1])),
                  let texture = try? loader.newTexture(URL: url, options: [
                      .SRGB: false, .origin: MTKTextureLoader.Origin.topLeft,
                      .textureUsage: MTLTextureUsage.shaderRead.rawValue,
                      .textureStorageMode: MTLStorageMode.private.rawValue,
                  ]) else {
                NSLog("Encore: Night Drive texture \(name) missing")
                return nil
            }
            textures.append(texture)
        }
        return textures
    }()

    func makeTarget(width: Int, height: Int) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.hdrFormat, width: max(1, width), height: max(1, height), mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        return device?.makeTexture(descriptor: d)
    }
}

/// SwiftUI wrapper around an `MTKView` that renders one scene at the display's refresh rate.
struct MetalSceneView: NSViewRepresentable {
    let scene: MetalScene
    let visualizer: VisualizerEngine
    let palette: ArtworkPalette
    var artwork: NSImage?
    var maxPixelWidth: CGFloat = 2000

    func makeCoordinator() -> SceneRenderer { SceneRenderer(visualizer: visualizer) }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MetalContext.shared.device)
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0.02, green: 0.015, blue: 0.03, alpha: 1)
        view.preferredFramesPerSecond = 120
        view.framebufferOnly = true
        view.autoResizeDrawable = false
        view.layer?.isOpaque = true
        view.delegate = context.coordinator
        update(context.coordinator)
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) { update(context.coordinator) }

    private func update(_ renderer: SceneRenderer) {
        renderer.maxPixelWidth = maxPixelWidth
        renderer.configure(scene: scene, palette: palette, artwork: artwork)
    }

    static func dismantleNSView(_ view: MTKView, coordinator: SceneRenderer) {
        view.isPaused = true
        view.delegate = nil
        coordinator.stopFootage()
    }
}

/// Runs the multi-pass pipeline every frame.
final class SceneRenderer: NSObject, MTKViewDelegate {
    private let visualizer: VisualizerEngine
    private var scene: MetalScene = .flow
    private var palette: ArtworkPalette = .brand
    private var colors: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) = (.zero, .zero, .zero, .zero)
    private var targetColors: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) = (.zero, .zero, .zero, .zero)
    var maxPixelWidth: CGFloat = 2000

    private var specTexture: MTLTexture?
    private var histTexture: MTLTexture?
    private var artTexture: MTLTexture?
    private var fallbackArt: MTLTexture?
    private weak var lastArtwork: NSImage?
    private var spectrum = [UInt8](repeating: 0, count: 64)
    private var history = [UInt8](repeating: 0, count: 64 * 64)
    private var scroll: Float = 0
    private var lastTime = CACurrentMediaTime()
    private let start = CACurrentMediaTime()

    // Render targets (recreated when the drawable size changes).
    private var targetSize: (Int, Int) = (0, 0)
    private var sceneTarget: MTLTexture?
    private var accum: [MTLTexture] = []
    private var current = 0
    private var bloomDown: [MTLTexture] = []
    private var bloomUp: [MTLTexture] = []
    private var needsClear = true

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
            let d3 = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
            d3.usage = .shaderRead
            fallbackArt = device.makeTexture(descriptor: d3)
            var px: [UInt8] = [90, 50, 140, 255]
            fallbackArt?.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &px, bytesPerRow: 4)
        }
        colors = Self.vectors(.brand)
        targetColors = colors
    }

    private var usingFootage = false

    func configure(scene: MetalScene, palette: ArtworkPalette, artwork: NSImage?) {
        if scene != self.scene { self.scene = scene; needsClear = true }
        if (scene == .drive) != usingFootage {
            usingFootage = scene == .drive
            MainActor.assumeIsolated {
                if usingFootage { DriveFootage.shared.retain() } else { DriveFootage.shared.release() }
            }
        }
        if palette != self.palette {
            self.palette = palette
            targetColors = Self.vectors(palette)
        }
        if artwork !== lastArtwork {
            lastArtwork = artwork
            artTexture = nil
            if let artwork, let cg = artwork.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                MainActor.assumeIsolated {
                    artTexture = try? MetalContext.shared.textureLoader?.newTexture(cgImage: cg, options: [
                        .generateMipmaps: true, .SRGB: false, .textureUsage: MTLTextureUsage.shaderRead.rawValue,
                        .textureStorageMode: MTLStorageMode.private.rawValue,
                    ])
                }
            }
        }
    }

    func stopFootage() {
        guard usingFootage else { return }
        usingFootage = false
        MainActor.assumeIsolated { DriveFootage.shared.release() }
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

    @MainActor
    private func ensureTargets(width: Int, height: Int) {
        guard targetSize != (width, height) || sceneTarget == nil else { return }
        let ctx = MetalContext.shared
        targetSize = (width, height)
        sceneTarget = ctx.makeTarget(width: width, height: height)
        accum = [ctx.makeTarget(width: width, height: height), ctx.makeTarget(width: width, height: height)].compactMap { $0 }
        bloomDown = []
        bloomUp = []
        var w = width / 2, h = height / 2
        for _ in 0..<5 {
            if let d = ctx.makeTarget(width: w, height: h), let u = ctx.makeTarget(width: w, height: h) {
                bloomDown.append(d); bloomUp.append(u)
            }
            w = max(1, w / 2); h = max(1, h / 2)
        }
        needsClear = true
    }

    func draw(in view: MTKView) {
        MainActor.assumeIsolated { render(view) }
    }

    @MainActor
    private func pass(_ buffer: MTLCommandBuffer, into texture: MTLTexture, clear: Bool = true) -> MTLRenderCommandEncoder? {
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = texture
        rp.colorAttachments[0].loadAction = clear ? .clear : .load
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        rp.colorAttachments[0].storeAction = .store
        return buffer.makeRenderCommandEncoder(descriptor: rp)
    }

    @MainActor
    private func render(_ view: MTKView) {
        updateDrawableSize(view)
        let ctx = MetalContext.shared
        let size = view.drawableSize
        let width = Int(size.width), height = Int(size.height)
        guard width > 1, height > 1, let queue = ctx.queue else { return }
        ensureTargets(width: width, height: height)
        guard let sceneTarget, accum.count == 2, bloomDown.count == 5,
              let drawable = view.currentDrawable,
              let buffer = queue.makeCommandBuffer() else { return }

        // ---- inputs
        visualizer.tick()
        let now = CACurrentMediaTime()
        let dt = Float(min(0.1, now - lastTime))
        lastTime = now
        let bands = visualizer.bands
        for i in 0..<64 {
            let x = Float(i) / 63 * Float(bands.count - 1)
            let i0 = Int(x), i1 = min(bands.count - 1, i0 + 1), f = x - Float(i0)
            spectrum[i] = UInt8(max(0, min(255, (bands[i0] * (1 - f) + bands[i1] * f) * 255)))
        }
        scroll += dt * 10
        if scroll >= 1 {
            scroll = 0
            history.replaceSubrange(64..<(64 * 64), with: history[0..<(64 * 63)])
            history.replaceSubrange(0..<64, with: spectrum)
        }
        spectrum.withUnsafeBytes { specTexture?.replace(region: MTLRegionMake2D(0, 0, 64, 1), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 64) }
        history.withUnsafeBytes { histTexture?.replace(region: MTLRegionMake2D(0, 0, 64, 64), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 64) }

        let k = Float(1 - exp(-Double(dt) * 2.5))
        colors = (Self.mixVec(colors.0, targetColors.0, k), Self.mixVec(colors.1, targetColors.1, k),
                  Self.mixVec(colors.2, targetColors.2, k), Self.mixVec(colors.3, targetColors.3, k))

        var u = SceneUniforms()
        u.res = SIMD2(Float(width), Float(height))
        u.time = Float(now - start)
        u.bass = visualizer.bassNorm
        u.mid = visualizer.midNorm
        u.treble = visualizer.trebleNorm
        u.level = visualizer.level
        u.beat = visualizer.beat
        u.phase = Float(visualizer.phase)
        u.scroll = scroll
        u.dpr = Float(size.width / max(1, view.bounds.width))
        u.p0 = colors.0; u.p1 = colors.1; u.p2 = colors.2; u.shadow = colors.3
        // Night Drive: the painted cabin over the looping world outside. pad1 tells
        // the shader both are there (>= 1) and where the loop is (pad1 - 1 seconds).
        var paintedDrive: [MTLTexture]?
        if scene == .drive, let cabin = ctx.nightDrive, let device = ctx.device,
           let world = DriveFootage.shared.frame(device: device) {
            paintedDrive = cabin + [world]
            u.pad1 = 1 + Float(DriveFootage.shared.loopTime)
        }

        let cfg = scene.config
        let art = artTexture ?? fallbackArt

        // ---- 1. scene
        if let enc = pass(buffer, into: sceneTarget) {
            enc.setFragmentBytes(&u, length: MemoryLayout<SceneUniforms>.stride, index: 0)
            enc.setFragmentTexture(specTexture, index: 0)
            enc.setFragmentTexture(histTexture, index: 1)
            enc.setFragmentTexture(art, index: 2)
            if let paintedDrive {
                for (i, texture) in paintedDrive.enumerated() { enc.setFragmentTexture(texture, index: 3 + i) }
            }
            for name in [cfg.fragment, cfg.background].compactMap({ $0 }) {
                if let pso = ctx.pipeline(vertex: "quadVertex", fragment: name, additive: false, format: MetalContext.hdrFormat) {
                    enc.setRenderPipelineState(pso)
                    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                }
            }
            if let vname = cfg.pointVertex,
               let pso = ctx.pipeline(vertex: vname, fragment: "pointFragment", additive: true, format: MetalContext.hdrFormat) {
                enc.setRenderPipelineState(pso)
                enc.setVertexBytes(&u, length: MemoryLayout<SceneUniforms>.stride, index: 0)
                enc.setVertexTexture(specTexture, index: 0)
                enc.setVertexTexture(histTexture, index: 1)
                enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: cfg.pointCount)
            }
            enc.endEncoding()
        }

        // ---- 2. feedback
        if needsClear {
            for t in accum { if let enc = pass(buffer, into: t) { enc.endEncoding() } }
            needsClear = false
        }
        let prev = accum[current], next = accum[1 - current]
        current = 1 - current
        var fb = PassParams()
        fb.outSize = SIMD2(Float(width), Float(height))
        fb.decay = cfg.decay
        fb.zoom = cfg.zoom + cfg.zoomBass * visualizer.bassNorm
        fb.rot = cfg.rot
        fb.warp = cfg.warp
        fb.maxMode = cfg.maxMode
        if let enc = pass(buffer, into: next),
           let pso = ctx.pipeline(vertex: "quadVertex", fragment: "feedbackFragment", additive: false, format: MetalContext.hdrFormat) {
            enc.setRenderPipelineState(pso)
            enc.setFragmentBytes(&u, length: MemoryLayout<SceneUniforms>.stride, index: 0)
            enc.setFragmentBytes(&fb, length: MemoryLayout<PassParams>.stride, index: 1)
            enc.setFragmentTexture(sceneTarget, index: 0)
            enc.setFragmentTexture(prev, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }

        // ---- 3. bloom
        func run(_ fragment: String, into target: MTLTexture, params: PassParams, textures: [MTLTexture?]) {
            guard let enc = pass(buffer, into: target),
                  let pso = ctx.pipeline(vertex: "quadVertex", fragment: fragment, additive: false, format: target.pixelFormat) else { return }
            var p = params
            enc.setRenderPipelineState(pso)
            enc.setFragmentBytes(&u, length: MemoryLayout<SceneUniforms>.stride, index: 0)
            enc.setFragmentBytes(&p, length: MemoryLayout<PassParams>.stride, index: 1)
            for (i, t) in textures.enumerated() { enc.setFragmentTexture(t, index: i) }
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }
        func params(src: MTLTexture?, out: MTLTexture) -> PassParams {
            var p = PassParams()
            if let src { p.srcTexel = SIMD2(1 / Float(src.width), 1 / Float(src.height)) }
            p.outSize = SIMD2(Float(out.width), Float(out.height))
            p.threshold = cfg.threshold
            return p
        }
        run("brightFragment", into: bloomDown[0], params: params(src: next, out: bloomDown[0]), textures: [next])
        for i in 1..<bloomDown.count {
            run("downFragment", into: bloomDown[i], params: params(src: bloomDown[i - 1], out: bloomDown[i]), textures: [bloomDown[i - 1]])
        }
        var src = bloomDown[bloomDown.count - 1]
        for i in stride(from: bloomDown.count - 2, through: 0, by: -1) {
            run("upFragment", into: bloomUp[i], params: params(src: src, out: bloomUp[i]), textures: [src, bloomDown[i]])
            src = bloomUp[i]
        }

        // ---- 4. composite to the screen
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = drawable.texture
        rp.colorAttachments[0].loadAction = .dontCare
        rp.colorAttachments[0].storeAction = .store
        if let enc = buffer.makeRenderCommandEncoder(descriptor: rp),
           let pso = ctx.pipeline(vertex: "quadVertex", fragment: "compositeFragment", additive: false, format: view.colorPixelFormat) {
            var cp = PassParams()
            cp.outSize = SIMD2(Float(width), Float(height))
            cp.bloomAmt = cfg.bloom
            cp.exposure = cfg.exposure
            enc.setRenderPipelineState(pso)
            enc.setFragmentBytes(&u, length: MemoryLayout<SceneUniforms>.stride, index: 0)
            enc.setFragmentBytes(&cp, length: MemoryLayout<PassParams>.stride, index: 1)
            enc.setFragmentTexture(next, index: 0)
            enc.setFragmentTexture(src, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }
        buffer.present(drawable)
        buffer.commit()
    }
}
