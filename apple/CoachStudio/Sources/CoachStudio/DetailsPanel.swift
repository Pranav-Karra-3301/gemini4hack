import AppKit
import CoreImage
import SwiftUI
import CoachModels
import CoachUI

/// Left panel: how the photo was taken, how Decision-1 scored it, what the coach said, the depth
/// map, the pipeline stages, and the 3D view.
struct DetailsPanel: View {
    let model: EditorModel
    var open3D: () -> Void
    @State private var depthPreview: NSImage?

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 22) {
                capture
                scores
                notes
                depthCard
                stages
            }
            .padding(16)
        }
        .scrollIndicators(.never)
        .background(CoachColor.graphite.opacity(0.55))
        .task(id: model.depth == nil) {
            guard let d = model.depth else { return }
            let meta = model.shot?.assets.depth.meta
            depthPreview = await Task.detached(priority: .utility) { DepthPreview.make(d, meta: meta) }.value
            if let dir = StudioAutomation.snapshotDir, let img = depthPreview, let tiff = img.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appendingPathComponent("depth_preview.png"))
            }
        }
    }

    // MARK: Capture

    private var capture: some View {
        let m = model.shot?.meta
        let rows: [(String, String?)] = [
            ("Device", m?.device), ("Source", m?.source), ("Lens", lensText(m)), ("Mode", m?.mode),
            ("ISO", m?.iso.map { String(Int($0.rounded())) }), ("Shutter", m?.shutter.map(shutterText)),
            ("EV", m?.ev.map { String(format: "%+.1f", $0) }), ("White bal.", m?.wbKelvin.map { "\(Int($0)) K" }),
            ("Tint", m?.tint.map { String(format: "%+.0f", $0) }), ("Focus", m?.focus.map { String(format: "%.2f", $0) }),
            ("Intent", [m?.intent, m?.subject].compactMap { $0 }.joined(separator: " · ").nilIfEmpty),
            ("Taken", (m?.takenDate ?? model.shot?.createdDate)?.formatted(date: .abbreviated, time: .shortened)),
            ("Size", model.shot.flatMap { s in s.width.map { "\($0) × \(s.height ?? 0)" } }),
        ]
        return Section(title: "Capture") {
            let shown = rows.filter { $0.1 != nil }
            if shown.isEmpty {
                Text("No capture settings (imported photo).").font(CoachFont.sans(12)).foregroundStyle(CoachColor.paper45)
            }
            ForEach(shown, id: \.0) { row in
                HStack(alignment: .firstTextBaseline) {
                    Text(row.0.uppercased()).font(CoachFont.mono(10)).tracking(1).foregroundStyle(CoachColor.paper45)
                    Spacer(minLength: 12)
                    Text(row.1 ?? "").font(CoachFont.mono(12)).foregroundStyle(CoachColor.paper)
                        .lineLimit(2).multilineTextAlignment(.trailing)
                }
            }
        }
    }

    private func lensText(_ m: ShotMeta?) -> String? {
        guard let m else { return nil }
        let parts = [m.lens, m.zoom.map { String(format: "%.1f×", $0) }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func shutterText(_ s: Double) -> String {
        s >= 0.5 ? String(format: "%.1f s", s) : "1/\(Int((1 / s).rounded()))"
    }

    // MARK: Scores

    private var scores: some View {
        Section(title: "Scores", trailing: model.score?.provider) {
            if let report = model.score {
                ForEach(report.scores.keys.sorted(), id: \.self) { key in
                    if let s = report.scores[key] { ScoreRow(name: key, score: s) }
                }
                if let ms = report.ms { Caption("\(Int(ms)) ms") }
            } else {
                StageHint(status: model.shot?.assets.score.status, what: "Scoring")
            }
        }
    }

    // MARK: Notes

    private var notes: some View {
        Section(title: "Coach's notes", trailing: model.regionsModel) {
            let coach = model.shot?.meta?.coach ?? []
            ForEach(Array(coach.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle().fill(CoachColor.safelight).frame(width: 5, height: 5).offset(y: -2)
                    Text(line).font(CoachFont.sans(13)).foregroundStyle(CoachColor.paper)
                }
            }
            ForEach(model.regions) { r in
                Button {
                    model.selectedRegion = model.selectedRegion == r.id ? nil : r.id
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(r.id.uppercased())
                            .font(CoachFont.mono(10, weight: .semibold))
                            .foregroundStyle(r.isRemove ? CoachColor.signal : CoachColor.safelight)
                            .frame(width: 22, alignment: .leading)
                        Text(r.note).font(CoachFont.sans(12.5)).foregroundStyle(CoachColor.paper62)
                            .multilineTextAlignment(.leading)
                    }
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(model.selectedRegion == r.id ? CoachColor.paper.opacity(0.07) : .clear))
                }
                .buttonStyle(.plain)
            }
            if coach.isEmpty && model.regions.isEmpty {
                StageHint(status: model.shot?.assets.regions.status, what: "Finding regions")
            }
        }
    }

    // MARK: Depth

    private var depthCard: some View {
        Section(title: "Depth", trailing: depthTrailing) {
            if let img = depthPreview {
                Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                HStack {
                    Caption("near")
                    Rectangle().fill(LinearGradient(colors: [CoachColor.safelightHot, CoachColor.safelight, CoachColor.ink],
                                                    startPoint: .leading, endPoint: .trailing))
                        .frame(height: 4).clipShape(Capsule())
                    Caption("far")
                }
            } else {
                StageHint(status: model.shot?.assets.depth.status, what: "Depth Pro")
            }
            HStack(spacing: 8) {
                let splat = model.shot?.assets.splat.status ?? .none
                Button(action: open3D) { Label("Open 3D", systemImage: "cube.transparent") }
                    .buttonStyle(StudioButtonStyle(kind: .quiet))
                if splat == .none || splat == .error {
                    Button { Task { await model.requestSplat() } } label: { Text("Make splat") }
                        .buttonStyle(StudioButtonStyle(kind: .quiet))
                        .help("SHARP on Core (~7 s, ~9 GB)")
                } else {
                    Caption(splat == .done ? "splat ready" : "splat \(splat.rawValue)…")
                }
            }
            .padding(.top, 4)
        }
    }

    private var depthTrailing: String? {
        guard let m = model.shot?.assets.depth.meta, let a = m.p02, let b = m.p98 else { return nil }
        return String(format: "%.1f–%.0f m", a, min(b, 999))
    }

    // MARK: Stages

    private var stages: some View {
        Section(title: "Pipeline") {
            if let a = model.shot?.assets {
                let list: [(String, ShotAsset)] = [("depth", a.depth), ("score", a.score), ("regions", a.regions),
                                                   ("masks", a.masks), ("suggest", a.suggest), ("splat", a.splat)]
                ForEach(list, id: \.0) { name, asset in
                    HStack {
                        StatusDot(status: asset.status)
                        Text(name.uppercased()).font(CoachFont.mono(10.5)).tracking(1).foregroundStyle(CoachColor.paper62)
                        Spacer()
                        Text(asset.ms.map { "\(Int($0)) ms" } ?? asset.status.rawValue)
                            .font(CoachFont.mono(10.5)).foregroundStyle(CoachColor.paper45)
                    }
                    .help(asset.error ?? asset.model ?? "")
                }
            }
        }
    }
}

