import CoachModels
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A pretend camera for the simulator and DEBUG runs (`-mockCamera YES`): a bundled sample photo
/// stands in for the sensor. It honours `set_camera` like the real engine (same ranges, priority
/// exposure, presets), renders the result (exposure, white balance, zoom crop) for the viewfinder
/// and for Live frames, and "captures" the rendered photo.
final class MockCaptureEngine: CaptureEngine, @unchecked Sendable {
    let isMock = true
    var onSnapshot: (@MainActor (CameraSnapshot) -> Void)?
    /// Rendered viewfinder image (main queue), refreshed when a setting changes.
    var onPreview: (@MainActor (CGImage) -> Void)?
    var frameSink: FrameSink? {
        get { lock.withLock { sink } }
        set { lock.withLock { sink = newValue } }
    }

    private let lock = NSLock()
    private var sink: FrameSink?
    private var state: CameraSnapshot
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "coachcam.mock", qos: .userInitiated)
    private let source: CIImage?
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var tick = 0.0

    init() {
        var s = CameraSnapshot()
        s.isoRange = 32...3200
        s.shutterRange = (1.0 / 8000)...1
        s.zoomRange = 0.5...10
        s.lenses = [.ultrawide: 0.5, .wide: 1, .tele: 4]
        s.iso = 125; s.shutter = 1.0 / 120; s.focus = 0.62; s.wbKelvin = 5600
        s.hasTorch = true
        s.depthAvailable = true
        state = s
        if let url = Bundle.main.url(forResource: "MockSample", withExtension: "jpg") {
            source = CIImage(contentsOf: url, options: [.applyOrientationProperty: true])
        } else {
            source = nil
        }
    }

    func start() async -> Bool {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 0.5)
        t.setEventHandler { [weak self] in self?.meter() }
        t.resume()
        lock.withLock { timer?.cancel(); timer = t }
        publish(render: true)
        return true
    }

    func stop() {
        lock.withLock { timer?.cancel(); timer = nil }
    }

    func setCaptureRotation(_ degrees: CGFloat) {}

    /// Auto values drift a little (like a real meter) and a frame goes to Live.
    private func meter() {
        tick += 0.5
        lock.withLock {
            if state.isoAuto && state.shutterAuto {
                state.iso = (125 + 8 * sin(tick / 3)).rounded()
                state.shutter = 1.0 / 120
            } else if state.shutterAuto {
                state.shutter = Self.clamp((125.0 / 120) / state.iso, state.shutterRange)
            } else if state.isoAuto {
                state.iso = Self.clamp(((125.0 / 120) / state.shutter).rounded(), state.isoRange)
            }
            if state.focusAuto { state.focus = 0.62 + 0.02 * sin(tick / 2) }
            if state.wbAuto { state.wbKelvin = 5600 + 40 * sin(tick / 5) }
        }
        publish(render: false)
        if Int(tick * 2) % 2 == 0, let sink = frameSink, let frame = render(maxSide: 768) {
            sink.offer(cgImage: frame)
        }
    }

    private func publish(render: Bool) {
        let snap = lock.withLock { state }
        let image = render ? self.render(maxSide: 1600) : nil
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.onSnapshot?(snap)
                if let image { self?.onPreview?(image) }
            }
        }
    }

    /// The sample as the "sensor" would see it with the current settings.
    private func render(maxSide: CGFloat) -> CGImage? {
        guard let src = source else { return nil }
        let s = lock.withLock { state }
        var img = src
        // Zoom: 1× shows the whole sample; tele crops the centre.
        let z = max(1, s.zoom)
        if z > 1.01 {
            let e = src.extent
            let w = e.width / z, h = e.height / z
            img = img.cropped(to: CGRect(x: e.midX - w / 2, y: e.midY - h / 2, width: w, height: h))
                .transformed(by: CGAffineTransform(translationX: -(e.midX - w / 2), y: -(e.midY - h / 2)))
        }
        // Exposure relative to what the meter would pick, plus EV.
        let metered = 125.0 / 120
        let ev = log2(max(s.iso * s.shutter, 1e-6) / metered) + (s.isoAuto && s.shutterAuto ? s.ev : 0)
        if abs(ev) > 0.01 { img = img.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: ev]) }
        // White balance: correcting for `wbKelvin` while the scene is ~5600 K daylight.
        if !s.wbAuto || abs(s.tint) > 0.5 {
            img = img.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: s.wbKelvin, y: s.tint),
                "inputTargetNeutral": CIVector(x: 5600, y: 0),
            ])
        }
        let scale = min(1, maxSide / max(img.extent.width, img.extent.height))
        if scale < 1 { img = img.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) }
        return context.createCGImage(img, from: img.extent.integral)
    }

    func apply(_ raw: CameraSettings) async -> CameraSettings {
        await withCheckedContinuation { c in
            queue.async { c.resume(returning: self.applyOnQueue(raw)) }
        }
    }

    private func applyOnQueue(_ raw: CameraSettings) -> CameraSettings {
        var out = CameraSettings(why: raw.why)
        out.ignored = raw.ignored
        lock.lock()
        var s = state
        var r = raw.clamped(iso: s.isoRange, shutter: s.shutterRange, zoom: s.zoomRange)
        if let lens = r.lens, r.zoom == nil { r.zoom = s.lenses[lens] }
        if let m = r.mode {
            let manual = r.iso != nil || r.shutter != nil
            switch m {
            case .photo:
                if !manual { r.iso = .auto; r.shutter = .auto }
                if r.ev == nil, abs(s.ev) > 0.01 { r.ev = 0 }
            case .portrait:
                if r.zoom == nil, r.lens == nil, s.zoom < 1.9 { r.zoom = 2 }
                if !manual { r.iso = .auto; r.shutter = .auto }
                if r.ev == nil, s.ev < 0.3 { r.ev = 0.3 }
            case .night:
                let dur = r.shutter?.number ?? max(s.shutter, 1.0 / 20)
                if r.shutter == nil { r.shutter = .value(dur) }
                if r.iso == nil { r.iso = .value(Self.clamp(s.iso * s.shutter * 1.4 / dur, s.isoRange).rounded()) }
            case .macro:
                if r.zoom == nil, r.lens == nil { r.zoom = 0.5 }
                if r.focus == nil { r.focus = .auto }
            }
            s.mode = m
            out.mode = m
        }
        if let z = r.zoom {
            s.zoom = z
            out.zoom = z
            out.lens = s.lens
        }
        let product = s.iso * s.shutter
        if let iso = r.iso {
            s.isoAuto = iso.isAuto
            if let v = iso.number { s.iso = v.rounded() }
            out.iso = iso.isAuto ? .auto : .value(s.iso)
        }
        if let sh = r.shutter {
            s.shutterAuto = sh.isAuto
            if let v = sh.number { s.shutter = v }
            out.shutter = sh.isAuto ? .auto : .value(s.shutter)
        }
        if !s.isoAuto && s.shutterAuto { s.shutter = Self.clamp(product / s.iso, s.shutterRange) }
        if s.isoAuto && !s.shutterAuto { s.iso = Self.clamp(product / s.shutter, s.isoRange).rounded() }
        if s.isoAuto && s.shutterAuto { s.iso = 125; s.shutter = 1.0 / 120 }
        if let ev = r.ev {
            s.ev = (ev * 10).rounded() / 10
            out.ev = s.ev
            if r.iso == nil, r.shutter == nil, !s.isoAuto, !s.shutterAuto {
                s.isoAuto = true; s.shutterAuto = true; s.iso = 125; s.shutter = 1.0 / 120
                out.iso = .auto; out.shutter = .auto
            }
        }
        if let fx = r.focusX ?? r.focusY.map({ _ in 0.5 }) {
            out.focusX = fx
            out.focusY = r.focusY ?? 0.5
            s.focusAuto = true
            out.focus = .auto
        }
        if let f = r.focus {
            s.focusAuto = f.isAuto
            if let v = f.number { s.focus = v }
            out.focus = f.isAuto ? .auto : .value(s.focus)
        }
        if let k = r.wbKelvin {
            s.wbAuto = k.isAuto
            if let v = k.number { s.wbKelvin = v }
            out.wbKelvin = k.isAuto ? .auto : .value(s.wbKelvin)
        }
        if let t = r.tint {
            s.tint = t
            if r.wbKelvin == nil { s.wbAuto = false }
            out.tint = t
        }
        if let t = r.torch { s.torch = t; out.torch = t }
        if let f = r.flash { s.flash = f; out.flash = f }
        state = s
        lock.unlock()
        publish(render: true)
        return out
    }

    func focus(at point: CGPoint) async {
        lock.withLock { state.focusAuto = true }
        publish(render: false)
    }

    func capture() async throws -> CapturedPhoto {
        try await withCheckedThrowingContinuation { c in
            queue.async {
                guard let cg = self.render(maxSide: 2048) else {
                    c.resume(throwing: CameraError.unavailable)
                    return
                }
                let data = NSMutableData()
                guard let dst = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
                    c.resume(throwing: CameraError.captureFailed("encode"))
                    return
                }
                CGImageDestinationAddImage(dst, cg, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
                CGImageDestinationFinalize(dst)
                guard var shot = PhotoFiles.jpegForUpload(data as Data) else {
                    c.resume(throwing: CameraError.captureFailed("encode"))
                    return
                }
                let s = self.lock.withLock { self.state }
                shot.iso = s.iso
                shot.shutter = s.shutter
                c.resume(returning: shot)
            }
        }
    }

    static func clamp(_ v: Double, _ r: ClosedRange<Double>) -> Double { min(max(v, r.lowerBound), r.upperBound) }
}
