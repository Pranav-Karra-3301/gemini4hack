import CoachModels
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO

/// What the camera is doing right now (read from the device via KVO, published ≤10 Hz).
/// Zoom is the *display* zoom (0.5 = ultra-wide, 1 = wide), the number the dial and Gemini use.
struct CameraSnapshot: Equatable, Sendable {
    var iso: Double = 100
    /// Exposure duration in seconds.
    var shutter: Double = 1.0 / 120
    /// Exposure target bias (EV).
    var ev: Double = 0
    /// Lens position 0 (near) … 1 (far).
    var focus: Double = 0.5
    var wbKelvin: Double = 5200
    var tint: Double = 0
    var zoom: Double = 1

    /// Which settings the camera decides (AUTO) vs. the user or coach (manual).
    var isoAuto = true
    var shutterAuto = true
    var focusAuto = true
    var wbAuto = true

    /// Device limits.
    var isoRange: ClosedRange<Double> = 32...3200
    var shutterRange: ClosedRange<Double> = (1.0 / 8000)...1
    var evRange: ClosedRange<Double> = -3...3
    var zoomRange: ClosedRange<Double> = 0.5...10
    /// Display zoom of each available lens (ultrawide 0.5, wide 1, tele 3/5).
    var lenses: [CameraLens: Double] = [.wide: 1]
    /// Closest focus distance of the active lens, metres (AVCaptureDevice.minimumFocusDistance).
    var minFocus: Double = 0.2

    var mode: CaptureMode = .photo
    var flash: FlashMode = .off
    var torch = false
    var hasTorch = false
    var depthAvailable = false

    /// The lens whose field of view the current zoom is closest to (at or above).
    var lens: CameraLens {
        let sorted = lenses.sorted { $0.value < $1.value }
        return sorted.last { $0.value <= zoom + 0.01 }?.key ?? .wide
    }

    /// `[state]` line for Gemini (ticks and reconnects).
    var stateLine: String {
        func f(_ v: Double, _ digits: Int = 1) -> String { String(format: "%.\(digits)f", v) }
        var bits = ["mode \(mode.rawValue)", "lens \(lens.rawValue)", "zoom \(f(zoom))x"]
        bits.append("ISO \(Int(iso.rounded()))\(isoAuto ? " (auto)" : "")")
        bits.append("shutter \(ShutterText.fraction(shutter))\(shutterAuto ? " (auto)" : "")")
        bits.append("EV \(ev >= 0 ? "+" : "")\(f(ev))")
        bits.append(focusAuto ? "focus auto" : "focus \(f(focus, 2))")
        bits.append(wbAuto ? "WB auto (~\(Int(wbKelvin / 100) * 100) K)" : "WB \(Int(wbKelvin)) K tint \(Int(tint))")
        if torch { bits.append("torch on") }
        if flash != .off { bits.append("flash \(flash.rawValue)") }
        return bits.joined(separator: ", ")
    }
}

/// Lens position (0 near … 1 far) ↔ focus distance in metres, for the focus ruler.
/// AVFoundation exposes no calibrated distance, so this is a plausible stand-in: lens travel is
/// roughly linear in dioptres, and position 0 sits at the lens's closest focus distance.
/// Positions within 3% of the far end read as ∞.
enum FocusDistance {
    static let curve = 1.5

    static func metres(lensPosition lp: Double, minFocus: Double) -> Double {
        let far = 1 - min(max(lp, 0), 1)
        guard far > 0.03 else { return .infinity }
        let dioptres = pow(far, curve) / max(minFocus, 0.02)
        return 1 / dioptres
    }

    static func lensPosition(metres m: Double, minFocus: Double) -> Double {
        guard m.isFinite, m > 0 else { return 1 }
        let far = pow(min(max(minFocus, 0.02) / m, 1), 1 / curve)
        return min(max(1 - far, 0), 1)
    }
}

enum ShutterText {
    /// 0.008 → "1/125", 0.5 → "0.5s".
    static func fraction(_ s: Double) -> String {
        guard s > 0 else { return "-" }
        if s >= 0.3 { return String(format: "%.1fs", s) }
        return "1/\(Int((1 / s).rounded()))"
    }
}

