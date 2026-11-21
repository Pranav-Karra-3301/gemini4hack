import AVFoundation
import CoachModels
import CoreImage
import ImageIO
import QuartzCore
import UniformTypeIdentifiers

/// The real camera: one `AVCaptureSession` on the back camera (the LiDAR depth camera when the
/// iPhone has one, else the wide lens), a photo output (HEIF, depth with every photo when the
/// camera has it) and a video data output that feeds Live frames. `apply` drives the hardware for
/// `set_camera` and the user's dials.
///
/// Threading: every device/session call runs on `queue`. KVO on the device marks the snapshot
/// dirty; it is read and published on the main queue at most every 100 ms.
final class AVCaptureEngine: NSObject, CaptureEngine, @unchecked Sendable {
    let isMock = false
    let session = AVCaptureSession()
    /// The camera in use (for the preview's rotation coordinator). Set once during configuration.
    private(set) var device: AVCaptureDevice?

    var onSnapshot: (@MainActor (CameraSnapshot) -> Void)?
    var frameSink: FrameSink? {
        get { lock.withLock { sink } }
        set { lock.withLock { sink = newValue } }
    }

    private let queue = DispatchQueue(label: "coachcam.camera", qos: .userInitiated)
    private let videoQueue = DispatchQueue(label: "coachcam.camera.video", qos: .userInitiated)
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private var configured = false
    private var observations: [NSKeyValueObservation] = []
    private var inFlight: [Int64: PhotoCaptureDelegate] = [:]
    /// Display zoom of each lens, computed once from the virtual device's switch-over factors.
    private var lensZooms: [CameraLens: Double] = [.wide: 1]

    /// Shared with KVO callbacks and the video queue.
    private let lock = NSLock()
    private var sink: FrameSink?
    private var rotation: CGFloat = 90
    private var publishPending = false
    private var lastPriorityStep: CFTimeInterval = 0
    /// Logical exposure state: nil = the camera decides. One manual + one auto = priority mode
    /// (the auto one follows the meter via `exposureTargetOffset`).
    private var isoManual: Double?
    private var shutterManual: Double?
    private var mode: CaptureMode = .photo
    private var flash: FlashMode = .off

    // MARK: Lifecycle

