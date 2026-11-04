import AVFoundation
import CoreMedia
import Speech

/// Listens to the song that's playing (through the audio tap) with on-device
/// speech recognition, and reports the words it hears with their times in the
/// video. Lyrics are then aligned against what was actually sung, which fixes
/// intros, skits, outros and different edits of a song without needing captions.
///
/// On macOS 26+ it uses SpeechAnalyzer/SpeechTranscriber (on-device, long-form,
/// independent of the Siri & Dictation setting). On older systems it falls back
/// to SFSpeechRecognizer with on-device recognition, which needs Dictation on.
/// Either way audio never leaves the Mac.
final class LyricsListener: @unchecked Sendable {
    enum Status: Equatable {
        case off
        case needsPermission
        case unavailable(String)
        case listening(String)      // locale identifier
    }

    enum StartResult {
        case listening(String)
        case failed(String, needsPermission: Bool)
    }

    private let queue = DispatchQueue(label: "app.encore.lyrics.listener")
    private var startTime: Double = 0
    private var totalFed: Double = 0
    private var running = false
    private var generation = 0

    // legacy engine
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var tasks: [SFSpeechRecognitionTask] = []
    private var format: AVAudioFormat?
    private var chunkBase: Double = 0
    private var chunkFed: Double = 0
    private let chunkLength = 15.0

    // modern engine (macOS 26+), stored type-erased
    private var session: AnyObject?

    /// Called on the main queue with newly heard words (video time).
    var onWords: (([LyricsAligner.Word]) -> Void)?
    /// Called on the main queue when something goes wrong while listening.
    var onProblem: ((String) -> Void)?

    static var authorization: SFSpeechRecognizerAuthorizationStatus { SFSpeechRecognizer.authorizationStatus() }