/// A captured photo: the camera's own file (HEIF, with embedded depth when the camera has it) for
/// Photos, and a JPEG for Core (the JPEG drops the depth).
struct CapturedPhoto: Sendable {
    var fileData: Data
    var jpeg: Data
    var width: Int
    var height: Int
    var iso: Double?
    var shutter: Double?
    var hasDepth: Bool
    var thumbnail: CGImage?
    /// The photo's depth, upright, as Core's `depth.png` (16-bit mm, 0 = unknown); nil without depth.
    /// Load with `EditRenderer.depthImage(pngData:)`.
    var depthPNG: Data? = nil
}

/// Receives preview frames on the camera's video queue (≈30 fps; the sink throttles to ≤1 fps).
protocol FrameSink: AnyObject, Sendable {
    func offer(pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation)
    func offer(cgImage: CGImage)
}

/// The device side of the camera. All AVFoundation work happens on the engine's own queue;
/// these methods are safe to call from the main actor.
protocol CaptureEngine: AnyObject, Sendable {
    var isMock: Bool { get }
    /// Called (on the main queue, ≤10 Hz) whenever the device's values change.
    var onSnapshot: (@MainActor (CameraSnapshot) -> Void)? { get set }
    var frameSink: FrameSink? { get set }
    func start() async -> Bool
    func stop()
    /// Applies `set_camera` (from the coach or the user's dials) and returns what was applied, clamped.
    func apply(_ settings: CameraSettings) async -> CameraSettings
    /// Tap-to-focus / focus_x,focus_y: `point` is in the upright frame (0…1, origin top-left).
    func focus(at point: CGPoint) async
    func capture() async throws -> CapturedPhoto
    /// Rotation of the device relative to the sensor, for upright frames and photos (degrees).
    func setCaptureRotation(_ degrees: CGFloat)
    /// Live depth for the viewfinder tile: while on, `handler` gets ~15 fps frames on the main
    /// queue. Cameras without streaming depth (mock, non-LiDAR) never call it.
    func setLiveDepth(_ on: Bool, handler: (@MainActor (LiveDepthFrame?) -> Void)?)
}

extension CaptureEngine {
    func setLiveDepth(_ on: Bool, handler: (@MainActor (LiveDepthFrame?) -> Void)?) {}
}

/// One colour-mapped live depth frame (sensor orientation; `orientation` makes it upright) and
/// the median depth of the frame's centre, in metres.
struct LiveDepthFrame: @unchecked Sendable {
    let image: CGImage
    let orientation: CGImagePropertyOrientation
    let subjectMetres: Double?
}

enum CameraError: LocalizedError {
    case unavailable, notAuthorized, captureFailed(String)
    var errorDescription: String? {
        switch self {
        case .unavailable: return "No camera available."
        case .notAuthorized: return "Camera access is off. Turn it on in Settings."
        case .captureFailed(let s): return "Capture failed: \(s)"
        }
    }
}

/// Maps between the upright frame Gemini sees and the sensor's device coordinates.
enum FrameGeometry {
    /// Upright point → AVCaptureDevice point of interest for a given capture rotation.
    static func devicePoint(upright p: CGPoint, rotation degrees: CGFloat) -> CGPoint {
        let x = min(max(p.x, 0), 1), y = min(max(p.y, 0), 1)
        switch Int(degrees.rounded()) % 360 {
        case 90: return CGPoint(x: y, y: 1 - x)
        case 180: return CGPoint(x: 1 - x, y: 1 - y)
        case 270: return CGPoint(x: 1 - y, y: x)
        default: return CGPoint(x: x, y: y)
        }
    }

    /// Orientation that turns a sensor buffer upright, for a capture rotation angle.
    static func orientation(rotation degrees: CGFloat) -> CGImagePropertyOrientation {
        switch Int(degrees.rounded()) % 360 {
        case 90: return .right
        case 180: return .down
        case 270: return .left
        default: return .up
        }
    }
}
