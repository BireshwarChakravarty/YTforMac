import AppKit
import CryptoKit
import Foundation
import Observation
import UserNotifications

/// The features around playback: SponsorBlock, chapters, the sleep timer,
/// resuming long videos where you left off, and track-change notifications.
/// Ticks four times a second while something plays.
@MainActor
@Observable
final class PlaybackExtras {
    // MARK: Chapters

    struct Chapter: Identifiable, Equatable {
        let start: Double
        let title: String
        var id: Double { start }
    }
    private(set) var chapters: [Chapter] = []

    /// The chapter the playhead is in.
    func currentChapter(at time: Double) -> Chapter? { chapters.last { $0.start <= time + 0.25 } }

    // MARK: Sleep timer

    enum SleepMode: Equatable {
        case off
        case at(Date)
        case endOfVideo
    }
    private(set) var sleep: SleepMode = .off
    /// Seconds left on a timed sleep (nil when off or at end of video).
    func sleepRemaining(now: Date = Date()) -> Double? {
        if case .at(let date) = sleep { return max(0, date.timeIntervalSince(now)) }
        return nil
    }

    // MARK: SponsorBlock

    struct Segment: Equatable {
        let start: Double
        let end: Double
        let category: String
    }
    private(set) var segments: [Segment] = []

    static let sponsorCategories: [(id: String, title: String)] = [
        ("sponsor", "Sponsors"), ("selfpromo", "Self-promotion"), ("interaction", "Like / subscribe reminders"),
        ("music_offtopic", "Non-music parts of music videos"), ("intro", "Intros"), ("outro", "Outros and end cards"),
        ("preview", "Previews and recaps"),
    ]

    // MARK: Plumbing

    private let player: PlayerEngine
    private let settings: AppSettings
    @ObservationIgnored var toast: ((String, String, String?, (() -> Void)?) -> Void)?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var currentId = ""
    @ObservationIgnored private var skipped = Set<Double>()
    @ObservationIgnored private var fading = false
    @ObservationIgnored private var lastNotifiedId = ""
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    // Crossfade: fading out the end of a video, then in the start of the next.
    @ObservationIgnored private var fadingOut = false
    @ObservationIgnored private var fadeInFrom: Date?
    @ObservationIgnored private var endedAt: Date?

