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

    var body: some View {
        let player = model.player
        HStack(spacing: 4) {
            Image(systemName: player.isPlaying ? "waveform" : (player.hasMedia ? "pause.circle" : "play.circle"))
            if model.settings.showTitleInMenuBar, player.hasMedia {
                Text(String(player.title.prefix(24)) + (player.title.count > 24 ? "…" : ""))
            }
        }
    }
}
