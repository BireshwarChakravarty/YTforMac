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
    case flow, swarm, ambient, halo, aurora, orb, tide, spectrum, waves, ridgeline
    var id: String { rawValue }
    var title: String {
        switch self {
        case .flow: return "Flow"
        case .swarm: return "Swarm"
        case .ambient: return "Ambient"
        case .halo: return "Halo"
        case .aurora: return "Aurora"
        case .orb: return "Orb"
        case .tide: return "Tide"
        case .spectrum: return "Spectrum"
        case .waves: return "Waves"
        case .ridgeline: return "Ridgeline"
        }
    }
    var symbol: String {
        switch self {
        case .flow: return "tornado"
        case .swarm: return "sparkles"
        case .ambient: return "paintpalette.fill"
        case .halo: return "circle.dashed"
        case .aurora: return "moon.stars.fill"
        case .orb: return "circle.circle.fill"
        case .tide: return "water.waves"
        case .spectrum: return "waveform"
        case .waves: return "alternatingcurrent"
        case .ridgeline: return "mountain.2.fill"
        }
    }
    /// Short description shown in the picker.
    var caption: String {
        switch self {
        case .flow: return "Rivers of light from the spectrum"
        case .swarm: return "Particles orbiting glowing cores"
        case .ambient: return "The artwork as a living painting"
        case .halo: return "Artwork ringed by the spectrum"
        case .aurora: return "Northern lights that rise with the music"
        case .orb: return "A glass sphere that breathes"
        case .tide: return "A calm sea of light"
        case .spectrum: return "A smooth, mirrored waveform"
        case .waves: return "Gentle ribbons of light"
        case .ridgeline: return "Sound drawn as distant hills"
        }
    }
    /// GPU scenes run through the Metal pipeline (feedback, bloom, tonemapping);
    /// the minimal ones use SwiftUI Canvas.
    var metalScene: MetalScene? {
        switch self {
        case .flow: return .flow
        case .swarm: return .swarm
        case .ambient: return .ambient
        case .halo: return .halo
        case .aurora: return .aurora
        case .orb: return .orb
        case .tide: return .tide
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
    case best, hd2160, hd1440, hd1080, hd720, large, medium, small, tiny
    var id: String { rawValue }
    var title: String {
        switch self {
        case .best: return "Highest available"
        case .hd2160: return "2160p (4K)"
        case .hd1440: return "1440p"
        case .hd1080: return "1080p"
        case .hd720: return "720p"
        case .large: return "480p"
        case .medium: return "360p"
        case .small: return "240p"
        case .tiny: return "144p (data saver)"
        }
    }

    /// Short label for a quality level reported by YouTube's player.
    static func label(forYouTubeLevel level: String) -> String {
        switch level {
        case "highres": return "8K"
        case "hd2160": return "4K"
        case "hd1440": return "1440p"
        case "hd1080": return "1080p"
        case "hd720": return "720p"
        case "large": return "480p"
        case "medium": return "360p"
        case "small": return "240p"
        case "tiny": return "144p"
        default: return ""
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
    var videoQuality: VideoQuality { didSet { save(videoQuality.rawValue, "videoQualityV2") } }
    var audioModeQuality: VideoQuality { didSet { save(audioModeQuality.rawValue, "audioModeQualityV2") } }
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
        visualizerStyle = string("visualizerStyle", VisualizerStyle.flow)
        visualizerColors = string("visualizerColors", VisualizerColorSource.artwork)
        visualizerSensitivity = double("visualizerSensitivity", 1.0)
        visualizerUsesAudio = bool("visualizerUsesAudio", true)
        // V2 keys: earlier builds defaulted audio mode to a 144p data saver.
        videoQuality = string("videoQualityV2", VideoQuality.best)
        audioModeQuality = string("audioModeQualityV2", VideoQuality.best)
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