    init(player: PlayerEngine, settings: AppSettings) {
        self.player = player
        self.settings = settings
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// Called on every player state change.
    func update() {
        guard player.videoId != currentId else { return }
        let previous = currentId
        currentId = player.videoId
        chapters = []
        segments = []
        skipped = []
        loadTask?.cancel()
        guard !currentId.isEmpty else { return }
        if case .endOfVideo = sleep, !previous.isEmpty {
            // The video we were waiting for ended and the next one started.
            player.pause()
            sleep = .off
            toast?("Sleep timer: paused", "moon.zzz.fill", nil, nil)
        }
        // Crossfade: the next video starts silent and fades in if the last one faded out.
        if fadingOut, settings.crossfade > 0 {
            player.setFade(0)
            fadeInFrom = Date()
        } else {
            fadeInFrom = nil
            player.setFade(1)
        }
        fadingOut = false
        endedAt = nil
        let id = currentId
        loadTask = Task { [weak self] in
            await self?.loadDetails(for: id)
        }
        notifyTrackChange()
    }

    private func tick() {
        guard player.hasMedia else { return }
        let t = player.position()
        // SponsorBlock: jump over a segment once per visit
        if settings.sponsorBlock, player.isPlaying, !player.isAd {
            for s in segments where t >= s.start && t < s.end - 0.6 && !skipped.contains(s.start) {
                skipped.insert(s.start)
                player.seek(to: s.end)
                let back = s.start
                let undo: () -> Void = { [weak self] in self?.player.seek(to: back + 0.1) }
                toast?("Skipped \(Self.label(for: s.category))", "forward.fill", "Undo", undo)
                break
            }
        }
        // Resume: remember where we are in long videos
        if settings.resumeLongVideos, player.duration > 600, !player.isLive, !player.isAd {
            ResumeStore.shared.record(id: player.videoId, position: t, duration: player.duration)
        }
        // Crossfade
        let xf = settings.crossfade
        if !fading {
            if let from = fadeInFrom {
                let k = player.isAd ? 1 : min(1, Date().timeIntervalSince(from) / max(1, xf))
                player.setFade(k * k * (3 - 2 * k))
                if k >= 1 { fadeInFrom = nil }
            } else if xf > 0, player.duration > xf * 3, !player.isLive, !player.isAd {
                let left = player.duration - t
                if left <= xf {
                    let k = max(0, left / xf)
                    player.setFade(k * k * (3 - 2 * k))
                    fadingOut = true
                    // Paused at the end (autoplay off): bring the volume back.
                    if !player.isPlaying, left < 1.5 {
                        if endedAt == nil { endedAt = Date() }
                        if let e = endedAt, Date().timeIntervalSince(e) > 3 { player.setFade(1); fadingOut = false }
                    }
                } else if fadingOut {
                    fadingOut = false            // seeked back out of the fade
                    player.setFade(1)
                }
            }
        }
        // Sleep timer
        switch sleep {
        case .off:
            break
        case .at(let date):
            let left = date.timeIntervalSinceNow
            if left <= 8, !fading, player.isPlaying { fadeOutAndPause(over: max(1, left)) }
        case .endOfVideo:
            if player.duration > 0, !player.isLive, player.duration - t <= 6, !fading, player.isPlaying {
                fadeOutAndPause(over: max(1, player.duration - t - 0.4))
            }
        }
    }

    // MARK: Sleep timer

    func setSleep(minutes: Int?) {
        if let minutes { sleep = .at(Date().addingTimeInterval(Double(minutes) * 60)) } else { sleep = .off }
        if let minutes { toast?("Sleep in \(minutes) minutes", "moon.zzz.fill", nil, nil) }
    }

    func setSleepAtEndOfVideo() {
        sleep = .endOfVideo
        toast?("Sleep at the end of this video", "moon.zzz.fill", nil, nil)
    }

    private func fadeOutAndPause(over seconds: Double) {
        fading = true
        let steps = 24
        Task { [weak self] in
            for i in 1...steps {
                try? await Task.sleep(for: .seconds(seconds / Double(steps)))
                guard let self, self.sleep != .off else { break }
                self.player.setFade(1 - Double(i) / Double(steps))
            }
            guard let self else { return }
            if self.sleep != .off {
                self.player.pause()
                self.sleep = .off
                self.toast?("Sleep timer: paused", "moon.zzz.fill", nil, nil)
            }
            try? await Task.sleep(for: .seconds(0.8))
            self.player.setFade(1)
            self.fading = false
        }
    }

    // MARK: Chapters, SponsorBlock and resume, per video

    private func loadDetails(for id: String) async {
        // Chapters come from the description's timestamps (YouTube's own rule:
        // at least three, the first at 0:00, in order).
        for attempt in 0..<6 {
            if Task.isCancelled || id != currentId { return }
            if let text = await player.videoDescription(), !text.isEmpty {
                let parsed = Self.parseChapters(text)
                if id == currentId { chapters = parsed }
                break
            }
            try? await Task.sleep(for: .seconds(attempt < 2 ? 1 : 2))
        }
        if settings.sponsorBlock {
            let found = await Self.fetchSegments(id: id, categories: settings.sponsorCategories)
            if id == currentId { segments = found }
        }
        if settings.resumeLongVideos, let saved = ResumeStore.shared.position(for: id) {
            // Wait for the player to report the new video's duration, then jump.
            for _ in 0..<20 {
                if id != currentId { return }
                if player.duration > 600, !player.isAd, player.position() < 15 { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard id == currentId, !player.isAd, player.position() < 15 else { return }
            player.seek(to: saved)
            let startOver: () -> Void = { [weak self] in
                self?.player.seek(to: 0)
                ResumeStore.shared.forget(id: id)
            }
            toast?("Resumed at \(Self.clock(saved))", "clock.arrow.circlepath", "Start Over", startOver)
        }
    }

    func seek(to chapter: Chapter) { player.seek(to: chapter.start + 0.05) }

    func nextChapter() {
        let t = player.position()
        if let c = chapters.first(where: { $0.start > t + 1 }) { seek(to: c) }
    }

    func previousChapter() {
        let t = player.position()
        guard let i = chapters.lastIndex(where: { $0.start <= t + 0.25 }) else { return }
        // Within the first few seconds of a chapter, go to the one before it.
        let target = t - chapters[i].start < 3 && i > 0 ? chapters[i - 1] : chapters[i]
        seek(to: target)
    }

    static func parseChapters(_ text: String) -> [Chapter] {
        var out: [Chapter] = []
        let pattern = try! NSRegularExpression(pattern: #"(?:^|\s|\()((?:\d{1,2}:)?\d{1,2}:\d{2})(?=\s|\)|$|[\s\-–—|:])"#)
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let ns = line as NSString
            guard let m = pattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
            let stamp = ns.substring(with: m.range(at: 1))
            let parts = stamp.split(separator: ":").compactMap { Double($0) }
            let seconds = parts.reduce(0) { $0 * 60 + $1 }
            var title = ns.replacingCharacters(in: m.range(at: 1), with: "")
            let seps = CharacterSet(charactersIn: " -–—|:•·()[]\t")
            title = title.replacingOccurrences(of: #"^\s*\d{1,3}[.)]\s*"#, with: "", options: .regularExpression)
            title = title.trimmingCharacters(in: seps)
            title = title.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            if title.isEmpty { title = "Chapter \(out.count + 1)" }
            if let last = out.last, seconds <= last.start { continue }
            out.append(Chapter(start: seconds, title: title))
        }
        guard out.count >= 3, out.first?.start == 0 else { return [] }
        return out
    }

    // SponsorBlock's privacy-preserving lookup: only the first four characters
    // of the video ID's SHA-256 leave the Mac.
    private static func fetchSegments(id: String, categories: [String]) async -> [Segment] {
        guard !categories.isEmpty else { return [] }
        let hash = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
        let prefix = String(hash.prefix(4))
        var c = URLComponents(string: "https://sponsor.ajay.app/api/skipSegments/\(prefix)")!
        let cats = "[" + categories.map { "\"\($0)\"" }.joined(separator: ",") + "]"
        c.queryItems = [URLQueryItem(name: "categories", value: cats), URLQueryItem(name: "actionTypes", value: "[\"skip\"]")]
        guard let url = c.url else { return [] }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue("Encore (macOS)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        let match = list.first { ($0["videoID"] as? String) == id }
        let raw = match?["segments"] as? [[String: Any]] ?? []
        return raw.compactMap { s in
            guard let seg = s["segment"] as? [Double], seg.count == 2, seg[1] - seg[0] > 1 else { return nil }
            return Segment(start: seg[0], end: seg[1], category: s["category"] as? String ?? "sponsor")
        }.sorted { $0.start < $1.start }
    }

    private static func label(for category: String) -> String {
        switch category {
        case "sponsor": return "sponsor"
        case "selfpromo": return "self-promotion"
        case "interaction": return "reminder"
        case "music_offtopic": return "non-music part"
        case "intro": return "intro"
        case "outro": return "outro"
        case "preview": return "preview"
        default: return "segment"
        }
    }

    static func clock(_ t: Double) -> String {
        let s = Int(t.rounded(.down))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: Notifications

    private func notifyTrackChange() {
        guard settings.notifyTrackChanges, !NSApp.isActive, !player.isAd else { return }
        let id = currentId
        Task { [weak self] in
            // Give the title and artwork a moment to arrive.
            try? await Task.sleep(for: .seconds(2.5))
            guard let self, id == self.currentId, id != self.lastNotifiedId, !self.player.title.isEmpty else { return }
            self.lastNotifiedId = id
            let center = UNUserNotificationCenter.current()
            let granted = (try? await center.requestAuthorization(options: [.alert])) ?? false
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = self.player.title
            content.body = self.player.author
            if let image = self.player.artwork, let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("encore-\(id).png")
                if (try? png.write(to: url)) != nil, let a = try? UNNotificationAttachment(identifier: id, url: url) {
                    content.attachments = [a]
                }
            }
            try? await center.add(UNNotificationRequest(identifier: "track", content: content, trigger: nil))
        }
    }
}

/// Where you left off in long videos (over ten minutes), for the last 300.
@MainActor
final class ResumeStore {
    static let shared = ResumeStore()
    private var positions: [String: [Double]]   // id: [position, timestamp]
    private var dirty = false
    private var lastWrite = Date.distantPast

    private init() {
        positions = UserDefaults.standard.dictionary(forKey: "resumePositions") as? [String: [Double]] ?? [:]
    }

    func record(id: String, position: Double, duration: Double) {
        guard !id.isEmpty else { return }
        if position < 30 || duration - position < 45 {
            if positions.removeValue(forKey: id) != nil { dirty = true }
        } else {
            positions[id] = [position, Date().timeIntervalSince1970]
            dirty = true
        }
        if dirty, Date().timeIntervalSince(lastWrite) > 5 { flush() }
    }

    func position(for id: String) -> Double? { positions[id]?.first }

    func forget(id: String) {
        positions.removeValue(forKey: id)
        flush()
    }

    private func flush() {
        if positions.count > 300 {
            let keep = positions.sorted { ($0.value.last ?? 0) > ($1.value.last ?? 0) }.prefix(300)
            positions = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        UserDefaults.standard.set(positions, forKey: "resumePositions")
        dirty = false
        lastWrite = Date()
    }
}