    func start() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else { return false }
        default: return false
        }
        return await withCheckedContinuation { c in
            queue.async {
                if !self.configured { self.configured = self.configure() }
                guard self.configured else { c.resume(returning: false); return }
                if !self.session.isRunning { self.session.startRunning() }
                self.markDirty()
                c.resume(returning: self.session.isRunning)
            }
        }
    }

    func stop() {
        queue.async { if self.session.isRunning { self.session.stopRunning() } }
    }

    func setCaptureRotation(_ degrees: CGFloat) {
        lock.withLock { rotation = degrees }
    }

    /// The physical wide camera: virtual multi-lens devices refuse custom exposure and manual lens
    /// position (`setExposureModeCustom` throws "Unsupported" on an iPhone 15 Pro's triple camera),
    /// and the coach's ISO / shutter / focus changes are the point. Zoom is digital on that lens.
    /// First choice: the LiDAR depth camera (that same wide lens + LiDAR, no lens switching), when
    /// it takes those manual controls, so every photo carries dense metric depth.
    private static func bestBackCamera() -> AVCaptureDevice? {
        if let lidar = AVCaptureDevice.default(.builtInLiDARDepthCamera, for: .video, position: .back),
           lidar.isExposureModeSupported(.custom), lidar.isLockingFocusWithCustomLensPositionSupported,
           lidar.isLockingWhiteBalanceWithCustomDeviceGainsSupported,
           lidar.formats.contains(where: { !$0.supportedDepthDataFormats.isEmpty }) {
            return lidar
        }
        let types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .builtInTripleCamera,
                                                   .builtInDualWideCamera, .builtInDualCamera]
        let found = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .back).devices
        for t in types { if let d = found.first(where: { $0.deviceType == t }) { return d } }
        return nil
    }

    private func configure() -> Bool {
        guard let device = Self.bestBackCamera(),
              let input = try? AVCaptureDeviceInput(device: device) else { return false }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        // Video only: the Live coach owns the audio session (`.playAndRecord`); capture must
        // never reconfigure it.
        session.automaticallyConfiguresApplicationAudioSession = false
        session.sessionPreset = .photo
        guard session.canAddInput(input), session.canAddOutput(photoOutput) else { return false }
        session.addInput(input)
        session.addOutput(photoOutput)
        if session.canAddOutput(videoOutput) {
            videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String:
                                            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
            session.addOutput(videoOutput)
        }
        Self.selectDepthFormat(device)
        // Photos: Core keeps originals up to 4032 px, so skip 48 MP (faster capture, smaller upload).
        let dims = device.activeFormat.supportedMaxPhotoDimensions
        if let best = dims.filter({ max($0.width, $0.height) <= 4032 }).max(by: { $0.width * $0.height < $1.width * $1.height })
            ?? dims.first {
            photoOutput.maxPhotoDimensions = best
        }
        photoOutput.maxPhotoQualityPrioritization = .balanced
        if photoOutput.isDepthDataDeliverySupported { photoOutput.isDepthDataDeliveryEnabled = true }
        if photoOutput.isResponsiveCaptureSupported { photoOutput.isResponsiveCaptureEnabled = true }

        self.device = device
        lensZooms = Self.lensZooms(device)
        if (try? device.lockForConfiguration()) != nil {
            if device.isLowLightBoostSupported { device.automaticallyEnablesLowLightBoostWhenAvailable = true }
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            // Start at 1× (the wide lens) on multi-lens devices, like the system camera.
            if let wide = lensZooms[.wide] {
                let f = Self.clamp(wide / Double(device.displayVideoZoomFactorMultiplier),
                                   Double(device.minAvailableVideoZoomFactor)...Double(device.maxAvailableVideoZoomFactor))
                device.videoZoomFactor = CGFloat(depthSafeZoom(f, device).factor)
            }
            device.unlockForConfiguration()
        }
        observe(device)
        return true
    }

    /// Depth-capable devices (LiDAR / dual): keep the preset's format when it carries depth, else
    /// take the depth format with the largest photo ≤ 4032 px (continuous zoom with depth, 4:3 and
    /// unbinned preferred). Then the densest depth map, metric `DepthFloat32` first.
    private static func selectDepthFormat(_ d: AVCaptureDevice) {
        guard d.formats.contains(where: { !$0.supportedDepthDataFormats.isEmpty }),
              (try? d.lockForConfiguration()) != nil else { return }
        defer { d.unlockForConfiguration() }
        if d.activeFormat.supportedDepthDataFormats.isEmpty {
            func score(_ f: AVCaptureDevice.Format) -> (Int, Int, Int, Int, Int) {
                let photo = f.supportedMaxPhotoDimensions.filter { max($0.width, $0.height) <= 4032 }
                    .map { Int($0.width) * Int($0.height) }.max() ?? 0
                let continuous = f.supportedVideoZoomRangesForDepthDataDelivery.contains { $0.lowerBound < $0.upperBound }
                let v = f.formatDescription.dimensions
                let fourThree = Int(v.width) * 3 == Int(v.height) * 4
                return (photo, continuous ? 1 : 0, fourThree ? 1 : 0, f.isVideoBinned ? 0 : 1, Int(v.width) * Int(v.height))
            }
            if let best = d.formats.filter({ !$0.supportedDepthDataFormats.isEmpty }).max(by: { score($0) < score($1) }) {
                d.activeFormat = best
            }
        }
        let rank: [OSType: Int] = [kCVPixelFormatType_DepthFloat32: 3, kCVPixelFormatType_DepthFloat16: 2,
                                   kCVPixelFormatType_DisparityFloat32: 1]
        func depthScore(_ f: AVCaptureDevice.Format) -> (Int, Int) {
            let dims = f.formatDescription.dimensions
            return (rank[f.formatDescription.mediaSubType.rawValue] ?? 0, Int(dims.width) * Int(dims.height))
        }
        if let depth = d.activeFormat.supportedDepthDataFormats.max(by: { depthScore($0) < depthScore($1) }) {
            d.activeDepthDataFormat = depth
        }
    }

    /// With depth on, a virtual device may accept only certain zoom factors (discrete depth ranges
    /// throw on any other value): snap to the nearest and set it without a ramp. Continuous ranges
    /// accept any zoom; outside them the photo just has no depth.
    private func depthSafeZoom(_ f: Double, _ d: AVCaptureDevice) -> (factor: Double, ramp: Bool) {
        guard photoOutput.isDepthDataDeliveryEnabled else { return (f, true) }
        let ranges = d.activeFormat.supportedVideoZoomRangesForDepthDataDelivery
        guard !ranges.isEmpty, !ranges.contains(where: { $0.lowerBound < $0.upperBound }) else { return (f, true) }
        if ranges.contains(where: { abs(Double($0.lowerBound) - f) < 0.001 }) { return (f, false) }
        let snapped = ranges.map { Double($0.lowerBound) }.min { abs($0 - f) < abs($1 - f) } ?? f
        return (snapped, false)
    }

    /// Display zoom per lens: constituent devices are ordered widest first, and the virtual
    /// device switches at `virtualDeviceSwitchOverVideoZoomFactors`.
    private static func lensZooms(_ d: AVCaptureDevice) -> [CameraLens: Double] {
        let mult = Double(d.displayVideoZoomFactorMultiplier)
        guard d.isVirtualDevice else { return [.wide: 1] }
        let factors = [1.0] + d.virtualDeviceSwitchOverVideoZoomFactors.map(\.doubleValue)
        var out: [CameraLens: Double] = [:]
        for (i, c) in d.constituentDevices.enumerated() where i < factors.count {
            let z = (factors[i] * mult * 10).rounded() / 10
            switch c.deviceType {
            case .builtInUltraWideCamera: out[.ultrawide] = z
            case .builtInWideAngleCamera: out[.wide] = z
            case .builtInTelephotoCamera: out[.tele] = z
            default: break
            }
        }
        return out.isEmpty ? [.wide: 1] : out
    }

    // MARK: Live values (KVO → snapshot)

    private func observe(_ d: AVCaptureDevice) {
        let dirty: (AVCaptureDevice) -> Void = { [weak self] _ in self?.markDirty() }
        observations = [
            d.observe(\.iso) { dev, _ in dirty(dev) },
            d.observe(\.exposureDuration) { dev, _ in dirty(dev) },
            d.observe(\.exposureTargetBias) { dev, _ in dirty(dev) },
            d.observe(\.lensPosition) { dev, _ in dirty(dev) },
            d.observe(\.deviceWhiteBalanceGains) { dev, _ in dirty(dev) },
            d.observe(\.videoZoomFactor) { dev, _ in dirty(dev) },
            d.observe(\.focusMode) { dev, _ in dirty(dev) },
            d.observe(\.whiteBalanceMode) { dev, _ in dirty(dev) },
            d.observe(\.torchMode) { dev, _ in dirty(dev) },
            d.observe(\.exposureTargetOffset) { [weak self] _, _ in self?.exposureOffsetChanged() },
        ]
    }

    /// Coalesces KVO bursts (each fires at the frame rate) into one main-queue publish per 100 ms.
    private func markDirty() {
        let schedule = lock.withLock { () -> Bool in
            if publishPending { return false }
            publishPending = true
            return true
        }
        guard schedule else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.publishPending = false }
            let snap = self.snapshot()
            MainActor.assumeIsolated { self.onSnapshot?(snap) }
        }
    }

    private func snapshot() -> CameraSnapshot {
        var s = CameraSnapshot()
        guard let d = device else { return s }
        let mult = Double(d.displayVideoZoomFactorMultiplier)
        let fmt = d.activeFormat
        s.iso = Double(d.iso)
        s.shutter = d.exposureDuration.seconds
        s.ev = Double(d.exposureTargetBias)
        s.focus = Double(d.lensPosition)
        let tt = d.temperatureAndTintValues(for: d.deviceWhiteBalanceGains)
        s.wbKelvin = Double(tt.temperature)
        s.tint = Double(tt.tint)
        s.zoom = Double(d.videoZoomFactor) * mult
        s.focusAuto = d.focusMode != .locked
        s.wbAuto = d.whiteBalanceMode != .locked
        s.isoRange = Double(fmt.minISO)...Double(fmt.maxISO)
        s.shutterRange = fmt.minExposureDuration.seconds...min(fmt.maxExposureDuration.seconds, 1)
        s.evRange = max(Double(d.minExposureTargetBias), -3)...min(Double(d.maxExposureTargetBias), 3)
        s.zoomRange = displayZoomRange(d)
        s.lenses = lensZooms
        // Virtual devices can report the ultra-wide's macro distance (2 cm); keep it to a main-lens range.
        if d.minimumFocusDistance > 0 { s.minFocus = min(max(Double(d.minimumFocusDistance) / 1000, 0.12), 0.5) }
        s.hasTorch = d.hasTorch
        s.torch = d.torchMode == .on
        s.depthAvailable = photoOutput.isDepthDataDeliveryEnabled
        lock.withLock {
            s.isoAuto = isoManual == nil
            s.shutterAuto = shutterManual == nil
            s.mode = mode
            s.flash = flash
        }
        return s
    }

    private func displayZoomRange(_ d: AVCaptureDevice) -> ClosedRange<Double> {
        let mult = Double(d.displayVideoZoomFactorMultiplier)
        let lo = Double(d.minAvailableVideoZoomFactor) * mult
        let hi = min(Double(d.maxAvailableVideoZoomFactor) * mult, CameraSettings.Limits.zoom.upperBound)
        return lo...max(lo, hi)
    }

    // MARK: Priority exposure (one of ISO / shutter manual, the other follows the meter)

    private func exposureOffsetChanged() {
        let go = lock.withLock { () -> Bool in
            guard (isoManual == nil) != (shutterManual == nil) else { return false }
            let now = CACurrentMediaTime()
            guard now - lastPriorityStep > 0.2 else { return false }
            lastPriorityStep = now
            return true
        }
        if go { queue.async { self.priorityStep() } }
    }

    private func priorityStep() {
        guard let d = device, d.exposureMode == .custom else { return }
        let offset = Double(d.exposureTargetOffset)       // EV; negative = darker than the target
        guard abs(offset) > 0.12, offset.isFinite else { return }
        let gain = pow(2, -offset * 0.7)                   // damped so it settles without hunting
        let fmt = d.activeFormat
        let (isoM, shM) = lock.withLock { (isoManual, shutterManual) }
        var iso = Double(d.iso), dur = d.exposureDuration.seconds
        if let isoM {
            iso = isoM
            dur = Self.clamp(dur * gain, fmt.minExposureDuration.seconds...min(fmt.maxExposureDuration.seconds, 1))
        } else if let shM {
            dur = shM
            iso = Self.clamp(iso * gain, Double(fmt.minISO)...Double(fmt.maxISO))
        } else { return }
        guard (try? d.lockForConfiguration()) != nil else { return }
        d.setExposureModeCustom(duration: CMTime(seconds: dur, preferredTimescale: 1_000_000), iso: Float(iso))
        d.unlockForConfiguration()
    }

    // MARK: Apply (set_camera / user dials)

    func apply(_ settings: CameraSettings) async -> CameraSettings {
        await withCheckedContinuation { c in
            queue.async { c.resume(returning: self.applyOnQueue(settings)) }
        }
    }

    private func applyOnQueue(_ raw: CameraSettings) -> CameraSettings {
        var out = CameraSettings(why: raw.why)
        out.ignored = raw.ignored
        guard let d = device else {
            out.ignored.append("camera unavailable")
            return out
        }
        let fmt = d.activeFormat
        let mult = Double(d.displayVideoZoomFactorMultiplier)
        let isoR = Double(fmt.minISO)...Double(fmt.maxISO)
        let shR = fmt.minExposureDuration.seconds...min(fmt.maxExposureDuration.seconds, 1)
        let zoomR = displayZoomRange(d)
        var r = raw.clamped(iso: isoR, shutter: shR, zoom: zoomR)

        if let lens = r.lens, r.zoom == nil {
            if let z = lensZooms[lens] { r.zoom = Self.clamp(z, zoomR) }
            else { out.ignored.append("lens \(lens.rawValue) (not on this iPhone)") }
        }
        var restriction: AVCaptureDevice.AutoFocusRangeRestriction?
        if let m = r.mode {
            restriction = preset(m, &r, d, isoR: isoR, shR: shR, zoomR: zoomR)
            lock.withLock { mode = m }
            out.mode = m
        }

        guard (try? d.lockForConfiguration()) != nil else {
            out.ignored.append("camera busy")
            return out
        }
        defer { d.unlockForConfiguration() }

        if let z = r.zoom {
            let safe = depthSafeZoom(Self.clamp(z / mult, Double(d.minAvailableVideoZoomFactor)...Double(d.maxAvailableVideoZoomFactor)), d)
            let f = safe.factor
            if safe.ramp { d.ramp(toVideoZoomFactor: CGFloat(f), withRate: 10) } else { d.videoZoomFactor = CGFloat(f) }
            let shown = (f * mult * 100).rounded() / 100
            out.zoom = shown
            out.lens = lensZooms.sorted { $0.value < $1.value }.last { $0.value <= shown + 0.01 }?.key ?? .wide
        }
        applyExposure(r, d, isoR: isoR, shR: shR, out: &out)
        if let ev = r.ev {
            let b = Self.clamp(ev, Double(d.minExposureTargetBias)...Double(d.maxExposureTargetBias))
            d.setExposureTargetBias(Float(b))
            out.ev = (b * 10).rounded() / 10
        }
        applyFocus(r, d, restriction: restriction, out: &out)
        applyWhiteBalance(r, d, out: &out)
        if let t = r.torch {
            if d.hasTorch, d.isTorchModeSupported(t ? .on : .off) {
                d.torchMode = t ? .on : .off
                out.torch = t
            } else {
                out.ignored.append("torch (no torch)")
            }
        }
        if let f = r.flash {
            let m: AVCaptureDevice.FlashMode = f == .on ? .on : (f == .auto ? .auto : .off)
            if photoOutput.supportedFlashModes.contains(m) {
                lock.withLock { flash = f }
                out.flash = f
            } else {
                out.ignored.append("flash \(f.rawValue)")
            }
        }
        markDirty()
        return out
    }

    /// Fills in what a capture mode implies, without overriding anything this call set explicitly.
    private func preset(_ m: CaptureMode, _ r: inout CameraSettings, _ d: AVCaptureDevice,
                        isoR: ClosedRange<Double>, shR: ClosedRange<Double>,
                        zoomR: ClosedRange<Double>) -> AVCaptureDevice.AutoFocusRangeRestriction {
        let mult = Double(d.displayVideoZoomFactorMultiplier)
        let curZoom = Double(d.videoZoomFactor) * mult
        let manualExposure = r.iso != nil || r.shutter != nil
        switch m {
        case .photo:
            if !manualExposure { r.iso = .auto; r.shutter = .auto }
            if r.ev == nil, abs(d.exposureTargetBias) > 0.01 { r.ev = 0 }
            return .none
        case .portrait:
            // ~2× (48 mm) flatters faces; the coach can still pass its own zoom or lens.
            if r.zoom == nil, r.lens == nil, curZoom < 1.9 { r.zoom = Self.clamp(2, zoomR) }
            if !manualExposure { r.iso = .auto; r.shutter = .auto }
            if r.ev == nil, d.exposureTargetBias < 0.3 { r.ev = 0.3 }
            if r.focus == nil, r.focusX == nil { r.focus = .auto }
            return .none
        case .night:
            let curISO = Double(d.iso), curDur = d.exposureDuration.seconds
            let dur = r.shutter?.number ?? Self.clamp(max(curDur, 1.0 / 20), shR)
            if r.shutter == nil { r.shutter = .value(dur) }
            // About +0.5 EV over what the meter had, mostly from the slower shutter.
            if r.iso == nil { r.iso = .value(Self.clamp(curISO * curDur * 1.4 / dur, isoR).rounded()) }
            return .none
        case .macro:
            if r.zoom == nil, r.lens == nil, let uw = lensZooms[.ultrawide] { r.zoom = Self.clamp(uw, zoomR) }
            if r.focus == nil, r.focusX == nil { r.focus = .auto }
            return .near
        }
    }

    private func applyExposure(_ r: CameraSettings, _ d: AVCaptureDevice, isoR: ClosedRange<Double>,
                               shR: ClosedRange<Double>, out: inout CameraSettings) {
        var touched = false
        lock.withLock {
            if let iso = r.iso { isoManual = iso.number; touched = true }
            if let sh = r.shutter { shutterManual = sh.number; touched = true }
            // EV alone while fully manual: hand exposure back to the camera so the change is visible.
            if r.ev != nil, r.iso == nil, r.shutter == nil, isoManual != nil, shutterManual != nil {
                isoManual = nil; shutterManual = nil; touched = true
                out.iso = .auto; out.shutter = .auto
            }
        }
        guard touched else { return }
        guard d.isExposureModeSupported(.custom) else {
            lock.withLock { isoManual = nil; shutterManual = nil }
            if r.iso?.number != nil { out.ignored.append("iso (manual exposure unsupported)") }
            if r.shutter?.number != nil { out.ignored.append("shutter (manual exposure unsupported)") }
            return
        }
        let (isoM, shM) = lock.withLock { (isoManual, shutterManual) }
        let product = Double(d.iso) * d.exposureDuration.seconds   // what the meter has now (ISO·s)
        func custom(_ dur: Double, _ iso: Double) {
            d.setExposureModeCustom(duration: CMTime(seconds: dur, preferredTimescale: 1_000_000), iso: Float(iso))
        }
        switch (isoM, shM) {
        case (nil, nil):
            if d.isExposureModeSupported(.continuousAutoExposure) { d.exposureMode = .continuousAutoExposure }
            if r.iso != nil { out.iso = .auto }
            if r.shutter != nil { out.shutter = .auto }
        case let (iso?, dur?):
            custom(dur, iso)
            out.iso = .value(iso.rounded())
            out.shutter = .value(dur)
        case let (iso?, nil):
            // ISO priority: the shutter keeps the current brightness, then follows the meter.
            custom(Self.clamp(product / iso, shR), iso)
            out.iso = .value(iso.rounded())
            if r.shutter != nil { out.shutter = .auto }
        case let (nil, dur?):
            // Shutter priority: ISO keeps the brightness.
            custom(dur, Self.clamp(product / dur, isoR))
            out.shutter = .value(dur)
            if r.iso != nil { out.iso = .auto }
        }
    }

    private func applyFocus(_ r: CameraSettings, _ d: AVCaptureDevice,
                            restriction: AVCaptureDevice.AutoFocusRangeRestriction?, out: inout CameraSettings) {
        if let restriction, d.isAutoFocusRangeRestrictionSupported { d.autoFocusRangeRestriction = restriction }
        if r.focusX != nil || r.focusY != nil {
            let upright = CGPoint(x: r.focusX ?? 0.5, y: r.focusY ?? 0.5)
            let p = FrameGeometry.devicePoint(upright: upright, rotation: lock.withLock { rotation })
            setPointOfInterest(p, d)
            out.focusX = r.focusX
            out.focusY = r.focusY
            if r.focus == nil { out.focus = .auto }
        }
        switch r.focus {
        case .auto?:
            if d.isFocusModeSupported(.continuousAutoFocus) { d.focusMode = .continuousAutoFocus }
            out.focus = .auto
        case .value(let v)?:
            if d.isLockingFocusWithCustomLensPositionSupported {
                d.setFocusModeLocked(lensPosition: Float(v))
                out.focus = .value((v * 100).rounded() / 100)
            } else {
                out.ignored.append("focus (manual focus unsupported)")
            }
        case nil:
            break
        }
    }

    private func setPointOfInterest(_ p: CGPoint, _ d: AVCaptureDevice) {
        if d.isFocusPointOfInterestSupported {
            d.focusPointOfInterest = p
            if d.isFocusModeSupported(.continuousAutoFocus) { d.focusMode = .continuousAutoFocus }
        }
        if d.isExposurePointOfInterestSupported, d.exposureMode != .custom {
            d.exposurePointOfInterest = p
            d.exposureMode = .continuousAutoExposure
        }
    }

    private func applyWhiteBalance(_ r: CameraSettings, _ d: AVCaptureDevice, out: inout CameraSettings) {
        guard r.wbKelvin != nil || r.tint != nil else { return }
        if r.wbKelvin == .auto {
            if d.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                d.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            out.wbKelvin = .auto
            return
        }
        guard d.isLockingWhiteBalanceWithCustomDeviceGainsSupported else {
            out.ignored.append("wb_kelvin (unsupported)")
            return
        }
        let cur = d.temperatureAndTintValues(for: d.deviceWhiteBalanceGains)
        let k = r.wbKelvin?.number ?? Double(cur.temperature)
        let t = r.tint ?? (d.whiteBalanceMode == .locked ? Double(cur.tint) : 0)
        var g = d.deviceWhiteBalanceGains(for: .init(temperature: Float(k), tint: Float(t)))
        let maxGain = d.maxWhiteBalanceGain
        g.redGain = min(max(g.redGain, 1), maxGain)
        g.greenGain = min(max(g.greenGain, 1), maxGain)
        g.blueGain = min(max(g.blueGain, 1), maxGain)
        d.setWhiteBalanceModeLocked(with: g)
        let actual = d.temperatureAndTintValues(for: g)
        out.wbKelvin = .value((Double(actual.temperature) / 10).rounded() * 10)
        out.tint = Double(actual.tint).rounded()
    }

    func focus(at point: CGPoint) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async {
                defer { c.resume() }
                guard let d = self.device, (try? d.lockForConfiguration()) != nil else { return }
                let p = FrameGeometry.devicePoint(upright: point, rotation: self.lock.withLock { self.rotation })
                self.setPointOfInterest(p, d)
                d.unlockForConfiguration()
            }
        }
    }

    // MARK: Capture

    func capture() async throws -> CapturedPhoto {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                guard self.configured, self.session.isRunning else {
                    cont.resume(throwing: CameraError.unavailable)
                    return
                }
                let out = self.photoOutput
                let settings = out.availablePhotoCodecTypes.contains(.hevc)
                    ? AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
                    : AVCapturePhotoSettings()
                settings.maxPhotoDimensions = out.maxPhotoDimensions
                settings.photoQualityPrioritization = .balanced
                let (flash, rot) = self.lock.withLock { (self.flash, self.rotation) }
                // Depth with every photo, in every mode, whenever this zoom can deliver it
                // (LiDAR: metric; dual camera: relative; ultrawide / macro: none).
                if out.isDepthDataDeliveryEnabled, let d = self.device {
                    let ranges = d.activeFormat.supportedVideoZoomRangesForDepthDataDelivery
                    if ranges.isEmpty || ranges.contains(where: { $0.contains(d.videoZoomFactor) }) {
                        settings.isDepthDataDeliveryEnabled = true
                        settings.embedsDepthDataInPhoto = true
                    }
                }
                let fm: AVCaptureDevice.FlashMode = flash == .on ? .on : (flash == .auto ? .auto : .off)
                if out.supportedFlashModes.contains(fm) { settings.flashMode = fm }
                if let c = out.connection(with: .video), c.isVideoRotationAngleSupported(rot) {
                    c.videoRotationAngle = rot
                }
                let id = settings.uniqueID
                let delegate = PhotoCaptureDelegate { result in
                    self.queue.async { self.inFlight[id] = nil }
                    cont.resume(with: result)
                }
                self.inFlight[id] = delegate
                out.capturePhoto(with: settings, delegate: delegate)
            }
        }
    }

    static func clamp(_ v: Double, _ r: ClosedRange<Double>) -> Double { min(max(v, r.lowerBound), r.upperBound) }
}

