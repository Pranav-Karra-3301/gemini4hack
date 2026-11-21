import CoreMotion
import Observation
import SwiftUI
import UIKit
import Vision
import CoachUI

/// What the director says about framing, in normalised coordinates of the frame as sent (upright,
/// 3:4, origin top-left). The lead maps CoachKit's `Direction` into this.
struct FrameTargetInput: Equatable {
    /// Where the subject is now.
    var subject: CGRect?
    /// Where the subject should be.
    var target: CGRect?
    /// Horizon tilt in the frame, degrees, positive = clockwise (right side low). Nil = not measured.
    var levelDeg: Double?
    /// With `levelDeg` nil: still show the level line from device roll (landscapes, architecture).
    var horizon = false

    init(subject: CGRect?, target: CGRect?, levelDeg: Double?, horizon: Bool = false) {
        self.subject = subject; self.target = target; self.levelDeg = levelDeg; self.horizon = horizon
    }

    /// From the director's `[x0, y0, x1, y1]` boxes.
    init(subjectBox: [Double]?, targetBox: [Double]?, levelDeg: Double?, horizon: Bool = false) {
        self.init(subject: Self.rect(subjectBox), target: Self.rect(targetBox), levelDeg: levelDeg, horizon: horizon)
    }

    /// `[x0, y0, x1, y1]` (0...1, top-left origin) as a rect; nil when malformed or degenerate.
    static func rect(_ b: [Double]?) -> CGRect? {
        guard let b, b.count == 4, b.allSatisfy(\.isFinite) else { return nil }
        let x0 = min(max(min(b[0], b[2]), 0), 1), x1 = min(max(max(b[0], b[2]), 0), 1)
        let y0 = min(max(min(b[1], b[3]), 0), 1), y1 = min(max(max(b[1], b[3]), 0), 1)
        guard x1 - x0 > 0.01, y1 - y0 > 0.01 else { return nil }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}

// MARK: - Tracking

/// Follows the subject between director answers (every ~3-4 s): seeded with the director's box,
/// then `VNTrackObjectRequest` on camera frames at ~12 fps. `tracked` (normalised, upright frame,
/// top-left origin) is published on the main thread; nil until seeded or once the track is lost.
@Observable
final class SubjectTracker: FrameSink, @unchecked Sendable {
    /// The app's tracker (one camera, one subject).
    static let shared = SubjectTracker()

    private(set) var tracked: CGRect?
    /// The latest director answer's framing (main thread), for `FrameTargetOverlay(input:)`.
    private(set) var input: FrameTargetInput?

    /// A new director answer: keeps its framing and re-seeds the track from its subject box.
    /// Call on the main thread.
    func direct(_ input: FrameTargetInput?) {
        self.input = input
        if let s = input?.subject { seed(s) }
    }

    @ObservationIgnored private let lock = NSLock()
    @ObservationIgnored private let queue = DispatchQueue(label: "coachcam.subject-tracker", qos: .userInitiated)
    @ObservationIgnored private var request: VNTrackObjectRequest?
    @ObservationIgnored private var handler = VNSequenceRequestHandler()
    @ObservationIgnored private var busy = false
    @ObservationIgnored private var lastRun: CFTimeInterval = 0
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let interval: CFTimeInterval = 1.0 / 12
    @ObservationIgnored private let minConfidence: Float = 0.3

    /// Starts a new track from `box` (normalised, top-left origin, frame as sent).
    func seed(_ box: CGRect) {
        let b = box.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !b.isNull, b.width > 0.01, b.height > 0.01 else { return }
        // Vision: normalised, lower-left origin, in the oriented (upright) image.
        let obs = VNDetectedObjectObservation(boundingBox: CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height))
        let req = VNTrackObjectRequest(detectedObjectObservation: obs)
        req.trackingLevel = .accurate
        lock.withLock {
            request = req
            handler = VNSequenceRequestHandler()
            generation += 1
        }
        publish(b)
    }

    /// Stops tracking (new scene, coach off).
    func clear() {
        lock.withLock { request = nil; generation += 1 }
        publish(nil)
    }

