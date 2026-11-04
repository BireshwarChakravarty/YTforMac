import AVFoundation
import CoreVideo
import Metal
import QuartzCore

/// Plays Night Drive's world outside the windshield into a Metal texture.
///
/// The clip (`drive-world.mp4`) is the view through the Creta's windshield only,
/// cropped to the painting's glass (1920 px wide, the top 432 rows), with its
/// end crossfaded into its start and interpolated to 60 fps, so it loops without
/// a seam. `AVPlayerLooper` keeps it playing gaplessly; frames are wrapped as
/// Metal textures without copying (via `CVMetalTextureCache`). The painted cabin
/// is drawn over it by the shader.
@MainActor
final class DriveFootage {
    static let shared = DriveFootage()
    static let resource = "drive-world"

    private let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private var outputs: [ObjectIdentifier: AVPlayerItemVideoOutput] = [:]
    private var cache: CVMetalTextureCache?
    private var texture: MTLTexture?
    private var holder: CVMetalTexture?
    private var users = 0

    /// Seconds into the loop of the frame last returned.
    private(set) var loopTime: Double = 0

    var isAvailable: Bool { Bundle.main.url(forResource: Self.resource, withExtension: "mp4") != nil }

    private init() {
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
    }

    func retain() {
        users += 1
        if users == 1 { start() }
    }

    func release() {
        users = max(0, users - 1)
        if users == 0 { player.pause() }
    }

    private func start() {
        if looper == nil, let url = Bundle.main.url(forResource: Self.resource, withExtension: "mp4") {
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        }
        attachOutputs()
        player.play()
    }

    /// Every copy of the clip the looper queues needs its own video output.
    private func attachOutputs() {
        for item in looper?.loopingPlayerItems ?? [] where outputs[ObjectIdentifier(item)] == nil {
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ])
            item.add(output)
            outputs[ObjectIdentifier(item)] = output
        }
    }

    /// The newest frame, or the previous one if no new frame is due yet.
    func frame(device: MTLDevice) -> MTLTexture? {
        guard users > 0 else { return texture }
        attachOutputs()
        guard let item = player.currentItem, let output = outputs[ObjectIdentifier(item)] else { return texture }
        let time = output.itemTime(forHostTime: CACurrentMediaTime())
        guard output.hasNewPixelBuffer(forItemTime: time),
              let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else { return texture }
        if time.isNumeric { loopTime = max(0, time.seconds) }
        if cache == nil { CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) }
        guard let cache else { return texture }
        var cvTexture: CVMetalTexture?
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil, .bgra8Unorm, w, h, 0, &cvTexture)
        if let cvTexture, let tex = CVMetalTextureGetTexture(cvTexture) {
            texture = tex
            holder = cvTexture
        }
        return texture
    }

}
