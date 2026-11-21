// Logic and snapshot tests for the v2 instruments (InstrumentDrums, FocusRuler, CoachKeys, EdgeGlow,
// TapFocusMark, GrainOverlay). Snapshots go to /tmp/lc_qa/inst_<component>_<state>.png.
// Gated on COACHUI_TESTS, which Package.swift defines for CoachKitTests (it depends on CoachUI).
#if COACHUI_TESTS && os(macOS)
import AppKit
import CoachModels
import CoreText
@testable import CoachUI
import SwiftUI
import Testing

@MainActor
enum InstSnap {
    static let dir = URL(fileURLWithPath: "/tmp/lc_qa", isDirectory: true)
    static let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    static let repo = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Registers the bundled fonts straight from the source tree (no resource bundle in tests).
    static let fonts: Int = GXFont.register(directory: repo.appendingPathComponent("Sources/CoachUI/Resources/Fonts"))

    /// The design's swatch ground: panel colour plus the 3% grain.
    static var panel: some View {
        ZStack { GXColor.panel; GrainOverlay() }
    }

    /// A viewfinder stand-in: a sample photo, or a dark gradient.
    static var photo: some View {
        let url = repo.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("web/public/samples/img-1427.jpg")
        return ZStack {
            if let img = NSImage(contentsOf: url) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(colors: [Color(white: 0.4), Color(white: 0.15)], startPoint: .top, endPoint: .bottom)
            }
        }
    }

    @discardableResult
    static func write<V: View, B: View>(_ name: String, width: CGFloat, height: CGFloat, at date: Date = t0,
                                        background: B, @ViewBuilder _ view: () -> V) -> Bool {
        _ = fonts
        let content = ZStack {
            background.frame(width: width, height: height).clipped()
            view()
        }
        .frame(width: width, height: height)
        .coachClock(date)
        .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let cg = renderer.cgImage else { return false }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do { try data.write(to: dir.appendingPathComponent("inst_\(name).png")) } catch { return false }
        return true
    }

    static func write<V: View>(_ name: String, width: CGFloat, height: CGFloat, at date: Date = t0,
                               @ViewBuilder _ view: () -> V) -> Bool {
        write(name, width: width, height: height, at: date, background: panel, view)
    }

    static func at(_ ms: Int) -> Date { t0.addingTimeInterval(Double(ms) / 1000) }
}

@MainActor
@Suite("CoachUI instruments")
struct CoachUIInstrumentsTests {
    // MARK: Logic

    @Test func formatsValues() {
        #expect(InstrumentValue.iso(400).text == "400")
        #expect(InstrumentValue.iso(320.4).text == "320")
        #expect(InstrumentValue.shutter(1.0 / 125).text == "1/125")
        #expect(InstrumentValue.shutter(0.008).text == "1/125")
        #expect(InstrumentValue.shutter(1.0 / 60).text == "1/60")
        #expect(InstrumentValue.shutter(0.4).text == "1/2.5")
        #expect(InstrumentValue.shutter(1).text == "1\u{2033}")
        #expect(InstrumentValue.ev(0.3).text == "+0.3")
        #expect(InstrumentValue.ev(-0.667).text == "-0.7")
        #expect(InstrumentValue.ev(0).text == "0.0")
        #expect(InstrumentValue.ev(-0.01).text == "0.0")
        #expect(InstrumentValue.iso(320, auto: true).text == "AUTO")
        #expect(InstrumentValue.ev(1).isAuto == false)
        #expect(InstrumentValue.parts(.shutter, 1.0 / 250).prefix == "1/")
        #expect(InstrumentValue.parts(.shutter, 1.0 / 250).body == "250")
    }

