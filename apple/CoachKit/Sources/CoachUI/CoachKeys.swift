import SwiftUI

/// The two keys under the instruments: a matte red mic capsule (talk to Gemini) and the frosted
/// lantern shutter capsule. One geometry: height 72, radius 36, 16pt outer padding, 12pt gap;
/// the mic is 120 wide and the shutter takes the rest (229 on a 393pt phone). Press compresses
/// either key to 0.96.
///
///     CoachKeys(shutter: .ready, listening: live.isListening, level: live.inputLevel,
///               onMic: { live.toggleMic() }, onShutter: { camera.capture() })
///
/// The ready halo blooms ~20pt past the shutter, so leave room around the view.
public struct CoachKeys: View {
    /// What the shutter shows.
    public enum Shutter: Hashable, Sendable {
        /// Calm lantern with a debossed "+".
        case idle
        /// Inner glow brightens and a soft halo blooms (Gemini says the shot is lined up).
        case ready
        /// Depth Pro is running: a 2pt blue progress ring sweeps clockwise from the top (0…1).
        /// The mic dims to 30% meanwhile.
        case scanning(Double)
        /// Depth is ready: the "+" becomes a debossed check.
        case depthReady
    }

    private let shutter: Shutter
    private let listening: Bool
    private let level: Double
    private let onMic: () -> Void
    private let onShutter: () -> Void

    /// - Parameters:
    ///   - listening: the mic is open; the glyph slides left and a waveform fills the key.
    ///   - level: input level 0…1 driving the waveform (ignored when not listening).
    public init(shutter: Shutter = .idle, listening: Bool = false, level: Double = 0,
                onMic: @escaping () -> Void = {}, onShutter: @escaping () -> Void = {}) {
        self.shutter = shutter
        self.listening = listening
        self.level = level
        self.onMic = onMic
        self.onShutter = onShutter
    }

    private var scanning: Bool { if case .scanning = shutter { return true } else { return false } }

    public var body: some View {
        HStack(spacing: 12) {
            Button(action: onMic) { MicKey(listening: listening, level: level) }
                .buttonStyle(KeyPressStyle())
                .frame(width: 120)
                .opacity(scanning ? 0.3 : 1)
                .accessibilityLabel(listening ? "Stop talking to Gemini" : "Talk to Gemini")
            Button(action: onShutter) { ShutterKey(shutter: shutter) }
                .buttonStyle(KeyPressStyle())
                .accessibilityLabel(Self.accessibilityLabel(shutter))
        }
        .frame(height: 72)
        .padding(.horizontal, 16)
        .animation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.42), value: shutter)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: listening)
    }

    private static func accessibilityLabel(_ s: Shutter) -> String {
        switch s {
        case .idle: return "Shutter"
        case .ready: return "Shutter, ready"
        case .scanning(let p): return "Scanning depth, \(Int((p * 100).rounded())) percent"
        case .depthReady: return "Depth ready"
        }
    }
}

/// Press compresses the key to 0.96.
struct KeyPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - Mic

/// Matte red soft-touch capsule. Off: deep red, centred glyph. Listening: brighter red, a soft red
/// inner glow that breathes with the level, glyph at the left end and a live 10-bar waveform.
struct MicKey: View {
    var listening: Bool
    var level: Double

