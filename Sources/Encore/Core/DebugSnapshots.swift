import AppKit
import ImageIO
import ScreenCaptureKit
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
            try? await Task.sleep(for: .seconds(wait))
            await logPage(model)
            log(model, "initial")
            await captureMain(dir, "1-audio-\(model.settings.visualizerStyle.rawValue)")

            for style in [VisualizerStyle.halo, .tide, .warp, .vortex, .contours, .spectrum, .nebula] {
                model.settings.visualizerStyle = style
                try? await Task.sleep(for: .seconds(3.5))
                await captureMain(dir, "2-audio-\(style.rawValue)")
            }
            log(model, "after visualisers")

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

            log(model, "done")
            print("SNAPSHOTS-DONE")
            fflush(stdout)
        }
    }

    /// CI displays are small; a window larger than the screen cannot be captured.
    private static func fitMainWindow() {
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }),
              let screen = window.screen ?? NSScreen.main else { return }
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
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true && $0.isVisible })
            ?? NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 600 }) else {
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
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
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