    @Test func stripsKeepOffLadderValues() {
        let s = InstrumentValue.strip(.iso, including: [320])
        #expect(s.contains(320))
        #expect(s[InstrumentValue.index(of: 320, in: s, kind: .iso) - 1] == 200)
        #expect(s[InstrumentValue.index(of: 320, in: s, kind: .iso) + 1] == 400)
        let ss = InstrumentValue.strip(.shutter, including: [1.0 / 125])
        let i = InstrumentValue.index(of: 1.0 / 125, in: ss, kind: .shutter)
        #expect(InstrumentValue.parts(.shutter, ss[i - 1]).body == "60")
        #expect(InstrumentValue.parts(.shutter, ss[i + 1]).body == "250")
        let ev = InstrumentValue.strip(.ev, including: [0])
        let j = InstrumentValue.index(of: 0, in: ev, kind: .ev)
        #expect(InstrumentValue.parts(.ev, ev[j - 1]).body == "-0.3")
        #expect(InstrumentValue.parts(.ev, ev[j + 1]).body == "+0.3")
        for p in stride(from: 0.0, through: Double(ev.count - 1), by: 0.37) {
            let back = InstrumentValue.position(ofStops: InstrumentValue.stops(atPosition: p, in: ev, kind: .ev), in: ev, kind: .ev)
            #expect(abs(back - p) < 1e-9)
        }
    }

    @Test func geminiRollBlursOvershootsSettles() {
        let s = DrumState.changing(from: .iso(800), to: .iso(400), by: .gemini, at: InstSnap.t0)
        let to = Double(s.target)
        let p = { (ms: Int) in s.position(at: InstSnap.at(ms)) }
        #expect(abs(p(0) - (to + 1)) < 1e-9 && s.velocity(at: InstSnap.t0) == 0) // starts on 800, crisp
        #expect(abs(p(90) - to) < 0.5 && abs(s.velocity(at: InstSnap.at(90))) > 1) // mid-roll, moving fast
        let overshoot = (60...300).map { p($0) }.min()! - to         // 800 → 400 moves down the strip
        #expect(overshoot < -0.03 && overshoot > -0.12)             // a visible ~2-4pt overshoot past 400
        #expect(abs(p(400) - to) < 0.02)                            // settled
        // Glow: 0.5 → 0.82 at 90ms → ~0.72 at 170ms → 0.3 at 240ms → gone 420ms later.
        #expect(abs(s.glow(at: InstSnap.at(0)) - 0.5) < 1e-9)
        #expect(abs(s.glow(at: InstSnap.at(90)) - 0.82) < 1e-6)
        #expect(abs(s.glow(at: InstSnap.at(170)) - 0.74) < 0.03)
        #expect(abs(s.glow(at: InstSnap.at(240)) - 0.3) < 1e-6)
        #expect(s.glow(at: InstSnap.at(661)) == 0)
        // Multi-detent: one detent per 240ms.
        let m = DrumState.changing(from: .iso(800), to: .iso(100), by: .gemini, at: InstSnap.t0)
        #expect(m.segments.count == 6)
        #expect(abs(m.segments[4].start.timeIntervalSince(InstSnap.t0) - 0.48) < 1e-5)
        #expect(abs(m.motionEnd!.timeIntervalSince(InstSnap.t0) - 0.72) < 1e-5)
    }

    @Test func dragFlingSnapsToADetent() {
        var s = DrumState(.ev(0))
        let start = s.target
        s.beginDrag(at: InstSnap.t0)
        s.updateDrag(translation: -44 * 1.4, velocity: -300, spacing: 44)
        #expect(s.nearestIndex == start + 1)
        let to = s.endDrag(velocity: -600, spacing: 44, at: InstSnap.t0)
        #expect(to == start + 4)                     // 1.4 + 13.6 det/s × 0.2 s ≈ 4.1
        #expect(abs(s.position(at: InstSnap.at(2000)) - Double(to)) < 1e-6)
        // Past the end it rubber-bands instead of running off.
        var e = DrumState(.iso(6400))
        e.beginDrag(at: InstSnap.t0)
        e.updateDrag(translation: -46 * 5, velocity: 0, spacing: 46)
        #expect(e.drag!.position < Double(e.strip.count - 1) + 0.6)
    }

