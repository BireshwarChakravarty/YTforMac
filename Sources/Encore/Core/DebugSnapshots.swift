import AppKit
import AVFoundation
import ImageIO
import ScreenCaptureKit
import Speech
import SwiftUI
import UniformTypeIdentifiers

/// `--snapshot <dir>`: walks through the main screens and writes PNGs of
/// Encore's own windows, plus a state log. Used by CI to verify that the app
/// really plays and renders. Capturing your own process's windows with
/// `SCShareableContent.currentProcess` needs no Screen Recording permission.
@MainActor
enum DebugSnapshots {
    static func runIfRequested(model: AppModel) {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let wait = Double(args.firstIndex(of: "--snapshot-wait").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } ?? "") ?? 25

        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            if args.contains("--demo-visuals") { model.visualizer.forceDemo = true }
            try? await Task.sleep(for: .seconds(2))
            fitMainWindow()
            try? await Task.sleep(for: .seconds(1))
            fitMainWindow()
            try? await Task.sleep(for: .seconds(wait))
            await logPage(model)
            log(model, "initial")
            await captureMain(dir, "1-audio-\(model.settings.visualizerStyle.rawValue)")

            for style in [VisualizerStyle.cosmos, .aurora, .silk, .drive, .waves, .halo, .spectrum] {
                model.settings.visualizerStyle = style
                try? await Task.sleep(for: .seconds(3.5))
                await captureMain(dir, "2-audio-\(style.rawValue)")
                if style == .drive {
                    // The wipers sweep 7 s into each cycle.
                    try? await Task.sleep(for: .seconds(4.0))
                    await captureMain(dir, "2-audio-drive-wipers")
                }
            }
            log(model, "after visualisers")

            // Lyrics: YouTube can't play on CI, so run the sample lyrics on their own clock.
            if args.contains("--demo-lyrics") {
                await lyricsSelfTest()
                model.lyrics.startDemo()
                model.settings.visualizerStyle = .lyricPop
                try? await Task.sleep(for: .seconds(8.0))
                await captureMain(dir, "2-audio-lyricpop")
                try? await Task.sleep(for: .seconds(1.6))
                await captureMain(dir, "2-audio-lyricpop-b")
                model.settings.visualizerStyle = .singAlong
                try? await Task.sleep(for: .seconds(4.5))
                await captureMain(dir, "2-audio-singalong")
                MiniPlayerController.shared.show()
                try? await Task.sleep(for: .seconds(3))
                if let panel = NSApp.windows.first(where: { $0 is NSPanel && $0.isVisible && $0.frameAutosaveName == "EncoreMiniPlayer" }) {
                    await capture(panel, dir, "5-mini-player-lyrics")
                }
                MiniPlayerController.shared.close()
                model.settings.visualizerStyle = .flow
            }

            model.setMode(.video)
            try? await Task.sleep(for: .seconds(6))
            await captureMain(dir, "3-video")
            log(model, "video mode")

            model.select(.home)
            try? await Task.sleep(for: .seconds(7))
            await captureMain(dir, "4-browse-home")

            MiniPlayerController.shared.show()
            try? await Task.sleep(for: .seconds(4))
            if let panel = NSApp.windows.first(where: { $0 is NSPanel && $0.isVisible && $0.frameAutosaveName == "EncoreMiniPlayer" }) {
                await capture(panel, dir, "5-mini-player")
            }
            MiniPlayerController.shared.close()

            model.setMode(.audio)
            let menu = NSPanel(contentRect: NSRect(x: 200, y: 200, width: 340, height: 420),
                               styleMask: [.borderless], backing: .buffered, defer: false)
            menu.contentView = NSHostingView(rootView: MenuBarView().environment(model).preferredColorScheme(.dark))
            menu.setContentSize(menu.contentView!.fittingSize)
            menu.backgroundColor = .clear
            menu.orderFrontRegardless()
            try? await Task.sleep(for: .seconds(3))
            await capture(menu, dir, "6-menu-bar")
            menu.close()