    // FrameSink: called on the capture queue; drops frames while one is in flight or too soon.
    func offer(pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) {
        guard let job = claim() else { return }
        queue.async { [self] in
            track(job) { h, r in try h.perform([r], on: pixelBuffer, orientation: orientation) }
        }
    }

    func offer(cgImage: CGImage) {
        guard let job = claim() else { return }
        queue.async { [self] in
            track(job) { h, r in try h.perform([r], on: cgImage) }
        }
    }

    private struct Job { let request: VNTrackObjectRequest; let handler: VNSequenceRequestHandler; let generation: Int }

    private func claim() -> Job? {
        lock.withLock {
            let now = CACurrentMediaTime()
            guard let request, !busy, now - lastRun >= interval else { return nil }
            busy = true
            lastRun = now
            return Job(request: request, handler: handler, generation: generation)
        }
    }

    private func track(_ job: Job, perform: (VNSequenceRequestHandler, VNTrackObjectRequest) throws -> Void) {
        defer { lock.withLock { busy = false } }
        do { try perform(job.handler, job.request) } catch { lost(job); return }
        guard let obs = job.request.results?.first as? VNDetectedObjectObservation, obs.confidence >= minConfidence
        else { lost(job); return }
        let current = lock.withLock { job.generation == generation }
        guard current else { return }
        job.request.inputObservation = obs
        let bb = obs.boundingBox
        publish(CGRect(x: bb.minX, y: 1 - bb.maxY, width: bb.width, height: bb.height))
    }

    private func lost(_ job: Job) {
        let current: Bool = lock.withLock {
            guard job.generation == generation else { return false }
            request = nil
            return true
        }
        if current { publish(nil) }
    }

    private func publish(_ r: CGRect?) {
        DispatchQueue.main.async { [weak self] in self?.tracked = r }
    }
}

/// Hands each camera frame to several sinks (the engine has one `frameSink`).
final class FrameSinks: FrameSink, @unchecked Sendable {
    let sinks: [FrameSink]
    init(_ sinks: [FrameSink]) { self.sinks = sinks }
    func offer(pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) {
        for s in sinks { s.offer(pixelBuffer: pixelBuffer, orientation: orientation) }
    }
    func offer(cgImage: CGImage) { for s in sinks { s.offer(cgImage: cgImage) } }
}

// MARK: - Overlay

/// Framing guidance with no arrows and no text: a thin light frame hugging the subject, a soft
/// dashed Gemini-blue ghost where it should go, one glowing frame (and a success haptic, once)
/// when they meet, and a level line that straightens and fades as the phone is levelled.
/// Place it over the preview, same size as the card (the preview is a 3:4 frame, aspect fill).
struct FrameTargetOverlay: View {
    let input: FrameTargetInput?
    let tracked: CGRect?

    init(input: FrameTargetInput?, tracked: CGRect?) {
        self.input = input
        self.tracked = tracked
    }

    @State private var aligned = false
    @State private var roll = RollMeter()
    /// Device roll when the current `levelDeg` arrived, so the line follows the phone live.
    @State private var rollAtAnswer: Double = 0

    private static let enterIoU = 0.75
    private static let leaveIoU = 0.62