    @Test func rulerMapsMetres() {
        let r = RulerState(metres: 1.25)
        #expect(abs(r.metres(atTicks: r.target) - 1.25) < 1e-9)
        #expect(RulerState.ticks(metres: .infinity) == 0)
        #expect(RulerState(metres: 0.05).target == -100)
        #expect(RulerFace.format(1.234) == ["1.2", " m"])
        #expect(RulerFace.format(0.35) == ["0.35", " m"])
        #expect(RulerFace.format(12.4) == ["12", " m"])
        #expect(RulerFace.format(.infinity) == ["\u{221E}", ""])
        let g = RulerState.changing(from: 1.2, to: 3, at: InstSnap.t0)
        #expect(g.glow(at: InstSnap.at(200)) > 0.8)
        #expect(abs(g.metres(atTicks: g.position(at: InstSnap.at(3000))) - 3) < 1e-6)
    }

    @Test func guideDirectionsMapToCues() {
        #expect(EdgeGlow.cue(for: .left) == .move(.left))
        #expect(EdgeGlow.cue(for: .up) == .move(.top))
        #expect(EdgeGlow.cue(for: .closer) == .closer)
        #expect(EdgeGlow.cue(for: .rotateRight) == .roll(clockwise: true))
        #expect(EdgeGlow.cue(for: .hold) == .hold)
        #expect(EdgeGlow.cue(for: nil) == .hold)
    }

