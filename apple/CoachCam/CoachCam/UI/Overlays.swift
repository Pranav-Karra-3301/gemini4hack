import CoachModels
import CoachUI
import SwiftUI

/// Top and bottom scrims so the HUD reads over any scene (DESIGN.md §4.1: 0–150 and 500–852).
struct Scrims: View {
    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [CoachColor.ink.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 150)
            Spacer(minLength: 0)
            LinearGradient(colors: [.clear, CoachColor.ink.opacity(0.62)], startPoint: .top, endPoint: .bottom)
                .frame(height: 380)
        }
    }
}

/// Four glowing corner arcs when the coach says the shot is ready.
struct ReadyBrackets: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathe = false

    var body: some View {
        Canvas { ctx, size in
            let l: CGFloat = 36, r: CGFloat = 12
            var p = Path()
            let w = size.width, h = size.height
            // top-left
            p.move(to: CGPoint(x: 0, y: l)); p.addLine(to: CGPoint(x: 0, y: r))
            p.addQuadCurve(to: CGPoint(x: r, y: 0), control: .zero); p.addLine(to: CGPoint(x: l, y: 0))
            // top-right
            p.move(to: CGPoint(x: w - l, y: 0)); p.addLine(to: CGPoint(x: w - r, y: 0))
            p.addQuadCurve(to: CGPoint(x: w, y: r), control: CGPoint(x: w, y: 0)); p.addLine(to: CGPoint(x: w, y: l))
            // bottom-right
            p.move(to: CGPoint(x: w, y: h - l)); p.addLine(to: CGPoint(x: w, y: h - r))
            p.addQuadCurve(to: CGPoint(x: w - r, y: h), control: CGPoint(x: w, y: h)); p.addLine(to: CGPoint(x: w - l, y: h))
            // bottom-left
            p.move(to: CGPoint(x: l, y: h)); p.addLine(to: CGPoint(x: r, y: h))
            p.addQuadCurve(to: CGPoint(x: 0, y: h - r), control: CGPoint(x: 0, y: h)); p.addLine(to: CGPoint(x: 0, y: h - l))
            ctx.stroke(p, with: .color(CoachColor.safelight), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
        }
        .shadow(color: CoachColor.safelight.opacity(breathe ? 0.75 : 0.45), radius: breathe ? 12 : 7)
        .allowsHitTesting(false)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { breathe = true }
        }
        .accessibilityLabel("Shot ready")
    }
}

/// A brief wash over the frame when the coach hears the user react (pleased = warm, disappointed = dim).
struct ReactionWash: View {
    let reaction: UserReaction?
    let id: Int
    @State private var opacity = 0.0

    var body: some View {
        RadialGradient(colors: [color.opacity(0.0), color.opacity(0.55)], center: .center, startRadius: 120, endRadius: 520)
            .opacity(opacity)
            .allowsHitTesting(false)
            .onChange(of: id) { _, _ in
                guard reaction != nil, reaction != .neutral else { return }
                opacity = 0.9
                withAnimation(CoachEase.out(0.9)) { opacity = 0 }
            }
    }

    private var color: Color { reaction == .pleased ? CoachColor.safelight : CoachColor.ink }
}

/// The viewfinder dips on each capture.
struct ShutterBlink: View {
    let count: Int
    @State private var opacity = 0.0

    var body: some View {
        Color.black
            .opacity(opacity)
            .allowsHitTesting(false)
            .onChange(of: count) { _, _ in
                opacity = 0.85
                withAnimation(.easeOut(duration: 0.22)) { opacity = 0 }
            }
    }
}

/// Tap-to-focus square.
struct FocusMark: View {
    @State private var shown = true
    @State private var scale = 1.25

    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .stroke(CoachColor.safelight, lineWidth: 1.5)
            .frame(width: 72, height: 72)
            .scaleEffect(scale)
            .opacity(shown ? 1 : 0)
            .onAppear {
                withAnimation(CoachEase.out(CoachDuration.base)) { scale = 1 }
                withAnimation(.easeIn(duration: 0.3).delay(1.1)) { shown = false }
            }
    }
}

struct CameraDeniedNote: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "camera.fill").font(.system(size: 30))
            Text("Camera access is off")
                .font(CoachFont.sans(20, weight: .semibold))
            Text("Turn it on in Settings to shoot with the coach.")
                .font(CoachFont.sans(15))
                .foregroundStyle(CoachColor.paper62)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            .font(CoachFont.sans(16, weight: .semibold))
            .foregroundStyle(CoachColor.ink)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Capsule().fill(CoachColor.safelightGradient))
        }
        .foregroundStyle(CoachColor.paper)
        .multilineTextAlignment(.center)
        .padding(32)
    }
}
