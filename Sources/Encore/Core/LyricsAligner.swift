import Foundation

/// Aligns lyrics to the video that's actually playing.
///
/// Lyrics databases time their lyrics to the album track, but music videos often
/// add an intro, a skit or an outro, which throws every line off. YouTube's
/// captions (hand-made or speech-recognised, which carry per-word timings) are
/// in the video's own time, so matching their words against the lyrics tells
/// us how far each part of the song is shifted.
///
/// Words are compared as consonant "skeletons", which makes "tere bin" match
/// "तेरे बिन" and survives the spelling noise of auto-captions. Matches are
/// chained in order (longest increasing sequence), outliers are dropped, and the
/// remaining anchors give a smooth time map from lyric time to video time.
enum LyricsAligner {
    struct Word {
        let time: Double
        let text: String
    }

    struct Alignment {
        let lines: [LyricLine]
        /// Matching words that agree with each other (more = more trustworthy).
        let anchors: Int
        /// Share of the song's lyrics span the anchors cover.
        let coverage: Double
        /// How far the first line moved.
        let shiftAtStart: Double
    }

    /// Returns the lines re-timed to the video, or nil when there isn't enough
    /// evidence to trust an alignment. `reestimate` re-spreads the words inside
    /// each line (for lyrics whose timings were estimated in the first place).
    static func align(_ lines: [LyricLine], to captions: [Word], reestimate: Bool) -> Alignment? {
        let sung = lines.filter { !$0.text.isEmpty }
        guard sung.count >= 4, captions.count >= 8 else { return nil }

        var lyricWords: [Word] = []
        for line in sung {
            if line.words.isEmpty {
                lyricWords += line.text.split(separator: " ").map { Word(time: line.start, text: String($0)) }
            } else {
                lyricWords += line.words.map { Word(time: $0.start, text: $0.text) }
            }
        }
        let lyricTokens = tokens(lyricWords)
        let captionTokens = tokens(captions)
        var index: [String: [Double]] = [:]
        for t in captionTokens { index[t.text, default: []].append(t.time) }

        // Candidate matches (lyric time, video time), within a plausible window.
        var pairs: [(Double, Double)] = []
        for t in lyricTokens {
            guard let times = index[t.text], times.count <= 12 else { continue }
            for v in times where abs(v - t.time) < 150 { pairs.append((t.time, v)) }
        }
        guard pairs.count >= 5 else { return nil }
        let fallback = globalShift(pairs, lines: lines, sung: sung, reestimate: reestimate)

        // Longest chain increasing in both lyric and video time.
        pairs.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 > $1.1 }
        let chain = longestIncreasing(pairs)
        guard chain.count >= 6 else { return fallback }

        // Drop anchors that disagree with their neighbours, then smooth.
        let deltas = chain.map { $0.1 - $0.0 }
        let local = medianFilter(deltas, radius: 3)
        var anchors: [(Double, Double)] = []
        for (i, p) in chain.enumerated() where abs(deltas[i] - local[i]) <= 1.5 {
            anchors.append((p.0, deltas[i]))
        }
        // Speech recognition on music is noisy: insist the chain mostly agrees.
        guard anchors.count >= 6, Double(anchors.count) >= Double(chain.count) * 0.55 else { return fallback }
        let lyricSpan = (sung.last?.start ?? 0) - (sung.first?.start ?? 0)
        let covered = (anchors.last?.0 ?? 0) - (anchors.first?.0 ?? 0)
        guard covered >= min(30, lyricSpan * 0.3) else { return fallback }
        let smooth = medianFilter(anchors.map(\.1), radius: 2)
        let map = zip(anchors.map(\.0), smooth).map { ($0, $1) }

        func shift(_ t: Double) -> Double {
            if t <= map[0].0 { return map[0].1 }
            if t >= map[map.count - 1].0 { return map[map.count - 1].1 }
            var lo = 0, hi = map.count - 1
            while hi - lo > 1 {
                let mid = (lo + hi) / 2
                if map[mid].0 <= t { lo = mid } else { hi = mid }
            }
            let a = map[lo], b = map[hi]
            let f = (t - a.0) / max(b.0 - a.0, 1e-3)
            return a.1 + (b.1 - a.1) * f
        }

