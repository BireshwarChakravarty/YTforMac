import Foundation

/// Lyrics offered by one source, before Encore picks the best.
struct LyricsCandidate {
    var lines: [LyricLine]?          // time-synced
    var plain: [String]?             // text only
    var source: LyricsSource
    var trackDuration: Double?       // length of the recording the lyrics were timed to
    var instrumental = false
    /// Linked to this very video by YouTube Music (no guessing involved).
    var exactVideo = false
}

/// The song YouTube Music recognises in a video.
struct MusicMetadata {
    let title: String
    let artist: String
    let duration: Double
}

private let safariUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

/// Walks a decoded JSON tree with string keys and integer indexes.
private func dig(_ value: Any?, _ path: Any...) -> Any? {
    var current = value
    for step in path {
        if let key = step as? String { current = (current as? [String: Any])?[key] }
        else if let index = step as? Int {
            guard let array = current as? [Any], array.indices.contains(index) else { return nil }
            current = array[index]
        }
    }
    return current
}

private func seconds(fromClock text: String) -> Double {
    text.split(separator: ":").reduce(0) { $0 * 60 + (Double($1) ?? 0) }
}

/// Normalised for loose title comparisons ("Tum Hi Ho (From Aashiqui 2)" ≈ "tum hi ho").
func normalizedTitle(_ s: String) -> String {
    let base = LyricsQuery.clean(s).lowercased()
        .replacingOccurrences(of: #"[\(\[].*?[\)\]]"#, with: "", options: .regularExpression)
    return String(base.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
}

private func titlesMatch(_ a: String, _ b: String) -> Bool {
    let x = normalizedTitle(a), y = normalizedTitle(b)
    guard !x.isEmpty, !y.isEmpty else { return false }
    return x == y || x.contains(y) || y.contains(x)
}

// MARK: - YouTube Music

/// YouTube Music's own lyrics (licensed from LyricFind/Musixmatch), looked up by
/// video id. Many are time-synced, including a lot of non-English music.
enum YouTubeMusicLyrics {
    static func lookup(videoId: String, region: String) async -> (meta: MusicMetadata?, candidate: LyricsCandidate?) {
        guard let next = await post("next", ["videoId": videoId, "isAudioOnly": true],
                                    client: "WEB_REMIX", version: "1.20251015.01.00", region: region),
              let tabs = dig(next, "contents", "singleColumnMusicWatchNextResultsRenderer", "tabbedRenderer",
                             "watchNextTabbedResultsRenderer", "tabs") as? [Any] else { return (nil, nil) }

        var meta: MusicMetadata?
        if let item = dig(tabs, 0, "tabRenderer", "content", "musicQueueRenderer", "content", "playlistPanelRenderer",
                          "contents", 0, "playlistPanelVideoRenderer") as? [String: Any],
           (item["videoId"] as? String) == videoId,
           let title = dig(item, "title", "runs", 0, "text") as? String {
            let byline = ((dig(item, "longBylineText", "runs") as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined()
            let artist = byline.components(separatedBy: " \u{2022} ").first ?? ""
            let length = (dig(item, "lengthText", "runs", 0, "text") as? String).map(seconds(fromClock:)) ?? 0
            meta = MusicMetadata(title: title, artist: artist, duration: length)
        }

        guard let tab = dig(tabs, 1, "tabRenderer") as? [String: Any], tab["unselectable"] as? Bool != true,
              let browseId = dig(tab, "endpoint", "browseEndpoint", "browseId") as? String else { return (meta, nil) }

        // The Android client returns timings; the web client only plain text.
        if let timed = await post("browse", ["browseId": browseId], client: "ANDROID_MUSIC", version: "7.21.50", region: region),
           let rows = dig(timed, "contents", "elementRenderer", "newElement", "type", "componentType", "model",
                          "timedLyricsModel", "lyricsData", "timedLyricsData") as? [[String: Any]], !rows.isEmpty {
            var cues: [(Double, Double, String)] = []
            for row in rows {
                guard let start = (dig(row, "cueRange", "startTimeMilliseconds") as? String).flatMap(Double.init) else { continue }
                let end = (dig(row, "cueRange", "endTimeMilliseconds") as? String).flatMap(Double.init) ?? start
                var text = (row["lyricLine"] as? String ?? "").trimmingCharacters(in: .whitespaces)
                if text == "\u{266A}" || text == "\u{266B}" { text = "" }
                cues.append((start / 1000, end / 1000, text))
            }
            if cues.count >= 3 {
                return (meta, LyricsCandidate(lines: LRC.lines(from: cues), source: .youtubeMusic,
                                              trackDuration: meta?.duration, exactVideo: true))
            }
        }
        if let page = await post("browse", ["browseId": browseId], client: "WEB_REMIX", version: "1.20251015.01.00", region: region),
           let text = dig(page, "contents", "sectionListRenderer", "contents", 0, "musicDescriptionShelfRenderer",
                          "description", "runs", 0, "text") as? String, !text.isEmpty {
            return (meta, LyricsCandidate(plain: text.components(separatedBy: .newlines), source: .youtubeMusic,
                                          trackDuration: meta?.duration, exactVideo: true))
        }
        return (meta, nil)
    }

    private static func post(_ endpoint: String, _ body: [String: Any], client: String, version: String, region: String) async -> [String: Any]? {
        var body = body
        body["context"] = ["client": ["clientName": client, "clientVersion": version, "hl": "en", "gl": region]]
        guard let url = URL(string: "https://music.youtube.com/youtubei/v1/\(endpoint)?prettyPrint=false"),
              let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(safariUA, forHTTPHeaderField: "User-Agent")
        request.setValue("https://music.youtube.com", forHTTPHeaderField: "Origin")
        guard let result = try? await URLSession.shared.data(for: request),
              (result.1 as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return (try? JSONSerialization.jsonObject(with: result.0)) as? [String: Any]
    }
}

// MARK: - LRCLIB

/// LRCLIB: a free, open database of time-synced lyrics.
enum LRCLibLyrics {
    private struct Record: Decodable {
        let trackName: String?
        let artistName: String?
        let duration: Double?
        let instrumental: Bool?
        let plainLyrics: String?
        let syncedLyrics: String?
    }

    static let userAgent = "Encore/1.1 (https://github.com/BireshwarChakravarty/YTforMac)"

    static func lookup(_ q: LyricsQuery) async -> [LyricsCandidate] {
        var records: [Record] = []
        if !q.artist.isEmpty, !q.track.isEmpty {
            var items = [URLQueryItem(name: "track_name", value: q.track), URLQueryItem(name: "artist_name", value: q.artist)]
            if q.duration > 0 { items.append(URLQueryItem(name: "duration", value: String(Int(q.duration.rounded())))) }
            if let one: Record = await fetch("get", items) { records.append(one) }
            if records.first?.syncedLyrics == nil, let many: [Record] = await fetch("search", [
                URLQueryItem(name: "track_name", value: q.track), URLQueryItem(name: "artist_name", value: q.artist)]) {
                records += many.filter { titlesMatch($0.trackName ?? "", q.track) }
            }
        }
        if !records.contains(where: { $0.syncedLyrics != nil }),
           let many: [Record] = await fetch("search", [URLQueryItem(name: "q", value: q.fullTitle)]) {
            records += many.filter { r in
                let name = normalizedTitle(r.trackName ?? "")
                return !name.isEmpty && (titlesMatch(r.trackName ?? "", q.track) || normalizedTitle(q.fullTitle).contains(name))
            }
        }
        var out: [LyricsCandidate] = []
        // Up to three synced versions; the picker compares their lengths with the video.
        let synced = records.filter { $0.syncedLyrics?.isEmpty == false }
            .sorted { abs(($0.duration ?? 0) - q.duration) < abs(($1.duration ?? 0) - q.duration) }
        for r in synced.prefix(3) {
            let lines = LRC.parse(r.syncedLyrics ?? "")
            if !lines.isEmpty { out.append(LyricsCandidate(lines: lines, source: .lrclib, trackDuration: r.duration)) }
        }
        if let r = records.first(where: { $0.plainLyrics?.isEmpty == false }) {
            out.append(LyricsCandidate(plain: r.plainLyrics!.components(separatedBy: .newlines), source: .lrclib, trackDuration: r.duration))
        }
        if out.isEmpty, records.contains(where: { $0.instrumental == true }) {
            out.append(LyricsCandidate(source: .lrclib, instrumental: true))
        }
        return out
    }

    private static func fetch<T: Decodable>(_ endpoint: String, _ items: [URLQueryItem]) async -> T? {
        var c = URLComponents(string: "https://lrclib.net/api/\(endpoint)")!
        c.queryItems = items
        guard let url = c.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("Encore", forHTTPHeaderField: "Lrclib-Client")
        guard let result = try? await URLSession.shared.data(for: request),
              (result.1 as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(T.self, from: result.0)
    }
}

// MARK: - NetEase Cloud Music

/// NetEase Cloud Music's public lyrics API: a very large catalogue of synced
/// lyrics, including plenty of Indian, Asian and Latin music.
enum NetEaseLyrics {
    private struct Search: Decodable {
        struct Result: Decodable { let songs: [Song]? }
        struct Song: Decodable {
            struct Artist: Decodable { let name: String }
            let id: Int
            let name: String
            let artists: [Artist]
            let duration: Double
        }
        let result: Result?
    }
    private struct Lyric: Decodable {
        struct Text: Decodable { let lyric: String? }
        let lrc: Text?
    }

    static func lookup(_ q: LyricsQuery) async -> LyricsCandidate? {
        guard !q.track.isEmpty else { return nil }
        let term = q.artist.isEmpty ? q.track : "\(q.artist) \(q.track)"
        var c = URLComponents(string: "https://music.163.com/api/search/get")!
        c.queryItems = [URLQueryItem(name: "s", value: term), URLQueryItem(name: "type", value: "1"), URLQueryItem(name: "limit", value: "12")]
        guard let url = c.url, let search: Search = await fetch(url), let songs = search.result?.songs else { return nil }

        let artist = normalizedTitle(q.artist)
        func score(_ s: Search.Song) -> Double? {
            guard titlesMatch(s.name, q.track) else { return nil }
            var v = 0.0
            if !artist.isEmpty, s.artists.contains(where: { let a = normalizedTitle($0.name); return !a.isEmpty && (artist.contains(a) || a.contains(artist)) }) { v += 30 }
            if q.duration > 0 {
                let diff = abs(s.duration / 1000 - q.duration)
                v += diff < 2 ? 30 : diff < 6 ? 20 : diff < 15 ? 5 : -20
            }
            if normalizedTitle(s.name) == normalizedTitle(q.track) { v += 5 }
            return v
        }
        let ranked = songs.compactMap { s in score(s).map { (s, $0) } }.sorted { $0.1 > $1.1 }
        for (song, _) in ranked.prefix(2) {
            guard let lyricURL = URL(string: "https://music.163.com/api/song/lyric?id=\(song.id)&lv=1&kv=1&tv=-1"),
                  let lyric: Lyric = await fetch(lyricURL), let text = lyric.lrc?.lyric, !text.isEmpty else { continue }
            if text.contains("\u{7EAF}\u{97F3}\u{4E50}") {   // "纯音乐": instrumental
                return LyricsCandidate(source: .netease, trackDuration: song.duration / 1000, instrumental: true)
            }
            let lines = LRC.parse(stripCredits(text))
            if lines.filter({ !$0.text.isEmpty }).count >= 3 {
                return LyricsCandidate(lines: lines, source: .netease, trackDuration: song.duration / 1000)
            }
        }
        return nil
    }

    /// Drops the "作词 : …" / "Composer : …" credit lines NetEase puts first.
    private static func stripCredits(_ text: String) -> String {
        let credit = try! NSRegularExpression(pattern: #"^\s*(\[[^\]]*\])+\s*[^\s:：]{1,24}\s*[:：]"#)
        let keywords = ["作", "编曲", "制作", "混音", "母带", "录音", "和声", "监制", "出品", "发行", "lyricist", "composer",
                        "producer", "arranger", "written by", "composed by", "produced by", "lyrics by", "music by"]
        return text.components(separatedBy: .newlines).filter { line in
            let ns = line as NSString
            guard credit.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) != nil else { return true }
            let lower = line.lowercased()
            return !keywords.contains(where: { lower.contains($0) })
        }.joined(separator: "\n")
    }

    private static func fetch<T: Decodable>(_ url: URL) async -> T? {
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue(safariUA, forHTTPHeaderField: "User-Agent")
        request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        guard let result = try? await URLSession.shared.data(for: request),
              (result.1 as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(T.self, from: result.0)
    }
}
