import Foundation
import Observation
import WebKit

/// One timed line of lyrics. `words` carries per-word start times, either from
/// enhanced LRC (`<mm:ss.xx>` tags) or estimated by spreading the line's time
/// across its words.
struct LyricLine: Identifiable, Equatable {
    struct Word: Equatable {
        let text: String
        let start: Double
        let end: Double
    }
    let id: Int
    let start: Double
    let end: Double
    let text: String
    let words: [Word]

    /// 0…1 progress through the line at time `t`, following word timings so the
    /// karaoke wipe slows on long words and pauses between phrases.
    func progress(at t: Double) -> Double {
        guard t > start else { return 0 }
        guard t < end, !words.isEmpty else { return 1 }
        let total = Double(text.count)
        var done = 0.0
        for (i, w) in words.enumerated() {
            let len = Double(w.text.count + (i < words.count - 1 ? 1 : 0))
            if t >= w.end { done += len; continue }
            if t > w.start { done += len * (t - w.start) / max(0.05, w.end - w.start) }
            break
        }
        return min(1, done / max(1, total))
    }
}

/// Where the lyrics came from (shown as a small credit).
enum LyricsSource: String {
    case lrclib = "LRCLIB"
    case captions = "YouTube captions"
    case demo = "Demo"
}

/// Finds synced lyrics for whatever is playing: LRCLIB first (free, open,
/// time-synced LRC), then the video's own captions as a fallback.
@MainActor
@Observable
final class LyricsService {
    enum State: Equatable {
        case idle
        case searching
        case synced([LyricLine], LyricsSource)
        /// Lyrics without timings: shown as a slow scroll.
        case plain([String])
        case instrumental
        case notFound
    }

    private(set) var state: State = .idle
    /// The track the current state belongs to.
    private(set) var trackKey = ""
    /// User nudge for out-of-sync lyrics, in seconds (positive shows lines later).
    var offset: Double = 0

    var lines: [LyricLine] {
        if case .synced(let l, _) = state { return l }
        return []
    }
    var source: LyricsSource? {
        if case .synced(_, let s) = state { return s }
        return nil
    }

    /// When set, lyrics follow this clock instead of the player (CI demo mode).
    @ObservationIgnored private(set) var demoStart: Date?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var cache: [String: State] = [:]
    @ObservationIgnored weak var player: PlayerEngine?

    nonisolated static let userAgent = "Encore/1.1.0 (https://github.com/BireshwarChakravarty/YTforMac)"

    /// Lyric time at `date`: the playhead, adjusted by the user's offset.
    func time(at date: Date = Date()) -> Double {
        if let demoStart { return date.timeIntervalSince(demoStart) }
        return (player?.position(at: date) ?? 0) - offset
    }

