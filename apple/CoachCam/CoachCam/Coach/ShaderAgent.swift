import CoachAPI
import CoachModels
import Foundation
import Metal
import Observation

/// Looks: Gemini 4 Neon writes the body of one Metal function for a dictated look, the phone
/// compiles it at runtime and the photo renders through it. A compile error goes back to Neon in
/// the same conversation (at most two repair rounds). The last good body is kept per shot.
@MainActor @Observable
final class ShaderAgent {
    enum Phase: Equatable { case idle, writing, fixing(Int), ready, failed }

    /// The code as it streams in (fences stripped), for the on-screen pane.
    private(set) var code = ""
    private(set) var phase: Phase = .idle
    /// True once a compile error was repaired; the pane flashes blue.
    private(set) var repaired = false
    private(set) var pipeline: MTLRenderPipelineState?
    private(set) var usesTime = false
    /// Bumps each time a new pipeline lands (the view crossfades on it).
    private(set) var serial = 0
    private(set) var body: String?

    private let shot: ObjectIdentifier?
    private var task: Task<Void, Never>?
    @ObservationIgnored private lazy var gemini: GeminiDirect? = GeminiDirect.keyFromBundle().map { GeminiDirect(apiKey: $0) }

    static let device = MTLCreateSystemDefaultDevice()
    private static var lastGood: [ObjectIdentifier: String] = [:]

    init(shot: ObjectIdentifier?) {
        self.shot = shot
        let start = shot.flatMap { Self.lastGood[$0] } ?? Self.identity
        if let p = try? Self.compile(start) {
            pipeline = p
            body = start
            code = start == Self.identity ? "" : start
            usesTime = Self.mentionsTime(start)
            phase = start == Self.identity ? .idle : .ready
        }
    }

    var busy: Bool { phase == .writing || { if case .fixing = phase { return true }; return false }() }

    /// Asks Neon for a look. With a current look, a follow-up ("more grain") refines it.
    func ask(_ request: String, preset: LookPreset? = nil) {
        let words = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        task?.cancel()
        let refining = preset == nil && body != nil && body != Self.identity
        let prompt = refining
            ? "Current look body:\n```metal\n\(body!)\n```\nChange it: \(words)\nReturn the full updated body."
            : "Look: \(words)"
        task = Task { await run(prompt: prompt, title: preset?.title, fallback: preset?.fallback) }
    }

    func cancel() { task?.cancel(); task = nil }

    private func run(prompt: String, title: String?, fallback: String?) async {
        repaired = false
        var contents: [JSONValue] = [GeminiDirect.user([GeminiDirect.text(prompt)])]
        for round in 0...2 {
            phase = round == 0 ? .writing : .fixing(round)
            code = ""
            var text = ""
            do {
                guard let gemini else { throw GeminiDirect.Failure.noKey }
                var opts = GeminiDirect.Options(system: Self.system)
                opts.thinking = nil
                opts.timeout = 60
                for try await delta in gemini.stream(model: GeminiDirect.strongModel, contents: contents, options: opts) {
                    text += delta
                    code = Self.display(text)
                }
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                await typeOut(fallback, title: title)
                return
            }
            if Task.isCancelled { return }
            let candidate = Self.extractBody(text)
            do {
                let p = try await Self.compileOff(candidate)
                if Task.isCancelled { return }
                install(p, candidate)
                repaired = round > 0
                Speaker.shared.say(title.map { "\($0), live." } ?? "Your look is live.")
                return
            } catch {
                if round == 2 { break }
                contents.append(.object(["role": .string("model"), "parts": .array([GeminiDirect.text(text)])]))
                contents.append(GeminiDirect.user([GeminiDirect.text(
                    "That failed to compile. The body starts at line \(Self.bodyLine) of the full source.\n"
                    + Self.trimError(error) + "\nFix it. Return the full corrected body in one ```metal block.")]))
            }
        }
        if let fallback, (try? await Self.compileOff(fallback)) != nil {
            await typeOut(fallback, title: title)
        } else {
            phase = .failed
        }
    }

    /// Offline: types the bundled preset body out (so the pane still reads) and installs it.
    private func typeOut(_ fallback: String?, title: String?) async {
        guard let fallback, let p = try? await Self.compileOff(fallback) else { phase = .failed; return }
        phase = .writing
        code = ""
        let chars = Array(fallback)
        var i = 0
        while i < chars.count {
            if Task.isCancelled { return }
            let n = min(chars.count - i, 14)
            code += String(chars[i..<(i + n)])
            i += n
            try? await Task.sleep(for: .milliseconds(16))
        }
        install(p, fallback)
        Speaker.shared.say(title.map { "\($0), live." } ?? "Your look is live.")
    }

