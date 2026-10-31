import AppKit
import SwiftUI

/// A floating, always-on-top mini player. In video mode it shows the video
/// itself (the shared player web view moves into it); in audio mode it shows
/// the current visualiser.
@MainActor
final class MiniPlayerController: NSObject, NSWindowDelegate {
    static let shared = MiniPlayerController()

    private var panel: NSPanel?

    var isVisible: Bool { panel?.isVisible == true }

    func toggle() { isVisible ? close() : show() }

    func show() {
        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 260),
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel, .utilityWindow],
                backing: .buffered, defer: false
            )
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isMovableByWindowBackground = true
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.minSize = NSSize(width: 280, height: 180)
            panel.backgroundColor = .black
            panel.delegate = self
            panel.contentView = NSHostingView(rootView: MiniPlayerView().environment(AppModel.shared))
            panel.setFrameAutosaveName("EncoreMiniPlayer")
            if panel.frame.origin == .zero, let screen = NSScreen.main {
                let f = screen.visibleFrame
                panel.setFrameOrigin(NSPoint(x: f.maxX - 420, y: f.minY + 20))
            }
            self.panel = panel
        }
        panel?.orderFrontRegardless()
    }

    func close() { panel?.close() }

    func windowWillClose(_ notification: Notification) {
        // Tear the SwiftUI tree down so the web view returns to the main window.
        panel?.contentView = nil
        panel = nil
    }
}

struct MiniPlayerView: View {
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        let player = model.player
        ZStack {
            Color.black
            if model.settings.mode == .video && player.hasMedia {
                WebViewHost(webView: player.webView)
            } else if player.hasMedia {
                ZStack {
                    AmbientBackground()
                    VisualizerView(style: model.settings.visualizerStyle, compact: true)
                        .id(model.settings.visualizerStyle)
                }
            } else {
                VStack(spacing: 8) {
                    EncoreMark().frame(width: 44, height: 44)
                    Text("Nothing playing").font(Theme.Fonts.title(13)).foregroundStyle(Theme.Palette.textSecondary)
                }
            }

            if hovering && player.hasMedia {
                VStack(spacing: 8) {
                    Spacer()
                    Text(player.title).font(Theme.Fonts.title(12.5)).lineLimit(1).padding(.horizontal, 12)
                    TransportControls(size: .small)
                    ScrubberView(compact: true).padding(.horizontal, 12)
                }
                .padding(.bottom, 10)
                .frame(maxWidth: .infinity)
                .background(LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom))
                .transition(.opacity)
            }
        }
        .onHover { h in withAnimation(.easeInOut(duration: 0.2)) { hovering = h } }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
    }
}