// MARK: - Pieces

private struct Section<Content: View>: View {
    let title: String
    var trailing: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text(title.uppercased())
                    .font(CoachFont.mono(10.5)).tracking(CoachFont.labelTracking(10.5))
                    .foregroundStyle(CoachColor.paper55)
                Spacer()
                if let trailing { Text(trailing).font(CoachFont.mono(9.5)).foregroundStyle(CoachColor.paper45).lineLimit(1) }
            }
            content
        }
    }
}

private struct Caption: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(CoachFont.mono(10)).foregroundStyle(CoachColor.paper45) }
}

private struct StageHint: View {
    let status: AssetStatus?
    let what: String
    var body: some View {
        HStack(spacing: 8) {
            StatusDot(status: status ?? .none)
            Text(status?.isInProgress == true ? "\(what)…" : (status == .error ? "\(what) failed" : "Not yet"))
                .font(CoachFont.sans(12)).foregroundStyle(CoachColor.paper45)
        }
    }
}

struct StatusDot: View {
    let status: AssetStatus
    @State private var pulse = false
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .opacity(status == .running ? (pulse ? 1 : 0.35) : 1)
            .onAppear { startPulse() }
            .onChange(of: status) { _, _ in startPulse() }
    }

    private func startPulse() {
        guard status == .running, !pulse else { return }
        withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { pulse = true }
    }
    private var color: Color {
        switch status {
        case .done: return CoachColor.paper
        case .running: return CoachColor.safelight
        case .pending: return CoachColor.paper.opacity(0.3)
        case .error: return CoachColor.signal
        case .none: return CoachColor.paper.opacity(0.12)
        }
    }
}

