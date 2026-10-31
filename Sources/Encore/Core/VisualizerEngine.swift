import Foundation
import QuartzCore

/// Turns raw spectrum frames from the page into smooth, musical motion.
///
/// Real data comes from a Web Audio `AnalyserNode` inside the player page.
/// When it is unavailable (live HLS streams, Web Audio disabled, or before
/// the first frame) a synthetic, tempo-locked generator takes over so the
/// visualisers never look dead while something is playing.
///
/// Deliberately *not* observable: the visualiser views pull from it every
/// frame inside a `TimelineView`, which avoids SwiftUI invalidation churn.
@MainActor
final class VisualizerEngine {
    static let bandCount = 56

    private(set) var bands = [Float](repeating: 0, count: VisualizerEngine.bandCount)
    private(set) var peaks = [Float](repeating: 0, count: VisualizerEngine.bandCount)
    /// Overall loudness, 0…1, smoothed.
    private(set) var level: Float = 0
    /// Low-end energy, 0…1, with a fast attack: good for "kick" pulses.
    private(set) var bass: Float = 0
    /// Accumulates with loudness; handy for rotation / drift that speeds up with the music.
    private(set) var phase: Double = 0
    /// True while real analyser frames are arriving.
    private(set) var isLive = false

    var isPlaying = false
    /// State of the system-audio tap feeding real spectrum data.
    var audioStatus: AudioTap.Status = .idle
    /// Debug/demo: animate as if playing (used by `--snapshot` on CI, where nothing can play).
    var forceDemo = false
    var sensitivity: Float = 1

    private var target = [Float](repeating: 0, count: VisualizerEngine.bandCount)
    private var targetLevel: Float = 0
    private var lastFrame: CFTimeInterval = 0
    private var lastTick: CFTimeInterval = CACurrentMediaTime()
    private var seed = Double.random(in: 0...1000)

    /// Called with each analyser frame from the page (values 0…255).
    func ingest(bands raw: [UInt8], level: UInt8) {
        let n = min(raw.count, Self.bandCount)
        for i in 0..<n {
            // Gentle spectral tilt: high frequencies carry less energy.
            let tilt: Float = 0.82 + 0.5 * Float(i) / Float(Self.bandCount)
            let v = Float(raw[i]) / 255 * tilt * sensitivity
            target[i] = min(1, pow(v, 1.35))
        }
        targetLevel = min(1, Float(level) / 255 * 1.4 * sensitivity)
        lastFrame = CACurrentMediaTime()
    }

    /// Advances the simulation. Safe to call several times per frame (from
    /// multiple visualiser views): the step is time-based.
    func tick() {
        let now = CACurrentMediaTime()
        let dt = Float(min(0.1, max(0, now - lastTick)))
        lastTick = now
        guard dt > 0.0005 else { return }

        isLive = now - lastFrame < 0.4
        let isPlaying = self.isPlaying || forceDemo
        if !isLive {
            synthesize(time: now)
        }

        // Fast enough to feel the beat, slow enough to stay soothing.
        let attack = 1 - exp(-dt * 16)
        let release = 1 - exp(-dt * 4)
        var lowSum: Float = 0
        for i in 0..<Self.bandCount {
            let goal = isPlaying ? target[i] : idle(i, now)
            let k = goal > bands[i] ? attack : release
            bands[i] += (goal - bands[i]) * k
            if bands[i] > peaks[i] { peaks[i] = bands[i] } else { peaks[i] = max(0, peaks[i] - dt * 0.45) }
            if i < 7 { lowSum += bands[i] }
        }
        let low = lowSum / 7
        bass += (low - bass) * (low > bass ? (1 - exp(-dt * 20)) : (1 - exp(-dt * 3)))
        let lvlGoal = isPlaying ? max(targetLevel, bands.reduce(0, +) / Float(Self.bandCount) * 1.4) : 0.02
        level += (lvlGoal - level) * (1 - exp(-dt * 6))
        phase += Double(dt) * (0.25 + Double(level) * 1.6)
    }

    /// Low, breathing motion while paused so the scene still feels alive.
    private func idle(_ i: Int, _ t: CFTimeInterval) -> Float {
        let x = Double(i) / Double(Self.bandCount)
        return Float(0.035 + 0.025 * sin(t * 1.1 + x * 9))
    }

    /// Procedural, tempo-locked spectrum used when no analyser data arrives.
    private func synthesize(time t: CFTimeInterval) {
        let bpm = 112.0
        let beat = t * bpm / 60
        let kick = pow(max(0, 1 - (beat - floor(beat)) * 2.6), 2.2)
        let snare = pow(max(0, 1 - abs((beat + 0.5).truncatingRemainder(dividingBy: 2) - 1) * 3.5), 2)
        for i in 0..<Self.bandCount {
            let x = Double(i) / Double(Self.bandCount)
            let n1 = sin(t * (1.3 + x * 3.1) + seed + x * 13) * 0.5 + 0.5
            let n2 = sin(t * (2.7 + x * 5.3) + seed * 0.37 + x * 29) * 0.5 + 0.5
            let body = pow(1 - x, 1.3) * 0.55 + 0.12
            var v = body * (0.45 + 0.35 * n1 + 0.2 * n2)
            v += kick * max(0, 0.55 - x * 2.2)
            v += snare * 0.25 * exp(-pow((x - 0.55) * 4, 2))
            target[i] = Float(min(1, v * 0.9)) * sensitivity
        }
        targetLevel = Float(0.35 + kick * 0.35) * sensitivity
    }

    /// Bands resampled to an arbitrary count (linear interpolation).
    func resampled(_ count: Int, mirrored: Bool = false) -> [Float] {
        guard count > 0 else { return [] }
        var out = [Float](repeating: 0, count: count)
        let src = bands
        for i in 0..<count {
            var x = Float(i) / Float(max(1, count - 1))
            if mirrored { x = abs(x * 2 - 1) }
            let p = x * Float(src.count - 1)
            let i0 = Int(p), i1 = min(src.count - 1, i0 + 1)
            let f = p - Float(i0)
            out[i] = src[i0] * (1 - f) + src[i1] * f
        }
        return out
    }
}
