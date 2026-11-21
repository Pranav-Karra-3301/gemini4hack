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

    /// The voice clip of one hold (16 kHz mono 16-bit WAV), right at release.
    @ObservationIgnored var onRelease: ((Data?) -> Void)?
    /// The final transcript of one hold (may be empty), shortly after release.
    @ObservationIgnored var onText: ((String) -> Void)?

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var latest = ""
    @ObservationIgnored private var holding = false
    @ObservationIgnored private var delivered = false
    @ObservationIgnored private var serial = 0
    @ObservationIgnored private let clip = ClipBuffer(seconds: 6)

    /// Finger down: open the mic (asks for speech + mic permission the first time).
    func begin() {
        guard !isListening else { return }
        holding = true
        Speaker.shared.stop()
        Task {
            guard await Self.authorize(), holding else { return }
            do {
                try start()
            } catch {
                Self.log.error("Mic failed: \(error.localizedDescription, privacy: .public)")
                teardown()
            }
        }
    }

    /// Finger up: stop listening and hand over what was said.
    func end() {
        holding = false
        guard isListening else { return }
        request?.endAudio()
        stopAudio()
        onRelease?(clip.wav())
        // The final result usually lands within a few hundred ms; don't wait forever.
        let s = serial
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            guard let self, self.serial == s else { return }
            self.deliver()
        }
    }

    /// Drops the current hold without sending anything.
    func cancel() {
        holding = false
        delivered = true
        teardown()
    }

    private func start() throws {
        guard let recognizer, recognizer.isAvailable else { throw VoiceError.unavailable }
        serial += 1
        latest = ""
        delivered = false
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        req.contextualStrings = ["warmer", "cooler", "brighter", "darker", "more contrast", "less contrast",
                                 "blur the background", "brighter face", "more vibrant", "reset"]
        request = req

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        clip.reset(sampleRate: format.sampleRate)
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

        let s = serial
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            Task { @MainActor in
                guard let self, self.serial == s else { return }
                if let text { self.latest = text }
                if final || (error != nil && !self.isListening) { self.deliver() }
            }
        }
    }

    private func deliver() {
        guard !delivered else { return }
        delivered = true
        let text = latest.trimmingCharacters(in: .whitespacesAndNewlines)
        teardown()
        onText?(text)
    }

    private func stopAudio() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
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

    private static func authorize() async -> Bool {
        let speech: Bool = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await AVAudioApplication.requestRecordPermission()
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
        case unavailable
        var errorDescription: String? { "Speech recognition isn't available right now." }
    }
}

/// The last few seconds of the mic (channel 0), written out as a 16 kHz mono 16-bit WAV for
/// Gemini Decision. Appended from the audio thread.
final class ClipBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let seconds: Double
    private var rate: Double = 48_000
    private var samples: [Float] = []

    init(seconds: Double) { self.seconds = seconds }

    func reset(sampleRate: Double) {
        lock.lock(); defer { lock.unlock() }
        rate = sampleRate > 0 ? sampleRate : 48_000
        samples.removeAll(keepingCapacity: true)
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let ch = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        lock.lock(); defer { lock.unlock() }
        samples.append(contentsOf: UnsafeBufferPointer(start: ch, count: n))
        let cap = Int(rate * seconds)
        if samples.count > cap { samples.removeFirst(samples.count - cap) }
    }

    func wav() -> Data? {
        lock.lock()
        let src = samples, r = rate
        lock.unlock()
        let out = 16_000.0
        let step = r / out
        let count = Int(Double(src.count) / step)
        guard count > 1_600 else { return nil }   // under 0.1 s: nothing said
        var pcm = Data(capacity: count * 2)
        for i in 0..<count {
            let a = Int(Double(i) * step), b = min(src.count, max(a + 1, Int(Double(i + 1) * step)))
            var sum: Float = 0
            for j in a..<b { sum += src[j] }
            let v = max(-1, min(1, sum / Float(b - a)))
            withUnsafeBytes(of: Int16(v * 32_767).littleEndian) { pcm.append(contentsOf: $0) }
        }
        var h = Data()
        func u32(_ x: UInt32) { withUnsafeBytes(of: x.littleEndian) { h.append(contentsOf: $0) } }
        func u16(_ x: UInt16) { withUnsafeBytes(of: x.littleEndian) { h.append(contentsOf: $0) } }
        h.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + pcm.count)); h.append(contentsOf: Array("WAVE".utf8))
        h.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(16_000); u32(32_000); u16(2); u16(16)
        h.append(contentsOf: Array("data".utf8)); u32(UInt32(pcm.count))
        return h + pcm
    }
}
