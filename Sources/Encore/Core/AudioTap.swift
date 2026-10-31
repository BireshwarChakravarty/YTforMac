import Accelerate
import AppKit
import CoreAudio
import Darwin

/// Captures the sound Encore is actually playing and turns it into spectrum
/// bands for the visualisers.
///
/// YouTube's audio is decoded and played by WebKit's helper processes (the
/// GPU process), not by Encore itself, and WebKit's Web Audio API returns
/// silence for YouTube's streams. So Encore uses a Core Audio *process tap*
/// (macOS 14.2+) on the WebKit helpers that belong to Encore. The tap only
/// listens: playback is never muted or altered. macOS asks once for
/// permission ("System Audio Recording Only").
final class AudioTap: @unchecked Sendable {
    enum Status: Equatable {
        case idle
        case waitingForAudio      // no WebKit audio process yet
        case running
        case noPermission         // tap runs but delivers silence while playing
        case unsupported          // macOS < 14.2
        case failed(String)
    }

    /// Called on the main queue with 56 bands (0…255) and a level (0…255).
    var onFrame: (([UInt8], UInt8) -> Void)?
    /// Called on the main queue when the status changes.
    var onStatus: ((Status) -> Void)?

    static let bandCount = 56

    private let queue = DispatchQueue(label: "app.encore.audiotap", qos: .userInitiated)
    private let ioQueue = DispatchQueue(label: "app.encore.audiotap.io", qos: .userInteractive)
    private var lock = os_unfair_lock()
    private var ring = [Float](repeating: 0, count: 8192)
    private var ringWrite = 0
    private var samplesSinceRead = 0

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var tappedPIDs: [pid_t] = []
    private var sampleRate: Double = 48_000
    private var timer: DispatchSourceTimer?
    private var wanted = false
    private var expectingAudio = false
    private var silentSince: CFAbsoluteTime?
    private(set) var status: Status = .idle {
        didSet {
            guard status != oldValue else { return }
            let s = status
            DispatchQueue.main.async { self.onStatus?(s) }
        }
    }

