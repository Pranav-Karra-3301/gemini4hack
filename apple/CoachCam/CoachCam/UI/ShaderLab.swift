import AVFoundation
import CoachUI
import MetalKit
import Speech
import SwiftUI
import UIKit

/// Looks: say a look ("Kodachrome 400", "halftone"), Gemini 4 Neon writes the Metal for it while
/// the code types out over the photo, and the photo renders through it live. Follow-ups refine
/// the current look ("more grain"). A quiet preset row asks for the reliable ones.
struct ShaderLab: View {
    let model: RevealModel
    @State private var agent: ShaderAgent
    @State private var listener = LookListener()
    @State private var source: CGImage?
    @State private var expanded = false
    @State private var chosen: String?
    @State private var pulse = false
    @State private var flash = false
    @State private var pressed = false
    @State private var pressStart: Date?
    @State private var tapMode = false

    init(model: RevealModel) {
        self.model = model
        _agent = State(initialValue: ShaderAgent(shot: model.photo.map(ObjectIdentifier.init)))
    }

    private var image: UIImage? { model.edited ?? model.photo }

    var body: some View {
        VStack(spacing: 14) {
            GeometryReader { box in
                let rect = ShotReveal.fit(image?.size, in: box.size)
                ZStack(alignment: .bottom) {
                    LabMetalView(texture: source, agent: agent)
                    codePane(height: rect.height)
                    DictationBar(isListening: listener.armed || listener.isListening,
                                 transcript: listener.transcript,
                                 level: Float(listener.level))
                }
                .frame(width: rect.width, height: rect.height)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .offset(x: rect.minX, y: rect.minY)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            presets
            micKey
        }
        .task(id: image.map(ObjectIdentifier.init)) { await load() }
        .onAppear { listener.prepare() }
        .onChange(of: agent.phase) { old, p in
            pulse = false
            if case .fixing = p { withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) { pulse = true } }
            if p == .writing || { if case .fixing = p { return true }; return false }() {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { expanded = true }
            }
            if p == .ready, old != .ready {
                if agent.repaired {
                    flash = true
                    withAnimation(.easeOut(duration: 1.4)) { flash = false }
                }
                Task {
                    try? await Task.sleep(for: .milliseconds(700))
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.9)) { expanded = false }
                }
            }
        }
        .onDisappear {
            agent.cancel()
            listener.cancel()
        }
    }

    // MARK: Code pane

    private func codePane(height: CGFloat) -> some View {
        let open = expanded && !agent.code.isEmpty || agent.busy
        let border: Color = {
            if case .fixing = agent.phase { return CoachColor.safelight.opacity(pulse ? 0.9 : 0.3) }
            if agent.phase == .failed { return CoachColor.signal.opacity(0.6) }
            if flash { return ShotReveal.geminiBlue.opacity(0.95) }
            return agent.busy ? ShotReveal.geminiBlue.opacity(0.45) : Color.white.opacity(0.10)
        }()
        return Group {
            if open {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 0) {
                            (Text(CodeTint.tint(agent.code)) + Text(agent.busy ? "▍" : "")
                                .foregroundColor(ShotReveal.geminiBlue))
                                .font(CoachFont.mono(10.5, weight: .regular))
                                .lineSpacing(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                            Color.clear.frame(height: 1).id("end")
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                    }
                    .onChange(of: agent.code) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
                    .onAppear { proxy.scrollTo("end", anchor: .bottom) }
                }
                .frame(height: max(120, height * 0.46))
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if !agent.code.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "curlybraces").font(.system(size: 11, weight: .semibold))
                    Text("\(agent.code.components(separatedBy: "\n").count)")
                        .font(CoachFont.mono(10.5))
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up").font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(GXColor.frost.opacity(0.55))
                .padding(.horizontal, 12)
                .frame(height: 28)
                .transition(.opacity)
            }
        }
        .background(Color.black.opacity(0.55))
        .background(.ultraThinMaterial.opacity(0.5))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(8)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !agent.busy else { return }
            withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { expanded.toggle() }
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: open)
    }

    // MARK: Keys

    private var presets: some View {
        HStack(spacing: 6) {
            ForEach(LookPreset.all) { p in
                Button {
                    UISelectionFeedbackGenerator().selectionChanged()
                    chosen = p.title
                    agent.ask(p.request, preset: p)
                } label: {
                    Text(p.title)
                        .font(CoachFont.mono(11))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .foregroundStyle(GXColor.frost.opacity(chosen == p.title ? 0.95 : 0.5))
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                        .background(GXColor.frost.opacity(chosen == p.title ? 0.14 : 0.06), in: Capsule(style: .circular))
                }
                .buttonStyle(KeyPressStyle())
            }
        }
        .padding(.horizontal, 4)
    }

    private var micKey: some View {
        Capsule(style: .circular)
            .fill(Color(red: 0.64, green: 0.09, blue: 0.11))
            .overlay {
                Capsule(style: .circular)
                    .fill(RadialGradient(colors: [Color(red: 1, green: 0.38, blue: 0.34).opacity(0.85), .clear],
                                         center: .center, startRadius: 0, endRadius: 80))
                    .opacity(listener.isListening ? 0.35 + 0.65 * listener.level : (listener.armed ? 0.35 : 0))
                    .animation(.easeOut(duration: 0.12), value: listener.level)
            }
            .overlay(Image(systemName: agent.busy ? "wand.and.rays" : "mic.fill")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.92))
                .symbolEffect(.pulse, isActive: agent.busy))
            .scaleEffect(pressed ? 0.96 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: pressed)
            .frame(width: 160, height: 64)
            .contentShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !pressed else { return }
                        pressed = true
                        pressStart = .now
                        UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.8)
                        if listener.armed {
                            // Second tap in tap mode: stop and send.
                            tapMode = false
                            send()
                        } else {
                            listener.onSilence = { if tapMode { tapMode = false; send() } }
                            listener.begin()
                        }
                    }
                    .onEnded { _ in
                        pressed = false
                        let held = Date.now.timeIntervalSince(pressStart ?? .now)
                        guard listener.armed else { return }
                        if held < 0.35 {
                            // A quick tap keeps listening until the next tap or 1.2 s of silence.
                            tapMode = true
                        } else {
                            send()
                        }
                    }
            )
            .accessibilityLabel(listener.armed ? "Stop and send" : "Tap or hold to say a look")
            .accessibilityAddTraits(.isButton)
    }

    private func send() {
        listener.end { said in
            guard !said.isEmpty else { return }
            chosen = nil
            agent.ask(said)
        }
    }

    // MARK: Source

    /// The viewer's current photo, rendered once off the main thread at screen-fit resolution.
    private func load() async {
        guard let image else { return }
        let scale = UIScreen.main.scale
        let longSide = max(UIScreen.main.bounds.width, UIScreen.main.bounds.height) * scale
        let cg = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            let size = image.size
            let k = min(1, longSide / max(size.width, size.height))
            let target = CGSize(width: (size.width * k).rounded(), height: (size.height * k).rounded())
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.preferredRange = .standard
            return UIGraphicsImageRenderer(size: target, format: format)
                .image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }.cgImage
        }.value
        source = cg
    }
}