    var body: some View {
        let shape = Capsule(style: .circular)
        ZStack {
            // Drop shadows: #00000073 -3 10 20, #00000059 -1 2 5.
            shape.fill(Color.black).shadow(color: Color(rgba: 0x00000073), radius: 10, x: -3, y: 10)
            shape.fill(Color.black).shadow(color: Color(rgba: 0x00000059), radius: 2.5, x: -1, y: 2)
            // Soft-touch body.
            EllipticalFill(stops: listening
                           ? [.init(color: Color(rgba: 0xEE5C61FF), location: 0), .init(color: Color(rgba: 0xE5484DFF), location: 0.46),
                              .init(color: Color(rgba: 0xC9353BFF), location: 1)]
                           : [.init(color: Color(rgba: 0xB71F25FF), location: 0), .init(color: Color(rgba: 0xA3161BFF), location: 0.46),
                              .init(color: Color(rgba: 0x8C1217FF), location: 1)],
                           rx: 1.2, ry: 1.7, cx: 0.8, cy: 0)
                .clipShape(shape)
            // Form shade (low-left, away from the key light).
            EllipticalFill(stops: listening
                           ? [.init(color: Color(rgba: 0x5A060B40), location: 0), .init(color: Color(rgba: 0x5A060B00), location: 1)]
                           : [.init(color: Color(rgba: 0x38030752), location: 0), .init(color: Color(rgba: 0x38030700), location: 1)],
                           rx: 0.7, ry: 0.9, cx: 0.08, cy: 1)
                .clipShape(shape)
            // Edge falloff / listening inner glow.
            if listening {
                CoachTimeline(animating: true) { date in
                    let breathe = 0.82 + 0.18 * sin(date.timeIntervalSinceReferenceDate * 2 * .pi / 1.6)
                    let k = (0.7 + 0.3 * GXMath.clamp01(level)) * breathe
                    ZStack {
                        InsetShadow(color: Color(rgba: 0xFFA3A6A6).alpha(k), blur: 16, radius: 36)
                        InsetShadow(color: Color(rgba: 0xFFC9CB80).alpha(k), blur: 4, radius: 36)
                    }
                }
            } else {
                InsetShadow(color: Color(rgba: 0x30020638), blur: 12, radius: 36)
            }
            GrainOverlay(amount: 0.021, animated: false, tile: 120)
                .blendMode(.overlay)
                .clipShape(shape)
            GeometryReader { geo in
                MicGlyph()
                    .instrumentGlyphTurn()
                    .frame(width: 22, height: 22)
                    .position(x: listening ? 27 : geo.size.width / 2, y: geo.size.height / 2)
                if listening {
                    Waveform(level: level)
                        .frame(width: 56, height: 30)
                        .position(x: 46 + 28, y: geo.size.height / 2)
                        .transition(.opacity)
                }
            }
        }
        .compositingGroup()
        .frame(height: 72)
    }
}

/// The 22pt mic glyph.
struct MicGlyph: View {
    var body: some View {
        Canvas { ctx, size in
            let s = size.width / 22
            ctx.scaleBy(x: s, y: s)
            ctx.fill(Path(roundedRect: CGRect(x: 7.5, y: 2, width: 7, height: 11), cornerRadius: 3.5), with: .color(.white))
            var arc = Path()
            arc.move(to: CGPoint(x: 4.5, y: 10.5))
            arc.addCurve(to: CGPoint(x: 11, y: 17), control1: CGPoint(x: 4.5, y: 14.1), control2: CGPoint(x: 7.4, y: 17))
            arc.addCurve(to: CGPoint(x: 17.5, y: 10.5), control1: CGPoint(x: 14.6, y: 17), control2: CGPoint(x: 17.5, y: 14.1))
            arc.move(to: CGPoint(x: 11, y: 17))
            arc.addLine(to: CGPoint(x: 11, y: 20.5))
            ctx.stroke(arc, with: .color(.white), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
        }
        .accessibilityHidden(true)
    }
}

/// Ten 2pt bars, 6pt apart, up to 30pt tall; heights follow `level` with a lively per-bar motion.
struct Waveform: View {
    var level: Double

    /// The design's bar heights at a speaking level (6 14 24 12 28 18 10 20 10 4) as an envelope.
    static let envelope: [Double] = [6, 14, 24, 12, 28, 18, 10, 20, 10, 4].map { $0 / 28 }

