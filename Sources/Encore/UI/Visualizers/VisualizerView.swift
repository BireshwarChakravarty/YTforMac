import SwiftUI

/// Renders the chosen visualiser style. GPU scenes go through Metal, the
/// rest through a 60/120 fps `Canvas`. While on screen, each instance asks
/// the player page to stream spectrum frames.
struct VisualizerView: View {
    let style: VisualizerStyle
    var compact = false

    @Environment(AppModel.self) private var model
    @State private var state = CanvasVizState()

    var body: some View {
        let palette = model.settings.visualizerColors == .artwork ? model.player.palette : .brand
        Group {
            if let scene = style.metalScene, MetalContext.shared.library != nil {
                ZStack {
                    MetalSceneView(scene: scene, visualizer: model.visualizer, palette: palette,
                                   artwork: model.player.artwork,
                                   maxPixelWidth: compact ? 900 : scene.maxPixelWidth)
                    if style == .drive { DriveOverlay(compact: compact) }
                    if style == .lyricPop {
                        // Keep the words readable over the light show.
                        RadialGradient(colors: [.black.opacity(0.25), .clear], center: .center, startRadius: 0, endRadius: 600)
                            .allowsHitTesting(false)
                    }
                    if style.isLyrics && compact { LyricPopView(compact: true).padding(10) }
                }
            } else {
                TimelineView(.animation) { timeline in
                    Canvas { ctx, size in
                        let t = timeline.date.timeIntervalSinceReferenceDate
                        model.visualizer.tick()
                        state.step(palette: palette, engine: model.visualizer)
                        draw(&ctx, size: size, time: t)
                    }
                }
            }
        }
        .onAppear { model.player.setVisualizerDemand(1) }
        .onDisappear { model.player.setVisualizerDemand(-1) }
    }

    private func draw(_ ctx: inout GraphicsContext, size: CGSize, time t: Double) {
        let e = model.visualizer
        switch style {
        case .spectrum:
            CanvasPainter.spectrum(&ctx, size: size, engine: e, state: state,
                                   options: compact ? .init(count: 40, gap: 3, mini: true, peaks: false)
                                                    : .init(count: 64, gap: 5, mirroredVertical: true, cycleColours: true))
        default:
            // GPU styles fall back to Halo if Metal is unavailable.
            CanvasPainter.halo(&ctx, size: size, engine: e, state: state, artwork: model.player.artwork, time: t, compact: compact)
        }
    }
}

/// A small spectrum used in the player bar and the menu bar.
struct MiniSpectrumView: View {
    var bars = 22
    var reflect = false
    @Environment(AppModel.self) private var model
    @State private var state = CanvasVizState()

    var body: some View {
        let palette = model.settings.visualizerColors == .artwork ? model.player.palette : .brand
        TimelineView(.animation(minimumInterval: 1.0 / 60)) { timeline in
            Canvas { ctx, size in
                _ = timeline.date
                model.visualizer.tick()
                state.step(palette: palette, engine: model.visualizer)
                CanvasPainter.spectrum(&ctx, size: size, engine: model.visualizer, state: state, options: .init(
                    count: bars,
                    baseline: reflect ? size.height * 0.66 : size.height - 1,
                    maxHeight: reflect ? size.height * 0.58 : size.height - 3,
                    padding: reflect ? 8 : 0,
                    gap: reflect ? 3 : 2,
                    mini: true, reflect: reflect, peaks: false))
            }
        }
        .onAppear { model.player.setVisualizerDemand(1) }
        .onDisappear { model.player.setVisualizerDemand(-1) }
    }
}