    private func install(_ p: MTLRenderPipelineState, _ b: String) {
        pipeline = p
        body = b
        code = b
        usesTime = Self.mentionsTime(b)
        serial += 1
        phase = .ready
        if let shot { Self.lastGood[shot] = b }
    }

    // MARK: Metal

    static let identity = "return c;"

    static let header = """
    #include <metal_stdlib>
    using namespace metal;

    struct LabOut { float4 pos [[position]]; float2 uv; };
    struct LabU { float2 size; float t; float mix; };

    vertex LabOut lab_vertex(uint vid [[vertex_id]]) {
        float2 p = float2(float((vid << 1) & 2), float(vid & 2)) * 2.0 - 1.0;
        LabOut o;
        o.pos = float4(p, 0.0, 1.0);
        o.uv = float2(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5);
        return o;
    }

    static float4 look(float4 c, float2 uv, float2 size, float t, texture2d<float> src, sampler s) {

    """

    static let footer = """

    }

    fragment float4 lab_fragment(LabOut in [[stage_in]], constant LabU& u [[buffer(0)]],
                                 texture2d<float> src [[texture(0)]], sampler s [[sampler(0)]]) {
        float4 c = src.sample(s, in.uv);
        float4 r = look(c, in.uv, u.size, u.t, src, s);
        return float4(clamp(r.rgb, 0.0, 1.0), u.mix);
    }
    """

    static var bodyLine: Int { header.components(separatedBy: "\n").count }

    static func source(_ body: String) -> String { header + body + footer }

