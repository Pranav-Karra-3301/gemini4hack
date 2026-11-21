import CoachUI
import SwiftUI
import UIKit

/// Full-screen post-shot reveal (#34): photo → scan → depth sweep → the fix. No text.
/// Press and hold shows the original; swipe down dismisses.
struct ShotReveal: View {
    let model: RevealModel
    @State private var sweep: CGFloat = 0
    @State private var depthOpacity: Double = 0
    @State private var holding = false
    @State private var drag: CGFloat = 0

    static let geminiBlue = Color(red: 0.36, green: 0.55, blue: 0.95)

    var body: some View {
        GeometryReader { geo in
            let rect = Self.fit(model.photo?.size, in: geo.size)
            ZStack(alignment: .topLeading) {
                Color(red: 0.035, green: 0.035, blue: 0.04)
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
                    if let w = model.wipe, !holding { WipeLayer(wipe: w, width: rect.width) }
                    if let p = model.pulse { PulseLayer(pulse: p) }
                    if model.phase == .scanning || model.working {
                        ScanLine(height: rect.height)
                    }
                }
                .frame(width: rect.width, height: rect.height)
                .clipped()
                .offset(x: rect.minX, y: rect.minY)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if g.translation.height > 14 { holding = false; drag = g.translation.height } else { holding = true }
                    }
                    .onEnded { g in
                        holding = false
                        if g.translation.height > 110 || g.predictedEndTranslation.height > 260 {
                            withAnimation(.easeOut(duration: 0.22)) { drag = geo.size.height }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { model.dismiss() }
                        } else {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { drag = 0 }
                        }
                    }
            )
            .overlay(alignment: .bottom) {
                VStack(spacing: 14) {
                    EditNotes(model: model)
                    ViewerBar(model: model)
                }
                .padding(.bottom, max(geo.safeAreaInsets.bottom, 12) + 8)
                .background(alignment: .bottom) {
                    if !model.log.isEmpty || model.caption != nil {
                        LinearGradient(colors: [.black.opacity(0), .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                            .frame(height: 300).allowsHitTesting(false)
                    }
                }
            }
            .overlay(alignment: .topLeading) {
                if model.working, let word = model.stageWord {
                    Text(word)
                        .font(GXFont.mono(11))
                        .tracking(11 * 0.12)
                        .foregroundStyle(ShotReveal.geminiBlue.opacity(0.9))
                        .padding(.top, max(geo.safeAreaInsets.top, 12) + 20)
                        .padding(.leading, 20)
                        .transition(.opacity)
                        .id(word)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topTrailing) {
                if let photo = model.photo, let png = model.depthPNG, let show = model.onShow3D {
                    Button { show(photo, png) } label: {
                        Image(systemName: "cube")
                            .font(.system(size: 15, weight: .regular))
                            .foregroundStyle(Color.white.opacity(0.8))
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(Color(white: 0.1).opacity(0.7)))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, max(geo.safeAreaInsets.top, 12) + 8)
                    .padding(.trailing, 16)
                    .accessibilityLabel("3D")
                }
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
            UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.9)
        }
    }

    /// Aspect fit of the photo in the screen.
    static func fit(_ size: CGSize?, in box: CGSize) -> CGRect {
        guard let size, size.width > 0, size.height > 0 else { return CGRect(origin: .zero, size: box) }
        let s = min(box.width / size.width, box.height / size.height)
        let w = size.width * s, h = size.height * s
        return CGRect(x: (box.width - w) / 2, y: (box.height - h) / 2, width: w, height: h)
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

/// Mic (wide red capsule) + "Edit for Me" (yellow pill): same row geometry as CoachKeys (72 pt, 12 gap,
/// 16 side padding, mic 120 wide). Matte fills, no gloss.
private struct ViewerBar: View {
    let model: RevealModel

    var body: some View {
        HStack(spacing: 12) {
            Button { model.onMic?() } label: {
                Capsule(style: .circular)
                    .fill(Color(red: 0.64, green: 0.09, blue: 0.11))
                    .overlay(Image(systemName: "mic.fill").font(.system(size: 22, weight: .regular))
                        .foregroundStyle(Color.white.opacity(0.92)))
            }
            .buttonStyle(.plain)
            .frame(width: 120)
            .accessibilityLabel("Edit by voice")
            Button { model.editForMe() } label: {
                Capsule(style: .circular)
                    .fill(Color(red: 1.0, green: 0.80, blue: 0.30).opacity(model.working ? 0.7 : 1))
                    .overlay(Text("Edit for Me")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(Color(red: 0.08, green: 0.07, blue: 0.05)))
            }
            .buttonStyle(.plain)
            .disabled(model.shotID == nil || model.working)
        }
        .frame(height: 72)
        .padding(.horizontal, 16)
    }
}

/// The previous render on top, cut away left to right over `RevealModel.wipeDuration`, with a thin edge.
private struct WipeLayer: View {
    let wipe: RevealModel.Wipe
    let width: CGFloat

    var body: some View {
        TimelineView(.animation) { ctx in
            let t = min(1, ctx.date.timeIntervalSince(wipe.start) / RevealModel.wipeDuration)
            let e = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
            let x = width * e
            ZStack(alignment: .leading) {
                Image(uiImage: wipe.before).resizable().interpolation(.high)
                    .mask(alignment: .trailing) { Rectangle().frame(width: max(0, width - x)) }
                Rectangle().fill(ShotReveal.geminiBlue.opacity(t < 1 ? 0.7 : 0)).frame(width: 1).offset(x: x)
            }
        }
        .allowsHitTesting(false)
        .id(wipe.id)
    }
}

/// A changed layer's mask, tinted Gemini blue, fading in and out over `RevealModel.pulseDuration`.
private struct PulseLayer: View {
    let pulse: RevealModel.Pulse

    var body: some View {
        TimelineView(.animation) { ctx in
            let t = min(1, ctx.date.timeIntervalSince(pulse.start) / RevealModel.pulseDuration)
            Image(uiImage: pulse.image).resizable().interpolation(.high)
                .opacity(0.5 * sin(.pi * t))
        }
        .allowsHitTesting(false)
        .id(pulse.id)
    }
}

/// Edit for Me, readable without sound: the step's caption, then one line per change (≤5,
/// newest last, older ones fading).
private struct EditNotes: View {
    let model: RevealModel

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let caption = model.caption {
                Text(caption)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.92))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.bottom, 4)
                    .transition(.opacity)
                    .id(caption)
            }
            let n = model.log.count
            ForEach(Array(model.log.enumerated()), id: \.element.id) { i, line in
                Text(line.text)
                    .font(GXFont.mono(12))
                    .foregroundStyle(Color.white.opacity([0.9, 0.62, 0.45, 0.33, 0.25][min(4, n - 1 - i)]))
                    .lineLimit(1)
                    .transition(.asymmetric(insertion: .offset(y: 6).combined(with: .opacity), removal: .opacity))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22)
        .animation(.easeOut(duration: 0.24), value: model.log)
        .animation(.easeOut(duration: 0.24), value: model.caption)
        .allowsHitTesting(false)
    }
}