    /// Index of the line being sung at `t`, or nil before the first line.
    func currentIndex(at t: Double) -> Int? {
        let l = lines
        guard !l.isEmpty, t >= l[0].start else { return nil }
        var lo = 0, hi = l.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if l[mid].start <= t { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    // MARK: Lookup

    /// Called on every player state change; starts a lookup when a new track has
    /// enough metadata.
    func update(videoId: String, title: String, author: String, duration: Double, isAd: Bool) {
        guard demoStart == nil else { return }
        guard !videoId.isEmpty else {
            reset()
            return
        }
        guard !isAd, !title.isEmpty, videoId != trackKey else { return }
        // Wait for the duration so LRCLIB can match the right version, but don't stall forever.
        guard duration > 0 || pendingSince(videoId) > 3 else { return }
        trackKey = videoId
        offset = 0
        if let cached = cache[videoId] {
            state = cached
            return
        }
        state = .searching
        task?.cancel()
        let query = LyricsQuery(title: title, channel: author, duration: duration)
        task = Task { [weak self] in
            let result = await Self.lookup(query)
            guard let self, !Task.isCancelled, self.trackKey == videoId else { return }
            if case .notFound = result, let captions = await self.captionLyrics(videoId: videoId), !captions.isEmpty {
                guard self.trackKey == videoId else { return }
                self.finish(.synced(captions, .captions), for: videoId)
                return
            }
            self.finish(result, for: videoId)
        }
    }

    /// Looks the current track up again (e.g. after the network came back).
    func retry() {
        guard let player else { return }
        cache[trackKey] = nil
        trackKey = ""
        update(videoId: player.videoId, title: player.title, author: player.author, duration: player.duration, isAd: player.isAd)
    }

    private func finish(_ result: State, for videoId: String) {
        cache[videoId] = result
        state = result
        let summary: String
        switch result {
        case .synced(let l, let s): summary = "synced \(l.count) lines from \(s.rawValue)"
        case .plain(let l): summary = "plain \(l.count) lines"
        case .instrumental: summary = "instrumental"
        case .notFound: summary = "not found"
        default: summary = "\(result)"
        }
        print("LYRICS \(videoId): \(summary)")
    }

    private func reset() {
        task?.cancel()
        trackKey = ""
        state = .idle
    }

    @ObservationIgnored private var firstSeen: (id: String, at: Date) = ("", .distantPast)
    private func pendingSince(_ id: String) -> Double {
        if firstSeen.id != id { firstSeen = (id, Date()) }
        return Date().timeIntervalSince(firstSeen.at)
    }

    /// Plays built-in sample lyrics on a free-running clock (used on CI, where
    /// YouTube can't play).
    func startDemo() {
        task?.cancel()
        demoStart = Date().addingTimeInterval(-1.2)
        trackKey = "demo"
        state = .synced(LRC.parse(Self.demoLRC), .demo)
    }

    // MARK: LRCLIB


    nonisolated static func lookup(_ q: LyricsQuery) async -> State {
        var candidates: [LRCLibRecord] = []
        if !q.artist.isEmpty, !q.track.isEmpty {
            var items = [URLQueryItem(name: "track_name", value: q.track), URLQueryItem(name: "artist_name", value: q.artist)]
            if q.duration > 0 { items.append(URLQueryItem(name: "duration", value: String(Int(q.duration.rounded())))) }
            if let one: LRCLibRecord = await fetch("get", items) { candidates.append(one) }
            if candidates.first?.syncedLyrics == nil, let many: [LRCLibRecord] = await fetch("search", [
                URLQueryItem(name: "track_name", value: q.track), URLQueryItem(name: "artist_name", value: q.artist)]) {
                candidates += many
            }
        }
        if !candidates.contains(where: { $0.syncedLyrics != nil }),
           let many: [LRCLibRecord] = await fetch("search", [URLQueryItem(name: "q", value: q.fullTitle)]) {
            candidates += many
        }
        guard !candidates.isEmpty else { return .notFound }

        // Prefer synced lyrics whose length matches the video.
        func score(_ r: LRCLibRecord) -> Double {
            var s = 0.0
            if r.syncedLyrics?.isEmpty == false { s += 100 }
            if let d = r.duration, q.duration > 0 {
                let diff = abs(d - q.duration)
                s += diff < 2 ? 40 : diff < 6 ? 25 : diff < 15 ? 5 : -40
            }
            if let t = r.trackName?.lowercased(), t == q.track.lowercased() { s += 10 }
            return s
        }
        let best = candidates.max(by: { score($0) < score($1) })!
        if let synced = best.syncedLyrics, !synced.isEmpty, score(best) > 60 || q.duration == 0 {
            let lines = LRC.parse(synced)
            if !lines.isEmpty { return .synced(lines, .lrclib) }
        }
        if best.instrumental == true { return .instrumental }
        if let plain = best.plainLyrics, !plain.isEmpty, score(best) > -20 {
            return .plain(plain.components(separatedBy: .newlines))
        }
        return .notFound
    }

    nonisolated private static func fetch<T: Decodable>(_ endpoint: String, _ items: [URLQueryItem]) async -> T? {
        var c = URLComponents(string: "https://lrclib.net/api/\(endpoint)")!
        c.queryItems = items
        guard let url = c.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("Encore", forHTTPHeaderField: "Lrclib-Client")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            return nil
        }
    }

    // MARK: YouTube captions fallback

    /// Reads a hand-made caption track from the player page (auto-generated
    /// captions are skipped: on music they're mostly "[Music]").
    private func captionLyrics(videoId: String) async -> [LyricLine]? {
        guard let webView = player?.webView else { return nil }
        let js = """
        const p = document.getElementById('movie_player');
        const resp = (p && p.getPlayerResponse && p.getPlayerResponse()) || window.ytInitialPlayerResponse || {};
        if (!resp.videoDetails || resp.videoDetails.videoId !== vid) return null;
        const tracks = ((resp.captions || {}).playerCaptionsTracklistRenderer || {}).captionTracks || [];
        const manual = tracks.filter(t => t.kind !== 'asr');
        if (!manual.length) return null;
        const pick = manual.find(t => /^en/.test(t.languageCode)) || manual[0];
        const r = await fetch(pick.baseUrl + '&fmt=json3', {credentials: 'include'});
        const text = await r.text();
        if (!text) return null;
        const j = JSON.parse(text);
        return (j.events || []).filter(e => e.segs).map(e => [e.tStartMs / 1000, (e.dDurationMs || 0) / 1000, e.segs.map(s => s.utf8 || '').join('')]);
        """
        do {
            let result = try await webView.callAsyncJavaScript(js, arguments: ["vid": videoId], in: nil, in: .page)
            guard let rows = result as? [[Any]] else { return nil }
            var cues: [(Double, Double, String)] = []
            for row in rows where row.count == 3 {
                let start = (row[0] as? NSNumber)?.doubleValue ?? 0
                let dur = (row[1] as? NSNumber)?.doubleValue ?? 0
                let text = (row[2] as? String ?? "")
                    .replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "♪", with: "")
                    .trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty, !text.hasPrefix("[") else { continue }
                cues.append((start, start + dur, text))
            }
            guard cues.count >= 4 else { return nil }
            return LRC.lines(from: cues)
        } catch {
            return nil
        }
    }

