import AVFoundation
import CoachAPI
import os

/// Speaks the coach's short lines out loud. There is no on-screen transcript: the user hears the
/// coach, never reads it.
///
/// The voice is Gemini TTS (`GeminiDirect.voiceModel`, falling back to the lite TTS model), cached
/// by line and pre-warmed with the common lines. A line whose audio isn't there within
/// `deadline` (or fails) is spoken by the system voice instead; its audio still lands in the
/// cache for next time. The newest line always wins.
@MainActor
final class Speaker: NSObject {
    static let shared = Speaker()

    /// A warm, natural prebuilt Gemini voice.
    static let geminiVoice = "Umbriel"   // easy-going; Sulafat read as too bright/excited
    /// Style tag spoken lines get. Measured 2026-11-21: a "Say warmly: ..." preamble or director's
    /// notes are read aloud by these models; an inline bracket tag is not (line length unchanged).
    private static let style = "[relaxed, even, conversational, low energy]"
    /// The lines the coach says most, fetched when the coach starts.
    static let commonLines = [
        "That's it. Take it.", "Take a step back.", "Come a little closer.", "Switch to portrait.",
        "A little to the left.", "A little to the right.", "Hold it there.",
    ]
    /// How long a line waits for Gemini audio before the system voice says it.
    private static let deadline: Duration = .milliseconds(1500)
    private static let maxCached = 64

    private let synth = AVSpeechSynthesizer()
    private let log = Logger(subsystem: "app.heliocam.CoachCam", category: "Speaker")
    private lazy var voice: AVSpeechSynthesisVoice? = Self.bestVoice()
    private lazy var gemini: GeminiDirect? = GeminiDirect.keyFromBundle().map { GeminiDirect(apiKey: $0) }

    private var cache: [String: Data] = [:]
    private var inflight: Set<String> = []
    private var failed: Set<String> = []
    /// Set once the primary TTS model errors: use the fallback model from then on.
    private var primaryDown = false
    private var player: AVAudioPlayer?
    private var waiting: Task<Void, Never>?
    /// Bumped by every `say`/`stop`, so an older line never plays over a newer one.
    private var serial = 0

    override private init() {
        super.init()
        // Keep the app's audio session (camera + mic) instead of letting the synth swap it.
        synth.usesApplicationAudioSession = true
    }

    var isSpeaking: Bool { synth.isSpeaking || player?.isPlaying == true }

    /// Speaks `text`, cutting off whatever was still being said so the newest line wins.
    /// Takes the hype out of a line: no exclamation marks, no stock cheer openers.
    static func calm(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "!", with: ".")
        let openers = ["great", "perfect", "awesome", "amazing", "wow", "nice", "excellent", "fantastic", "beautiful", "love it", "oh"]
        for o in openers {
            for sep in [". ", ", ", " - ", " "] where t.lowercased().hasPrefix(o + sep) && t.count > o.count + sep.count + 3 {
                t = String(t.dropFirst(o.count + sep.count))
                t = t.prefix(1).uppercased() + t.dropFirst()
            }
        }
        while t.contains("..") { t = t.replacingOccurrences(of: "..", with: ".") }
        return t
    }

    func say(_ text: String) {
        let line = Self.calm(text)
        guard !line.isEmpty else { return }
        configureSession()
        cutOff()
        let id = serial
        if let wav = cache[line] { play(wav, line); return }
        failed.remove(line)
        guard fetch(line) else { speakLocally(line); return }
        waiting = Task { [weak self] in
            let until = ContinuousClock.now + Self.deadline
            while ContinuousClock.now < until {
                try? await Task.sleep(for: .milliseconds(40))
                guard let self, !Task.isCancelled, id == self.serial else { return }
                if let wav = self.cache[line] { self.play(wav, line); return }
                if self.failed.contains(line) { break }
            }
            guard let self, !Task.isCancelled, id == self.serial else { return }
            self.log.notice("Gemini voice late or failed, system voice for: \(line, privacy: .public)")
            self.speakLocally(line)
        }
    }

    func stop() {
        cutOff()
    }

    /// Fetches the common lines so the first ones play instantly in the Gemini voice.
    func warmUp() {
        for line in Self.commonLines { fetch(line) }
    }

    private func cutOff() {
        serial += 1
        waiting?.cancel()
        waiting = nil
        player?.stop()
        player = nil
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
    }

    /// Starts (or joins) the Gemini audio fetch for `line`. False without a key.
    @discardableResult
    private func fetch(_ line: String) -> Bool {
        guard let gemini else { return false }
        if cache[line] != nil || inflight.contains(line) { return true }
        inflight.insert(line)
        let prompt = "\(Self.style) \(line)"
        let models = primaryDown ? [GeminiDirect.voiceFallbackModel]
                                 : [GeminiDirect.voiceModel, GeminiDirect.voiceFallbackModel]
        Task { [weak self] in
            var wav: Data?
            for model in models {
                let t0 = ContinuousClock.now
                do {
                    wav = try await gemini.speech(prompt, voice: Self.geminiVoice, model: model)
                    self?.log.info("Gemini voice \(model, privacy: .public) \(String(describing: ContinuousClock.now - t0), privacy: .public): \(line, privacy: .public)")
                    break
                } catch {
                    self?.log.error("Gemini voice \(model, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                    if model == GeminiDirect.voiceModel { self?.primaryDown = true }
                }
            }
            guard let self else { return }
            self.inflight.remove(line)
            if let wav {
                if self.cache.count >= Self.maxCached, let drop = self.cache.keys.first(where: { !Self.commonLines.contains($0) }) {
                    self.cache[drop] = nil
                }
                self.cache[line] = wav
            } else {
                self.failed.insert(line)
            }
        }
        return true
    }

    private func play(_ wav: Data, _ line: String) {
        do {
            let p = try AVAudioPlayer(data: wav)
            p.prepareToPlay()
            guard p.play() else { throw CocoaError(.featureUnsupported) }
            player = p
        } catch {
            log.error("Gemini voice playback failed: \(error.localizedDescription, privacy: .public)")
            speakLocally(line)
        }
    }

    private func speakLocally(_ line: String) {
        let utterance = AVSpeechUtterance(string: line)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
        utterance.prefersAssistiveTechnologySettings = false
        synth.speak(utterance)
    }

    /// Plays alongside the running camera and the mic: play-and-record, out of the loud speaker.
    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        guard session.category != .playAndRecord || !session.categoryOptions.contains(.defaultToSpeaker) else {
            return
        }
        do {
            try session.setCategory(
                .playAndRecord, mode: .default,
                options: [.defaultToSpeaker, .allowBluetoothA2DP, .mixWithOthers])
            try session.setActive(true)
        } catch {
            log.error("audio session setup failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The best installed en-US voice: premium, then enhanced, then the default.
    private static func bestVoice() -> AVSpeechSynthesisVoice? {
        let english = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == "en-US" }
        if let premium = english.first(where: { $0.quality == .premium }) { return premium }
        if let enhanced = english.first(where: { $0.quality == .enhanced }) { return enhanced }
        return AVSpeechSynthesisVoice(language: "en-US")
    }
}
