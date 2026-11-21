import AVFAudio
import Foundation
import Observation
import os

/// Mic in and speaker out for a Live session, with echo cancellation.
///
/// - Input: `AVAudioEngine` input node with voice processing (AEC, noise suppression, AGC),
///   converted to 16 kHz mono PCM16 and delivered in 40 ms chunks via `onCapture`
///   (on the audio tap thread).
/// - Output: an `AVAudioPlayerNode` fed 24 kHz PCM16 through a gapless queue. `flush()` drops
///   queued speech on barge-in. `outputLevel` follows what is audible now, not what arrived.
/// - iOS: `AVAudioSession` `.playAndRecord` / `.voiceChat` with speaker + Bluetooth HFP; resumes
///   after interruptions and rebuilds the graph on route/config changes. macOS: same engine,
///   no audio session. Apps need `NSMicrophoneUsageDescription` (and on macOS the
///   `com.apple.security.device.audio-input` entitlement when sandboxed).
///
/// UI state is `@Observable` on the main actor; `enqueue`/`flush` are nonisolated and safe from
/// any thread, which is how `LiveSession` drives them.
@MainActor
@Observable
public final class LiveAudio: LiveAudioOutput {
    /// Loudness of Gemini's speech being played now (0…1, meter scale). Updated at ~30 Hz.
    public private(set) var outputLevel: Float = 0
    /// Loudness of the user's (processed) mic signal (0…1, meter scale). Updated at ~30 Hz.
    public private(set) var inputLevel: Float = 0
    /// True while queued speech is still playing.
    public private(set) var isPlaying = false
    /// True between `start()` and `stop()` (false while an interruption holds the engine).
    public private(set) var isRunning = false

    /// Mutes the mic at the voice-processing unit (AEC keeps running). Muting also tells an
    /// attached session `audioStreamEnd`, so Gemini doesn't wait for the rest of the sentence.
    public var isMicMuted = false {
        didSet {
            core.setMicMuted(isMicMuted)
            if isMicMuted && !oldValue { attached?.sendAudioStreamEnd() }
        }
    }

    /// Silences playback without dropping the queue (timing and levels keep running).
    public var isOutputMuted = false {
        didSet { core.setOutputMuted(isOutputMuted) }
    }

    /// Receives each 40 ms chunk of 16 kHz mono PCM16, on the audio thread. `attach(to:)` sets it.
    public var onCapture: (@Sendable (Data) -> Void)? {
        get { core.onCapture }
        set { core.onCapture = newValue }
    }

    @ObservationIgnored private nonisolated let core = LiveAudioCore()
    @ObservationIgnored private weak var attached: LiveSession?
    @ObservationIgnored private var meterTimer: Timer?

    public init() {
        core.onStateChange = { [weak self] running in
            Task { @MainActor in self?.isRunning = running }
        }
    }

    /// Asks for microphone permission (shows the system prompt the first time).
    public static func requestMicrophoneAccess() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    /// Wires mic → `session.sendAudio` and `session` audio → this player (plus barge-in flushes).
    public func attach(to session: LiveSession) {
        attached = session
        session.audioOutput = self
        onCapture = { [weak session] chunk in session?.sendAudio(pcm16k: chunk) }
    }

    /// Configures the audio session (iOS), enables voice processing and starts the engine.
    /// Takes ~100–300 ms; runs off the main thread.
    public func start() async throws {
        try await core.start()
        isRunning = true
        startMeters()
    }

    /// Stops capture and playback and releases the audio session (iOS).
    public func stop() {
        meterTimer?.invalidate()
        meterTimer = nil
        core.stop()
        isRunning = false
        isPlaying = false
        outputLevel = 0
        inputLevel = 0
    }

    /// Queues 24 kHz mono PCM16 for gapless playback. Any thread.
    public nonisolated func enqueue(pcm24k: Data) {
        core.enqueue(pcm24k: pcm24k)
    }

    /// Drops all queued speech immediately (barge-in). Any thread.
    public nonisolated func flush() {
        core.flush()
    }

    /// Pull-style level for a `TimelineView` (no observation churn). Any thread.
    public nonisolated var currentOutputLevel: Float { core.meters().output }

    private func startMeters() {
        meterTimer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateMeters() }
        }
        RunLoop.main.add(t, forMode: .common)
        meterTimer = t
    }

    private func updateMeters() {
        let m = core.meters()
        // Assign only on change so idle meters don't invalidate views 30×/s.
        if m.output != outputLevel { outputLevel = m.output }
        if m.input != inputLevel { inputLevel = m.input }
        if m.playing != isPlaying { isPlaying = m.playing }
    }
}