/// Gemini-blue keywords, soft amber numbers, dim comments.
enum CodeTint {
    private static let keywords = try! NSRegularExpression(
        pattern: #"\b(float[234]?(x[234])?|half[234]?|int[234]?|uint|bool|const|constexpr|return|for|if|else|while|break|continue)\b"#)
    private static let functions = try! NSRegularExpression(pattern: #"\b([a-z_][A-Za-z0-9_]*)(?=\()"#)
    private static let numbers = try! NSRegularExpression(pattern: #"\b\d+(\.\d+)?\b"#)
    private static let comments = try! NSRegularExpression(pattern: #"//[^\n]*"#)

    static func tint(_ code: String) -> AttributedString {
        var a = AttributedString(code)
        a.foregroundColor = CoachColor.paper.opacity(0.80)
        let ns = NSRange(code.startIndex..., in: code)
        func paint(_ re: NSRegularExpression, _ color: Color) {
            for m in re.matches(in: code, range: ns) {
                guard let r = Range(m.range, in: code), let ar = Range(r, in: a) else { continue }
                a[ar].foregroundColor = color
            }
        }
        paint(functions, CoachColor.paper.opacity(0.95))
        paint(keywords, ShotReveal.geminiBlue)
        paint(numbers, CoachColor.safelightHot.opacity(0.85))
        paint(comments, CoachColor.paper.opacity(0.35))
        return a
    }
}

// MARK: Metal view

private struct LabMetalView: UIViewRepresentable {
    let texture: CGImage?
    let agent: ShaderAgent

    func makeCoordinator() -> LabRenderer { LabRenderer() }

    func makeUIView(context: Context) -> MTKView {
        let v = MTKView(frame: .zero, device: ShaderAgent.device)
        v.colorPixelFormat = .bgra8Unorm
        v.framebufferOnly = true
        v.clearColor = MTLClearColor(red: 0.03, green: 0.03, blue: 0.04, alpha: 1)
        v.isOpaque = true
        v.backgroundColor = .black
        v.delegate = context.coordinator
        v.isPaused = true
        v.enableSetNeedsDisplay = true
        context.coordinator.view = v
        return v
    }

    func updateUIView(_ v: MTKView, context: Context) {
        let r = context.coordinator
        if r.image !== texture { r.setImage(texture) }
        r.usesTime = agent.usesTime
        if r.serial != agent.serial, let p = agent.pipeline {
            r.swap(to: p, crossfade: r.current != nil && r.serial >= 0)
            r.serial = agent.serial
        }
        r.schedule()
    }
}

private struct LabUniforms {
    var size: SIMD2<Float>
    var t: Float
    var mix: Float
}

private final class LabRenderer: NSObject, MTKViewDelegate {
    weak var view: MTKView?
    var image: CGImage?
    var current: MTLRenderPipelineState?
    var serial = -1
    var usesTime = false
    private var texture: MTLTexture?
    private var previous: MTLRenderPipelineState?
    private var fadeStart: CFTimeInterval = 0
    private let start = CACurrentMediaTime()
    private let fade: CFTimeInterval = 0.7
    private lazy var queue = ShaderAgent.device?.makeCommandQueue()
    private lazy var sampler: MTLSamplerState? = {
        let d = MTLSamplerDescriptor()
        d.minFilter = .linear
        d.magFilter = .linear
        d.sAddressMode = .clampToEdge
        d.tAddressMode = .clampToEdge
        return ShaderAgent.device?.makeSamplerState(descriptor: d)
    }()

    func setImage(_ cg: CGImage?) {
        image = cg
        guard let cg, let device = ShaderAgent.device else { texture = nil; return }
        texture = try? MTKTextureLoader(device: device).newTexture(cgImage: cg, options: [
            .SRGB: NSNumber(value: false),
            .origin: MTKTextureLoader.Origin.topLeft,
            .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
        ])
    }

    func swap(to p: MTLRenderPipelineState, crossfade: Bool) {
        previous = crossfade ? current : nil
        current = p
        fadeStart = CACurrentMediaTime()
    }

    /// Continuous frames while crossfading or when the look animates; on demand otherwise.
    func schedule() {
        guard let view else { return }
        let animating = previous != nil || usesTime
        if animating {
            view.enableSetNeedsDisplay = false
            view.isPaused = false
        } else {
            view.isPaused = true
            view.enableSetNeedsDisplay = true
            view.setNeedsDisplay()
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { view.setNeedsDisplay() }

    func draw(in view: MTKView) {
        guard let tex = texture, let cur = current, let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable, let cb = queue?.makeCommandBuffer(),
              let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        let now = CACurrentMediaTime()
        let k = Float(min(1, (now - fadeStart) / fade))
        var u = LabUniforms(size: SIMD2(Float(tex.width), Float(tex.height)), t: Float(now - start), mix: 1)
        enc.setFragmentTexture(tex, index: 0)
        enc.setFragmentSamplerState(sampler, index: 0)
        if let prev = previous, k < 1 {
            enc.setRenderPipelineState(prev)
            enc.setFragmentBytes(&u, length: MemoryLayout<LabUniforms>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            u.mix = k * k * (3 - 2 * k)
        }
        enc.setRenderPipelineState(cur)
        enc.setFragmentBytes(&u, length: MemoryLayout<LabUniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cb.present(drawable)
        cb.commit()
        if k >= 1, previous != nil {
            previous = nil
            DispatchQueue.main.async { [weak self] in self?.schedule() }
        }
    }
}

// MARK: Voice

/// Hold-to-talk dictation for Looks: its own recognizer and engine (the viewer's VoiceEdit is
/// untouched). The tap and engine stop on release; the transcript arrives a beat later.
@MainActor @Observable
final class LookListener {
    private(set) var isListening = false
    private(set) var level: Double = 0
    /// True from the tap, before the engine is up, so the UI shows listening at once.
    private(set) var armed = false
    private(set) var transcript = ""
    /// Called after 1.2 s of silence following speech (tap mode stops and sends on it).
    @ObservationIgnored var onSilence: (() -> Void)?
    @ObservationIgnored private var silence: Task<Void, Never>?
    @ObservationIgnored private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var tapped = false
    @ObservationIgnored private var wants = false
    @ObservationIgnored private var onFinal: ((String) -> Void)?

    /// Warms up permissions, the audio session and the engine when the page opens, so the first
    /// tap starts without lag.
    func prepare() {
        Task {
            guard await Self.authorized() else { return }
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
            _ = engine.inputNode
            engine.prepare()
        }
    }

    func begin() {
        wants = true
        armed = true
        transcript = ""
        Task {
            guard await Self.authorized(), wants else { return }
            start()
        }
    }

    func end(_ done: @escaping (String) -> Void) {
        wants = false
        armed = false
        silence?.cancel()
        guard isListening else { return }
        stopAudio()
        request?.endAudio()
        onFinal = done
        Task {
            try? await Task.sleep(for: .milliseconds(1300))
            deliver()
        }
    }

    func cancel() {
        wants = false
        armed = false
        silence?.cancel()
        onFinal = nil
        task?.cancel()
        task = nil
        request = nil
        stopAudio()
    }

    private static func authorized() async -> Bool {
        let speech = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        let mic = await AVAudioApplication.requestRecordPermission()
        return speech && mic
    }

    private func start() {
        guard let recognizer, recognizer.isAvailable else { return }
        stopAudio()
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            req.contextualStrings = ["Kodachrome", "Ektachrome", "Portra", "halftone", "cyanotype", "risograph", "VHS", "Polaroid", "Bayer"]
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                req.append(buffer)
                let lvl = Self.rms(buffer)
                Task { @MainActor in self?.level = lvl }
            }
            tapped = true
            engine.prepare()
            try engine.start()
            request = req
            task = recognizer.recognitionTask(with: req) { [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let final = (result?.isFinal ?? false) || error != nil
                Task { @MainActor in self?.heard(text, final: final) }
            }
            isListening = true
        } catch {
            stopAudio()
        }
    }

    private func heard(_ text: String?, final: Bool) {
        if let text, !text.isEmpty {
            transcript = text
            if isListening, !final {
                silence?.cancel()
                silence = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(1200))
                    guard !Task.isCancelled else { return }
                    self?.onSilence?()
                }
            }
        }
        if final { deliver() }
    }

    private func deliver() {
        guard let f = onFinal else { return }
        onFinal = nil
        task?.cancel()
        task = nil
        request = nil
        f(transcript.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func stopAudio() {
        if tapped { engine.inputNode.removeTap(onBus: 0); tapped = false }
        if engine.isRunning { engine.stop() }
        isListening = false
        level = 0
    }

    nonisolated private static func rms(_ buffer: AVAudioPCMBuffer) -> Double {
        guard let ch = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += ch[i] * ch[i] }
        let r = sqrt(sum / Float(buffer.frameLength))
        return Double(min(1, max(0, (20 * log10(max(r, 1e-6)) + 50) / 40)))
    }
}
