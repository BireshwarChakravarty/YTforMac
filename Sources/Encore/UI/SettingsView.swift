import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            PlaybackSettings().tabItem { Label("Playback", systemImage: "play.circle") }
            VisualizerSettings().tabItem { Label("Visualisers", systemImage: "waveform") }
            AccountSettings().tabItem { Label("YouTube", systemImage: "person.crop.circle") }
        }
        .frame(width: 520)
        .padding(.vertical, 8)
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Picker("Appearance", selection: $settings.appearance) {
                ForEach(AppearancePreference.allCases) { Text($0.title).tag($0) }
            }
            .onChange(of: settings.appearance) { _, _ in model.applyAppearance() }
            Toggle("Show the track title in the menu bar", isOn: $settings.showTitleInMenuBar)
            Toggle("Hide the Dock icon while the main window is closed", isOn: $settings.hideDockIconWhenClosed)
            Toggle("Pick up where you left off at launch", isOn: $settings.resumeOnLaunch)
            LabeledContent("Background playback") {
                Text("Closing the window keeps the music playing. Media keys, AirPods and Control Center keep working. Quit with ⌘Q to stop.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct PlaybackSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Picker("Default mode", selection: $settings.mode) {
                ForEach(PlaybackMode.allCases) { Text($0.title).tag($0) }
            }
            .onChange(of: settings.mode) { _, _ in model.player.applyQuality() }
            Picker("Video quality", selection: $settings.videoQuality) {
                ForEach(VideoQuality.allCases) { Text($0.title).tag($0) }
            }
            .onChange(of: settings.videoQuality) { _, _ in model.player.applyQuality() }
            Picker("Audio mode streams video at", selection: $settings.audioModeQuality) {
                ForEach(VideoQuality.allCases) { Text($0.title).tag($0) }
            }
            .onChange(of: settings.audioModeQuality) { _, _ in model.player.applyQuality() }
            Text("YouTube serves full-quality audio at any video resolution, so a low setting saves data without changing the sound.")
                .font(.callout).foregroundStyle(.secondary)
            Toggle("Cinema layout (the video fills the window)", isOn: $settings.cinemaLayout)
                .onChange(of: settings.cinemaLayout) { _, _ in model.player.applyCinema() }
            Toggle("Click \u{201C}Skip\u{201D} on ads as soon as YouTube offers it", isOn: $settings.autoSkipAds)
                .onChange(of: settings.autoSkipAds) { _, _ in model.player.applyAdSettings() }
            Toggle("Answer \u{201C}Video paused. Continue watching?\u{201D} automatically", isOn: $settings.dismissStillWatching)
                .onChange(of: settings.dismissStillWatching) { _, _ in model.player.applyAdSettings() }
            Picker("Skip buttons jump", selection: $settings.skipInterval) {
                Text("5 seconds").tag(5.0)
                Text("10 seconds").tag(10.0)
                Text("15 seconds").tag(15.0)
                Text("30 seconds").tag(30.0)
            }
        }
        .formStyle(.grouped)
    }
}

private struct VisualizerSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Picker("Style", selection: $settings.visualizerStyle) {
                ForEach(VisualizerStyle.allCases) { style in
                    Text(style.isGPU ? "\(style.title) (3D)" : style.title).tag(style)
                }
            }
            Picker("Colours", selection: $settings.visualizerColors) {
                ForEach(VisualizerColorSource.allCases) { Text($0.title).tag($0) }
            }
            LabeledContent("Sensitivity") {
                Slider(value: $settings.visualizerSensitivity, in: 0.4...2.0)
                    .frame(width: 220)
            }
            .onChange(of: settings.visualizerSensitivity) { _, v in model.visualizer.sensitivity = Float(v) }
            Toggle("React to the actual audio (Web Audio analyser)", isOn: $settings.visualizerUsesAudio)
                .onChange(of: settings.visualizerUsesAudio) { _, _ in model.player.refreshVisualizerSource() }
            Text("When this is off, or for live streams, the visualisers follow a tempo-matched simulation. The live analyser takes effect from the next video you play.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

private struct AccountSettings: View {
    @Environment(AppModel.self) private var model
    @State private var confirmSignOut = false

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            LabeledContent("Account") {
                Text(model.browser.isSignedIn ? "Signed in to YouTube" : "Not signed in")
            }
            HStack {
                if model.browser.isSignedIn {
                    Button("Sign Out and Clear Website Data", role: .destructive) { confirmSignOut = true }
                } else {
                    Button("Sign In to YouTube…") { model.destination = .home; model.browser.signIn() }
                }
            }
            Toggle("Hide YouTube's own header and sidebar (Encore provides them)", isOn: $settings.cleanYouTubeChrome)
                .onChange(of: settings.cleanYouTubeChrome) { _, _ in model.browser.applyCleanChrome() }
        }
        .formStyle(.grouped)
        .confirmationDialog("Sign out of YouTube?", isPresented: $confirmSignOut) {
            Button("Sign Out", role: .destructive) { model.browser.signOut() }
        } message: {
            Text("This removes YouTube cookies and cached website data from Encore.")
        }
    }
}
