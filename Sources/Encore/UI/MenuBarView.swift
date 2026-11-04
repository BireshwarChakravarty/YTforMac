import SwiftUI

/// The menu bar player (MenuBarExtra, window style).
struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let player = model.player
        VStack(spacing: 12) {
            if player.hasMedia {
                HStack(spacing: 12) {
                    ArtworkView(image: player.artwork, cornerRadius: 12, square: true)
                        .frame(width: 64, height: 64)
                        .shadow(color: .black.opacity(0.4), radius: 10, y: 5)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(player.title).font(Theme.Fonts.title(14.5)).lineLimit(2)
                        Text(player.isAd ? "Advertisement" : player.author)
                            .font(Theme.Fonts.body(12.5))
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .lineLimit(1)
                        Text("\(model.settings.mode.title) mode".uppercased())
                            .font(.system(size: 9.5, weight: .heavy, design: .rounded))
                            .tracking(0.8)
                            .foregroundStyle(Theme.Palette.textTertiary)
                    }
                    Spacer(minLength: 0)
                }

                MiniSpectrumView(bars: 44, reflect: true)
                    .frame(height: 56)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.black.opacity(0.18)))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(alignment: .topTrailing) { AudioSourceBadge(compact: true).padding(5) }

                ScrubberView(compact: true)
                TransportControls(size: .medium, showSkips: true)

                HStack {
                    ModePicker(compact: true)
                    Spacer()
                    VolumeControl(width: 86)
                }
            } else {
                VStack(spacing: 10) {
                    EncoreMark().frame(width: 52, height: 52)
                    Text("Nothing playing").font(Theme.Fonts.title(15))
                    Text("Open Encore to pick something, or play a copied YouTube link.")
                        .font(Theme.Fonts.body(12))
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .multilineTextAlignment(.center)
                    Button("Play Copied Link") { model.playFromClipboard() }
                        .buttonStyle(GradientButtonStyle())
                }
                .padding(.vertical, 8)
            }

            Divider().opacity(0.5)
            HStack {
                footerButton("Open Encore") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                footerButton("Settings…") {
                    openSettings()
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                footerButton("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 340)
        .background(AmbientBackground().opacity(0.9))
    }

    private func footerButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(Theme.Fonts.title(12.5)).foregroundStyle(Theme.Palette.textSecondary)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The icon (and optional title) shown in the menu bar.
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let player = model.player
        HStack(spacing: 4) {
            Image(nsImage: MenuBarIcon.image(playing: player.isPlaying))
            if model.settings.showTitleInMenuBar, player.hasMedia {
                Text(String(player.title.prefix(24)) + (player.title.count > 24 ? "…" : ""))
            }
        }
        .onAppear {
            if model.openMainWindow == nil { model.openMainWindow = { openWindow(id: "main") } }
        }
    }
}

/// The menu bar icon: Encore's mark as a template image (the system tints it).
/// The play button is solid while something plays and drawn in outline otherwise.
@MainActor
enum MenuBarIcon {
    private static var cache: [Bool: NSImage] = [:]

    static func image(playing: Bool) -> NSImage {
        if let image = cache[playing] { return image }
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: true) { rect in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            let (s, p) = EncoreMarkGeometry.mapping(CGSize(width: rect.width, height: rect.height))
            cg.setFillColor(NSColor.black.cgColor)
            cg.setStrokeColor(NSColor.black.cgColor)
            cg.setLineCap(.round)
            cg.setLineJoin(.round)
            cg.setLineWidth(80 * s)
            cg.addPath(EncoreMarkGeometry.loop(p, s).cgPath)
            cg.strokePath()
            cg.setLineWidth(24 * s)
            cg.addPath(EncoreMarkGeometry.arrow(p).cgPath)
            cg.drawPath(using: .fillStroke)
            cg.addPath(EncoreMarkGeometry.play(p).cgPath)
            if playing {
                cg.setLineWidth(30 * s)
                cg.drawPath(using: .fillStroke)
            } else {
                cg.setLineWidth(46 * s)
                cg.strokePath()
            }
            return true
        }
        image.isTemplate = true
        cache[playing] = image
        return image
    }
}