    var body: some View {
        CoachTimeline(animating: true) { date in
            Canvas { ctx, size in
                let t = date.timeIntervalSinceReferenceDate
                let l = GXMath.clamp01(level)
                for i in 0..<10 {
                    let phase = Double(i) * 1.7
                    let wobble = 0.78 + 0.22 * sin(t * (5.1 + Double(i % 3) * 1.3) + phase)
                    let h = max(4, min(30, 28 * Self.envelope[i] * wobble * (0.3 + 0.7 * l)))
                    let rect = CGRect(x: CGFloat(i) * 6, y: (size.height - h) / 2, width: 2, height: h)
                    let alpha = (i == 0 || i == 9) ? 0.7 : 1
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(.white.opacity(alpha)))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Shutter

/// The frosted lantern stretched into a capsule: matte, lit from inside low-left, debossed "+".
struct ShutterKey: View {
    var shutter: CoachKeys.Shutter

    private var ready: Bool { shutter == .ready }

    var body: some View {
        let shape = Capsule(style: .circular)
        ZStack {
            // Ready halo: 20pt past the sides, 18pt above/below, blurred 18.
            EllipticalFill(stops: [.init(color: Color(rgba: 0x7A9CFFCC), location: 0),
                                   .init(color: Color(rgba: 0x9A7CF673), location: 0.52),
                                   .init(color: Color(rgba: 0x9A7CF600), location: 1)],
                           rx: 0.62, ry: 0.72, cx: 0.36, cy: 0.6)
                .clipShape(RoundedRectangle(cornerRadius: 54))
                .padding(.horizontal, -20)
                .padding(.vertical, -18)
                .blur(radius: 18)
                .opacity(ready ? 1 : 0)
            // Drop shadows (+ the ready glow).
            if ready {
                shape.fill(Color.black).shadow(color: Color(rgba: 0x00000040), radius: 9, x: -2, y: 8)
                shape.fill(Color.black).shadow(color: Color(rgba: 0x6C8CFF59), radius: 12)
            } else {
                shape.fill(Color.black).shadow(color: Color(rgba: 0x0000008C), radius: 11, x: -3, y: 10)
                shape.fill(Color.black).shadow(color: Color(rgba: 0x00000066), radius: 2.5, x: -1, y: 2)
            }
            // Lantern body.
            EllipticalFill(stops: ready
                           ? [.init(color: Color(rgba: 0x6F8BEAFF), location: 0), .init(color: Color(rgba: 0x4D56B8FF), location: 0.28),
                              .init(color: Color(rgba: 0x33307AFF), location: 0.56), .init(color: Color(rgba: 0x1E1B48FF), location: 0.82),
                              .init(color: Color(rgba: 0x110F2AFF), location: 1)]
                           : [.init(color: Color(rgba: 0x5068C2FF), location: 0), .init(color: Color(rgba: 0x3A3F92FF), location: 0.28),
                              .init(color: Color(rgba: 0x2A2660FF), location: 0.54), .init(color: Color(rgba: 0x18163AFF), location: 0.8),
                              .init(color: Color(rgba: 0x0C0B1EFF), location: 1)],
                           rx: 0.78, ry: 1.5, cx: 0.26, cy: 0.8)
                .clipShape(shape)
            // Inner glow, low-left.
            EllipticalFill(stops: ready
                           ? [.init(color: Color(rgba: 0xDCE6FFB3), location: 0), .init(color: Color(rgba: 0x7EA2FF8C), location: 0.3),
                              .init(color: Color(rgba: 0xA88CFA4D), location: 0.62), .init(color: Color(rgba: 0x9A7CF600), location: 0.9)]
                           : [.init(color: Color(rgba: 0xBED0FF80), location: 0), .init(color: Color(rgba: 0x648CFF66), location: 0.3),
                              .init(color: Color(rgba: 0x9A7CF633), location: 0.6), .init(color: Color(rgba: 0x9A7CF600), location: 0.88)],
                           rx: ready ? 0.54 : 0.46, ry: ready ? 1.08 : 0.95, cx: 0.27, cy: 0.74)
                .clipShape(shape)
            // Soft AO rim.
            InsetShadow(color: Color(rgba: ready ? 0x080A1E66 : 0x080A1E8C), blur: ready ? 18 : 22, radius: 36)
            shape.strokeBorder(Color(rgba: ready ? 0x080A1E33 : 0x080A1E40), lineWidth: 1)
            // Form light, upper-right.
            EllipticalFill(stops: [.init(color: Color(rgba: 0xDCE6FF1C), location: 0), .init(color: Color(rgba: 0xDCE6FF00), location: 1)],
                           rx: 0.6, ry: 0.9, cx: 0.8, cy: 0.1)
                .clipShape(shape)
            // Debossed mark.
            if shutter == .depthReady {
                DebossCheck().instrumentGlyphTurn().transition(.opacity)
            } else {
                DebossPlus().instrumentGlyphTurn().transition(.opacity)
            }
            GrainOverlay(amount: 0.021, animated: false, tile: 120)
                .blendMode(.overlay)
                .clipShape(shape)
            if case .scanning(let p) = shutter {
                ScanRing(progress: p)
            }
        }
        .compositingGroup()
        .frame(height: 72)
    }
}

/// Matte debossed "+": 22 × 1.5 bars in #0A0E28 50% with a 0.75pt light lip lower-left.
struct DebossPlus: View {
    var body: some View {
        ZStack {
            bars.fill(Color(rgba: 0xD6E2FF38)).offset(x: -0.75, y: 0.75)
            bars.fill(Color(rgba: 0x0A0E2880))
        }
        .frame(width: 22, height: 22)
    }

    private var bars: some Shape {
        DebossPlusShape()
    }
}

struct DebossPlusShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.addRoundedRect(in: CGRect(x: r.minX, y: r.midY - 0.75, width: r.width, height: 1.5), cornerSize: CGSize(width: 1, height: 1))
        p.addRoundedRect(in: CGRect(x: r.midX - 0.75, y: r.minY, width: 1.5, height: r.height), cornerSize: CGSize(width: 1, height: 1))
        return p
    }
}

/// Debossed check (depth ready).
struct DebossCheck: View {
    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            func check(_ dx: CGFloat, _ dy: CGFloat) -> Path {
                var p = Path()
                p.move(to: CGPoint(x: c.x - 9.5 + dx, y: c.y + 0.5 + dy))
                p.addLine(to: CGPoint(x: c.x - 3 + dx, y: c.y + 7 + dy))
                p.addLine(to: CGPoint(x: c.x + 10 + dx, y: c.y - 6.5 + dy))
                return p
            }
            let style = StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round)
            ctx.stroke(check(-0.75, 0.75), with: .color(Color(rgba: 0xD6E2FF38)), style: style)
            ctx.stroke(check(0, 0), with: .color(Color(rgba: 0x0A0E288C)), style: style)
        }
        .accessibilityHidden(true)
    }
}

/// Depth-scan progress: a ring inset 3pt that sweeps clockwise from the top centre.
struct ScanRing: View {
    var progress: Double

    var body: some View {
        let p = GXMath.clamp01(progress)
        ZStack {
            RingPath().stroke(Color(rgba: 0xB4CEFF24), lineWidth: 2)
            RingPath().trim(from: 0, to: p)
                .stroke(Color(rgba: 0x4C8DFF4D), style: StrokeStyle(lineWidth: 5, lineCap: .round))
            RingPath().trim(from: 0, to: p)
                .stroke(Color(rgba: 0x7FAEFFFF), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }
        .animation(.linear(duration: 0.12), value: p)
    }
}

/// The capsule outline inset 3pt, starting at the top centre and running clockwise.
struct RingPath: Shape {
    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: 3, dy: 3)
        let radius = r.height / 2
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - radius, y: r.minY))
        p.addArc(center: CGPoint(x: r.maxX - radius, y: r.midY), radius: radius,
                 startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: r.minX + radius, y: r.maxY))
        p.addArc(center: CGPoint(x: r.minX + radius, y: r.midY), radius: radius,
                 startAngle: .degrees(90), endAngle: .degrees(270), clockwise: false)
        p.closeSubpath()
        return p
    }
}
