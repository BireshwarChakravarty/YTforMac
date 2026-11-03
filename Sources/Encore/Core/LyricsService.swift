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
    case youtubeMusic = "YouTube Music"
    case lrclib = "LRCLIB"
    case netease = "NetEase"
    case captions = "YouTube captions"
    case autoCaptions = "Auto-captions"
    case demo = "Demo"
}

/// Finds lyrics for whatever is playing. It asks several sources at once and
/// keeps the best match:
///   1. time-synced lyrics from YouTube Music (linked to this exact video),
///      LRCLIB and NetEase Cloud Music, compared by how well their length
///      matches the video;
///   2. the video's hand-made captions;
///   3. plain lyrics (YouTube Music, LRCLIB) with timings estimated from the
///      song's length;
///   4. the video's auto-generated captions, so even talks and podcasts get words.
@MainActor
@Observable
final class LyricsService {
    enum State: Equatable {
        case idle
        case searching
        case synced([LyricLine], LyricsSource)
        /// Lyrics without timings when the length is unknown (live streams).
        case plain([String])
        case instrumental
        case notFound
    }

    private(set) var state: State = .idle
    /// True when the timings were estimated rather than published with the lyrics.
    private(set) var approximate = false
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
    @ObservationIgnored private var cache: [String: (State, Bool)] = [:]
    @ObservationIgnored weak var player: PlayerEngine?

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
        // Wait for the duration so versions can be matched, but don't stall forever.
        guard duration > 0 || pendingSince(videoId) > 3 else { return }
        trackKey = videoId
        offset = 0
        if let cached = cache[videoId] {
            state = cached.0
            approximate = cached.1
            return
        }
        state = .searching
        approximate = false
        task?.cancel()
        let query = LyricsQuery(title: title, channel: author, duration: duration)
        let region = Locale.current.region?.identifier ?? "US"
        task = Task { [weak self] in
            let found = await Self.resolve(videoId: videoId, query: query, region: region)
            guard let self, !Task.isCancelled, self.trackKey == videoId else { return }
            if let best = found.timed, let lines = best.lines {
                self.finish(.synced(lines, best.source), approximate: false, for: videoId)
                return
            }
            if let captions = await self.captionLyrics(videoId: videoId, automatic: false) {
                guard self.trackKey == videoId else { return }
                self.finish(.synced(captions, .captions), approximate: false, for: videoId)
                return
            }
            let length = found.length > 0 ? found.length : (self.player?.duration ?? 0)
            if let plain = found.plain, let text = plain.plain, length > 0 {
                let lines = LRC.estimated(text, duration: length)
                if !lines.isEmpty {
                    self.finish(.synced(lines, plain.source), approximate: true, for: videoId)
                    return
                }
            }
            if !found.instrumental, let captions = await self.captionLyrics(videoId: videoId, automatic: true) {
                guard self.trackKey == videoId else { return }
                self.finish(.synced(captions, .autoCaptions), approximate: false, for: videoId)
                return
            }
            if found.instrumental {
                self.finish(.instrumental, approximate: false, for: videoId)
            } else if let text = found.plain?.plain {
                self.finish(.plain(text), approximate: false, for: videoId)
            } else {
                self.finish(.notFound, approximate: false, for: videoId)
            }
        }
    }

    /// Looks the current track up again (e.g. after the network came back).
    func retry() {
        guard let player else { return }
        cache[trackKey] = nil
        trackKey = ""
        update(videoId: player.videoId, title: player.title, author: player.author, duration: player.duration, isAd: player.isAd)
    }

    private func finish(_ result: State, approximate: Bool, for videoId: String) {
        cache[videoId] = (result, approximate)
        state = result
        self.approximate = approximate
        let summary: String
        switch result {
        case .synced(let l, let s): summary = "synced \(l.count) lines from \(s.rawValue)\(approximate ? " (estimated timing)" : "")"
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
        approximate = false
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
        approximate = false
        state = .synced(LRC.parse(Self.demoLRC), .demo)
    }

    // MARK: Choosing between sources

    struct Resolution {
        var timed: LyricsCandidate?
        var plain: LyricsCandidate?
        var instrumental = false
        /// The song's length (the video's, or YouTube Music's when unknown).
        var length: Double = 0
        var candidates: [LyricsCandidate] = []
    }

    /// Asks every network source at once; retries LRCLIB and NetEase with the
    /// song details YouTube Music recognises when the title alone wasn't enough.
    nonisolated static func resolve(videoId: String, query: LyricsQuery, region: String) async -> Resolution {
        async let ytmTask = YouTubeMusicLyrics.lookup(videoId: videoId, region: region)
        async let lrcTask = LRCLibLyrics.lookup(query)
        async let neTask = NetEaseLyrics.lookup(query)
        let ytm = await ytmTask
        var candidates = await lrcTask
        if let n = await neTask { candidates.append(n) }
        if let c = ytm.candidate { candidates.append(c) }
        let duration = query.duration > 0 ? query.duration : (ytm.meta?.duration ?? 0)

        if let meta = ytm.meta, !meta.artist.isEmpty,
           (best(candidates, duration: duration).map { score($0, duration: duration) } ?? 0) < 130 {
            let q2 = LyricsQuery(artist: meta.artist, track: LyricsQuery.stripFeaturing(LyricsQuery.clean(meta.title)), duration: duration)
            if normalizedTitle(q2.track) != normalizedTitle(query.track) || normalizedTitle(q2.artist) != normalizedTitle(query.artist) {
                async let l2 = LRCLibLyrics.lookup(q2)
                async let n2 = NetEaseLyrics.lookup(q2)
                candidates += await l2
                if let n = await n2 { candidates.append(n) }
            }
        }

        var r = Resolution(length: duration, candidates: candidates)
        r.timed = best(candidates, duration: duration)
        // Plain text: YouTube Music's is tied to this video, so it comes first.
        r.plain = candidates.first(where: { $0.plain != nil && $0.exactVideo }) ?? candidates.first(where: { $0.plain != nil })
            ?? candidates.first(where: { $0.lines != nil }).map { c in
                var p = c; p.plain = c.lines?.map(\.text); p.lines = nil; return p
            }
        r.instrumental = r.timed == nil && r.plain == nil && candidates.contains(where: { $0.instrumental })
        return r
    }

    /// How much to trust a synced candidate: matching length matters most, then
    /// whether YouTube Music linked it to this exact video.
    nonisolated static func score(_ c: LyricsCandidate, duration: Double) -> Double {
        guard let lines = c.lines, lines.filter({ !$0.text.isEmpty }).count >= 3 else { return -1 }
        var s = 100.0
        if c.exactVideo { s += 35 }
        if let d = c.trackDuration, d > 0, duration > 0 {
            let diff = abs(d - duration)
            s += diff < 2 ? 40 : diff < 5 ? 28 : diff < 12 ? 10 : diff < 30 ? -15 : -60
        }
        if c.source == .lrclib { s += 2 }   // tie-break: LRCLIB timings are hand-checked
        return s
    }

    nonisolated static func best(_ candidates: [LyricsCandidate], duration: Double) -> LyricsCandidate? {
        candidates.filter { score($0, duration: duration) >= 60 }
            .max { score($0, duration: duration) < score($1, duration: duration) }
    }

    // MARK: YouTube captions

    /// Reads a caption track from the player page: hand-made captions, or with
    /// `automatic`, YouTube's speech recognition. YouTube now requires a token
    /// to download captions directly, so when that fails Encore turns captions
    /// on (hidden) and captures the file the player itself downloads.
    private func captionLyrics(videoId: String, automatic: Bool) async -> [LyricLine]? {
        guard let webView = player?.webView else { return nil }
        let js = """
        const p = document.getElementById('movie_player');
        const resp = (p && p.getPlayerResponse && p.getPlayerResponse()) || window.ytInitialPlayerResponse || {};
        if (!resp.videoDetails || resp.videoDetails.videoId !== vid) return null;
        const tracks = ((resp.captions || {}).playerCaptionsTracklistRenderer || {}).captionTracks || [];
        const pool = tracks.filter(t => auto ? t.kind === 'asr' : t.kind !== 'asr');
        if (!pool.length) return null;
        const pref = (navigator.language || 'en').slice(0, 2);
        const pick = pool.find(t => t.languageCode && t.languageCode.indexOf(pref) === 0) || pool.find(t => /^en/.test(t.languageCode)) || pool[0];
        const parse = (text) => {
          if (!text) return null;
          text = text.trim();
          if (text[0] === '{') {
            const j = JSON.parse(text);
            return (j.events || []).filter(e => e.segs).map(e => [e.tStartMs / 1000, (e.dDurationMs || 0) / 1000, e.segs.map(s => s.utf8 || '').join('')]);
          }
          const doc = new DOMParser().parseFromString(text, 'text/xml');
          const ps = Array.from(doc.getElementsByTagName('p'));
          if (ps.length) return ps.map(n => [(+n.getAttribute('t') || 0) / 1000, (+n.getAttribute('d') || 0) / 1000, n.textContent || '']);
          return Array.from(doc.getElementsByTagName('text')).map(n => [+n.getAttribute('start') || 0, +n.getAttribute('dur') || 0, n.textContent || '']);
        };
        let rows = null;
        try {
          const r = await fetch(pick.baseUrl + '&fmt=json3', { credentials: 'include' });
          rows = parse(await r.text());
        } catch (e) {}
        if (rows && rows.length) return rows;
        let wasOn = false;
        try { const cur = p.getOption('captions', 'track'); wasOn = !!(cur && cur.languageCode); } catch (e) {}
        const text = await new Promise(resolve => {
          let done = false;
          const finish = (t) => { if (!done) { done = true; window.__encoreCaptionSink = null; resolve(t || ''); } };
          window.__encoreCaptionSink = (url, t) => { if (url.indexOf('v=' + vid) >= 0 || url.indexOf(vid) >= 0) finish(t); };
          if (!wasOn) document.documentElement.classList.add('encore-cc-hidden');
          try {
            p.loadModule('captions');
            p.setOption('captions', 'track', { languageCode: pick.languageCode, kind: pick.kind || '' });
          } catch (e) {}
          setTimeout(() => finish(''), 7000);
        });
        if (!wasOn) {
          try { p.unloadModule('captions'); } catch (e) {}
          setTimeout(() => document.documentElement.classList.remove('encore-cc-hidden'), 500);
        }
        try { return parse(text); } catch (e) { return null; }
        """
        do {
            let result = try await webView.callAsyncJavaScript(js, arguments: ["vid": videoId, "auto": automatic], in: nil, in: .page)
            guard let rows = result as? [[Any]] else { return nil }
            var cues: [(Double, Double, String)] = []
            for row in rows where row.count == 3 {
                let start = (row[0] as? NSNumber)?.doubleValue ?? 0
                let dur = (row[1] as? NSNumber)?.doubleValue ?? 0
                let text = (row[2] as? String ?? "")
                    .replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "\u{266A}", with: "")
                    .replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression)   // [Music], [Applause]
                    .trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }
                cues.append((start, start + dur, text))
            }
            guard cues.count >= 3 else { return nil }
            return LRC.lines(from: automatic ? LRC.mergeShortCues(cues) : cues)
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