    static func requestAuthorization(_ done: @escaping (Bool) -> Void) {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: done(true)
        case .notDetermined:
            SFSpeechRecognizer.requestAuthorization { status in
                DispatchQueue.main.async { done(status == .authorized) }
            }
        default: done(false)
        }
    }

    /// Languages to try for these lyrics, best first (BCP-47).
    static func localeCandidates(for lines: [LyricLine]) -> [String] {
        let text = lines.map(\.text).joined(separator: " ")
        var candidates: [String] = []
        if text.unicodeScalars.contains(where: { (0x0900...0x097F).contains($0.value) }) {
            candidates += ["hi-IN", "en-IN"]
        } else {
            let words = text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
            func share(_ list: Set<String>) -> Double {
                Double(words.filter { list.contains($0) }.count) / Double(max(words.count, 1))
            }
            let hindi: Set<String> = ["hai", "hain", "tere", "tera", "teri", "mera", "meri", "mere", "dil", "tum", "main", "hum", "kya", "nahi",
                                      "nahin", "pyaar", "pyar", "tujhe", "mujhe", "ke", "ki", "ko", "se", "bhi", "jo", "ho", "yeh", "woh", "kabhi"]
            let spanish: Set<String> = ["que", "de", "el", "la", "y", "mi", "te", "tu", "amor", "corazón", "no", "me", "yo", "es", "por", "con", "una"]
            let portuguese: Set<String> = ["você", "não", "meu", "minha", "coração", "eu", "que", "de", "com", "uma", "sem"]
            let french: Set<String> = ["je", "tu", "et", "le", "la", "les", "est", "pas", "mon", "ma", "moi", "toi", "amour", "dans"]
            if share(hindi) > 0.12 { candidates += ["hi-IN", "en-IN"] }
            else if share(portuguese) > 0.1 { candidates += ["pt-BR"] }
            else if share(spanish) > 0.14 { candidates += ["es-ES", "es-MX"] }
            else if share(french) > 0.12 { candidates += ["fr-FR"] }
        }
        return candidates + ["en-US", "en-GB"]
    }

    /// Starts listening with the best available engine. `completion` runs on main.
    func start(lines: [LyricLine], videoTime: Double, completion: @escaping (StartResult) -> Void) {
        let candidates = Self.localeCandidates(for: lines)
        stop()
        // Ask for Speech Recognition permission up front (macOS shows its prompt once).
        Self.requestAuthorization { [weak self] ok in
            guard let self else { return }
            if !ok && Self.authorization != .notDetermined {
                completion(.failed("Speech Recognition is turned off for Encore in System Settings", needsPermission: true))
                return
            }
            self.startEngines(candidates, videoTime: videoTime, completion: completion)
        }
    }

    private func startEngines(_ candidates: [String], videoTime: Double, completion: @escaping (StartResult) -> Void) {
        if #available(macOS 26.0, *) {
            Task {
                if let (locale, dictation) = await AnalyzerSession.bestLocale(candidates) {
                    let s = AnalyzerSession(base: videoTime, dictation: dictation)
                    s.onWords = { [weak self] words in self?.onWords?(words) }
                    s.onProblem = { [weak self] message in self?.onProblem?(message) }
                    do {
                        try await s.start(locale: locale)
                        self.queue.async {
                            self.session = s
                            self.generation += 1
                            self.running = true
                            self.startTime = videoTime
                            self.totalFed = 0
                        }
                        let engine = dictation ? "DictationTranscriber" : "SpeechTranscriber"
                        DispatchQueue.main.async { completion(.listening(locale.identifier(.bcp47) + ", " + engine)) }
                        return
                    } catch {
                        print("LISTENER SpeechAnalyzer couldn't start: \(error)")
                        DispatchQueue.main.async { self.onProblem?("SpeechAnalyzer couldn't start: \(error.localizedDescription)") }
                    }
                } else {
                    print("LISTENER SpeechAnalyzer has no model for \(candidates)")
                }
                DispatchQueue.main.async { self.startLegacy(candidates, videoTime: videoTime, completion: completion) }
            }
        } else {
            startLegacy(candidates, videoTime: videoTime, completion: completion)
        }
    }

    private func startLegacy(_ candidates: [String], videoTime: Double, completion: @escaping (StartResult) -> Void) {
        Self.requestAuthorization { [weak self] ok in
            guard let self else { return }
            guard ok else { completion(.failed("speech recognition is turned off for Encore", needsPermission: true)); return }
            guard let recognizer = candidates.lazy.compactMap({ SFSpeechRecognizer(locale: Locale(identifier: $0)) })
                .first(where: { $0.isAvailable && $0.supportsOnDeviceRecognition }) else {
                completion(.failed("no on-device speech recognition for this language", needsPermission: false))
                return
            }
            self.startLegacy(recognizer: recognizer, videoTime: videoTime)
            completion(.listening(recognizer.locale.identifier))
        }
    }

    /// Legacy engine with a given recogniser.
    func startLegacy(recognizer: SFSpeechRecognizer, videoTime: Double) {
        queue.async {
            self.cancelAll()
            self.generation += 1
            self.recognizer = recognizer
            self.running = true
            self.chunkBase = videoTime
            self.startTime = videoTime
            self.chunkFed = 0
            self.totalFed = 0
            self.beginChunk()
        }
    }

    /// Ends the current input so its words are delivered, then stops feeding.
    func flush() {
        queue.async {
            self.running = false
            self.request?.endAudio()
            self.request = nil
            if #available(macOS 26.0, *), let s = self.session as? AnalyzerSession {
                Task { await s.finish() }
            }
        }
    }

    func stop() {
        queue.async {
            self.running = false
            self.cancelAll()
        }
    }

    /// Where the listener thinks the playhead is (start + audio heard). Used to
    /// notice seeks and pauses, which require starting over.
    func timeline(_ done: @escaping (Double?) -> Void) {
        queue.async { done(self.running ? self.startTime + self.totalFed : nil) }
    }

    /// Audio thread → listener queue.
    func feed(_ samples: UnsafeBufferPointer<Float>, sampleRate: Double) {
        let copy = Array(samples)
        queue.async { self.append(copy, sampleRate) }
    }

    // MARK: Private (listener queue)

    private func append(_ samples: [Float], _ rate: Double) {
        guard running else { return }
        totalFed += Double(samples.count) / rate
        if #available(macOS 26.0, *), let s = session as? AnalyzerSession {
            s.feed(samples, rate: rate)
            return
        }
        guard let request else { return }
        if format?.sampleRate != rate { format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) }
        guard let format, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in channel.update(from: src.baseAddress!, count: samples.count) }
        request.append(buffer)
        chunkFed += Double(samples.count) / rate
        if chunkFed >= chunkLength {
            request.endAudio()
            chunkBase += chunkFed
            chunkFed = 0
            beginChunk()
        }
    }

    private func beginChunk() {
        guard let recognizer else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.taskHint = .dictation
        if #available(macOS 13, *) { request.addsPunctuation = false }
        self.request = request
        let base = chunkBase
        let gen = generation
        let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            if let error = error as NSError?, error.code != 216, error.code != 301 {   // 216/301: cancelled
                print("LISTENER recognition error \(error.domain) \(error.code): \(error.localizedDescription)")
                if error.code == 201 {
                    DispatchQueue.main.async { self?.onProblem?("Siri & Dictation is turned off, which the speech recogniser needs on this macOS version") }
                }
            }
            guard let self, let result, result.isFinal else { return }
            let words = result.bestTranscription.segments.compactMap { seg -> LyricsAligner.Word? in
                let w = seg.substring.trimmingCharacters(in: .whitespacesAndNewlines)
                return w.isEmpty ? nil : LyricsAligner.Word(time: base + seg.timestamp, text: w)
            }
            guard !words.isEmpty else { return }
            self.queue.async {
                guard gen == self.generation else { return }
                DispatchQueue.main.async { self.onWords?(words) }
            }
        }
        tasks.append(task)
        if tasks.count > 4 { tasks.removeFirst() }
    }

    private func cancelAll() {
        request?.endAudio()
        request = nil
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        if #available(macOS 26.0, *), let s = session as? AnalyzerSession { s.cancel() }
        session = nil
    }
}