    nonisolated static func compile(_ body: String) throws -> MTLRenderPipelineState {
        guard let device = MTLCreateSystemDefaultDevice() else { throw GeminiDirect.Failure.badReply("no Metal device") }
        let opts = MTLCompileOptions()
        opts.mathMode = .fast
        let lib = try device.makeLibrary(source: header + body + footer, options: opts)
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: "lab_vertex")
        d.fragmentFunction = lib.makeFunction(name: "lab_fragment")
        let a = d.colorAttachments[0]!
        a.pixelFormat = .bgra8Unorm
        a.isBlendingEnabled = true
        a.sourceRGBBlendFactor = .sourceAlpha
        a.destinationRGBBlendFactor = .oneMinusSourceAlpha
        a.sourceAlphaBlendFactor = .one
        a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try device.makeRenderPipelineState(descriptor: d)
    }

    private struct Box: @unchecked Sendable { let p: MTLRenderPipelineState }

    static func compileOff(_ body: String) async throws -> MTLRenderPipelineState {
        try await Task.detached(priority: .userInitiated) { Box(p: try compile(body)) }.value.p
    }

    /// The streamed text with the code fences dropped.
    static func display(_ text: String) -> String {
        text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
            .joined(separator: "\n").trimmingCharacters(in: .newlines)
    }

    /// The body from the reply: the ```metal block, unwrapped if the model wrote the whole function.
    static func extractBody(_ text: String) -> String {
        var s = text
        if let open = s.range(of: "```") {
            let afterFence = s[open.upperBound...]
            let start = afterFence.firstIndex(of: "\n").map { afterFence.index(after: $0) } ?? afterFence.startIndex
            let rest = s[start...]
            s = String(rest.range(of: "```").map { rest[..<$0.lowerBound] } ?? rest)
        }
        if let sig = s.range(of: "float4 look("), let open = s[sig.upperBound...].firstIndex(of: "{"),
           let close = s.lastIndex(of: "}"), open < close {
            s = String(s[s.index(after: open)..<close])
        }
        let lines = s.components(separatedBy: "\n").filter {
            let t = $0.trimmingCharacters(in: .whitespaces)
            return !t.hasPrefix("#include") && !t.hasPrefix("using namespace")
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func mentionsTime(_ body: String) -> Bool {
        body.range(of: #"(?<![A-Za-z0-9_.])t(?![A-Za-z0-9_])"#, options: .regularExpression) != nil
    }

    static func trimError(_ error: Error) -> String {
        let s = (error as NSError).localizedDescription
        return String(s.prefix(1800))
    }

    static let system = """
    You write Metal Shading Language for a live photo look on iPhone.
    Write ONLY the body of this function; the signature and braces are already written around it:

    float4 look(float4 c, float2 uv, float2 size, float t, texture2d<float> src, sampler s)

    - c: this pixel's source colour, sRGB-encoded, 0 to 1, alpha 1.
    - uv: 0 to 1, origin top-left. size: the image size in pixels (about 1000 to 2000 on the long side).
    - t: seconds since the look started. Use t only if the look needs motion (VHS jitter, flicker); otherwise never use it.
    - src and s: the source photo. Sample other points with src.sample(s, uv2) for blur, halftone, bleed or grain. At most 48 samples per pixel.
    - Return the new colour: rgb 0 to 1, alpha 1.
    - Metal standard library only (mix, smoothstep, clamp, saturate, dot, fract, floor, sin, cos, pow, length, step, max, min, abs). No helper functions, no structs, no #include, no globals, no texture writes. Local arrays are fine.
    - Declare every variable with an explicit type (float, float2, float3, float4, int, float2x2). Use float literals (1.0, not 1). No `auto`.
    - Hash for grain: fract(sin(dot(p, float2(12.9898, 78.233))) * 43758.5453), with p = uv * size so grain is per pixel.
    - Scale pattern sizes from size (for example a halftone cell of max(size.x, size.y) / 150.0 pixels) so the look holds at any resolution.
    Reply with exactly one ```metal code block containing only the body. No prose.

    Make film and print looks read as real photography, not a cartoon:
    - Grade with a gentle S-curve; never clip; keep skin believable; luminance grain about 2 to 4 percent, strongest in midtones.
    - Kodachrome 64: rich warm reds and yellows, deep dense blues and cyan skies, punchy contrast, slightly crushed shadows, very fine grain. Kodachrome 200/400: the same palette, warmer, more contrast and clearly visible grain.
    - Ektachrome: cooler and clean, saturated blues and cyans, neutral highlights. Portra 400: soft contrast, warm gentle skin, pastel greens, lifted shadows, fine grain, restrained saturation.
    - Polaroid fade: lifted blacks, creamy warm highlights, cyan-green shadows, lower contrast, soft vignette.
    - Cyanotype: monochrome from Prussian blue (about 0.06, 0.20, 0.42) to slightly warm paper white.
    - Risograph: two inks (fluorescent pink and teal or blue) as posterised halftone layers with a few pixels of misregistration and paper tooth.
    - Halftone: CMYK dots on rotated grids (C 15, M 75, Y 0, K 45 degrees), dot radius from the ink amount, composited subtractively on paper white.
    - VHS: horizontal chroma bleed, soft luma, scanlines, tracking noise and slight jitter animated with t.
    - Thermal: luminance through a black, indigo, magenta, orange, yellow, white ramp.
    - 1-bit or Bayer dither: an 8x8 ordered dither on luminance to ink black and paper white (or a two-colour palette).
    """
}

/// The quiet preset keys. Each still asks Neon live; `fallback` is used only if the network fails.
struct LookPreset: Identifiable, Hashable {
    let title: String
    let request: String
    let fallback: String
    var id: String { title }

    static let all: [LookPreset] = [
        LookPreset(title: "Halftone", request: "CMYK halftone print, rotated dot screens on paper", fallback: """
        float cell = max(size.x, size.y) / 140.0;
        float2 px = uv * size;
        float3 paper = float3(0.97, 0.95, 0.90);
        float4 angles = float4(0.2618, 1.309, 0.0, 0.7854);
        float4 ink = float4(0.0);
        for (int i = 0; i < 4; i++) {
            float a = angles[i];
            float2x2 r = float2x2(cos(a), -sin(a), sin(a), cos(a));
            float2 q = r * px;
            float2 center = (floor(q / cell) + 0.5) * cell;
            float2 back = transpose(r) * center;
            float3 cs = src.sample(s, back / size).rgb;
            float k = 1.0 - max(cs.r, max(cs.g, cs.b));
            float denom = max(1.0 - k, 0.001);
            float4 cmyk = float4((1.0 - cs.r - k) / denom, (1.0 - cs.g - k) / denom, (1.0 - cs.b - k) / denom, k);
            float rad = sqrt(clamp(cmyk[i], 0.0, 1.0)) * cell * 0.62;
            float d = length(q - center);
            ink[i] = 1.0 - smoothstep(rad - 0.8, rad + 0.8, d);
        }
        float3 col = paper;
        col *= mix(float3(1.0), float3(0.0, 0.62, 0.92), ink.x);
        col *= mix(float3(1.0), float3(0.92, 0.10, 0.55), ink.y);
        col *= mix(float3(1.0), float3(1.0, 0.92, 0.0), ink.z);
        col *= mix(float3(1.0), float3(0.12, 0.12, 0.14), ink.w);
        return float4(col, 1.0);
        """),
        LookPreset(title: "Kodachrome", request: "Kodachrome 400 slide film", fallback: """
        float3 x = c.rgb;
        x = float3(x.r * 1.08 + x.g * -0.04, x.g * 0.98 + x.r * 0.02, x.b * 1.04 - x.r * 0.04);
        float l = dot(x, float3(0.299, 0.587, 0.114));
        x = mix(float3(l), x, 1.18);
        x = clamp(x, 0.0, 1.0);
        x = x * x * (3.0 - 2.0 * x) * 0.55 + x * 0.45;
        x.r = pow(x.r, 0.94);
        x.b = pow(x.b, 1.06);
        x = mix(x, x * float3(1.04, 1.0, 0.92), smoothstep(0.5, 1.0, l));
        float2 p = uv * size;
        float g = fract(sin(dot(p, float2(12.9898, 78.233))) * 43758.5453) - 0.5;
        x += g * 0.06 * (1.0 - abs(l - 0.5) * 1.6);
        return float4(x, 1.0);
        """),
        LookPreset(title: "Cyanotype", request: "cyanotype print", fallback: """
        float l = dot(c.rgb, float3(0.299, 0.587, 0.114));
        l = smoothstep(0.04, 0.96, l);
        float3 blue = float3(0.06, 0.20, 0.42);
        float3 paper = float3(0.95, 0.94, 0.89);
        float2 p = uv * size;
        float g = fract(sin(dot(floor(p * 0.5), float2(12.9898, 78.233))) * 43758.5453) - 0.5;
        float3 col = mix(blue, paper, pow(l, 1.15)) + g * 0.03;
        return float4(col, 1.0);
        """),
        LookPreset(title: "Riso", request: "two-colour risograph print, fluorescent pink and teal", fallback: """
        float2 off = float2(3.0, -2.0) / size;
        float l1 = dot(src.sample(s, uv + off).rgb, float3(0.299, 0.587, 0.114));
        float l2 = dot(c.rgb, float3(0.299, 0.587, 0.114));
        float2 px = uv * size;
        float cell = max(size.x, size.y) / 220.0;
        float2 q = fract(px / cell) - 0.5;
        float dotv = length(q);
        float pink = 1.0 - smoothstep(0.0, 0.05, dotv - sqrt(1.0 - l1) * 0.55);
        float teal = 1.0 - smoothstep(0.0, 0.05, dotv - sqrt(clamp(0.8 - l2, 0.0, 1.0)) * 0.6);
        float3 col = float3(0.96, 0.94, 0.89);
        col *= mix(float3(1.0), float3(1.0, 0.30, 0.62), pink * 0.9);
        col *= mix(float3(1.0), float3(0.0, 0.47, 0.55), teal * 0.85);
        float g = fract(sin(dot(px, float2(12.9898, 78.233))) * 43758.5453);
        col -= g * 0.03;
        return float4(col, 1.0);
        """),
        LookPreset(title: "VHS", request: "worn VHS tape", fallback: """
        float jitter = (fract(sin(floor(t * 24.0) * 91.7) * 4375.5) - 0.5) * 2.0 / size.x;
        float row = floor(uv.y * size.y / 2.0);
        float wobble = sin(uv.y * 40.0 + t * 3.0) * 0.6 / size.x;
        float2 u = uv + float2(jitter + wobble, 0.0);
        float r = src.sample(s, u + float2(4.0 / size.x, 0.0)).r;
        float g = src.sample(s, u).g;
        float b = src.sample(s, u - float2(4.0 / size.x, 0.0)).b;
        float3 col = float3(r, g, b);
        col = mix(float3(dot(col, float3(0.299, 0.587, 0.114))), col, 0.85);
        col *= 0.92 + 0.08 * fmod(row, 2.0);
        float n = fract(sin(dot(float2(row, floor(t * 30.0)), float2(12.9898, 78.233))) * 43758.5453);
        col += (n - 0.5) * 0.05;
        col = col * 0.9 + 0.05;
        return float4(col, 1.0);
        """),
    ]
}