    // MARK: Demo

    /// Original sample verse for demo mode.
    static let demoLRC = """
    [00:00.00]
    [00:01.50]City lights are falling like rain
    [00:05.00]Every window hums a different name
    [00:08.50]Turn it up and let the night begin
    [00:12.00]We are glowing from the inside in
    [00:15.50]Hold on, hold on, the chorus is near
    [00:19.00]Sing it loud so the stars can hear
    [00:22.50]Oh, oh, oh, we're never coming down
    [00:26.00]Dancing on the edges of the sound
    [00:29.50]Encore, encore, play it one more time
    [00:33.00]Every heartbeat falling into rhyme
    [00:36.50]
    [00:40.00]City lights are falling like rain
    """
}

/// One result from the LRCLIB API.
private struct LRCLibRecord: Decodable {
    let trackName: String?
    let artistName: String?
    let duration: Double?
    let instrumental: Bool?
    let plainLyrics: String?
    let syncedLyrics: String?
}

/// Artist and track guessed from a YouTube title and channel.
struct LyricsQuery {
    let artist: String
    let track: String
    let fullTitle: String
    let duration: Double

    init(title: String, channel: String, duration: Double) {
        self.duration = duration
        let cleaned = Self.clean(title)
        self.fullTitle = cleaned
        let separators = [" - ", " – ", " — ", " -- ", " ~ "]
        if let sep = separators.first(where: { cleaned.contains($0) }),
           let range = cleaned.range(of: sep) {
            artist = String(cleaned[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            track = Self.stripFeaturing(String(cleaned[range.upperBound...]))
        } else if let open = cleaned.firstIndex(of: "\u{201C}") ?? cleaned.firstIndex(of: "\""),
                  let close = cleaned[cleaned.index(after: open)...].firstIndex(where: { $0 == "\u{201D}" || $0 == "\"" }) {
            // Artist "Title"
            artist = String(cleaned[..<open]).trimmingCharacters(in: .whitespaces)
            track = String(cleaned[cleaned.index(after: open)..<close])
        } else {
            artist = Self.cleanChannel(channel)
            track = Self.stripFeaturing(cleaned)
        }
    }

    /// Removes the decorations YouTube music titles carry.
    static func clean(_ title: String) -> String {
        var s = title
        let noise = ["official", "video", "audio", "lyric", "lyrics", "visuali", "music video", "mv", "m/v", "hd", "hq",
                     "4k", "8k", "remaster", "explicit", "clean", "color coded", "live", "performance", "full song",
                     "with lyrics", "letra", "legendado", "subtitulado", "out now", "premiere", "1080p", "720p"]
        // Bracketed segments mentioning any of the noise words.
        let pattern = #"[\(\[\{【「『](?:[^\)\]\}】」』]*)[\)\]\}】」』]"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let ns = s as NSString
            var out = s
            for m in regex.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed() {
                let seg = ns.substring(with: m.range).lowercased()
                if noise.contains(where: { seg.contains($0) }) || seg.contains("feat") || seg.contains("ft.") {
                    out = (out as NSString).replacingCharacters(in: m.range, with: "")
                }
            }
            s = out
        }
        // "Song | Movie | Label", "Song // Lyrics": keep the first part.
        for sep in [" | ", " // ", " ｜ "] {
            if let r = s.range(of: sep) { s = String(s[..<r.lowerBound]) }
        }
        // Unbracketed "Official Video", "Full Song", "Lyrical Video"…
        s = s.replacingOccurrences(of: #"\b(?:official|full|lyrical|lyric|music|hd|4k)\s+(?:music\s+)?(?:video|audio|song|visualizer)\b"#,
                                   with: "", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: CharacterSet(charactersIn: " -–—|·"))
    }

    static func stripFeaturing(_ s: String) -> String {
        let pattern = #"\s+(?:ft\.?|feat\.?|featuring|with)\s+.*$"#
        return s.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespaces)
    }

    static func cleanChannel(_ c: String) -> String {
        var s = c
        for suffix in [" - Topic", "VEVO", "Vevo", " Official", "Official"] where s.hasSuffix(suffix) {
            s = String(s.dropLast(suffix.count))
        }
        return s.trimmingCharacters(in: .whitespaces)
    }
}