/// One Decision-1 score: value, label and the 1–5 probability bars.
private struct ScoreRow: View {
    let name: String
    let score: Score
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(name.capitalized).font(CoachFont.sans(13, weight: .semibold)).foregroundStyle(CoachColor.paper)
                Spacer()
                Text(String(format: "%.2f", score.score)).font(CoachFont.mono(15, weight: .semibold)).foregroundStyle(CoachColor.safelight)
                Text("/ \(Int(score.scale.last ?? 5))").font(CoachFont.mono(10)).foregroundStyle(CoachColor.paper45)
            }
            if !score.label.isEmpty {
                Text(score.label).font(CoachFont.sans(12)).foregroundStyle(CoachColor.paper62).lineLimit(2)
            }
            let bins = score.bins
            let peak = bins.map(\.p).max() ?? 1
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(bins, id: \.bucket) { b in
                    VStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(b.bucket == Int(score.score.rounded()) ? CoachColor.safelight : CoachColor.paper.opacity(0.28))
                            .frame(height: max(2, 34 * b.p / max(peak, 0.001)))
                        Text("\(b.bucket)").font(CoachFont.mono(9)).foregroundStyle(CoachColor.paper45)
                    }
                    .frame(maxWidth: .infinity)
                    .help(String(format: "p(%d) = %.2f", b.bucket, b.p))
                }
            }
            .frame(height: 50)
        }
    }
}

/// False-color depth (inverse depth, near = bright amber, far = ink) from Core's `depth.png`.
enum DepthPreview {
    static func make(_ depth: CIImage, meta: DepthMeta?) -> NSImage? {
        let ctx = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        let e = depth.extent.integral
        let w = Int(e.width), h = Int(e.height)
        guard w > 0, h > 0 else { return nil }
        var buf = [Float](repeating: 0, count: w * h)
        buf.withUnsafeMutableBytes { p in
            ctx.render(depth, toBitmap: p.baseAddress!, rowBytes: w * 4, bounds: e, format: .Rf, colorSpace: nil)
        }
        // values are mm / 65535
        let near = max(0.2, meta?.p02 ?? 0.5), far = min(max(near * 2, meta?.p98 ?? 20), 60)
        let inN = 1 / near, inF = 1 / far
        var rgba = [UInt8](repeating: 255, count: w * h * 4)
        let ink: (Float, Float, Float) = (8, 8, 10), amber: (Float, Float, Float) = (255, 165, 61), hot: (Float, Float, Float) = (255, 222, 170)
        for i in 0..<(w * h) {
            let m = buf[i] * 65.535  // meters
            var t: Float = 0
            if m > 0 { t = Float(min(1, max(0, (1 / Double(m) - inF) / (inN - inF)))) }
            t = powf(t, 0.75)
            let c: (Float, Float, Float)
            if t < 0.7 {
                let k = t / 0.7
                c = (ink.0 + (amber.0 - ink.0) * k, ink.1 + (amber.1 - ink.1) * k, ink.2 + (amber.2 - ink.2) * k)
            } else {
                let k = (t - 0.7) / 0.3
                c = (amber.0 + (hot.0 - amber.0) * k, amber.1 + (hot.1 - amber.1) * k, amber.2 + (hot.2 - amber.2) * k)
            }
            let o = i * 4  // CIContext bitmaps are top row first, like CGImage
            rgba[o] = UInt8(c.0); rgba[o + 1] = UInt8(c.1); rgba[o + 2] = UInt8(c.2)
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: w, height: h))
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
