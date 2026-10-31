import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var observers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppModel.shared.start()
        observeWindows()
    }

    /// Closing the window must never stop the music.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Let SwiftUI reopen the main window when the Dock icon is clicked.
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        let player = AppModel.shared.player
        if player.hasMedia { AppSettings.shared.lastPosition = player.position() }
    }

    /// Right-click on the Dock icon: transport controls without opening a window.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let model = AppModel.shared
        let menu = NSMenu()
        if model.player.hasMedia {
            let now = NSMenuItem(title: model.player.title, action: nil, keyEquivalent: "")
            now.isEnabled = false
            menu.addItem(now)
            if !model.player.author.isEmpty {
                let by = NSMenuItem(title: model.player.author, action: nil, keyEquivalent: "")
                by.isEnabled = false
                menu.addItem(by)
            }
            menu.addItem(.separator())
            menu.addItem(item(model.player.isPlaying ? "Pause" : "Play", #selector(togglePlay)))
            menu.addItem(item("Next", #selector(nextTrack)))
            menu.addItem(item("Previous", #selector(previousTrack)))
            menu.addItem(.separator())
            menu.addItem(item(model.settings.mode == .audio ? "Switch to Video Mode" : "Switch to Audio Mode", #selector(toggleMode)))
        } else {
            menu.addItem(item("Play Link from Clipboard", #selector(playClipboard)))
        }
        return menu
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func togglePlay() { AppModel.shared.player.togglePlayPause() }
    @objc private func nextTrack() { AppModel.shared.player.next() }
    @objc private func previousTrack() { AppModel.shared.player.previous() }
    @objc private func toggleMode() { AppModel.shared.toggleMode() }
    @objc private func playClipboard() { AppModel.shared.playFromClipboard() }

    // MARK: Dock icon policy

    private func observeWindows() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                guard let window = note.object as? NSWindow, Self.isMainWindow(window) else { return }
                if NSApp.activationPolicy() != .regular {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        })
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                guard let window = note.object as? NSWindow, Self.isMainWindow(window),
                      AppSettings.shared.hideDockIconWhenClosed else { return }
                DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
            }
        })
    }

    private static func isMainWindow(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue.hasPrefix("main") == true
    }
}