/// LRC parsing: `[mm:ss.xx] line`, several stamps per line, and enhanced
/// `<mm:ss.xx> word` tags.
enum LRC {
    static func parse(_ text: String) -> [LyricLine] {
        var cues: [(Double, String, [(Double, String)])] = []
        var offset = 0.0
        let stamp = try! NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{1,2}(?:[.:]\d{1,3})?)\]"#)
        let wordStamp = try! NSRegularExpression(pattern: #"<(\d{1,3}):(\d{1,2}(?:[.:]\d{1,3})?)>"#)
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.lowercased().hasPrefix("[offset:") {
                let v = line.dropFirst(8).dropLast().trimmingCharacters(in: .whitespaces)
                offset = (Double(v) ?? 0) / 1000
                continue
            }
            let ns = line as NSString
            let matches = stamp.matches(in: line, range: NSRange(location: 0, length: ns.length))
            guard let last = matches.last, matches.first?.range.location == 0 else { continue }
            var body = ns.substring(from: last.range.location + last.range.length)
            // Enhanced LRC word timings.
            var words: [(Double, String)] = []
            let bodyNS = body as NSString
            let wordMatches = wordStamp.matches(in: body, range: NSRange(location: 0, length: bodyNS.length))
            if !wordMatches.isEmpty {
                for (i, m) in wordMatches.enumerated() {
                    let t = seconds(bodyNS, m) - offset
                    let from = m.range.location + m.range.length
                    let to = i + 1 < wordMatches.count ? wordMatches[i + 1].range.location : bodyNS.length
                    let w = bodyNS.substring(with: NSRange(location: from, length: to - from)).trimmingCharacters(in: .whitespaces)
                    if !w.isEmpty { words.append((t, w)) }
                }
                body = words.map(\.1).joined(separator: " ")
            }
            body = body.trimmingCharacters(in: .whitespaces)
            for m in matches {
                cues.append((seconds(ns, m) - offset, body, words))
            }
        }
        cues.sort { $0.0 < $1.0 }
        return build(cues)
    }

    /// Lines from caption cues (start, end, text).
    static func lines(from cues: [(Double, Double, String)]) -> [LyricLine] {
        var out: [(Double, String, [(Double, String)])] = []
        for (i, c) in cues.enumerated() {
            out.append((c.0, c.2, []))
            // Insert a gap when the caption ends well before the next one starts.
            let nextStart = i + 1 < cues.count ? cues[i + 1].0 : c.1 + 4
            if c.1 > c.0, nextStart - c.1 > 2.5 { out.append((c.1, "", [])) }
        }
        return build(out)
    }

    private static func build(_ cues: [(Double, String, [(Double, String)])]) -> [LyricLine] {
        var lines: [LyricLine] = []
        for (i, c) in cues.enumerated() {
            let next = i + 1 < cues.count ? cues[i + 1].0 : c.0 + 6
            // A line is "sung" for at most ~7 s; long gaps become instrumental breaks.
            let end = min(next, c.0 + max(2.5, min(7, Double(c.1.count) * 0.32)))
            let words: [LyricLine.Word]
            if !c.2.isEmpty {
                words = c.2.enumerated().map { j, w in
                    LyricLine.Word(text: w.1, start: w.0, end: j + 1 < c.2.count ? c.2[j + 1].0 : end)
                }
            } else {
                words = estimate(c.1, start: c.0, end: end)
            }
            lines.append(LyricLine(id: i, start: c.0, end: end, text: c.1, words: words))
        }
        // Drop leading/duplicate empty lines.
        var cleaned: [LyricLine] = []
        for l in lines where !(l.text.isEmpty && (cleaned.last?.text.isEmpty ?? true)) {
            cleaned.append(LyricLine(id: cleaned.count, start: l.start, end: l.end, text: l.text, words: l.words))
        }
        return cleaned
    }

    /// Spreads a line's duration over its words, weighted by length.
    static func estimate(_ text: String, start: Double, end: Double) -> [LyricLine.Word] {
        let parts = text.split(separator: " ").map(String.init)
        guard !parts.isEmpty else { return [] }
        // Singers land on the first word quickly and stretch the last one.
        let span = max(0.4, (end - start) * 0.88)
        let weights = parts.enumerated().map { i, w in Double(max(2, w.count)) + (i == parts.count - 1 ? 2 : 0) }
        let total = weights.reduce(0, +)
        var t = start
        var words: [LyricLine.Word] = []
        for (i, w) in parts.enumerated() {
            let d = span * weights[i] / total
            words.append(.init(text: w, start: t, end: t + d))
            t += d
        }
        return words
    }

    private static func seconds(_ s: NSString, _ m: NSTextCheckingResult) -> Double {
        let minutes = Double(s.substring(with: m.range(at: 1))) ?? 0
        let secs = Double(s.substring(with: m.range(at: 2)).replacingOccurrences(of: ":", with: ".")) ?? 0
        return minutes * 60 + secs
    }
}
