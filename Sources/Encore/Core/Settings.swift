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
    case drive, spectrum, classic, warp, aurora, halo, silk, waves, lyricPop, singAlong
    var id: String { rawValue }
    var title: String {
        switch self {
        case .lyricPop: return "Lyric Pop"
        case .singAlong: return "Sing-Along"
        case .spectrum: return "Spectrum"
        case .aurora: return "Aurora"
        case .silk: return "Silk"
        case .drive: return "Night Drive"
        case .waves: return "Waves"
        case .halo: return "Halo"
        case .classic: return "Classic"
        case .warp: return "Warp"
        }
    }
    var symbol: String {
        switch self {
        case .lyricPop: return "quote.bubble.fill"
        case .singAlong: return "music.mic"
        case .spectrum: return "waveform"
        case .aurora: return "moon.stars.fill"
        case .silk: return "wind"
        case .drive: return "car.rear.fill"
        case .waves: return "waveform.path"
        case .halo: return "circle.dashed"
        case .classic: return "chart.bar.fill"
        case .warp: return "hurricane"
        }
    }
    /// Short description shown in the picker.
    var caption: String {
        switch self {
        case .lyricPop: return "Synced lyrics that burst in, word by word"
        case .singAlong: return "Scrolling karaoke lyrics, line by line"
        case .spectrum: return "A mirrored spectrum that drifts through colour"
        case .aurora: return "Northern lights over a lake"
        case .silk: return "Flowing satin in your artwork's colours"
        case .drive: return "A rainy night drive in a Creta"
        case .waves: return "A soft glow that listens, waves at its heart"
        case .halo: return "Artwork ringed by the spectrum"
        case .classic: return "LED spectrum analyser and oscilloscope"
        case .warp: return "Tunnels of colour from the waveform"
        }
    }
    /// GPU scenes run through the Metal pipeline; Spectrum uses SwiftUI Canvas.
    var metalScene: MetalScene? {
        switch self {
        case .lyricPop: return .calm
        case .singAlong: return .stage
        case .spectrum: return nil
        case .aurora: return .aurora
        case .silk: return .silk
        case .drive: return .drive
        case .waves: return .waves
        case .halo: return .halo
        case .classic: return .classic
        case .warp: return .warp
        }
    }
    var isGPU: Bool { metalScene != nil }
    /// Styles that show synced lyrics over a GPU backdrop.
    var isLyrics: Bool { self == .lyricPop || self == .singAlong }
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
    var sponsorBlock: Bool { didSet { save(sponsorBlock, "sponsorBlock") } }
    var sponsorCategories: [String] { didSet { save(sponsorCategories, "sponsorCategories") } }
    var resumeLongVideos: Bool { didSet { save(resumeLongVideos, "resumeLongVideos") } }
    var notifyTrackChanges: Bool { didSet { save(notifyTrackChanges, "notifyTrackChanges") } }

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
        visualizerStyle = string("visualizerStyle", VisualizerStyle.drive)
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
        sponsorBlock = bool("sponsorBlock", true)
        sponsorCategories = defaults.stringArray(forKey: "sponsorCategories") ?? ["sponsor", "selfpromo", "interaction", "music_offtopic"]
        resumeLongVideos = bool("resumeLongVideos", true)
        notifyTrackChanges = bool("notifyTrackChanges", false)
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
