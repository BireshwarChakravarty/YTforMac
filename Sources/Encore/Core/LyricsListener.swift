import AVFoundation
import Speech

/// Listens to the song that's playing (through the audio tap) with on-device
/// speech recognition, and reports the words it hears with their times in the
/// video. Lyrics are then aligned against what was actually sung, which fixes
/// intros, skits, outros and different edits of a song without needing captions.
///
/// Recognition runs entirely on the Mac (`requiresOnDeviceRecognition`); audio
/// never leaves it. Audio is fed in ~15 s chunks so words arrive steadily.
final class LyricsListener: @unchecked Sendable {
    enum Status: Equatable {
        case off
        case needsPermission
        case unavailable(String)
        case listening(String)      // locale identifier
    }

    private let queue = DispatchQueue(label: "app.encore.lyrics.listener")
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var tasks: [SFSpeechRecognitionTask] = []
    private var format: AVAudioFormat?
    private var chunkBase: Double = 0       // video time where the current chunk starts
    private var chunkFed: Double = 0        // seconds of audio in the current chunk
    private var totalFed: Double = 0
    private var startTime: Double = 0
    private var running = false
    private var generation = 0
    private let chunkLength = 15.0

    /// Called on the main queue with newly heard words (video time).
    var onWords: (([LyricsAligner.Word]) -> Void)?

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

    /// The best on-device recogniser for these lyrics: their language first, then
    /// English variants (which still catch many words of other languages).
    static func recognizer(for lines: [LyricLine]) -> SFSpeechRecognizer? {
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
        candidates += ["en-US", "en-GB"]
        for id in candidates {
            if let r = SFSpeechRecognizer(locale: Locale(identifier: id)), r.isAvailable, r.supportsOnDeviceRecognition {
                return r
            }
        }
        return nil
    }

    /// Starts listening; `videoTime` is the playhead right now.
    func start(recognizer: SFSpeechRecognizer, videoTime: Double) {
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

    /// Ends the current chunk so its words are delivered, then stops feeding.
    func flush() {
        queue.async {
            self.request?.endAudio()
            self.request = nil
            self.running = false
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
        guard running, let request else { return }
        if format?.sampleRate != rate { format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) }
        guard let format, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in channel.update(from: src.baseAddress!, count: samples.count) }
        request.append(buffer)
        let seconds = Double(samples.count) / rate
        chunkFed += seconds
        totalFed += seconds
        if chunkFed >= chunkLength {
            request.endAudio()          // the final result for this chunk arrives shortly
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
    }
}