            // Audio-capture check: YouTube can't play on CI machines, so play a
            // synthesized tone through WebKit and see whether the tap hears it.
            if args.contains("--test-tone") {
                model.visualizer.forceDemo = false
                model.player.webView.loadHTMLString(testToneHTML, baseURL: URL(string: "https://www.youtube.com/"))
                try? await Task.sleep(for: .seconds(3))
                model.audioTap.setActive(true, playing: true)
                for second in 1...8 {
                    try? await Task.sleep(for: .seconds(1))
                    model.visualizer.tick()
                    let peak = model.visualizer.bands.max() ?? 0
                    print("TAP t=\(second)s status=\(model.visualizer.audioStatus) live=\(model.visualizer.isLive) peakBand=\(String(format: "%.2f", peak))")
                }
                let ctxState = try? await model.player.webView.evaluateJavaScript("window.__toneCtx ? window.__toneCtx.state : 'none'")
                print("TAP webkit tone AudioContext: \(ctxState as? String ?? "n/a")")
                print("TAP processes: \(AudioTap.describeProcesses())")

                // Self-test of the capture + FFT path: play a native tone in
                // Encore's own process and tap that.
                model.audioTap.setActive(false, playing: false)
                let tone = NativeTestTone()
                tone.start()
                model.audioTap.debugIncludeSelf = true
                model.visualizer.forceDemo = true   // let ingested frames drive the bands
                try? await Task.sleep(for: .seconds(1))
                model.audioTap.setActive(true, playing: true)
                for second in 1...6 {
                    try? await Task.sleep(for: .seconds(1))
                    model.visualizer.tick()
                    let bands = model.visualizer.bands
                    let peak = bands.max() ?? 0
                    let peakIndex = bands.firstIndex(of: peak) ?? -1
                    print("SELFTAP t=\(second)s status=\(model.visualizer.audioStatus) live=\(model.visualizer.isLive) peakBand=\(String(format: "%.2f", peak)) at band \(peakIndex)")
                }
                print("SELFTAP processes: \(AudioTap.describeProcesses())")
                tone.stop()
                model.audioTap.setActive(false, playing: false)
                print("TAP output device: \(AudioTap.defaultOutputUID() ?? "none")")
                fflush(stdout)
            }

