import Foundation
import Observation

enum PlaybackMode: String, CaseIterable, Identifiable, Codable {
    case video, audio
    var id: String { rawValue }
    var title: String { self == .video ? "Video" : "Audio" }
    var symbol: String { self == .video ? "play.rectangle.fill" : "waveform" }
    var toggled: PlaybackMode { self == .video ? .audio : .video }
}

enum VisualizerStyle: String, CaseIterable, Identifiable, Codable {
    case halo, voxels, tide, warp, vortex, contours, spectrum, waves, nebula, ridgeline
    var id: String { rawValue }
    var title: String {
        switch self {
        case .halo: return "Halo"
        case .voxels: return "Voxels"
        case .tide: return "Tide"
        case .warp: return "Warp"
        case .vortex: return "Vortex"
        case .contours: return "Contours"
        case .spectrum: return "Spectrum"
        case .waves: return "Waves"
        case .nebula: return "Nebula"
        case .ridgeline: return "Ridgeline"
        }
    }
    var symbol: String {
        switch self {
        case .halo: return "circle.dashed"
        case .voxels: return "cube.fill"
        case .tide: return "circle.grid.3x3.fill"
        case .warp: return "scope"
        case .vortex: return "tornado"
        case .contours: return "map.fill"
        case .spectrum: return "chart.bar.fill"
        case .waves: return "water.waves"
        case .nebula: return "sparkles"
        case .ridgeline: return "mountain.2.fill"
        }
    }
    /// Short description shown in the picker.
    var caption: String {
        switch self {
        case .halo: return "Artwork ringed by light"
        case .voxels: return "3D block terrain"
        case .tide: return "Holographic point sea"
        case .warp: return "Light-speed tunnel"
        case .vortex: return "Storm with a calm eye"
        case .contours: return "Living topographic map"
        case .spectrum: return "Glowing mirrored bars"
        case .waves: return "Aurora ribbons"
        case .nebula: return "Particle burst"
        case .ridgeline: return "Scrolling sound ridges"
        }
    }
    /// GPU scenes are rendered with Metal; the rest use SwiftUI Canvas.
    var metalScene: MetalScene? {
        switch self {
        case .voxels: return .voxels
        case .tide: return .tide
        case .warp: return .warp
        case .vortex: return .vortex
        case .contours: return .contours
        default: return nil
        }
    }
    var isGPU: Bool { metalScene != nil }
    var next: VisualizerStyle {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

enum VideoQuality: String, CaseIterable, Identifiable, Codable {
    case auto, hd2160, hd1440, hd1080, hd720, large, medium, small, tiny
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: return "Auto"
        case .hd2160: return "2160p (4K)"
        case .hd1440: return "1440p"
        case .hd1080: return "1080p"
        case .hd720: return "720p"
        case .large: return "480p"
        case .medium: return "360p"
        case .small: return "240p"
        case .tiny: return "144p"
        }
    }
}

enum AppearancePreference: String, CaseIterable, Identifiable, Codable {
    case dark, system
    var id: String { rawValue }
    var title: String { self == .dark ? "Always Dark" : "Match System" }
}

enum VisualizerColorSource: String, CaseIterable, Identifiable, Codable {
    case artwork, brand
    var id: String { rawValue }
    var title: String { self == .artwork ? "From Artwork" : "Encore Gradient" }
}

/// All user preferences, persisted in `UserDefaults`.
@Observable
final class AppSettings {
    static let shared = AppSettings()


    var mode: PlaybackMode { didSet { save(mode.rawValue, "mode") } }
    var visualizerStyle: VisualizerStyle { didSet { save(visualizerStyle.rawValue, "visualizerStyle") } }
    var visualizerColors: VisualizerColorSource { didSet { save(visualizerColors.rawValue, "visualizerColors") } }
    var visualizerSensitivity: Double { didSet { save(visualizerSensitivity, "visualizerSensitivity") } }
    var visualizerUsesAudio: Bool { didSet { save(visualizerUsesAudio, "visualizerUsesAudio") } }
    var videoQuality: VideoQuality { didSet { save(videoQuality.rawValue, "videoQuality") } }
    var audioModeQuality: VideoQuality { didSet { save(audioModeQuality.rawValue, "audioModeQuality") } }
    var cinemaLayout: Bool { didSet { save(cinemaLayout, "cinemaLayout") } }
    var cleanYouTubeChrome: Bool { didSet { save(cleanYouTubeChrome, "cleanYouTubeChrome") } }
    var autoSkipAds: Bool { didSet { save(autoSkipAds, "autoSkipAds") } }
    var dismissStillWatching: Bool { didSet { save(dismissStillWatching, "dismissStillWatching") } }
    var resumeOnLaunch: Bool { didSet { save(resumeOnLaunch, "resumeOnLaunch") } }
    var appearance: AppearancePreference { didSet { save(appearance.rawValue, "appearance") } }
    var showTitleInMenuBar: Bool { didSet { save(showTitleInMenuBar, "showTitleInMenuBar") } }
    var hideDockIconWhenClosed: Bool { didSet { save(hideDockIconWhenClosed, "hideDockIconWhenClosed") } }
    var skipInterval: Double { didSet { save(skipInterval, "skipInterval") } }

    // Session restore (not shown in Settings).
    var lastURL: String? { didSet { save(lastURL, "lastURL") } }
    var lastPosition: Double { didSet { save(lastPosition, "lastPosition") } }
    var lastVolume: Double { didSet { save(lastVolume, "lastVolume") } }

    private init() {
        let defaults = UserDefaults.standard
        func string<T: RawRepresentable>(_ key: String, _ fallback: T) -> T where T.RawValue == String {
            (defaults.string(forKey: key)).flatMap(T.init(rawValue:)) ?? fallback
        }
        func bool(_ key: String, _ fallback: Bool) -> Bool {
            defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
        }
        func double(_ key: String, _ fallback: Double) -> Double {
            defaults.object(forKey: key) == nil ? fallback : defaults.double(forKey: key)
        }
        mode = string("mode", PlaybackMode.video)
        visualizerStyle = string("visualizerStyle", VisualizerStyle.halo)
        visualizerColors = string("visualizerColors", VisualizerColorSource.artwork)
        visualizerSensitivity = double("visualizerSensitivity", 1.0)
        visualizerUsesAudio = bool("visualizerUsesAudio", true)
        videoQuality = string("videoQuality", VideoQuality.auto)
        audioModeQuality = string("audioModeQuality", VideoQuality.tiny)
        cinemaLayout = bool("cinemaLayout", true)
        cleanYouTubeChrome = bool("cleanYouTubeChrome", true)
        autoSkipAds = bool("autoSkipAds", true)
        dismissStillWatching = bool("dismissStillWatching", true)
        resumeOnLaunch = bool("resumeOnLaunch", true)
        appearance = string("appearance", AppearancePreference.dark)
        showTitleInMenuBar = bool("showTitleInMenuBar", false)
        hideDockIconWhenClosed = bool("hideDockIconWhenClosed", false)
        skipInterval = double("skipInterval", 10)
        lastURL = defaults.string(forKey: "lastURL")
        lastPosition = double("lastPosition", 0)
        lastVolume = double("lastVolume", 100)
    }

    /// The YouTube quality that should be requested right now.
    var effectiveQuality: VideoQuality { mode == .audio ? audioModeQuality : videoQuality }

    private func save(_ value: Any?, _ key: String) {
        let defaults = UserDefaults.standard
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}