        var out: [LyricLine] = []
        var lastStart = -Double.infinity
        for line in lines {
            var start = line.start + shift(line.start)
            start = max(start, lastStart + 0.05)
            lastStart = start
            let end = max(start + 0.8, line.end + shift(line.end))
            let words: [LyricLine.Word]
            if reestimate || line.words.isEmpty {
                words = LRC.estimate(line.text, start: start, end: end)
            } else {
                let d = start - line.start
                words = line.words.map { .init(text: $0.text, start: $0.start + d, end: $0.end + d) }
            }
            out.append(LyricLine(id: line.id, start: start, end: end, text: line.text, words: words))
        }
        // Keep each line ending before the next one starts.
        for i in out.indices.dropLast() where out[i].end > out[i + 1].start {
            let l = out[i]
            out[i] = LyricLine(id: l.id, start: l.start, end: max(l.start + 0.3, out[i + 1].start), text: l.text,
                               words: reestimate ? LRC.estimate(l.text, start: l.start, end: max(l.start + 0.3, out[i + 1].start)) : l.words)
        }
        let shiftAtStart = (out.first(where: { !$0.text.isEmpty })?.start ?? 0) - (sung.first?.start ?? 0)
        return Alignment(lines: out, anchors: anchors.count, coverage: lyricSpan > 0 ? min(1, covered / lyricSpan) : 1,
                         shiftAtStart: shiftAtStart)
    }

    /// When the matches don't form a long enough chain, a single clear offset
    /// still fixes the common case (an intro or outro): the time difference most
    /// matches agree on, if it clearly beats every other.
    static func globalShift(_ pairs: [(Double, Double)], lines: [LyricLine], sung: [LyricLine], reestimate: Bool) -> Alignment? {
        let deltas = pairs.map { $0.1 - $0.0 }.sorted()
        guard deltas.count >= 5 else { return nil }
        var best = (count: 0, center: 0.0)
        for d in deltas {
            let n = deltas.filter { abs($0 - d) <= 0.75 }.count
            if n > best.count { best = (n, d) }
        }
        let others = deltas.filter { abs($0 - best.center) > 3.0 }
        var second = 0
        for d in others { second = max(second, others.filter { abs($0 - d) <= 0.75 }.count) }
        guard best.count >= 5, best.count >= second * 2 else { return nil }
        let window = deltas.filter { abs($0 - best.center) <= 0.75 }
        let shift = window[window.count / 2]
        let out = lines.map { l in
            LyricLine(id: l.id, start: l.start + shift, end: l.end + shift, text: l.text,
                      words: reestimate ? LRC.estimate(l.text, start: l.start + shift, end: l.end + shift)
                                        : l.words.map { .init(text: $0.text, start: $0.start + shift, end: $0.end + shift) })
        }
        let span = max((sung.last?.start ?? 0) - (sung.first?.start ?? 0), 1)
        return Alignment(lines: out, anchors: best.count, coverage: min(1, Double(best.count) * 4 / span), shiftAtStart: shift)
    }

    // MARK: Tokens

    /// Single words with a distinctive skeleton, plus adjacent-word pairs (which
    /// keep short-word languages like Hindi matchable).
    static func tokens(_ words: [Word]) -> [Word] {
        let skeletons = words.map { Word(time: $0.time, text: skeleton($0.text)) }.filter { !$0.text.isEmpty }
        var out: [Word] = []
        for (i, w) in skeletons.enumerated() {
            if w.text.count >= 3 { out.append(w) }
            if i + 1 < skeletons.count, skeletons[i + 1].time - w.time < 4 {
                let pair = w.text + skeletons[i + 1].text
                if pair.count >= 4 { out.append(Word(time: w.time, text: pair)) }
            }
        }
        return out
    }

    /// A rough consonant skeleton shared by English, romanised Hindi and
    /// Devanagari: vowels dropped, aspiration ignored, similar sounds merged.
    /// Other scripts keep their letters as they are.
    static func skeleton(_ word: String) -> String {
        let folded = word.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        var raw: [Character] = []
        let scalars = Array(folded.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let s = scalars[i]
            let v = s.value
            if (0x61...0x7A).contains(v) {
                let c = Character(s)
                let next = i + 1 < scalars.count ? Character(scalars[i + 1]) : " "
                switch c {
                case "a", "e", "i", "o", "u": break
                case "y":
                    // A consonant only before a vowel and after a consonant ("kya"),
                    // not as a glide between vowels ("jaayenge" ≈ "जाएंगे").
                    let prevVowel = i > 0 && "aeiou".contains(Character(scalars[i - 1]))
                    if "aeiou".contains(next), !prevVowel { raw.append("y") }
                case "n":
                    // Nasal before a consonant is usually an anusvara, which Devanagari skips.
                    if "bcdfgjklmnpqrstvwxz".contains(next) { break }
                    raw.append("n")
                case "c": if next == "h" { raw.append("c"); i += 1 } else { raw.append("k") }
                case "s": if next == "h" { raw.append("s"); i += 1 } else { raw.append("s") }
                case "p": if next == "h" { raw.append("f"); i += 1 } else { raw.append("p") }
                case "q": raw.append("k")
                case "x": raw.append("k"); raw.append("s")
                case "w": raw.append("v")
                case "z": raw.append("j")
                case "h": if raw.isEmpty || !(i > 0 && "bcdfgjklmnpqrstvwxz".contains(Character(scalars[i - 1]))) { raw.append("h") }
                default: raw.append(c)
                }
            } else if (0x0900...0x097F).contains(v) {
                if let c = devanagari[v] { raw.append(c) }
            } else if (0x30...0x39).contains(v) {
                raw.append(Character(s))
            } else if CharacterSet.letters.contains(s) {
                raw.append(Character(s))
            }
            i += 1
        }
        // Collapse doubled letters ("gonna" ≈ "gona").
        var out = ""
        for c in raw where out.last != c { out.append(c) }
        return out
    }

    private static let devanagari: [UInt32: Character] = {
        var m: [UInt32: Character] = [:]
        let table: [(UInt32, Character)] = [
            (0x0915, "k"), (0x0916, "k"), (0x0917, "g"), (0x0918, "g"), (0x0919, "n"),
            (0x091A, "c"), (0x091B, "c"), (0x091C, "j"), (0x091D, "j"), (0x091E, "n"),
            (0x091F, "t"), (0x0920, "t"), (0x0921, "d"), (0x0922, "d"), (0x0923, "n"),
            (0x0924, "t"), (0x0925, "t"), (0x0926, "d"), (0x0927, "d"), (0x0928, "n"),
            (0x092A, "p"), (0x092B, "f"), (0x092C, "b"), (0x092D, "b"), (0x092E, "m"),
            (0x092F, "y"), (0x0930, "r"), (0x0932, "l"), (0x0935, "v"), (0x0936, "s"),
            (0x0937, "s"), (0x0938, "s"), (0x0939, "h"),
            (0x0958, "k"), (0x0959, "k"), (0x095A, "g"), (0x095B, "j"), (0x095C, "r"),
            (0x095D, "r"), (0x095E, "f"), (0x095F, "y"),
        ]
        for (k, v) in table { m[k] = v }
        return m
    }()

    // MARK: Helpers

    /// Longest subsequence strictly increasing in video time (pairs are already
    /// sorted by lyric time, ties by descending video time).
    static func longestIncreasing(_ pairs: [(Double, Double)]) -> [(Double, Double)] {
        var tails: [Int] = []          // index of the smallest tail for each length
        var parent = [Int](repeating: -1, count: pairs.count)
        for (i, p) in pairs.enumerated() {
            var lo = 0, hi = tails.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if pairs[tails[mid]].1 < p.1 { lo = mid + 1 } else { hi = mid }
            }
            if lo > 0 { parent[i] = tails[lo - 1] }
            if lo == tails.count { tails.append(i) } else { tails[lo] = i }
        }
        var out: [(Double, Double)] = []
        var k = tails.last ?? -1
        while k >= 0 { out.append(pairs[k]); k = parent[k] }
        return out.reversed()
    }

    static func medianFilter(_ values: [Double], radius: Int) -> [Double] {
        values.indices.map { i in
            let window = values[max(0, i - radius)...min(values.count - 1, i + radius)].sorted()
            return window[window.count / 2]
        }
    }
}
