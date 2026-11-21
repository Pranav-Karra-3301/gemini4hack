import AVFoundation
import Observation
import os
import Speech

/// On-device speech recognition for the mic key: while it runs, every finished utterance (a
/// pause of ~1.2 s after speech) goes to `onUtterance` as the user's request for the coach.
/// Words heard while the coach itself is speaking are dropped (its voice comes out the speaker).
@MainActor
@Observable
final class Listener {
    private(set) var isRunning = false
    /// Mic input level 0...1 for the capsule.
    private(set) var inputLevel: Float = 0

    /// The utterance's text and a 16-bit WAV of the last few seconds of voice (for the reaction).
    @ObservationIgnored var onUtterance: ((String, Data?) -> Void)?

    @ObservationIgnored private let log = Logger(subsystem: "app.heliocam.CoachCam", category: "Listener")
    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    @ObservationIgnored private let feed = AudioFeed()
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest? {
        didSet { feed.request = request }
    }
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var partial = ""
    @ObservationIgnored private var silence: Task<Void, Never>?
    @ObservationIgnored private var spokeUntil = Date.distantPast

    static let pause: Duration = .milliseconds(1200)

    static func requestAccess() async -> Bool {
        let speech = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }

    func start() async {
        guard !isRunning else { return }
        guard await Self.requestAccess() else {
            log.error("speech or microphone permission denied; the mic key can't listen")
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            log.error("speech recognizer unavailable for en-US")
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.defaultToSpeaker, .allowBluetoothA2DP, .mixWithOthers])
            try? session.setAllowHapticsAndSystemSoundsDuringRecording(true)
            try session.setActive(true)
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.removeTap(onBus: 0)
            let feed = self.feed
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                feed.append(buffer)
                let level = Self.level(buffer)
                Task { @MainActor [weak self] in self?.update(level: level) }
            }
            engine.prepare()
            try engine.start()
            isRunning = true
            beginRecognition()
        } catch {
            log.error("mic start failed: \(error.localizedDescription, privacy: .public)")
            stop()
        }
    }

    func stop() {
        silence?.cancel(); silence = nil
        task?.cancel(); task = nil
        request?.endAudio(); request = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        partial = ""
        isRunning = false
        inputLevel = 0
    }

    private func update(level: Float) {
        guard isRunning else { return }
        inputLevel = level
        let speaking = Speaker.shared.isSpeaking
        feed.muted = speaking       // don't transcribe the coach's own voice
        if speaking { spokeUntil = Date().addingTimeInterval(0.6) }
    }

    private func beginRecognition() {
        guard let recognizer else { return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        req.taskHint = .dictation
        request = req
        partial = ""
        generation += 1
        let gen = generation
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            let err = error.map { $0.localizedDescription }
            Task { @MainActor [weak self] in self?.handle(gen, text: text, final: final, error: err) }
        }
    }

    private func handle(_ gen: Int, text: String?, final: Bool, error: String?) {
        guard isRunning, gen == generation else { return }   // a cancelled task's last callback
        if let text, !text.isEmpty, Date() > spokeUntil {
            partial = text
            silence?.cancel()
            silence = Task { [weak self] in
                try? await Task.sleep(for: Self.pause)
                guard !Task.isCancelled else { return }
                self?.finishUtterance()
            }
        }
        if final { finishUtterance() }
        else if let error {
            log.debug("recognition ended: \(error, privacy: .public)")
            // Recognition tasks end on their own (about a minute, or after silence): start a new one.
            restartRecognition()
        }
    }

    private func finishUtterance() {
        silence?.cancel(); silence = nil
        let text = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        partial = ""
        if !text.isEmpty { onUtterance?(text, feed.recentWAV()) }
        restartRecognition()
    }

    private func restartRecognition() {
        guard isRunning else { return }
        task?.cancel(); task = nil
        request?.endAudio(); request = nil
        beginRecognition()
    }

    nonisolated private static func level(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let ch = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += ch[i] * ch[i] }
        let rms = (sum / Float(buffer.frameLength)).squareRoot()
        return min(1, rms * 8)
    }
}

/// The tap's side of the recognizer: appends mic buffers on the audio thread unless muted.
private final class AudioFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var _request: SFSpeechAudioBufferRecognitionRequest?
    private var _muted = false

    var request: SFSpeechAudioBufferRecognitionRequest? {
        get { lock.withLock { _request } }
        set { lock.withLock { _request = newValue } }
    }

    var muted: Bool {
        get { lock.withLock { _muted } }
        set { lock.withLock { _muted = newValue } }
    }

    /// The last `keep` seconds of mic audio (channel 0), for the decision call's voice clip.
    private var samples: [Float] = []
    private var rate: Double = 48_000
    static let keep: Double = 6

    func append(_ buffer: AVAudioPCMBuffer) {
        let (req, muted) = lock.withLock { (_request, _muted) }
        guard !muted else { return }
        req?.append(buffer)
        guard let ch = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        let chunk = Array(UnsafeBufferPointer(start: ch, count: Int(buffer.frameLength)))
        let r = buffer.format.sampleRate
        lock.withLock {
            rate = r
            samples.append(contentsOf: chunk)
            let max = Int(r * Self.keep)
            if samples.count > max { samples.removeFirst(samples.count - max) }
        }
    }

    /// The rolling clip as 16-bit mono PCM WAV at ~16 kHz (nil when there's under 0.3 s of audio).
    func recentWAV() -> Data? {
        let (src, r) = lock.withLock { (samples, rate) }
        guard Double(src.count) > r * 0.3 else { return nil }
        let step = max(1, Int((r / 16_000).rounded()))
        let outRate = UInt32(r) / UInt32(step)
        var pcm = Data(capacity: src.count / step * 2)
        var i = 0
        while i < src.count {
            let v = Int16(max(-1, min(1, src[i])) * Float(Int16.max))
            withUnsafeBytes(of: v.littleEndian) { pcm.append(contentsOf: $0) }
            i += step
        }
        var wav = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
        wav.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + pcm.count))
        wav.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1)
        u32(outRate); u32(outRate * 2); u16(2); u16(16)
        wav.append(contentsOf: Array("data".utf8)); u32(UInt32(pcm.count))
        wav.append(pcm)
        return wav
    }
}
