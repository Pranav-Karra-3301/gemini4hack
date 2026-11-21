// Snapshot and logic tests for CoachUI. Snapshots go to /tmp/lc_qa/ui_<component>_<state>.png.
// Gated on COACHUI_TESTS, which Package.swift defines for CoachKitTests (it depends on CoachUI).
#if COACHUI_TESTS && os(macOS)
import AppKit
import CoachModels
@testable import CoachUI
import SwiftUI
import Testing

@MainActor
enum Snap {
    static let dir = URL(fileURLWithPath: "/tmp/lc_qa", isDirectory: true)
    static let t0 = Date()

    /// A viewfinder stand-in: a sample photo under the bottom scrim, or a dark gradient.
    static var viewfinder: some View {
        let url = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("web/public/samples/img-1427.jpg")
        return ZStack {
            if let img = NSImage(contentsOf: url) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(colors: [Color(white: 0.35), Color(white: 0.12)], startPoint: .top, endPoint: .bottom)
            }
            LinearGradient(stops: [.init(color: CoachColor.ink.opacity(0), location: 0),
                                   .init(color: CoachColor.ink.opacity(0.6), location: 0.38),
                                   .init(color: CoachColor.ink.opacity(0.86), location: 1)],
                           startPoint: .top, endPoint: .bottom)
        }
    }

    /// Renders `view` at `date` on `background` and writes `ui_<name>.png` (2x).
    @discardableResult
    static func write<V: View, B: View>(_ name: String, width: CGFloat, height: CGFloat, at date: Date,
                                        background: B, @ViewBuilder _ view: () -> V) -> Bool {
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
        do { try data.write(to: dir.appendingPathComponent("ui_\(name).png")) } catch { return false }
        return true
    }

    static func write<V: View>(_ name: String, width: CGFloat, height: CGFloat, at date: Date,
                               @ViewBuilder _ view: () -> V) -> Bool {
        write(name, width: width, height: height, at: date, background: viewfinder, view)
    }
}

@MainActor
@Suite("CoachUI")
struct CoachUISnapshotTests {
    // MARK: Logic

    @Test func formatsCameraValues() {
        #expect(CameraParameter.iso.format(400) == "ISO 400")
        #expect(CameraParameter.iso.format(63.5) == "ISO 64")
        #expect(CameraParameter.shutter.format(0.004) == "1/250")
        #expect(CameraParameter.shutter.format(0.008) == "1/125")
        #expect(CameraParameter.shutter.format(0.5) == "0.5\u{2033}")
        #expect(CameraParameter.ev.format(0.3) == "+0.3")
        #expect(CameraParameter.ev.format(-0.667) == "\u{2212}0.7")
        #expect(CameraParameter.whiteBalance.format(5200) == "5200K")
        #expect(CameraParameter.zoom.format(1.5) == "1.5\u{00D7}")
        #expect(CameraParameter.zoom.format(2) == "2\u{00D7}")
        #expect(CameraParameter.iso.format(DialSetting.auto(metered: 320)) == "AUTO")
    }

    @Test func detentsRoundTrip() {
        for p in CameraParameter.allCases {
            let r = p.defaultRange
            let lo = Int(ceil(p.position(for: r.lowerBound) - 1e-6)), hi = Int(floor(p.position(for: r.upperBound) + 1e-6))
            #expect(lo < hi, "\(p)")
            for u in lo...hi {
                let v = p.detentValue(at: Double(u))
                #expect(abs(p.position(for: v) - Double(u)) < 0.35, "\(p) unit \(u) -> \(v)")
            }
        }
    }

    @Test func springSettlesAndIsInterruptible() {
        let g = Glide(from: 0, to: 10, start: Snap.t0, spring: .glide, epsilon: 0.02)
        #expect(g.duration > 0.3 && g.duration < 1.0)
        #expect(abs(g.value(at: g.end.addingTimeInterval(0.01)) - 10) < 1e-9)
        #expect(abs(g.value(at: g.end.addingTimeInterval(-0.01)) - 10) < 0.05)
        let mid = g.value(at: Snap.t0.addingTimeInterval(0.15))
        #expect(mid > 0 && mid < 10)
        #expect(g.velocity(at: Snap.t0.addingTimeInterval(0.15)) > 0)
    }