            log(model, "done")
            print("SNAPSHOTS-DONE")
            fflush(stdout)
        }
    }

    /// Checks title cleanup and a real LRCLIB lookup (prints counts only).
    private static func lyricsSelfTest() async {
        let samples: [(String, String, String, Double)] = [
            ("dQw4w9WgXcQ", "Rick Astley - Never Gonna Give You Up (Official Music Video)", "Rick Astley", 213),
            ("kJQP7kiw5Fk", "Luis Fonsi - Despacito ft. Daddy Yankee", "LuisFonsiVEVO", 282),
            ("BddP6PYo2gs", "Kesariya (Synthwave)", "VDJ Fly", 173),
            ("", "Arijit Singh: Tum Hi Ho Full Video | Aashiqui 2", "T-Series", 262),
            ("", "Daft Punk - Get Lucky (Official Audio) ft. Pharrell Williams, Nile Rodgers", "Daft Punk", 369),
            ("", "The Weeknd - Blinding Lights (Official Audio)", "TheWeekndVEVO", 201),
        ]
        let region = Locale.current.region?.identifier ?? "US"
        for (id, title, channel, duration) in samples {
            let q = LyricsQuery(title: title, channel: channel, duration: duration)
            let r = await LyricsService.resolve(videoId: id, query: q, region: region)
            let all = r.candidates.map { c -> String in
                let kind = c.lines != nil ? "synced \(c.lines!.count)" : c.plain != nil ? "plain" : c.instrumental ? "instrumental" : "?"
                return "\(c.source.rawValue):\(kind):\(Int(LyricsService.score(c, duration: duration)))"
            }.joined(separator: ", ")
            let pick = r.timed.map { "\($0.source.rawValue) synced" } ?? r.plain.map { "\($0.source.rawValue) plain (estimated timing)" } ?? (r.instrumental ? "instrumental" : "none")
            print("LYRICSTEST \"\(q.artist)\" / \"\(q.track)\" -> \(pick)  [\(all)]")
        }
        // Aligner: the demo lyrics against "captions" of the same words shifted by
        // a 7.5 s intro, with some words missing.
        let demo = LRC.parse(LyricsService.demoLRC)
        var fake: [LyricsAligner.Word] = []
        for (i, line) in demo.enumerated() where !line.text.isEmpty {
            for (j, w) in line.words.enumerated() where (i + j) % 4 != 0 {
                fake.append(.init(time: w.start + 7.5 + (j % 2 == 0 ? 0.2 : -0.15), text: w.text))
            }
        }
        if let aligned = LyricsAligner.align(demo, to: fake, reestimate: false)?.lines {
            let shifts = zip(aligned, demo).filter { !$0.1.text.isEmpty }.map { $0.0.start - $0.1.start }
            print("LYRICSTEST aligner recovered shift \(String(format: "%.2f", shifts.sorted()[shifts.count / 2]))s (expected 7.5)")
        } else {
            print("LYRICSTEST aligner found no alignment")
        }
        await listenerSelfTest()
        let roman = "Hum tere bin ab reh nahi sakte".split(separator: " ").map { LyricsAligner.skeleton(String($0)) }
        let deva = "\u{0939}\u{092E} \u{0924}\u{0947}\u{0930}\u{0947} \u{092C}\u{093F}\u{0928} \u{0905}\u{092C} \u{0930}\u{0939} \u{0928}\u{0939}\u{0940}\u{0902} \u{0938}\u{0915}\u{0924}\u{0947}".split(separator: " ").map { LyricsAligner.skeleton(String($0)) }
        print("LYRICSTEST skeleton roman=\(roman) devanagari=\(deva) match=\(roman == deva)")
        let parsed = LRC.parse(LyricsService.demoLRC)
        print("LYRICSTEST demo parsed \(parsed.count) lines; words in line 1: \(parsed.first(where: { !$0.text.isEmpty })?.words.count ?? 0)")
        fflush(stdout)
    }

    /// Align-by-ear check: a synthesised voice reads the demo lyrics 7.5 s late;
    /// on-device recognition must hear them and the aligner recover the shift.
    private static func listenerSelfTest() async {
        let demo = LRC.parse(LyricsService.demoLRC)
        print("LISTENTEST speech authorization: \(LyricsListener.authorization.rawValue)")
        guard LyricsListener.authorization == .authorized else { return }
        guard let recognizer = LyricsListener.recognizer(for: demo) else {
            print("LISTENTEST no on-device recogniser available")
            return
        }
        let rate = 22_050.0
        var audio = [Float](repeating: 0, count: Int(rate * 50))
        let synth = AVSpeechSynthesizer()
        for line in demo where !line.text.isEmpty {
            let samples = await speak(line.text, with: synth, rate: rate)
            let at = Int((line.start + 7.5) * rate)
            for (i, v) in samples.enumerated() where at + i < audio.count { audio[at + i] += v }
        }
        let rms = sqrt(audio.reduce(0) { $0 + $1 * $1 } / Float(audio.count))
        print("LISTENTEST synthesised \(audio.count) samples, rms \(String(format: "%.4f", rms)), on-device \(recognizer.supportsOnDeviceRecognition)")
        let listener = LyricsListener()
        var heard: [LyricsAligner.Word] = []
        listener.onWords = { heard += $0 }
        listener.start(recognizer: recognizer, videoTime: 0)
        try? await Task.sleep(for: .milliseconds(300))
        let step = 2048
        var i = 0
        while i < audio.count {
            let n = min(step, audio.count - i)
            audio.withUnsafeBufferPointer { listener.feed(UnsafeBufferPointer(rebasing: $0[i..<(i + n)]), sampleRate: rate) }
            i += n
            if i % (step * 40) == 0 { try? await Task.sleep(for: .milliseconds(20)) }
        }
        listener.flush()
        try? await Task.sleep(for: .seconds(20))
        print("LISTENTEST locale=\(recognizer.locale.identifier) heard \(heard.count) words: \(heard.prefix(8).map { "\($0.text)@\(String(format: "%.1f", $0.time))" }.joined(separator: " "))")
        if let r = LyricsAligner.align(demo, to: heard, reestimate: false) {
            print("LISTENTEST aligned by ear: shift \(String(format: "%.2f", r.shiftAtStart)) s (expected 7.5), \(r.anchors) anchors")
        } else {
            print("LISTENTEST could not align from what was heard")
        }
        listener.stop()
    }

    private static func speak(_ text: String, with synth: AVSpeechSynthesizer, rate: Double) async -> [Float] {
        await withCheckedContinuation { (cont: CheckedContinuation<[Float], Never>) in
            var out: [Float] = []
            var done = false
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
            synth.write(utterance) { buffer in
                guard !done else { return }
                guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
                    done = true
                    cont.resume(returning: out)
                    return
                }
                let n = Int(pcm.frameLength)
                let step = pcm.format.sampleRate / rate
                if let f = pcm.floatChannelData?[0] {
                    var x = 0.0
                    while Int(x) < n { out.append(f[Int(x)]); x += step }
                } else if let s16 = pcm.int16ChannelData?[0] {
                    var x = 0.0
                    while Int(x) < n { out.append(Float(s16[Int(x)]) / 32768); x += step }
                }
            }
        }
    }

    /// CI displays are small; a window larger than the screen cannot be captured.
    private static var mainWindow: NSWindow? {
        NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true })
            ?? NSApp.windows.filter { !($0 is NSPanel) && $0.isVisible && $0.frame.minX > -10000 && $0.styleMask.contains(.titled) }
                .max(by: { $0.frame.width < $1.frame.width })
    }

    private static func fitMainWindow() {
        for w in NSApp.windows {
            print("WINLIST id=\(w.identifier?.rawValue ?? "nil") class=\(type(of: w)) visible=\(w.isVisible) frame=\(w.frame) number=\(w.windowNumber)")
        }
        guard let window = mainWindow, let screen = window.screen ?? NSScreen.main else {
            print("WINDOW none found")
            return
        }
        let visible = screen.visibleFrame
        let size = NSSize(width: min(1280, visible.width - 20), height: min(800, visible.height - 20))
        window.setFrame(NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
                               width: size.width, height: size.height), display: true)
        print("WINDOW fitted to \(Int(size.width))x\(Int(size.height)) on screen \(Int(visible.width))x\(Int(visible.height))")
    }

    private static func logPage(_ model: AppModel) async {
        let js = "JSON.stringify({url: location.href, player: !!document.getElementById('movie_player'), " +
                 "video: !!document.querySelector('video'), src: (document.querySelector('video')||{}).currentSrc || '', " +
                 "text: (document.body ? document.body.innerText : '').slice(0, 240)})"
        let result = try? await model.player.webView.evaluateJavaScript(js)
        print("PAGE \(result as? String ?? "n/a")")
        fflush(stdout)
    }

    private static func log(_ model: AppModel, _ label: String) {
        let p = model.player
        print("STATE[\(label)] videoId=\(p.videoId) title=\"\(p.title)\" author=\"\(p.author)\" playing=\(p.isPlaying) " +
              "position=\(Int(p.position())) duration=\(Int(p.duration)) ad=\(p.isAd) artwork=\(p.artwork != nil) error=\(p.playerError ?? "none") " +
              "analyserLive=\(model.visualizer.isLive) mode=\(model.settings.mode.rawValue) metal=\(MetalContext.shared.library != nil) " +
              "metalError=\(MetalContext.shared.compileError ?? "none")")
        fflush(stdout)
    }

    private static func captureMain(_ dir: URL, _ name: String) async {
        guard let window = mainWindow else {
            print("SNAPSHOT \(name): no main window (\(NSApp.windows.map { $0.identifier?.rawValue ?? "?" }))")
            return
        }
        await capture(window, dir, name)
    }

    private static func capture(_ window: NSWindow, _ dir: URL, _ name: String) async {
        guard #available(macOS 14.4, *) else { return }
        do {
            let content = try await SCShareableContent.currentProcess
            guard let scWindow = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
                print("SNAPSHOT \(name): window not shareable")
                return
            }
            let filter = SCContentFilter(desktopIndependentWindow: scWindow)
            let config = SCStreamConfiguration()
            let scale = window.backingScaleFactor
            config.width = Int(scWindow.frame.width * scale)
            config.height = Int(scWindow.frame.height * scale)
            config.showsCursor = false
            let image: CGImage
            do {
                image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            } catch {
                print("SNAPSHOT \(name): retrying at 1x after \(error.localizedDescription) frame=\(scWindow.frame) onScreen=\(scWindow.isOnScreen)")
                config.width = Int(scWindow.frame.width)
                config.height = Int(scWindow.frame.height)
                image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            }
            let url = dir.appendingPathComponent("\(name).png")
            if let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, image, nil)
                CGImageDestinationFinalize(dest)
            }
            print("SNAPSHOT \(name): ok \(image.width)x\(image.height)")
        } catch {
            print("SNAPSHOT \(name): failed \(error)")
        }
        fflush(stdout)
    }
}

