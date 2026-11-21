import AVFoundation
import CoachModels
import Foundation
import Observation

/// Main-actor face of the camera: owns the engine (real or mock), publishes the live values the
/// dials show, and serialises changes so a burst of dial detents lands in order.
@MainActor
@Observable
final class CameraController {
    @ObservationIgnored let engine: any CaptureEngine
    /// What the device is doing now (≤10 Hz).
    private(set) var snapshot = CameraSnapshot()
    /// Mock camera only: the rendered "sensor" image.
    private(set) var mockFrame: CGImage?
    private(set) var isRunning = false
    private(set) var denied = false
    /// Called after every snapshot update (AppModel feeds the AUTO dials from it).
    @ObservationIgnored var onSnapshot: ((CameraSnapshot) -> Void)?

    @ObservationIgnored private var pendingUser = CameraSettings()
    @ObservationIgnored private var userApplyRunning = false

    init(mock: Bool) {
        if mock {
            let m = MockCaptureEngine()
            engine = m
            m.onPreview = { [weak self] img in self?.mockFrame = img }
        } else {
            engine = AVCaptureEngine()
        }
        engine.onSnapshot = { [weak self] snap in
            guard let self else { return }
            if snap != self.snapshot { self.snapshot = snap }
            self.onSnapshot?(snap)
        }
    }

    var isMock: Bool { engine.isMock }
    var avSession: AVCaptureSession? { (engine as? AVCaptureEngine)?.session }
    var avDevice: AVCaptureDevice? { (engine as? AVCaptureEngine)?.device }

    func start() async {
        guard !isRunning else { return }
        isRunning = await engine.start()
        denied = !isRunning && !isMock && AVCaptureDevice.authorizationStatus(for: .video) == .denied
    }

    func stop() {
        engine.stop()
        isRunning = false
    }

    /// Applies a coach `set_camera` and returns the clamped values the hardware took.
    func apply(_ settings: CameraSettings) async -> CameraSettings {
        await engine.apply(settings)
    }

    /// User changes (dial detents, pinch, mode taps): merged and applied one batch at a time.
    func applyUser(_ change: CameraSettings) {
        pendingUser.merge(change)
        guard !userApplyRunning else { return }
        userApplyRunning = true
        Task {
            while !pendingUser.isEmpty {
                let batch = pendingUser
                pendingUser = CameraSettings()
                _ = await engine.apply(batch)
            }
            userApplyRunning = false
        }
    }

    func focus(atUpright point: CGPoint) {
        Task { await engine.focus(at: point) }
    }

    func capture() async throws -> CapturedPhoto {
        try await engine.capture()
    }

    func setCaptureRotation(_ degrees: CGFloat) {
        engine.setCaptureRotation(degrees)
    }
}

extension CameraSettings {
    /// Later values win; used to coalesce user changes.
    mutating func merge(_ o: CameraSettings) {
        if let v = o.mode { mode = v }
        if let v = o.lens { lens = v }
        if let v = o.zoom { zoom = v }
        if let v = o.iso { iso = v }
        if let v = o.shutter { shutter = v }
        if let v = o.ev { ev = v }
        if let v = o.focus { focus = v }
        if let v = o.focusX { focusX = v }
        if let v = o.focusY { focusY = v }
        if let v = o.wbKelvin { wbKelvin = v }
        if let v = o.tint { tint = v }
        if let v = o.flash { flash = v }
        if let v = o.torch { torch = v }
    }
}