    var body: some View {
        GeometryReader { geo in
            let map = PreviewMap(size: geo.size)
            let subject = (tracked ?? input?.subject).map(map.rect)
            let target = input?.target.map(map.rect)
            let iou = Self.iou(tracked ?? input?.subject, input?.target)
            ZStack {
                if let target {
                    box(target)
                        .stroke(GXColor.gemini.opacity(0.7), style: StrokeStyle(lineWidth: 1.2, dash: [5, 6]))
                        .shadow(color: GXColor.gemini.opacity(0.35), radius: 6)
                        .place(target)
                        .opacity(aligned ? 0 : 1)
                }
                if let subject {
                    let r = aligned ? (target ?? subject) : subject
                    box(r)
                        .stroke(aligned ? GXColor.geminiHot : GXColor.frost.opacity(0.55), lineWidth: aligned ? 1.6 : 1)
                        .shadow(color: GXColor.gemini.opacity(aligned ? 0.9 : 0), radius: 10)
                        .shadow(color: GXColor.gemini.opacity(aligned ? 0.6 : 0), radius: 3)
                        .place(r)
                }
                levelLine(width: geo.size.width)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.86), value: subject)
            .animation(.spring(response: 0.45, dampingFraction: 0.9), value: target)
            .animation(.easeInOut(duration: 0.35), value: aligned)
            .onChange(of: iou, initial: true) { _, v in
                let next = aligned ? v >= Self.leaveIoU : v >= Self.enterIoU
                guard next != aligned else { return }
                aligned = next
                if next { UINotificationFeedbackGenerator().notificationOccurred(.success) }
            }
        }
        .onChange(of: input, initial: true) { _, _ in rollAtAnswer = roll.degrees }
        .onAppear { roll.start() }
        .onDisappear { roll.stop() }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func box(_ r: CGRect) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: min(16, min(r.width, r.height) * 0.18), style: .continuous)
    }

    /// The horizon as the camera sees it now: the director's tilt, corrected live by how far the
    /// phone has turned since; without a tilt (and `horizon`), the device roll alone.
    @ViewBuilder
    private func levelLine(width: CGFloat) -> some View {
        if let residual = residualTilt {
            let fade = min(max((abs(residual) - 0.6) / 2.4, 0), 1)
            Capsule()
                .fill(GXColor.frost.opacity(0.75))
                .frame(width: width * 0.56, height: 1)
                .shadow(color: GXColor.void.opacity(0.6), radius: 1.5)
                .rotationEffect(.degrees(residual))
                .opacity(fade)
                .animation(.easeOut(duration: 0.25), value: fade)
        }
    }

    private var residualTilt: Double? {
        if let lv = input?.levelDeg {
            guard abs(lv) > 2 else { return nil }
            return lv - (roll.degrees - rollAtAnswer)
        }
        guard input?.horizon == true, abs(roll.degrees) > 2 else { return nil }
        return -roll.degrees
    }

    static func iou(_ a: CGRect?, _ b: CGRect?) -> Double {
        guard let a, let b else { return 0 }
        let i = a.intersection(b)
        guard !i.isNull else { return 0 }
        let inter = i.width * i.height
        let union = a.width * a.height + b.width * b.height - inter
        return union > 0 ? Double(inter / union) : 0
    }
}

private extension View {
    /// Sizes and centres a shape on `r` (animatable, unlike a path in `r`).
    func place(_ r: CGRect) -> some View {
        frame(width: max(r.width, 1), height: max(r.height, 1)).position(x: r.midX, y: r.midY)
    }
}

/// Normalised frame coordinates → the card: the 3:4 frame aspect-fills the card (as `tapFocus`).
private struct PreviewMap {
    let size: CGSize
    private static let frameAspect: CGFloat = 3.0 / 4.0

    func rect(_ n: CGRect) -> CGRect {
        let fillW = max(size.width, size.height * Self.frameAspect)
        let fillH = max(size.height, size.width / Self.frameAspect)
        let ox = (size.width - fillW) / 2, oy = (size.height - fillH) / 2
        return CGRect(x: ox + n.minX * fillW, y: oy + n.minY * fillH, width: n.width * fillW, height: n.height * fillH)
    }
}

/// Device roll in portrait, degrees, positive = turned clockwise (as the user sees the screen).
@MainActor
@Observable
private final class RollMeter {
    private(set) var degrees: Double = 0
    @ObservationIgnored private let motion = CMMotionManager()
    @ObservationIgnored private var users = 0

    func start() {
        users += 1
        guard users == 1, motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 30
        motion.startDeviceMotionUpdates(to: .main) { [weak self] m, _ in
            guard let g = m?.gravity else { return }
            let d = atan2(g.x, -g.y) * 180 / .pi
            MainActor.assumeIsolated {
                // Light smoothing; ignore the jump when the phone is flat (gravity along z).
                guard let self, abs(g.z) < 0.9 else { return }
                self.degrees += (d - self.degrees) * 0.35
            }
        }
    }

    func stop() {
        users = max(0, users - 1)
        if users == 0 { motion.stopDeviceMotionUpdates() }
    }
}