    @Test func choreographyWalksTheStrip() {
        let m = CameraControlsModel(settings: [.iso: .manual(100), .shutter: .manual(1.0 / 60)])
        m.coachApply([.iso: .manual(400), .shutter: .manual(1.0 / 500), .ev: .manual(0.3)],
                     why: "Freeze the kids, keep it bright", at: Snap.t0)
        #expect(m.presentedSelection(at: Snap.t0.addingTimeInterval(0.1)) == .iso)
        #expect(m.presentedSelection(at: Snap.t0.addingTimeInterval(0.8)) == .shutter)
        #expect(m.presentedSelection(at: Snap.t0.addingTimeInterval(1.4)) == .ev)
        #expect(m.presentedSelection(at: Snap.t0.addingTimeInterval(9)) == nil)
        #expect(m.coachAmount(.iso, at: Snap.t0.addingTimeInterval(0.3)) > 0.9)
        #expect(m.coachAmount(.iso, at: Snap.t0.addingTimeInterval(9)) == 0)
        #expect(m.displayedValue(.shutter, at: Snap.t0.addingTimeInterval(5)) == 1.0 / 500)
        // A new event retargets from the value on screen.
        let mid = Snap.t0.addingTimeInterval(0.2)
        let before = m.displayedPosition(.iso, at: mid)
        m.coachApply([.iso: .manual(100)], why: nil, at: mid)
        #expect(abs(m.displayedPosition(.iso, at: mid) - before) < 1e-9)
        // Unstarted steps (shutter, EV) carry over after the new one.
        #expect(m.presentedSelection(at: mid.addingTimeInterval(0.8)) == .shutter)
        #expect(m.displayedValue(.ev, at: mid.addingTimeInterval(6)) == 0.3)
        // Grabbing a dial mid-sequence keeps it open.
        _ = m.beginDrag(.ev, at: mid.addingTimeInterval(0.1))
        #expect(m.presentedSelection(at: mid.addingTimeInterval(0.2)) == .ev)
    }

    // MARK: Snapshots

