import AppKit
import CoreImage
import SwiftUI
import CoachModels
import CoachUI

/// Argon's regions over the photo: boxes with id chips (toggle), and the highlighted region's
/// SAM mask washed in amber (the coach's current step, `select_region`, or a click).
struct RegionOverlay: View {
    let model: EditorModel
    let fit: CGRect

    var body: some View {
        let hl = model.highlightedRegion
        ZStack(alignment: .topLeading) {
            if let hl, let wash = model.maskWash(hl) {
                MaskWash(image: wash)
                    .frame(width: fit.width, height: fit.height)
                    .offset(x: fit.minX, y: fit.minY)
                    .transition(.opacity)
                    .id(hl)
            }
            if model.showRegions || hl != nil {
                ForEach(model.regions) { r in
                    if model.showRegions || r.id == hl {
                        RegionBox(region: r, fit: fit, highlighted: r.id == hl,
                                  isSubject: r.id == model.subject, color: color(for: r))
                            .onTapGesture {
                                model.selectedRegion = model.selectedRegion == r.id ? nil : r.id
                            }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(CoachEase.out(CoachDuration.slow), value: hl)
        .animation(CoachEase.out(CoachDuration.base), value: model.showRegions)
        .allowsHitTesting(model.showRegions)
    }

    private func color(for r: Region?) -> Color {
        guard let r else { return CoachColor.safelight }
        return r.isRemove ? CoachColor.signal : CoachColor.safelight
    }
}

/// A region's mask as a colored wash with a bright rim (pre-tinted once per region by
/// `MaskWash.make`), breathing slowly while highlighted.
struct MaskWash: View {
    let image: NSImage
    @State private var pulse = false

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .opacity(pulse ? 1 : 0.62)
            .allowsHitTesting(false)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { pulse = true }
            }
    }

    private static let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])

    /// Mask PNG (8-bit gray, 255 = inside) → premultiplied RGBA: `color` at 30 % inside, opaque rim.
    static func make(maskPNG: Data, color: NSColor) -> NSImage? {
        guard let mask = CIImage(data: maskPNG, options: [.colorSpace: NSNull()]) else { return nil }
        let e = mask.extent
        let rgb = color.usingColorSpace(.sRGB) ?? color
        let solid = CIImage(color: CIColor(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent))
            .cropped(to: e)
        let clear = CIImage.empty().cropped(to: e)
        let side = max(e.width, e.height)
        let radius = max(2, side / 420)
        let rim = mask.applyingFilter("CIMorphologyGradient", parameters: ["inputRadius": radius])
        let fillAlpha = mask.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.3, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0.3, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0.3, w: 0),
        ])
        let fill = solid.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: clear, kCIInputMaskImageKey: fillAlpha])
        let edge = solid.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: clear, kCIInputMaskImageKey: rim])
        let out = edge.composited(over: fill).cropped(to: e)
        guard let cg = context.createCGImage(out, from: e, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: e.width, height: e.height))
    }
}

private struct RegionBox: View {
    let region: Region
    let fit: CGRect
    let highlighted: Bool
    let isSubject: Bool
    let color: Color

    var body: some View {
        let b = region.box
        let rect = CGRect(x: fit.minX + b.x * fit.width, y: fit.minY + b.y * fit.height,
                          width: b.w * fit.width, height: b.h * fit.height)
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(color.opacity(highlighted ? 0.95 : 0.55),
                              style: StrokeStyle(lineWidth: highlighted ? 2 : 1, dash: region.isRemove ? [5, 4] : []))
            HStack(spacing: 5) {
                Text(region.id.uppercased())
                    .font(CoachFont.mono(10, weight: .semibold))
                    .tracking(CoachFont.labelTracking(10))
                if isSubject {
                    Text("SUBJECT").font(CoachFont.mono(9)).tracking(CoachFont.labelTracking(9)).opacity(0.75)
                } else if region.isRemove {
                    Text("DISTRACTION").font(CoachFont.mono(9)).tracking(CoachFont.labelTracking(9)).opacity(0.75)
                }
            }
            .foregroundStyle(CoachColor.ink)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(highlighted ? 1 : 0.8)))
            .offset(x: 6, y: 6)
        }
        .frame(width: max(rect.width, 1), height: max(rect.height, 1))
        .contentShape(Rectangle())
        .offset(x: rect.minX, y: rect.minY)
        .help(region.note)
    }
}