/// The engine behind `LiveAudio`. Graph changes run on `queue`; playback bookkeeping is under
/// `lock`; player calls that must not interleave (schedule vs. stop) are under `playerLock`.
final class LiveAudioCore: @unchecked Sendable {
    private let log = Logger(subsystem: "CoachLive", category: "audio")
    private let queue = DispatchQueue(label: "CoachLive.audio", qos: .userInteractive)
    private let lock = NSLock()
    private let playerLock = NSLock()

    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()     // replaced only after a media-services reset
    private let playFormat = LivePCM.floatFormat(rate: LivePCM.outputRate)
    private var converter: LiveCaptureConverter?   // tap thread only
    private var observers: [NSObjectProtocol] = []
    private var running = false                    // queue only
    /// Echo cancellation (voice processing). Off after VPIO fails to initialize (e.g. a Bluetooth
    /// headset in HFP on macOS: kAUInitialize → -10875) or with `COACH_NO_VP=1` /
    /// `-liveNoVoiceProcessing YES` (QA: hear audio played through the speakers). Queue only.
    private var useVoiceProcessing = !LiveAudioCore.voiceProcessingDisabled
    static var voiceProcessingDisabled: Bool {
        ProcessInfo.processInfo.environment["COACH_NO_VP"] == "1" || UserDefaults.standard.bool(forKey: "liveNoVoiceProcessing")
    }

    // Guarded by `lock`.
    private var _onCapture: (@Sendable (Data) -> Void)?
    private var micMuted = false
    private var outputMuted = false
    private var scheduledEnd: Int64 = 0            // player frame where the queue runs dry
    private var envelope = LevelEnvelope()
    private var lastInputRMS: Float = 0
    private var lastInputAt: TimeInterval = 0
    private var carry: UInt8?                      // odd trailing byte of a chunk

    var onStateChange: (@Sendable (Bool) -> Void)?

    var onCapture: (@Sendable (Data) -> Void)? {
        get { lock.withLock { _onCapture } }
        set { lock.withLock { _onCapture = newValue } }
    }

    func setMicMuted(_ muted: Bool) {
        lock.withLock { micMuted = muted }
        queue.async { [self] in
            // Touching inputNode before start() would create it (and may prompt for the mic).
            if running && useVoiceProcessing { engine.inputNode.isVoiceProcessingInputMuted = muted }
        }
    }