/// A short looping synth pattern played with Web Audio inside WebKit.
private let testToneHTML = """
<html><body style="background:#000"><script>
const ctx = new AudioContext(); window.__toneCtx = ctx;
const out = ctx.createGain(); out.gain.value = 0.4; out.connect(ctx.destination);
function note(f, t, d, type) {
  const o = ctx.createOscillator(), g = ctx.createGain();
  o.type = type; o.frequency.value = f;
  g.gain.setValueAtTime(0.0001, t); g.gain.exponentialRampToValueAtTime(0.5, t + 0.01); g.gain.exponentialRampToValueAtTime(0.0001, t + d);
  o.connect(g); g.connect(out); o.start(t); o.stop(t + d + 0.05);
}
let t0 = ctx.currentTime + 0.1;
for (let i = 0; i < 64; i++) {
  const t = t0 + i * 0.25;
  note(55, t, 0.22, 'sine'); note(220 * (1 + (i % 4) / 4), t, 0.2, 'sawtooth'); note(1760, t + 0.125, 0.05, 'square');
}
ctx.resume();
</script></body></html>
"""


/// A 220 Hz + 1.76 kHz tone generated in Encore's own process (CI self-test).
private final class NativeTestTone {
    private let engine = AVAudioEngine()
    private var phase1 = 0.0, phase2 = 0.0

    func start() {
        let format = engine.outputNode.inputFormat(forBus: 0)
        let rate = format.sampleRate > 0 ? format.sampleRate : 48_000
        let source = AVAudioSourceNode { [unowned self] _, _, frameCount, bufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            for frame in 0..<Int(frameCount) {
                let s = Float(0.25 * sin(self.phase1) + 0.1 * sin(self.phase2))
                self.phase1 += 2 * .pi * 220 / rate
                self.phase2 += 2 * .pi * 1760 / rate
                for buffer in buffers { buffer.mData?.assumingMemoryBound(to: Float.self)[frame] = s }
            }
            return noErr
        }
        let mono = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: mono)
        do { try engine.start(); print("SELFTAP native tone started at \(Int(rate)) Hz") } catch { print("SELFTAP native tone failed: \(error)") }
    }

    func stop() { engine.stop() }
}