/// One continuous SpeechAnalyzer run (macOS 26+): audio in, timed words out.
@available(macOS 26.0, *)
final class AnalyzerSession: @unchecked Sendable {
    private let base: Double
    private var analyzer: SpeechAnalyzer?
    private var builder: AsyncStream<AnalyzerInput>.Continuation?
    private var format: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var resultsTask: Task<Void, Never>?
    var onWords: (([LyricsAligner.Word]) -> Void)?
    var onProblem: ((String) -> Void)?

    private let dictation: Bool

    init(base: Double, dictation: Bool) {
        self.base = base
        self.dictation = dictation
    }

    /// The best supported locale: SpeechTranscriber (the new long-form model)
    /// first, then DictationTranscriber, which runs on more Macs.
    static func bestLocale(_ candidates: [String]) async -> (Locale, Bool)? {
        let speech = await SpeechTranscriber.supportedLocales
        let dictation = await DictationTranscriber.supportedLocales
        print("LISTENER SpeechTranscriber locales: \(speech.count) (available \(SpeechTranscriber.isAvailable)), DictationTranscriber locales: \(dictation.count)")
        for id in candidates {
            if let match = speech.first(where: { $0.identifier(.bcp47) == id }) { return (match, false) }
        }
        for id in candidates {
            if let match = dictation.first(where: { $0.identifier(.bcp47) == id }) { return (match, true) }
        }
        return nil
    }

    func start(locale: Locale) async throws {
        if dictation {
            let transcriber = DictationTranscriber(locale: locale, contentHints: [], transcriptionOptions: [],
                                                   reportingOptions: [], attributeOptions: [.audioTimeRange])
            try await install([transcriber], locale: locale)
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
            let (stream, builder) = AsyncStream<AnalyzerInput>.makeStream()
            self.analyzer = analyzer
            self.builder = builder
            let base = self.base
            resultsTask = Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        let words = Self.words(in: result.text, base: base)
                        if !words.isEmpty, let self { DispatchQueue.main.async { self.onWords?(words) } }
                    }
                } catch {
                    print("LISTENER dictation analysis stopped: \(error)")
                    if let self { DispatchQueue.main.async { self.onProblem?("speech analysis stopped: \(error.localizedDescription)") } }
                }
            }
            try await analyzer.start(inputSequence: stream)
            return
        }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                                            attributeOptions: [.audioTimeRange])
        try await install([transcriber], locale: locale)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        let (stream, builder) = AsyncStream<AnalyzerInput>.makeStream()
        self.analyzer = analyzer
        self.builder = builder
        let base = self.base
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let words = Self.words(in: result.text, base: base)
                    if !words.isEmpty, let self {
                        let heard = words
                        DispatchQueue.main.async { self.onWords?(heard) }
                    }
                }
            } catch {
                print("LISTENER speech analysis stopped: \(error)")
                if let self { DispatchQueue.main.async { self.onProblem?("speech analysis stopped: \(error.localizedDescription)") } }
            }
        }
        try await analyzer.start(inputSequence: stream)
    }

    private func install(_ modules: [any SpeechModule], locale: Locale) async throws {
        if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
            print("LISTENER downloading the \(locale.identifier) speech model")
            try await request.downloadAndInstall()
        }
    }

    /// Timed words from a result's text (runs carry their audio time range).
    static func words(in text: AttributedString, base: Double) -> [LyricsAligner.Word] {
        var words: [LyricsAligner.Word] = []
        for run in text.runs {
            guard let range = run.audioTimeRange else { continue }
            let chunk = String(text[run.range].characters)
            let parts = chunk.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            let start = range.start.seconds
            let duration = max(range.duration.seconds, 0.05)
            for (i, p) in parts.enumerated() {
                words.append(.init(time: base + start + duration * Double(i) / Double(max(parts.count, 1)), text: p))
            }
        }
        return words
    }

    /// Converts the tap's mono float audio to the analyzer's format and queues it.
    func feed(_ samples: [Float], rate: Double) {
        guard let builder, let target = format, !samples.isEmpty else { return }
        if inputFormat?.sampleRate != rate {
            inputFormat = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)
            converter = inputFormat.flatMap { AVAudioConverter(from: $0, to: target) }
        }
        guard let inputFormat, let converter,
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = input.floatChannelData?[0] else { return }
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        let capacity = AVAudioFrameCount(Double(samples.count) * target.sampleRate / rate) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return input
        }
        if error == nil, output.frameLength > 0 { builder.yield(AnalyzerInput(buffer: output)) }
    }

    func finish() async {
        builder?.finish()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
    }

    func cancel() {
        builder?.finish()
        builder = nil
        let analyzer = self.analyzer
        Task { try? await analyzer?.finalizeAndFinishThroughEndOfInput() }
        resultsTask?.cancel()
    }
}
