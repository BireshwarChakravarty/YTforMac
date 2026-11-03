import AVFoundation
import CoreVideo
import Metal
import QuartzCore

/// Plays Night Drive's real driving footage into Metal textures.
///
/// Two players take turns: as one clip nears its end the next one starts and
/// the shader crossfades between them, so the loop never shows a cut. Frames
/// arrive through `AVPlayerItemVideoOutput` and are wrapped as Metal textures
/// without copying (via `CVMetalTextureCache`).
///
/// Footage: Mixkit (mixkit.co), used under the Mixkit Stock Video Free License.
@MainActor
final class FootagePlayer {
    static let shared = FootagePlayer()

    struct Clip {
        let resource: String
        /// Simulated raindrops on the glass (0 for clips that were shot in real rain).
        let rain: Float
        /// The car's speed in km/h at a time in the clip.
        let speed: (Double) -> Double
    }

    struct Frame {
        let a: MTLTexture
        let b: MTLTexture?
        let mix: Float
        let rainA: Float
        let rainB: Float
        let aspect: Float
    }

    let clips: [Clip] = [
        // Times Square on a rainy evening, through a wet windshield with wipers.
        Clip(resource: "drive-rain", rain: 0, speed: { t in
            FootagePlayer.sample(FootagePlayer.rainSpeeds, at: t, step: 0.5)
        }),
        // A city highway at night.
        Clip(resource: "drive-highway", rain: 0.55, speed: { t in
            64 + 5 * sin(t * 0.11) + 2.5 * sin(t * 0.37 + 1.3) + 1.2 * sin(t * 1.1)
        }),
    ]

    /// Measured from the rain clip's own motion (optical flow), every 0.5 s.
    nonisolated private static let rainSpeeds: [Double] = [12, 14, 16, 13, 15, 16, 16, 18, 19, 17, 18, 19, 19, 21, 21, 18, 15, 14, 16, 18,
                                               20, 17, 14, 16, 18, 20, 17, 17, 19, 21, 23, 23, 23, 22, 22, 23, 25, 24, 21, 18,
                                               19, 21, 19, 20, 17]

    nonisolated private static func sample(_ values: [Double], at t: Double, step: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let x = max(0, t / step)
        let i = min(values.count - 1, Int(x))
        let j = min(values.count - 1, i + 1)
        let f = x - Double(i)
        return values[i] + (values[j] - values[i]) * f
    }

    let fadeDuration = 1.8
    private let players = [AVPlayer(), AVPlayer()]
    private var outputs: [AVPlayerItemVideoOutput?] = [nil, nil]
    private var clipIndex = [0, 0]
    private var active = 0
    private var fading = false
    private var fadeStart: CFTimeInterval = 0
    private var cache: CVMetalTextureCache?
    private var textures: [MTLTexture?] = [nil, nil]
    private var holders: [CVMetalTexture?] = [nil, nil]
    private var users = 0

    var isAvailable: Bool { Bundle.main.url(forResource: clips[0].resource, withExtension: "mp4") != nil }

    private init() {
        for p in players {
            p.isMuted = true
            p.actionAtItemEnd = .pause
            p.preventsDisplaySleepDuringVideoPlayback = false
        }
    }

    // MARK: Lifetime

    func retain() {
        users += 1
        if users == 1 { resume() }
    }

    func release() {
        users = max(0, users - 1)
        if users == 0 { players.forEach { $0.pause() } }
    }

    private func resume() {
        if players[active].currentItem == nil { load(slot: active, clip: 0) }
        players[active].play()
        if fading { players[1 - active].play() }
    }

    private func load(slot: Int, clip: Int) {
        guard let url = Bundle.main.url(forResource: clips[clip].resource, withExtension: "mp4") else { return }
        let item = AVPlayerItem(url: url)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        item.add(output)
        players[slot].replaceCurrentItem(with: item)
        outputs[slot] = output
        clipIndex[slot] = clip
        textures[slot] = nil
        holders[slot] = nil
    }

    // MARK: Per frame

    /// Advances the playlist and returns the textures to draw this frame.
    func frame(device: MTLDevice) -> Frame? {
        let now = CACurrentMediaTime()
        if let item = players[active].currentItem {
            let duration = item.duration.seconds
            let t = players[active].currentTime().seconds
            if !fading, duration.isFinite, duration > fadeDuration * 2, t > duration - fadeDuration {
                load(slot: 1 - active, clip: (clipIndex[active] + 1) % clips.count)
                players[1 - active].play()
                fading = true
                fadeStart = now
            }
        }
        var mix: Float = 0
        if fading {
            mix = Float(min(1, (now - fadeStart) / fadeDuration))
            if mix >= 1 {
                players[active].pause()
                active = 1 - active
                fading = false
                mix = 0
            }
        }
        pull(0, device: device)
        pull(1, device: device)
        guard let a = textures[active] else { return nil }
        let other = 1 - active
        return Frame(a: a, b: fading ? textures[other] : nil, mix: fading && textures[other] != nil ? mix : 0,
                     rainA: clips[clipIndex[active]].rain, rainB: clips[clipIndex[other]].rain,
                     aspect: Float(a.width) / Float(max(1, a.height)))
    }

    /// The car's current speed, following the footage (blended during crossfades).
    func speed() -> Double {
        func at(_ slot: Int) -> Double {
            let t = players[slot].currentTime().seconds
            return clips[clipIndex[slot]].speed(t.isFinite ? t : 0)
        }
        guard players[active].currentItem != nil else { return 0 }
        if fading {
            let m = min(1, (CACurrentMediaTime() - fadeStart) / fadeDuration)
            return at(active) * (1 - m) + at(1 - active) * m
        }
        return at(active)
    }

    /// The speed limit for the road in the current clip.
    func speedLimit() -> Int { clipIndex[fading ? 1 - active : active] == 0 ? 40 : 80 }

    private func pull(_ slot: Int, device: MTLDevice) {
        guard let output = outputs[slot] else { return }
        let time = output.itemTime(forHostTime: CACurrentMediaTime())
        guard output.hasNewPixelBuffer(forItemTime: time),
              let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else { return }
        if cache == nil { CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) }
        guard let cache else { return }
        var cvTexture: CVMetalTexture?
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil, .bgra8Unorm, w, h, 0, &cvTexture)
        if let cvTexture, let texture = CVMetalTextureGetTexture(cvTexture) {
            textures[slot] = texture
            holders[slot] = cvTexture
        }
    }
}