    // Analysis state
    private let fftSize = 4096
    private lazy var fft = vDSP.FFT(log2n: vDSP_Length(log2(Double(fftSize))), radix: .radix2, ofType: DSPSplitComplex.self)
    private lazy var window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: fftSize, isHalfWindow: false)
    private var smoothedDB: [Float] = []
    private var gain: Float = 1
    private var lastFrameTime: CFAbsoluteTime = 0

    // MARK: Control

    /// Start or stop capturing. `playing` tells the tap whether silence is
    /// expected (paused) or suspicious (playing → probably no permission).
    func setActive(_ active: Bool, playing: Bool) {
        queue.async {
            self.wanted = active
            self.expectingAudio = playing
            if active {
                self.startTimerIfNeeded()
                self.ensureTap()
            } else {
                self.teardown()
                self.timer?.cancel()
                self.timer = nil
                self.status = .idle
            }
        }
    }

    func setPlaying(_ playing: Bool) {
        queue.async {
            self.expectingAudio = playing
            if !playing { self.silentSince = nil }
        }
    }

    // MARK: Tap lifecycle

    private func ensureTap() {
        guard #available(macOS 14.2, *) else { status = .unsupported; return }
        let pids = Self.encoreAudioProcesses()
        if pids.isEmpty {
            if procID == nil { status = .waitingForAudio }
            return
        }
        if procID != nil, Set(pids.map(\.pid)) == Set(tappedPIDs) { return }
        teardown()
        createTap(objects: pids.map(\.object), pids: pids.map(\.pid))
    }

    @available(macOS 14.2, *)
    private func createTap(objects: [AudioObjectID], pids: [pid_t]) {
        let description = CATapDescription(stereoMixdownOfProcesses: objects)
        description.uuid = UUID()
        // Default mute behaviour is "unmuted": the tap only listens.
        description.isPrivate = true
        description.name = "Encore Visualiser"

        var newTap = AudioObjectID(kAudioObjectUnknown)
        var err = AudioHardwareCreateProcessTap(description, &newTap)
        guard err == noErr else { status = .failed("tap \(err)"); return }
        tapID = newTap

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        if AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format) == noErr, format.mSampleRate > 0 {
            sampleRate = format.mSampleRate
        }

        var aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Encore Visualiser Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        if let outputUID = Self.defaultOutputUID() {
            aggregate[kAudioAggregateDeviceMainSubDeviceKey] = outputUID
            aggregate[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: outputUID]]
        }

        var newAggregate = AudioObjectID(kAudioObjectUnknown)
        err = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &newAggregate)
        guard err == noErr else { status = .failed("aggregate \(err)"); teardown(); return }
        aggregateID = newAggregate

        let channels = Int(max(1, format.mChannelsPerFrame))
        let interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        err = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) { [weak self] _, inInput, _, _, _ in
            self?.consume(inInput, channels: channels, interleaved: interleaved)
        }
        guard err == noErr, procID != nil else { status = .failed("ioproc \(err)"); teardown(); return }
        err = AudioDeviceStart(aggregateID, procID)
        guard err == noErr else { status = .failed("start \(err)"); teardown(); return }
        tappedPIDs = pids
        silentSince = nil
        status = .running
    }

    private func teardown() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if #available(macOS 14.2, *), tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        tappedPIDs = []
    }

    // MARK: Audio thread

    private func consume(_ list: UnsafePointer<AudioBufferList>, channels: Int, interleaved: Bool) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard let first = buffers.first, let data = first.mData else { return }
        let floats = data.assumingMemoryBound(to: Float.self)
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        if interleaved {
            let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * channels)
            for f in 0..<frames {
                var s: Float = 0
                for c in 0..<channels { s += floats[f * channels + c] }
                ring[ringWrite] = s / Float(channels)
                ringWrite = (ringWrite + 1) & (ring.count - 1)
            }
            samplesSinceRead += frames
        } else {
            let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            let second = buffers.count > 1 ? buffers[1].mData?.assumingMemoryBound(to: Float.self) : nil
            for f in 0..<frames {
                let s = second.map { (floats[f] + $0[f]) * 0.5 } ?? floats[f]
                ring[ringWrite] = s
                ringWrite = (ringWrite + 1) & (ring.count - 1)
            }
            samplesSinceRead += frames
        }
    }

    // MARK: Analysis (60 Hz on the tap queue)

    private func startTimerIfNeeded() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(4))
        var tick = 0
        t.setEventHandler { [weak self] in
            guard let self, self.wanted else { return }
            tick += 1
            if tick % 120 == 0 { self.ensureTap() } // re-check helper processes every ~2 s
            self.analyse()
        }
        timer = t
        t.resume()
    }

    private func analyse() {
        guard procID != nil else { return }
        var samples = [Float](repeating: 0, count: fftSize)
        os_unfair_lock_lock(&lock)
        let fresh = samplesSinceRead
        samplesSinceRead = 0
        var idx = (ringWrite - fftSize) & (ring.count - 1)
        for i in 0..<fftSize {
            samples[i] = ring[idx]
            idx = (idx + 1) & (ring.count - 1)
        }
        os_unfair_lock_unlock(&lock)
        guard fresh > 0, let fft else { return }

        // RMS level, used for silence detection (permission) and the level output.
        let rms = vDSP.rootMeanSquare(samples)
        let now = CFAbsoluteTimeGetCurrent()
        if rms < 1e-6 {
            if expectingAudio {
                if silentSince == nil { silentSince = now }
                if let since = silentSince, now - since > 4, status == .running { status = .noPermission }
            }
            return
        }
        silentSince = nil
        if status != .running { status = .running }

        // Windowed real FFT → power spectrum.
        let windowed = vDSP.multiply(samples, window)
        let half = fftSize / 2
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var power = [Float](repeating: 0, count: half)
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cp in
                        vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(half))
                    }
                }
                let input = split
                fft.forward(input: input, output: &split)
                vDSP.squareMagnitudes(split, result: &power)
            }
        }
        // Normalise to amplitude dB (Hann window, real FFT scaling).
        let scale = 1 / Float(fftSize * fftSize) * 4
        power = vDSP.multiply(scale, power)
        var db = [Float](repeating: 0, count: half)
        vDSP.convert(power: power, toDecibels: &db, zeroReference: 1)

        if smoothedDB.count != half { smoothedDB = db }
        // Analyser-style temporal smoothing (like smoothingTimeConstant 0.55).
        smoothedDB = vDSP.linearInterpolate(db, smoothedDB, using: 0.55)

        // Log-spaced bands, 30 Hz – 16 kHz.
        let n = Self.bandCount
        let nyquist = Float(sampleRate / 2)
        let lo: Float = 30, hi: Float = 16_000
        var bands = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let f0 = lo * pow(hi / lo, Float(i) / Float(n))
            let f1 = lo * pow(hi / lo, Float(i + 1) / Float(n))
            let b0 = min(half - 1, Int(f0 / nyquist * Float(half)))
            let b1 = min(half, max(b0 + 1, Int(ceil(f1 / nyquist * Float(half)))))
            var peak: Float = -200, sum: Float = 0
            for b in b0..<b1 { let v = smoothedDB[b]; sum += v; peak = max(peak, v) }
            let avg = sum / Float(b1 - b0)
            let dbValue = peak * 0.6 + avg * 0.4
            // Map -85 dB … -15 dB to 0…1, with a gentle tilt so highs register.
            let tilt = Float(i) / Float(n) * 9
            bands[i] = max(0, min(1, (dbValue + tilt + 85) / 70))
        }

        // Soft automatic gain: keeps the visuals lively at any volume.
        let peakBand = bands.max() ?? 0
        let target: Float = peakBand > 0.05 ? min(2.2, max(0.8, 0.82 / peakBand)) : gain
        gain += (target - gain) * (target < gain ? 0.08 : 0.01)
        let out = bands.map { UInt8(max(0, min(255, $0 * gain * 255))) }
        let level = UInt8(max(0, min(255, (20 * log10(max(rms, 1e-7)) + 60) / 60 * 255)))
        lastFrameTime = now
        DispatchQueue.main.async { self.onFrame?(out, level) }
    }

    // MARK: Process discovery

    struct AudioProcess { let object: AudioObjectID; let pid: pid_t; let bundleID: String }

    /// WebKit helper processes that Encore is responsible for and that are
    /// known to Core Audio.
    static func encoreAudioProcesses() -> [AudioProcess] {
        let me = getpid()
        let all = audioProcesses()
        let responsible = responsibilityLookup()
        // Launched from Finder, Encore is responsible for itself; launched from a
        // terminal, the terminal is. Match WebKit helpers against either.
        let myResponsible = responsible?(me) ?? me
        let mine = all.filter { p in
            guard p.pid != me, let responsible else { return false }
            let owner = responsible(p.pid)
            return owner == me || (owner == myResponsible && p.bundleID.hasPrefix("com.apple.WebKit"))
        }
        if !mine.isEmpty { return mine }
        // Fallback when responsibility can't be resolved: WebKit helpers that
        // are currently producing sound.
        if responsible == nil {
            return all.filter { $0.bundleID.hasPrefix("com.apple.WebKit") && isRunningOutput($0.object) }
        }
        return []
    }

    static func audioProcesses() -> [AudioProcess] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var pidAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var pid: pid_t = -1
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            guard AudioObjectGetPropertyData(id, &pidAddress, 0, nil, &pidSize, &pid) == noErr, pid > 0 else { return nil }
            var bundleAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var bundle: Unmanaged<CFString>?
            var bundleSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            let bundleID: String
            if AudioObjectGetPropertyData(id, &bundleAddress, 0, nil, &bundleSize, &bundle) == noErr, let b = bundle?.takeRetainedValue() {
                bundleID = b as String
            } else {
                bundleID = ""
            }
            return AudioProcess(object: id, pid: pid, bundleID: bundleID)
        }
    }

    static func isRunningOutput(_ object: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningOutput, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr && value != 0
    }

    /// `responsibility_get_pid_responsible_for_pid` maps a WebKit helper
    /// (launched by launchd) back to the app it works for.
    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
    static func responsibilityLookup() -> ((pid_t) -> pid_t)? {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        let fn = unsafeBitCast(sym, to: ResponsibleFn.self)
        return { fn($0) }
    }

    static func defaultOutputUID() -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        var uidAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &uidAddress, 0, nil, &uidSize, &uid) == noErr, let value = uid?.takeRetainedValue() else { return nil }
        return value as String
    }

    /// Opens System Settings → Privacy & Security → Screen & System Audio Recording.
    static func openPrivacySettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AudioCapture",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
        ]
        for s in urls { if let url = URL(string: s), NSWorkspace.shared.open(url) { return } }
    }

    /// Diagnostics for the debug snapshot log.
    static func describeProcesses() -> String {
        let me = getpid()
        let responsible = responsibilityLookup()
        return audioProcesses().map { p in
            "\(p.bundleID.isEmpty ? "?" : p.bundleID)#\(p.pid)\(responsible.map { $0(p.pid) == me ? "(mine)" : "" } ?? "(?)")\(isRunningOutput(p.object) ? "[out]" : "")"
        }.joined(separator: ", ")
    }
}