    func setOutputMuted(_ muted: Bool) {
        lock.withLock { outputMuted = muted }
        playerLock.withLock { if player.engine != nil { player.volume = muted ? 0 : 1 } } // else applied in buildGraph
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    try startOnQueue()
                    c.resume()
                } catch {
                    c.resume(throwing: error)
                }
            }
        }
    }

    func stop() {
        queue.sync { [self] in
            for o in observers { NotificationCenter.default.removeObserver(o) }
            observers = []
            guard running else { return }
            engine.inputNode.removeTap(onBus: 0)
            playerLock.withLock { player.stop() }
            engine.stop()
            running = false
            resetPlayback()
            #if os(iOS)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            #endif
        }
    }

    // MARK: Playback

    func enqueue(pcm24k: Data) {
        var bytes = pcm24k
        lock.withLock {
            if let c = carry { bytes.insert(c, at: bytes.startIndex); carry = nil }
            if bytes.count % 2 == 1 { carry = bytes.removeLast() }
        }
        guard let buf = LivePCM.floatBuffer(pcm16: bytes, rate: LivePCM.outputRate),
              let samples = buf.floatChannelData?[0] else { return }
        let frames = Int64(buf.frameLength)
        playerLock.withLock {
            // Not attached before start(): scheduling on a detached node is invalid; drop.
            guard player.engine != nil else { return }
            let now = playerFrame()
            lock.withLock {
                let start = max(scheduledEnd, now ?? scheduledEnd)
                envelope.append(UnsafeBufferPointer(start: samples, count: Int(frames)), start: start)
                scheduledEnd = start + frames
            }
            player.scheduleBuffer(buf, completionHandler: nil)
            if !player.isPlaying && player.engine?.isRunning == true { player.play() }
        }
    }

    func flush() {
        playerLock.withLock {
            guard player.engine != nil else { return }
            let wasPlaying = player.isPlaying
            player.stop() // drops scheduled buffers; player time restarts at 0
            resetPlayback()
            if wasPlaying && player.engine?.isRunning == true { player.play() }
        }
    }

    /// Meter values now: output follows the playhead, input decays if the mic goes quiet.
    func meters() -> (output: Float, input: Float, playing: Bool) {
        let now = playerFrame()
        return lock.withLock {
            let t = now ?? 0
            let playing = now != nil && t < scheduledEnd
            let out = playing && !outputMuted ? LivePCM.meterLevel(rms: envelope.level(at: t)) : 0
            let fresh = ProcessInfo.processInfo.systemUptime - lastInputAt < 0.25
            let input = fresh && !micMuted ? LivePCM.meterLevel(rms: lastInputRMS) : 0
            return (out, input, playing)
        }
    }

    private func playerFrame() -> Int64? {
        // AVAudioNode time APIs raise an ObjC exception on a node without an engine.
        guard player.engine != nil, let nodeTime = player.lastRenderTime, nodeTime.isSampleTimeValid,
              let t = player.playerTime(forNodeTime: nodeTime) else { return nil }
        return t.sampleTime
    }

    private func resetPlayback() {
        lock.withLock {
            scheduledEnd = 0
            envelope.reset()
            carry = nil
        }
    }

    // MARK: Graph

    private func startOnQueue() throws {
        guard !running else { return }
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try? session.setPreferredIOBufferDuration(0.02)
        try session.setActive(true)
        #endif
        do {
            try buildGraph()
            engine.prepare()
            try engine.start()
        } catch where useVoiceProcessing {
            // VPIO can't initialize on some routes (measured: a Bluetooth headset as both input and
            // output, -10875 on the output unit). A headset needs no echo cancellation: retry plain.
            log.error("voice processing failed (\(error.localizedDescription, privacy: .public)); retrying without it")
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            engine = AVAudioEngine()
            playerLock.withLock { player = AVAudioPlayerNode() }
            useVoiceProcessing = false
            try buildGraph()
            engine.prepare()
            try engine.start()
        }
        playerLock.withLock { player.play() }
        running = true
        if observers.isEmpty { observe() }
        onStateChange?(true)
    }

    private func buildGraph() throws {
        let input = engine.inputNode
        if useVoiceProcessing {
            if !input.isVoiceProcessingEnabled {
                do { try input.setVoiceProcessingEnabled(true) } catch {
                    throw LiveError.audio("voice processing unavailable: \(error.localizedDescription)")
                }
            }
            // Don't duck other apps more than needed (macOS VP ducks system audio hard by default).
            input.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: true, duckingLevel: .min)
            input.isVoiceProcessingInputMuted = lock.withLock { micMuted }
        } else if input.isVoiceProcessingEnabled {
            try? input.setVoiceProcessingEnabled(false)
        }

        if player.engine == nil { engine.attach(player) }
        engine.connect(player, to: engine.mainMixerNode, format: playFormat)
        player.volume = lock.withLock { outputMuted } ? 0 : 1

        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let conv = LiveCaptureConverter(inputFormat: format) else {
            throw LiveError.audio("no microphone input (permission or device)")
        }
        converter = conv
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            self?.captured(buffer)
        }
    }

    /// Tap thread.
    private func captured(_ buffer: AVAudioPCMBuffer) {
        let (muted, sink) = lock.withLock { (micMuted, _onCapture) }
        guard !muted, let converter else { return }
        for chunk in converter.process(buffer) {
            let r = LivePCM.rms(pcm16: chunk)
            lock.withLock {
                lastInputRMS = r
                lastInputAt = ProcessInfo.processInfo.systemUptime
            }
            sink?(chunk)
        }
    }

    /// Rebuilds taps/connections after the hardware format changed and restarts if we were running.
    private func restartAfterChange(reason: String) {
        guard running else { return }
        log.info("audio graph restart: \(reason, privacy: .public)")
        engine.inputNode.removeTap(onBus: 0)
        playerLock.withLock { player.stop() }
        engine.stop()
        resetPlayback()
        do {
            try buildGraph()
            engine.prepare()
            try engine.start()
            playerLock.withLock { player.play() }
            onStateChange?(true)
        } catch {
            log.error("audio restart failed: \(error.localizedDescription, privacy: .public)")
            onStateChange?(false)
        }
    }

    private func observe() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.restartAfterChange(reason: "configuration change") }
        })
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: nil) { [weak self] note in
            guard let self, let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            let opts = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init)
            self.queue.async {
                switch type {
                case .began:
                    self.onStateChange?(false) // the system already paused the engine
                case .ended:
                    guard opts?.contains(.shouldResume) ?? true else { return }
                    try? AVAudioSession.sharedInstance().setActive(true)
                    self.restartAfterChange(reason: "interruption ended")
                @unknown default:
                    break
                }
            }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: nil) { [weak self] note in
            guard let self, let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
            // Most route changes also post AVAudioEngineConfigurationChange; restart only if the
            // engine actually stopped.
            if reason == .newDeviceAvailable || reason == .oldDeviceUnavailable || reason == .override {
                self.queue.async {
                    if self.running && !self.engine.isRunning { self.restartAfterChange(reason: "route change") }
                }
            }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                // Every audio object is invalid now: start from a new engine.
                guard self.running else { return }
                for o in self.observers { nc.removeObserver(o) }
                self.observers = []
                self.engine = AVAudioEngine()
                self.playerLock.withLock { self.player = AVAudioPlayerNode() }
                self.resetPlayback()
                self.running = false
                do { try self.startOnQueue() } catch {
                    self.log.error("audio reset recovery failed: \(error.localizedDescription, privacy: .public)")
                    self.onStateChange?(false)
                }
            }
        })
        #endif
    }
}
