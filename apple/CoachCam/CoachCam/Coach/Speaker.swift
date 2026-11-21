import AVFoundation
import os

/// Speaks the coach's short lines out loud. There is no on-screen transcript: the user hears the
/// coach, never reads it.
@MainActor
final class Speaker: NSObject {
    static let shared = Speaker()

    private let synth = AVSpeechSynthesizer()
    private let log = Logger(subsystem: "app.heliocam.CoachCam", category: "Speaker")
    private lazy var voice: AVSpeechSynthesisVoice? = Self.bestVoice()

    override private init() {
        super.init()
        // Keep the app's audio session (camera + mic) instead of letting the synth swap it.
        synth.usesApplicationAudioSession = true
    }

    var isSpeaking: Bool { synth.isSpeaking }

    /// Speaks `text`, cutting off whatever was still being said so the newest line wins.
    func say(_ text: String) {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        configureSession()
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        let utterance = AVSpeechUtterance(string: line)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
        utterance.prefersAssistiveTechnologySettings = false
        synth.speak(utterance)
    }

    func stop() {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
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
