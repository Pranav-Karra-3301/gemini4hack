import CoachUI
import SwiftUI
import UIKit

/// The shot viewer: the photo (depth sweep when it has depth), a few faders under it and the
/// key row (hold the mic to talk an edit, or Edit for Me). Near-zero text: the fader names only.
/// Press and hold the photo for the original; swipe it down to close.
struct ShotReveal: View {
    let model: RevealModel
    let voice: VoiceEdit
    @State private var sweep: CGFloat = 0
    @State private var depthOpacity: Double = 0
    @State private var holding = false
    @State private var drag: CGFloat = 0

    static let geminiBlue = Color(red: 0.36, green: 0.55, blue: 0.95)

    var body: some View {
        GeometryReader { geo in
            let top = max(geo.safeAreaInsets.top, 12)
            let bottom = max(geo.safeAreaInsets.bottom, 12) + 8
            VStack(spacing: 0) {
                GeometryReader { box in
                    let rect = Self.fit(model.photo?.size, in: box.size)
                    photo(rect: rect)
                        .frame(width: rect.width, height: rect.height)
                        .clipped()
                        .offset(x: rect.minX, y: rect.minY)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .contentShape(Rectangle())
                        .gesture(photoGesture(height: geo.size.height))
                }
                .padding(.top, top + 52)
                .padding(.horizontal, 12)
                .padding(.bottom, 12)

                Faders(model: model)
                    .padding(.horizontal, 22)
                    .padding(.bottom, 16)
                    .opacity(model.phase == .fix ? 1 : 0.3)
                    .allowsHitTesting(model.phase == .fix)
                ViewerBar(model: model, voice: voice)
                    .padding(.bottom, bottom)
            }
            .background(Color(red: 0.035, green: 0.035, blue: 0.04))
            .overlay(alignment: .top) {
                HStack {
                    RoundKey(symbol: "chevron.down", label: "Close") { model.dismiss() }
                    Spacer()
                    if let photo = model.photo, let png = model.depthPNG, let show = model.onShow3D {
                        RoundKey(symbol: "cube", label: "3D") { show(photo, png) }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, top + 4)
            }
            .offset(y: max(0, drag))
            .opacity(1 - Double(min(max(drag, 0) / 600, 0.5)))
        }
        .ignoresSafeArea()
        .statusBarHidden()
        .onChange(of: model.depthSerial) { _, _ in
            sweep = 0
            depthOpacity = 1
            UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.7)
            withAnimation(.easeInOut(duration: 0.8)) { sweep = 1 }
        }
        .onChange(of: model.phase) { _, p in
            if p == .fix { withAnimation(.easeInOut(duration: 0.6)) { depthOpacity = 0 } }
        }
        .onChange(of: model.fixSerial) { _, _ in
            UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.6)
        }
        .onDisappear { voice.cancel() }
    }

    @ViewBuilder
    private func photo(rect: CGRect) -> some View {
        ZStack {
            if let photo = model.photo {
                Image(uiImage: photo).resizable().interpolation(.high)
            }
            if let edited = model.edited {
                Image(uiImage: edited).resizable().interpolation(.high)
                    .opacity(holding ? 0 : 1)
                    .animation(.easeOut(duration: 0.18), value: holding)
            }
            if let map = model.depthMap {
                Image(uiImage: map).resizable().interpolation(.high)
                    .mask(alignment: .top) {
                        LinearGradient(stops: [.init(color: .black, location: 0.92), .init(color: .clear, location: 1)],
                                       startPoint: .top, endPoint: .bottom)
                            .frame(height: rect.height * sweep * 1.08)
                            .frame(maxHeight: .infinity, alignment: .top)
                    }
                    .opacity(depthOpacity)
            }
            if model.phase == .scanning || model.working {
                ScanLine(height: rect.height)
            }
        }
    }

    /// Hold: the original. Drag down: close.
    private func photoGesture(height: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                if g.translation.height > 14 { holding = false; drag = g.translation.height } else { holding = true }
            }
            .onEnded { g in
                holding = false
                if g.translation.height > 110 || g.predictedEndTranslation.height > 260 {
                    withAnimation(.easeOut(duration: 0.22)) { drag = height }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        model.dismiss()
                        drag = 0
                    }
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { drag = 0 }
                }
            }
    }

    /// Aspect fit of the photo in the box.
    static func fit(_ size: CGSize?, in box: CGSize) -> CGRect {
        guard let size, size.width > 0, size.height > 0 else { return CGRect(origin: .zero, size: box) }
        let s = min(box.width / size.width, box.height / size.height)
        let w = size.width * s, h = size.height * s
        return CGRect(x: (box.width - w) / 2, y: (box.height - h) / 2, width: w, height: h)
    }
}