/// Artist and track guessed from a YouTube title and channel.
struct LyricsQuery {
    let artist: String
    let track: String
    let fullTitle: String
    let duration: Double

    init(artist: String, track: String, duration: Double) {
        self.artist = artist
        self.track = track
        self.fullTitle = artist.isEmpty ? track : "\(artist) \(track)"
        self.duration = duration
    }

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

    /// Timings for plain lyrics: lines are spread over the song (after a short
    /// intro, before the outro) in proportion to their length, with blank lines
    /// as breathing pauses. Approximate, but it keeps the words moving.
    static func estimated(_ text: [String], duration: Double) -> [LyricLine] {
        var rows = text.map { $0.trimmingCharacters(in: .whitespaces) }
        while rows.first?.isEmpty == true { rows.removeFirst() }
        while rows.last?.isEmpty == true { rows.removeLast() }
        var collapsed: [String] = []
        for r in rows where !(r.isEmpty && collapsed.last?.isEmpty == true) {
            // Section labels like "[Chorus]" aren't sung.
            if r.hasPrefix("[") && r.hasSuffix("]") { continue }
            collapsed.append(r)
        }
        guard collapsed.contains(where: { !$0.isEmpty }), duration > 20 else { return [] }
        let start = min(max(6, duration * 0.07), 25)
        let end = duration * 0.93
        let weights = collapsed.map { $0.isEmpty ? 14.0 : Double(max(8, $0.count)) + 6 }
        let total = weights.reduce(0, +)
        var t = start
        var cues: [(Double, String, [(Double, String)])] = []
        for (i, row) in collapsed.enumerated() {
            cues.append((t, row, []))
            t += (end - start) * weights[i] / total
        }
        return build(cues)
    }

    /// Auto-captions arrive as short overlapping fragments; join them into
    /// phrases a few seconds long.
    static func mergeShortCues(_ cues: [(Double, Double, String)]) -> [(Double, Double, String)] {
        var out: [(Double, Double, String)] = []
        for c in cues {
            if var last = out.last, c.0 - last.0 < 3.5, last.2.count + c.2.count < 48, c.0 - last.1 < 1.0 {
                last.1 = max(last.1, c.1)
                last.2 += " " + c.2
                out[out.count - 1] = last
            } else {
                out.append(c)
            }
        }
        return out
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
