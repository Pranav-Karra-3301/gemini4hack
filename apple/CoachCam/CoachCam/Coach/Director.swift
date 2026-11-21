import CoachAPI
import CoachLive
import Foundation
import UIKit

/// Second opinion on the live view: posts the newest frame Gemini Live got to Core's
/// `POST /api/cam/director` and keeps the latest answer, which the next `[tick]` carries.
///
/// One request in flight at a time, back to back but at most every 2.5 s (5 s after a failure),
/// and only when a new frame went out since the last request. `runNow()` (after a scene shift)
/// skips the spacing. Owned by `CoachSession`; the loop ends when `state` returns nil (it is only
/// asked once a request is due, so building it can consume one-shot flags) or on `stop()`.
@MainActor
final class Director {
    static let interval: TimeInterval = 2.5
    static let failureBackoff: TimeInterval = 5

    /// The latest answer and how many answers arrived (a new count = a fresh direction).
    private(set) var latest: Direction?
    /// When the request behind `latest` started: its frame is from then, not from when it arrived.
    private(set) var latestStartedAt: Date?
    private(set) var count = 0
    private(set) weak var live: LiveSession?
    /// Called with each answer and its request's start time.
    var onAnswer: (@MainActor (Direction, Date) -> Void)?

    private let client: CoachClient
    /// State for the request body; nil once the live session ended.
    private let state: @MainActor () -> [String: Any]?
    private var task: Task<Void, Never>?
    private var lastFrameCount = 0
    private var nextAllowed = Date.distantPast
    private var urgent = false

    init(live: LiveSession, client: CoachClient, state: @escaping @MainActor () -> [String: Any]?) {
        self.live = live
        self.client = client
        self.state = state
    }

    func start() {
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, await self.step() else { return }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// Ask as soon as a new frame is out, without waiting for the 2.5 s spacing.
    func runNow() { urgent = true }

    /// One poll; false once the session ended.
    private func step() async -> Bool {
        guard let live else { return false }
        guard let frame = live.latestSentFrame, frame.count != lastFrameCount else { return true }
        let now = Date()
        guard urgent || now >= nextAllowed else { return true }
        guard let body = state() else { return false }
        urgent = false
        lastFrameCount = frame.count
        do {
            let d = try await client.director(jpeg: frame.jpeg, state: body)
            guard !Task.isCancelled else { return false }
            latest = d
            SubjectTracker.shared.direct(FrameTargetInput(subjectBox: d.subjectBox, targetBox: d.targetBox,
                                                          levelDeg: d.levelDeg, horizon: d.intent == "landscape"))
            latestStartedAt = now
            count += 1
            onAnswer?(d, now)
            nextAllowed = now.addingTimeInterval(Self.interval)
            #if DEBUG
            print("CoachCam[live] director \(Int(Date().timeIntervalSince(now) * 1000)) ms: "
                  + "\(d.intent ?? "-") \"\(d.subject ?? "")\" new=\(d.newShot ?? false) score \(d.score ?? -1) "
                  + "move \(d.move ?? "-") ready \(d.ready ?? false)")
            #endif
        } catch {
            nextAllowed = Date().addingTimeInterval(Self.failureBackoff)
            #if DEBUG
            print("CoachCam[live] director failed: \(CoachSession.describe(error))")
            #endif
        }
        return true
    }
}

/// The "shot ready" moment: a success haptic, at most once per 3 s. Kept prepared so it lands on time.
/// `CoachSession` also fires it only once per subject (re-armed by set_intent or a scene shift).
@MainActor
final class ReadyHaptic {
    private let generator = UINotificationFeedbackGenerator()
    private var last = Date.distantPast

    func prepare() { generator.prepare() }

    func fire() {
        let now = Date()
        guard now.timeIntervalSince(last) >= 3 else { return }
        last = now
        generator.notificationOccurred(.success)
        generator.prepare()
    }
}