/// The faders, one per row (drag anywhere on a row; double-tap resets it). Gemini's moves glide
/// them one after another, each lit from inside while it moves.
private struct Faders: View {
    let model: RevealModel

    var body: some View {
        VStack(spacing: 10) {
            ForEach(RevealModel.faders, id: \.self) { s in
                if s != .depthBlur || model.depthPNG != nil {
                    EditSliderRow(model: model.sliders, slider: s)
                }
            }
        }
    }
}

/// A thin matte line sweeping slowly top to bottom, with a faint trail above it.
private struct ScanLine: View {
    let height: CGFloat
    @State private var t0 = Date()

    var body: some View {
        TimelineView(.animation) { ctx in
            let period = 2.6
            let p = ctx.date.timeIntervalSince(t0).truncatingRemainder(dividingBy: period) / period
            let e = p * p * (3 - 2 * p)
            let y = height * e
            ZStack(alignment: .top) {
                LinearGradient(colors: [ShotReveal.geminiBlue.opacity(0), ShotReveal.geminiBlue.opacity(0.10)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 90)
                    .offset(y: y - 90)
                Rectangle()
                    .fill(ShotReveal.geminiBlue.opacity(0.55))
                    .frame(height: 1)
                    .offset(y: y)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .opacity(min(1, min(p, 1 - p) * 8))
        }
        .allowsHitTesting(false)
    }
}

/// Mic (wide red capsule, hold to talk) + "Edit for Me" (yellow pill): the camera's key row
/// geometry (72 pt, 12 gap, 16 side padding, mic 120 wide). Matte fills; the mic glows from inside
/// with your voice while you hold it.
private struct ViewerBar: View {
    let model: RevealModel
    let voice: VoiceEdit
    @State private var pressed = false

    var body: some View {
        HStack(spacing: 12) {
            Capsule(style: .circular)
                .fill(Color(red: 0.64, green: 0.09, blue: 0.11))
                .overlay {
                    Capsule(style: .circular)
                        .fill(RadialGradient(colors: [Color(red: 1, green: 0.38, blue: 0.34).opacity(0.85), .clear],
                                             center: .center, startRadius: 0, endRadius: 70))
                        .opacity(voice.isListening ? 0.35 + 0.65 * voice.level : 0)
                        .animation(.easeOut(duration: 0.12), value: voice.level)
                }
                .overlay(Image(systemName: "mic.fill").font(.system(size: 22, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.92)))
                .scaleEffect(pressed ? 0.96 : 1)
                .animation(.spring(response: 0.22, dampingFraction: 0.7), value: pressed)
                .frame(width: 120)
                .contentShape(Capsule())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            guard !pressed else { return }
                            pressed = true
                            UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.8)
                            voice.begin()
                        }
                        .onEnded { _ in
                            pressed = false
                            voice.end()
                        }
                )
                .accessibilityLabel("Hold to say an edit")
                .accessibilityAddTraits(.isButton)
            Button { model.editForMe() } label: {
                Capsule(style: .circular)
                    .fill(Color(red: 1.0, green: 0.80, blue: 0.30).opacity(model.working ? 0.7 : 1))
                    .overlay(Text("Edit for Me")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(Color(red: 0.08, green: 0.07, blue: 0.05)))
            }
            .buttonStyle(KeyPressStyle())
            .disabled(model.working || model.phase != .fix)
        }
        .frame(height: 72)
        .padding(.horizontal, 16)
    }
}
