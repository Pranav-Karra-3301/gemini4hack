import AVFoundation
import Foundation
import Observation
import os
import Speech

/// Hold the shot viewer's mic and say what to change ("warmer", "brighter face"). On release the
/// last ≤6 s of audio goes to `onRelease` at once (Gemini Decision picks a fader move in ~1 s), and
/// the on-device transcript (SFSpeechRecognizer) follows through `onText` (Gemini 4 refines when
/// needed). Nothing is shown on screen: no transcript, no captions.
@MainActor
@Observable
final class VoiceEdit {
    private static let log = Logger(subsystem: "app.heliocam.CoachCam", category: "Voice")
    /// The mic is open (the key glows from inside while true).
    private(set) var isListening = false
    /// Input level 0…1 while listening.
    private(set) var level: Double = 0
    /// True from the instant the user asks to listen (tap or press) until they stop, so the key and
    /// the dictation bar react before the mic has finished opening.
    private(set) var active = false
    /// The live partial transcript of the current (or just-sent) dictation.
    private(set) var transcript = ""
    /// The dictation was just sent: the bar keeps the words for ~1 s with a blue dot, then clears.
    private(set) var sent = false
    @ObservationIgnored private var silence: Task<Void, Never>?

    /// The voice clip of one hold (16 kHz mono 16-bit WAV), right at release.
    @ObservationIgnored var onRelease: ((Data?) -> Void)?
    /// The final transcript of one hold (may be empty), shortly after release.
    @ObservationIgnored var onText: ((String) -> Void)?
    /// Silence after speech while listening: the key stops the dictation (with its haptic).
    @ObservationIgnored var onSilence: (() -> Void)?

    /// A fresh engine per hold: its input node reads the session's current format (a stale input
    /// format after the coach's Listener or the Speaker changed the session can't install a tap).
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var latest = ""
    @ObservationIgnored private var holding = false
    @ObservationIgnored private var delivered = true
    @ObservationIgnored private var serial = 0
    @ObservationIgnored private let clip = ClipBuffer(seconds: 6)

    /// Asks for speech + mic permission ahead of the first hold (the viewer calls this when it
    /// opens), so the first hold isn't spent on the permission alerts.
    func prepare() {
        Task { _ = await Self.authorize() }
    }

    /// Finger down: open the mic (asks for speech + mic permission the first time).
    func begin() {
        guard !isListening else { return }
        // A previous hold still waiting on its final transcript: hand over what it has now.
        if !delivered { deliver() }
        holding = true
        active = true
        sent = false
        transcript = ""
        Speaker.shared.stop()
        Task {
            let access = await Self.authorize()
            guard access.mic else {
                Self.log.error("Voice: microphone permission denied; can't listen")
                return
            }
            guard holding else {
                Self.log.notice("Voice: released before the mic opened")
                return
            }
            do {
                try start(speech: access.speech)
            } catch {
                Self.log.error("Voice: mic failed: \(error.localizedDescription, privacy: .public)")
                teardown()
            }
        }
    }