    @Test func bundledFontsRegister() {
        _ = InstSnap.fonts
        #expect(GXFont.hasDisplay)
        #expect(GXFont.hasMono)
        let light = GXFont.variableFont(family: GXFont.displayFamily, size: 30, weight: 300, opticalSize: true)!
        let bold = GXFont.variableFont(family: GXFont.displayFamily, size: 30, weight: 700, opticalSize: true)!
        #expect(CTFontGetSize(light) == 30)
        // Weight axis applied: heavier glyphs are wider in Google Sans Flex.
        func width(_ f: CTFont) -> CGFloat {
            let s = NSAttributedString(string: "400", attributes: [NSAttributedString.Key(kCTFontAttributeName as String): f])
            return CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(s), nil, nil, nil))
        }
        #expect(width(bold) > width(light))
    }

    // MARK: Snapshots

    private func drums(_ iso: InstrumentValue, _ ss: InstrumentValue, _ ev: InstrumentValue,
                       seeds: [InstrumentValue.Kind: DrumState] = [:]) -> some View {
        InstrumentDrums(iso: .constant(iso), shutter: .constant(ss), ev: .constant(ev), actor: .gemini, seeds: seeds)
            .frame(width: 393, height: 84)
    }

    @Test func drumSnapshots() {
        #expect(InstSnap.write("drums_rest", width: 393, height: 84) {
            drums(.iso(400), .shutter(1.0 / 125), .ev(0))
        })
        #expect(InstSnap.write("drums_auto", width: 393, height: 84) {
            drums(.iso(320, auto: true), .shutter(1.0 / 60, auto: true), .ev(0.3))
        })
        #expect(InstSnap.write("drums_offladder", width: 393, height: 84) {
            drums(.iso(320), .shutter(1.0 / 100), .ev(-1.3))
        })
        // Gemini: ISO 800 → 400, frame by frame (design: 0 drag, 90 blur, 170 overshoot, 240 settle).
        let roll = DrumState.changing(from: .iso(800), to: .iso(400), by: .gemini, at: InstSnap.t0)
        for ms in [0, 45, 90, 130, 170, 240, 400, 660] {
            #expect(InstSnap.write("drums_gemini_\(String(format: "%03d", ms))ms", width: 393, height: 84, at: InstSnap.at(ms)) {
                drums(.iso(400), .shutter(1.0 / 125), .ev(0), seeds: [.iso: roll])
            })
        }
        // Two detents (800 → 200) and a shutter roll, mid-flight.
        let two = DrumState.changing(from: .iso(800), to: .iso(200), by: .gemini, at: InstSnap.t0)
        let ss = DrumState.changing(from: .shutter(1.0 / 60), to: .shutter(1.0 / 250), by: .gemini, at: InstSnap.t0)
        for ms in [120, 330] {
            #expect(InstSnap.write("drums_gemini_twostep_\(ms)ms", width: 393, height: 84, at: InstSnap.at(ms)) {
                drums(.iso(200), .shutter(1.0 / 250), .ev(0), seeds: [.iso: two, .shutter: ss])
            })
        }
        // Leaving AUTO: metered 320 → Gemini sets 800.
        let auto = DrumState.changing(from: .iso(320, auto: true), to: .iso(800), by: .gemini, at: InstSnap.t0)
        #expect(InstSnap.write("drums_auto_to_800_150ms", width: 393, height: 84, at: InstSnap.at(150)) {
            drums(.iso(800), .shutter(1.0 / 125), .ev(0), seeds: [.iso: auto])
        })
    }

    private func ruler(_ m: Double, seed: RulerState? = nil) -> some View {
        FocusRuler(metres: .constant(m), actor: .gemini, seed: seed).frame(width: 393, height: 44)
    }

    @Test func rulerSnapshots() {
        #expect(InstSnap.write("ruler_rest", width: 393, height: 44) { ruler(1.2) })
        #expect(InstSnap.write("ruler_near", width: 393, height: 44) { ruler(0.35) })
        #expect(InstSnap.write("ruler_infinity", width: 393, height: 44) { ruler(.infinity) })
        let move = RulerState.changing(from: 1.2, to: 0.5, at: InstSnap.t0)
        for ms in [0, 120, 300, 700, 1100] {
            #expect(InstSnap.write("ruler_gemini_\(String(format: "%04d", ms))ms", width: 393, height: 44, at: InstSnap.at(ms)) {
                ruler(0.5, seed: move)
            })
        }
    }

    private func keys(_ s: CoachKeys.Shutter, listening: Bool = false, level: Double = 0) -> some View {
        CoachKeys(shutter: s, listening: listening, level: level).frame(width: 393, height: 124)
    }

    @Test func keySnapshots() {
        #expect(InstSnap.write("keys_idle", width: 393, height: 124) { keys(.idle) })
        #expect(InstSnap.write("keys_ready", width: 393, height: 124) { keys(.ready) })
        #expect(InstSnap.write("keys_listening", width: 393, height: 124, at: InstSnap.at(170)) {
            keys(.idle, listening: true, level: 0.85)
        })
        #expect(InstSnap.write("keys_listening_quiet", width: 393, height: 124, at: InstSnap.at(170)) {
            keys(.idle, listening: true, level: 0.1)
        })
        for p in [0.0, 0.25, 0.62, 1.0] {
            #expect(InstSnap.write("keys_scanning_\(Int(p * 100))", width: 393, height: 124) { keys(.scanning(p)) })
        }
        #expect(InstSnap.write("keys_depthready", width: 393, height: 124) { keys(.depthReady) })
        #expect(InstSnap.write("keys_pressed", width: 393, height: 124) {
            // What the press style does to the shutter: 0.96.
            HStack(spacing: 12) {
                MicKey(listening: false, level: 0).frame(width: 120)
                ShutterKey(shutter: .ready).scaleEffect(0.96)
            }
            .frame(height: 72).padding(.horizontal, 16).frame(width: 393, height: 124)
        })
    }

    private func viewfinder(_ cue: EdgeGlow.Cue, strength: Double = 1, previous: EdgeGlow.Cue? = nil,
                            since: Date = .distantPast) -> some View {
        InstSnap.photo
            .frame(width: 377, height: 584)
            .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
            .overlay(EdgeGlow(cue, strength: strength, cornerRadius: 30, previous: previous ?? cue, changedAt: since))
            .frame(width: 393, height: 600)
    }

    @Test func edgeGlowSnapshots() {
        let void = GXColor.void
        let cases: [(String, EdgeGlow.Cue)] = [
            ("left", .move(.left)), ("right", .move(.right)), ("up", .move(.top)), ("down", .move(.bottom)),
            ("left_up", .move([.left, .top])), ("right_down", .move([.right, .bottom])),
            ("roll_cw", .roll(clockwise: true)), ("closer", .closer), ("back", .back), ("hold", .hold),
        ]
        for (name, cue) in cases {
            #expect(InstSnap.write("edgeglow_\(name)", width: 393, height: 600, at: InstSnap.at(700), background: void) {
                viewfinder(cue)
            })
        }
        #expect(InstSnap.write("edgeglow_left_weak", width: 393, height: 600, at: InstSnap.at(700), background: void) {
            viewfinder(.move(.left), strength: 0.4)
        })
        for ms in [120, 300, 900] {
            #expect(InstSnap.write("edgeglow_aligned_\(ms)ms", width: 393, height: 600, at: InstSnap.at(ms), background: void) {
                viewfinder(.aligned, previous: .move(.left), since: InstSnap.t0)
            })
        }
        // The artboard's small corner swatch (150 × 232, radius 18).
        #expect(InstSnap.write("edgeglow_swatch_left_up", width: 174, height: 256, at: InstSnap.at(700), background: void) {
            InstSnap.photo.frame(width: 150, height: 232)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(EdgeGlow(.move([.left, .top]), strength: 1, cornerRadius: 18))
        })
    }

    @Test func markAndGrainSnapshots() {
        #expect(InstSnap.write("focusmark", width: 133, height: 98) { TapFocusMark() })
        #expect(InstSnap.write("grain", width: 120, height: 98, at: InstSnap.t0, background: GXColor.void) { GrainOverlay() })
        #expect(InstSnap.write("grain_none", width: 120, height: 98, at: InstSnap.t0, background: GXColor.void) { EmptyView() })
    }

    // MARK: Whole panel (compare with the Paper screens a–d)

    private func screen(iso: DrumState? = nil, cue: EdgeGlow.Cue, keys: CoachKeys.Shutter, dim: Bool = false,
                        since: Date = .distantPast) -> some View {
        VStack(spacing: 0) {
            InstSnap.photo
                .frame(width: 377, height: 584)
                .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                .overlay(EdgeGlow(cue, strength: 1, cornerRadius: 30, previous: cue, changedAt: since))
                .padding(8)
                .frame(width: 393, height: 600)
            ZStack(alignment: .top) {
                InstSnap.panel
                VStack(spacing: 0) {
                    Rectangle().fill(GXColor.hairline).frame(height: 1)
                    drums(.iso(400), .shutter(1.0 / 125), .ev(0), seeds: iso.map { [.iso: $0] } ?? [:])
                        .frame(height: 83, alignment: .bottom).clipped()
                    Rectangle().fill(GXColor.hairline).frame(height: 1)
                    ruler(1.2).frame(height: 43)
                    Rectangle().fill(GXColor.hairline).frame(height: 1)
                    Spacer(minLength: 0)
                }
                .opacity(dim ? 0.3 : 1)
                CoachKeys(shutter: keys).frame(height: 124).offset(y: 128)
            }
            .frame(width: 393, height: 252)
        }
    }

    @Test func screenSnapshots() {
        let void = GXColor.void
        #expect(InstSnap.write("screen_a_watching", width: 393, height: 852, background: void) {
            screen(cue: .hold, keys: .idle)
        })
        let roll = DrumState.changing(from: .iso(800), to: .iso(400), by: .gemini, at: InstSnap.t0)
        #expect(InstSnap.write("screen_b_gemini", width: 393, height: 852, at: InstSnap.at(170), background: void) {
            screen(iso: roll, cue: .move(.left), keys: .idle)
        })
        #expect(InstSnap.write("screen_c_aligned", width: 393, height: 852, at: InstSnap.at(300), background: void) {
            screen(cue: .aligned, keys: .ready, since: InstSnap.t0)
        })
        #expect(InstSnap.write("screen_d_depthscan", width: 393, height: 852, background: void) {
            screen(cue: .hold, keys: .scanning(0.62), dim: true)
        })
        #expect(InstSnap.write("screen_e_depthready", width: 393, height: 852, background: void) {
            screen(cue: .hold, keys: .depthReady)
        })
    }
}
#endif