extension AVCaptureEngine: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let sink = frameSink, let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // Buffers stay sensor-native (landscape); the sink rotates only the frames it sends.
        sink.offer(pixelBuffer: pb, orientation: FrameGeometry.orientation(rotation: lock.withLock { rotation }))
    }
}

/// One in-flight photo: collects the processed photo, then converts it once capture finishes.
private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private let done: (Result<CapturedPhoto, Error>) -> Void
    private var photo: AVCapturePhoto?
    private var error: Error?

    init(done: @escaping (Result<CapturedPhoto, Error>) -> Void) { self.done = done }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        self.photo = photo
        self.error = error
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: Error?) {
        if let e = error ?? self.error {
            done(.failure(CameraError.captureFailed(e.localizedDescription)))
            return
        }
        guard let photo, let data = photo.fileDataRepresentation() else {
            done(.failure(CameraError.captureFailed("no photo data")))
            return
        }
        let exif = photo.metadata[kCGImagePropertyExifDictionary as String] as? [String: Any]
        let iso = (exif?[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first?.doubleValue
        let shutter = (exif?[kCGImagePropertyExifExposureTime as String] as? NSNumber)?.doubleValue
        let hasDepth = photo.depthData != nil
        let depth = photo.depthData
        let orientation = (photo.metadata[kCGImagePropertyOrientation as String] as? NSNumber)
            .flatMap { CGImagePropertyOrientation(rawValue: $0.uint32Value) } ?? .up
        DispatchQueue.global(qos: .userInitiated).async { [done] in
            guard var shot = PhotoFiles.jpegForUpload(data) else {
                done(.failure(CameraError.captureFailed("JPEG conversion failed")))
                return
            }
            shot.iso = iso
            shot.shutter = shutter
            shot.hasDepth = hasDepth
            // Depth Pro 2 on device when bundled (#41), else the photo's LiDAR/AVDepthData.
            shot.depthPNG = PhotoDepth.depthPNGmm(fromPhotoData: data)
                ?? depth.flatMap { PhotoDepth.depthPNGmm(from: $0, orientation: orientation) }
            shot.hasDepth = shot.depthPNG != nil
            done(.success(shot))
        }
    }
}

/// HEIF → JPEG (quality 0.9, metadata and orientation kept) plus a small upright thumbnail.
enum PhotoFiles {
    static func jpegForUpload(_ data: Data, quality: Double = 0.9) -> CapturedPhoto? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let isJPEG = (CGImageSourceGetType(src) as String?) == UTType.jpeg.identifier
        var jpeg = data
        if !isJPEG {
            let out = NSMutableData()
            guard let dst = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImageFromSource(dst, src, 0,
                                                 [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(dst) else { return nil }
            jpeg = out as Data
        }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let w = (props?[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let h = (props?[kCGImagePropertyPixelHeight] as? Int) ?? 0
        let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 240,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary)
        return CapturedPhoto(fileData: data, jpeg: jpeg, width: w, height: h, iso: nil, shutter: nil,
                             hasDepth: false, thumbnail: thumb)
    }
}