    /// Finger up: stop listening and hand over what was said.
    func end() {
        holding = false
        silence?.cancel()
        if active {
            active = false
            sent = true
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1.1))
                guard let self, !self.active else { return }
                self.sent = false
                self.transcript = ""
            }
        }
        guard isListening else { return }
        let frames = clip.frames
        request?.endAudio()
        stopAudio()
        let wav = clip.wav()
        Self.log.notice("Voice release: \(frames) frames (\(String(format: "%.1f", self.clip.duration)) s), clip \(wav?.count ?? 0) bytes")
        onRelease?(wav)
        guard task != nil else {
            deliver()   // no recognizer: no transcript coming
            return
        }
        // The final result usually lands within a few hundred ms; don't wait forever.
        let s = serial
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard let self, self.serial == s else { return }
            Self.log.notice("Voice: no final transcript after 1.5 s; using the last partial")
            self.deliver()
        }
    }

    /// Drops the current hold without sending anything.
    func cancel() {
        holding = false
        silence?.cancel()
        active = false
        sent = false
        transcript = ""
        delivered = true
        teardown()
    }

    private func start(speech: Bool) throws {
        serial += 1
        latest = ""
        delivered = false
        let session = AVAudioSession.sharedInstance()
        // Same category and options as the Speaker and the coach's Listener: no route change, so
        // a line the Speaker plays right after isn't cut by a session reconfiguration.
        if session.category != .playAndRecord || !session.categoryOptions.contains(.defaultToSpeaker) {
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.defaultToSpeaker, .allowBluetoothA2DP, .mixWithOthers])
        }
        try session.setActive(true)

        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw VoiceError.noInput }
        clip.reset(sampleRate: format.sampleRate)

        var req: SFSpeechAudioBufferRecognitionRequest?
        if speech, let recognizer, recognizer.isAvailable {
            let r = SFSpeechAudioBufferRecognitionRequest()
            r.shouldReportPartialResults = true
            r.taskHint = .dictation
            // On device when this iPhone can; otherwise Apple's server.
            r.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
            r.contextualStrings = ["warmer", "cooler", "brighter", "darker", "more contrast", "less contrast",
                                   "blur the background", "brighter face", "more vibrant", "reset"]
            req = r
        } else {
            Self.log.error("Voice: speech recognition unavailable (authorized=\(speech)); sending the clip only")
        }
        request = req

        let clip = clip
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self, weak req] buffer, _ in
            req?.append(buffer)
            clip.append(buffer)
            let level = Self.rms(buffer)
            Task { @MainActor in self?.level = level }
        }
        engine.prepare()
        try engine.start()
        isListening = true
        Self.log.notice("Voice start: \(Int(format.sampleRate)) Hz \(format.channelCount) ch, input \(session.currentRoute.inputs.first?.portType.rawValue ?? "none", privacy: .public), on-device=\(req?.requiresOnDeviceRecognition ?? false)")

        guard let req, let recognizer else { return }
        let s = serial
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            let message = error?.localizedDescription
            Task { @MainActor in
                guard let self, self.serial == s else { return }
                if let text {
                    self.latest = text
                    if self.active { self.transcript = text }
                    // ~1.2 s of silence after speech ends a tapped dictation and sends it.
                    if self.active, !text.isEmpty {
                        self.silence?.cancel()
                        self.silence = Task { @MainActor [weak self] in
                            try? await Task.sleep(for: .seconds(1.2))
                            guard !Task.isCancelled, let self, self.active, self.serial == s else { return }
                            self.onSilence?()
                        }
                    }
                }
                if let message { Self.log.notice("Voice recognizer: \(message, privacy: .public)") }
                if final || (message != nil && !self.isListening) { self.deliver() }
            }
        }
    }

    private func deliver() {
        guard !delivered else { return }
        delivered = true
        let text = latest.trimmingCharacters(in: .whitespacesAndNewlines)
        Self.log.notice("Voice transcript: \"\(text, privacy: .public)\"")
        teardown()
        onText?(text)
    }

    private func stopAudio() {
        if let engine {
            if engine.isRunning { engine.stop() }
            engine.inputNode.removeTap(onBus: 0)
        }
        engine = nil
        isListening = false
        level = 0
    }

    private func teardown() {
        stopAudio()
        task?.cancel()
        task = nil
        request = nil
        serial += 1
    }

    struct Access: Sendable {
        let speech: Bool
        let mic: Bool
    }

    /// Speech and mic permission, asking only when not yet decided. The clip alone still works
    /// (Gemini Decision hears it) when speech recognition is refused.
    private static func authorize() async -> Access {
        let status = SFSpeechRecognizer.authorizationStatus()
        let speech: Bool
        if status == .notDetermined {
            speech = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
            }
        } else {
            speech = status == .authorized
        }
        let mic: Bool
        switch AVAudioApplication.shared.recordPermission {
        case .granted: mic = true
        case .denied: mic = false
        default: mic = await AVAudioApplication.requestRecordPermission()
        }
        log.notice("Voice permission: speech=\(speech) mic=\(mic)")
        return Access(speech: speech, mic: mic)
    }

    nonisolated private static func rms(_ buffer: AVAudioPCMBuffer) -> Double {
        guard let ch = buffer.floatChannelData?[0] else { return 0 }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<n { sum += ch[i] * ch[i] }
        return min(1, Double(sqrt(sum / Float(n))) * 8)
    }

    enum VoiceError: LocalizedError {
        case noInput
        var errorDescription: String? { "The microphone has no input format (another engine may hold it)." }
    }
}

/// The last few seconds of the mic (channel 0), written out as a 16 kHz mono 16-bit WAV for
/// Gemini Decision. Appended from the audio thread.
final class ClipBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let seconds: Double
    private var rate: Double = 48_000
    private var samples: [Float] = []
    private var total = 0

    init(seconds: Double) { self.seconds = seconds }

    /// Frames received since the last reset (all of them, not just the kept tail).
    var frames: Int {
        lock.lock(); defer { lock.unlock() }
        return total
    }

    /// Seconds of audio kept.
    var duration: Double {
        lock.lock(); defer { lock.unlock() }
        return Double(samples.count) / rate
    }

    func reset(sampleRate: Double) {
        lock.lock(); defer { lock.unlock() }
        rate = sampleRate > 0 ? sampleRate : 48_000
        samples.removeAll(keepingCapacity: true)
        total = 0
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let ch = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        lock.lock(); defer { lock.unlock() }
        samples.append(contentsOf: UnsafeBufferPointer(start: ch, count: n))
        total += n
        let cap = Int(rate * seconds)
        if samples.count > cap { samples.removeFirst(samples.count - cap) }
    }

    func wav() -> Data? {
        lock.lock()
        let src = samples, r = rate
        lock.unlock()
        return Self.wav(samples: src, rate: r)
    }

    /// Float samples at `rate` → a 16 kHz mono 16-bit PCM WAV (box-filter resample). Nil under 0.1 s.
    static func wav(samples src: [Float], rate r: Double, outRate: Int = 16_000) -> Data? {
        guard r > 0 else { return nil }
        let out = Double(outRate)
        let step = r / out
        let count = Int(Double(src.count) / step)
        guard count > outRate / 10 else { return nil }   // under 0.1 s: nothing said
        var pcm = Data(capacity: count * 2)
        for i in 0..<count {
            let a = min(src.count - 1, Int(Double(i) * step))
            let b = min(src.count, max(a + 1, Int(Double(i + 1) * step)))
            var sum: Float = 0
            for j in a..<b { sum += src[j] }
            let v = max(-1, min(1, sum / Float(b - a)))
            withUnsafeBytes(of: Int16(v * 32_767).littleEndian) { pcm.append(contentsOf: $0) }
        }
        var h = Data()
        func u32(_ x: UInt32) { withUnsafeBytes(of: x.littleEndian) { h.append(contentsOf: $0) } }
        func u16(_ x: UInt16) { withUnsafeBytes(of: x.littleEndian) { h.append(contentsOf: $0) } }
        h.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + pcm.count)); h.append(contentsOf: Array("WAVE".utf8))
        h.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(outRate)); u32(UInt32(outRate * 2)); u16(2); u16(16)
        h.append(contentsOf: Array("data".utf8)); u32(UInt32(pcm.count))
        return h + pcm
    }
}
