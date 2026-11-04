import SwiftUI

@main
struct EncoreApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private var model: AppModel { AppModel.shared }

    var body: some Scene {
        Window("Encore", id: "main") {
            MainView()
                .environment(model)
                .preferredColorScheme(model.settings.appearance == .dark ? .dark : nil)
                .tint(Theme.Palette.magenta)
                .accentColor(Theme.Palette.magenta)
        }
        .defaultSize(width: 1280, height: 800)
        .windowToolbarStyle(.unified)
        .commands { EncoreCommands(model: model) }

        MenuBarExtra {
            MenuBarView()
                .environment(model)
                .preferredColorScheme(.dark)
        } label: {
            MenuBarLabel().environment(model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
                .preferredColorScheme(model.settings.appearance == .dark ? .dark : nil)
        }
    }
}

struct EncoreCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Play Link from Clipboard") { model.playFromClipboard() }
                .keyboardShortcut("l", modifiers: .command)
            Button("Copy Link to Current Video") { model.copyCurrentLink() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(!model.player.hasMedia)
            Divider()
            Button("Show Main Window") { openWindow(id: "main") }
                .keyboardShortcut("1", modifiers: [.command, .option])
        }

        CommandMenu("Playback") {
            Button(model.player.isPlaying ? "Pause" : "Play") { model.player.togglePlayPause() }
                .keyboardShortcut("p", modifiers: .command)
            Button("Next") { model.player.next() }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            Button("Previous") { model.player.previous() }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            Divider()
            Button("Skip Forward \(Int(model.settings.skipInterval))s") { model.player.skip(by: model.settings.skipInterval) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .control])
            Button("Skip Back \(Int(model.settings.skipInterval))s") { model.player.skip(by: -model.settings.skipInterval) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .control])
            Divider()
            Button("Volume Up") { model.player.setVolume(model.player.volume + 10) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button("Volume Down") { model.player.setVolume(model.player.volume - 10) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Button(model.player.isMuted ? "Unmute" : "Mute") { model.player.toggleMute() }
                .keyboardShortcut("m", modifiers: [.command, .option])
            Divider()
            Menu("Speed") {
                ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { r in
                    Button(r == 1 ? "Normal" : "\(r.formatted())×") { model.player.setRate(r) }
                }
            }
        }

        CommandGroup(after: .toolbar) {
            Button(model.settings.mode == .audio ? "Switch to Video Mode" : "Switch to Audio Mode") { model.toggleMode() }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            Button("Next Visualiser") { model.cycleVisualizer() }
                .keyboardShortcut("v", modifiers: [.command, .shift])
            Button(model.immersive ? "Exit Full-Screen Visualiser" : "Full-Screen Visualiser") { model.toggleImmersive() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Button(MiniPlayerController.shared.isVisible ? "Close Mini Player" : "Open Mini Player") { MiniPlayerController.shared.toggle() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Divider()
            ForEach(Destination.allCases) { d in
                if let key = d.shortcut {
                    Button(d.title) { model.select(d); openWindow(id: "main") }
                        .keyboardShortcut(KeyEquivalent(key), modifiers: .command)
                }
            }
            Divider()
            Button("Back") { model.goBack() }.keyboardShortcut("[", modifiers: .command)
            Button("Forward") { model.goForward() }.keyboardShortcut("]", modifiers: .command)
            Button("Reload Page") { model.reload() }.keyboardShortcut("r", modifiers: .command)
            Divider()
        }
    }
}