    @Test func cameraDialSnapshots() {
        let w: CGFloat = 393, h: CGFloat = 150
        func dial(_ m: CameraControlsModel, _ p: CameraParameter) -> some View {
            CameraDial(model: m, parameter: p).padding(.horizontal, 16).frame(width: w)
        }
        let m = CameraControlsModel(settings: [.iso: .manual(400), .shutter: .manual(1.0 / 250), .ev: .manual(0.3),
                                               .whiteBalance: .auto(metered: 5200), .zoom: .manual(1.5),
                                               .focus: .manual(0.42)])
        #expect(Snap.write("dial_iso_manual", width: w, height: h, at: Snap.t0) { dial(m, .iso) })
        #expect(Snap.write("dial_shutter_manual", width: w, height: h, at: Snap.t0) { dial(m, .shutter) })
        #expect(Snap.write("dial_ev_manual", width: w, height: h, at: Snap.t0) { dial(m, .ev) })
        #expect(Snap.write("dial_wb_auto", width: w, height: h, at: Snap.t0) { dial(m, .whiteBalance) })
        #expect(Snap.write("dial_zoom_manual", width: w, height: h, at: Snap.t0) { dial(m, .zoom) })
        #expect(Snap.write("dial_focus_manual", width: w, height: h, at: Snap.t0) { dial(m, .focus) })

        let c = CameraControlsModel(settings: [.shutter: .manual(1.0 / 60)])
        c.coachApply([.shutter: .manual(1.0 / 500)], why: "Freeze the motion", at: Snap.t0)
        for (i, t) in [0.0, 0.12, 0.25, 0.45, 0.9, 2.2].enumerated() {
            #expect(Snap.write("dial_shutter_coach_\(i)_\(Int(t * 1000))ms", width: w, height: h,
                               at: Snap.t0.addingTimeInterval(t)) { dial(c, .shutter) })
        }
    }

    @Test func cameraDialStripSnapshots() {
        let w: CGFloat = 393, h: CGFloat = 330
        func strip(_ m: CameraControlsModel) -> some View {
            VStack { Spacer(); CameraDialStrip(model: m).padding(.horizontal, 12).padding(.bottom, 16) }.frame(width: w, height: h)
        }
        let settings: [CameraParameter: DialSetting] = [.iso: .auto(metered: 125), .shutter: .auto(metered: 1.0 / 120),
                                                        .ev: .manual(0), .focus: .auto(metered: 0.5),
                                                        .whiteBalance: .auto(metered: 5600), .zoom: .manual(1)]
        let a = CameraControlsModel(settings: settings)
        #expect(Snap.write("strip_collapsed", width: w, height: h, at: Snap.t0) { strip(a) })
        a.select(.iso)
        #expect(Snap.write("strip_iso_open", width: w, height: h, at: Snap.t0) { strip(a) })

        let b = CameraControlsModel(settings: settings)
        b.coachApply([.iso: .manual(400), .shutter: .manual(1.0 / 500), .ev: .manual(-0.3)],
                     why: "Freeze the waves, keep the sky", at: Snap.t0)
        for t in [0.15, 0.4, 0.75, 1.0, 1.45, 2.6, 4.0] {
            #expect(Snap.write("strip_coach_\(Int(t * 1000))ms", width: w, height: h,
                               at: Snap.t0.addingTimeInterval(t)) { strip(b) })
        }
    }
    // MARK: Editor

    @Test func sliderLogic() async {
        let m = EditSlidersModel(values: [.exposure: 0.31, .warmth: 12])
        #expect(m.value(.exposure) == 0.3)            // snapped to the 0.05 step
        #expect(m.value(.focusDepth) == nil)          // auto
        let applied = await m.coachStep(EditStep(slider: .contrast, value: 140, why: "More punch"))
        #expect(applied == 100)                       // clamped
        #expect(m.spotlight?.slider == .contrast)
        let fd = SliderSpec.table[.focusDepth]!
        #expect(abs(fd.value(normalized: fd.normalized(2.4)) - 2.4) < 1e-9)
    }

    @Test func editSliderSnapshots() {
        let w: CGFloat = 300
        let bg = CoachColor.graphite
        func row(_ m: EditSlidersModel, _ s: CoachModels.Slider) -> some View {
            EditSliderRow(model: m, slider: s).frame(width: w - 16)
        }
        let m = EditSlidersModel(values: [.exposure: 0.3, .depthBlur: 35, .shadows: -22])
        #expect(Snap.write("slider_default", width: w, height: 64, at: Snap.t0, background: bg) { row(m, .contrast) })
        #expect(Snap.write("slider_bipolar_value", width: w, height: 64, at: Snap.t0, background: bg) { row(m, .exposure) })
        #expect(Snap.write("slider_negative", width: w, height: 64, at: Snap.t0, background: bg) { row(m, .shadows) })
        #expect(Snap.write("slider_unipolar", width: w, height: 64, at: Snap.t0, background: bg) { row(m, .depthBlur) })
        #expect(Snap.write("slider_auto", width: w, height: 64, at: Snap.t0, background: bg) { row(m, .focusDepth) })

        let c = EditSlidersModel(values: [.warmth: -10])
        _ = c.beginCoachStep(EditStep(slider: .warmth, value: 28, why: "Bring back the sunset color"),
                             index: 2, of: 5, at: Snap.t0)
        for t in [0.0, 0.1, 0.22, 0.4, 0.8, 1.6, 4.5] {
            #expect(Snap.write("slider_coach_\(Int(t * 1000))ms", width: w, height: 96, at: Snap.t0.addingTimeInterval(t),
                               background: bg) { row(c, .warmth) })
        }
    }

    @Test func editPanelSnapshots() {
        let w: CGFloat = 320, h: CGFloat = 1060
        let bg = CoachColor.ink
        let idle = EditSlidersModel(values: [.exposure: 0.3, .contrast: 12, .warmth: 15, .depthBlur: 35])
        #expect(Snap.write("panel_idle", width: w, height: h, at: Snap.t0, background: bg) {
            EditSliderPanel(model: idle).frame(width: w, height: h)
        })
        let g = EditSlidersModel()
        let steps = [EditStep(slider: .exposure, value: 0.3, why: "Lift the underexposed faces"),
                     EditStep(slider: .highlights, value: -35, why: "Keep detail in the bright sky")]
        let t1 = Snap.t0.addingTimeInterval(-2)
        _ = g.beginCoachStep(steps[0], index: 1, of: 4, at: t1)
        g.setBannerForTesting("Warm it up and let the group glow")
        _ = g.beginCoachStep(steps[1], index: 2, of: 4, at: Snap.t0)
        for t in [0.18, 1.0] {
            #expect(Snap.write("panel_guided_step2_\(Int(t * 1000))ms", width: w, height: h,
                               at: Snap.t0.addingTimeInterval(t), background: bg) {
                EditSliderPanel(model: g).frame(width: w, height: h)
            })
        }
    }

    // MARK: Guide arrow and shutter

    @Test func guideArrowSnapshots() {
        let w: CGFloat = 393, h: CGFloat = 560
        let cases: [(GuideDirection, GuideStrength)] = [(.left, .medium), (.right, .large), (.up, .medium), (.down, .small),
                                                        (.closer, .medium), (.back, .medium), (.rotateLeft, .medium),
                                                        (.rotateRight, .medium), (.hold, .medium)]
        for (d, s) in cases {
            #expect(Snap.write("arrow_\(d.rawValue)", width: w, height: h, at: Snap.t0.addingTimeInterval(0.3)) {
                GuideArrow(d, strength: s, subject: CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4))
                    .frame(width: w, height: h)
            })
        }
    }

    @Test func shutterSnapshots() {
        for (name, state) in [("idle", ShutterState.idle), ("ready", .ready), ("busy", .busy), ("disabled", .disabled)] {
            #expect(Snap.write("shutter_\(name)", width: 160, height: 160, at: Snap.t0.addingTimeInterval(0.4)) {
                ShutterButton(state: state) {}
            })
        }
    }
}
#endif
