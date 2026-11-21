import Foundation
import Observation
import CoachModels

/// State for the camera dials: the settings, the dial motion (user drags, flings, coach glides)
/// and the coach choreography that walks the strip through several changes in turn.
///
/// The app owns one model. It calls ``coachApply(_:why:at:)`` with the values it actually applied
/// to AVFoundation after a `set_camera` tool call, and listens to ``onUserChange`` for the user's
/// own changes. Every animation is a function of time, so a new event always retargets from the
/// value on screen; nothing is queued.
@MainActor
@Observable
public final class CameraControlsModel {
    /// Dials in strip order.
    public let parameters: [CameraParameter]
    /// The dial the user expanded (the strip shows the coach's dial instead while it acts).
    public private(set) var selection: CameraParameter?
    /// Called for user changes only: drags (once per detent), flings (the landing value), AUTO taps.
    @ObservationIgnored public var onUserChange: (@MainActor (CameraParameter, DialSetting) -> Void)?
    /// Set from `accessibilityReduceMotion`: coach moves snap quickly and steps follow faster.
    public var reduceMotion = false

    /// Seconds between consecutive coach changes in one choreography.
    public static let stepInterval = 0.62
    /// How long the strip holds the coach's last dial before settling back.
    public static let holdAfter = 1.1

    private(set) var settings: [CameraParameter: DialSetting]
    private var ranges: [CameraParameter: ClosedRange<Double>] = [:]
    private var motions: [CameraParameter: DialMotion] = [:]
    var motionsSnapshot: [CameraParameter: DialMotion] { motions }
    private var dragging: [CameraParameter: Double] = [:]
    private(set) var sequence: CoachSequence?
    @ObservationIgnored private var settleTask: Task<Void, Never>?
    @ObservationIgnored private var lastReported: [CameraParameter: DialSetting] = [:]

    /// - Parameters:
    ///   - parameters: dials in strip order.
    ///   - settings: starting settings; missing ones start at AUTO (or the default value).
    public init(parameters: [CameraParameter] = CameraParameter.stripDefault,
                settings: [CameraParameter: DialSetting] = [:]) {
        self.parameters = parameters
        var s = settings
        for p in parameters where s[p] == nil {
            s[p] = p.supportsAuto ? .auto(metered: nil) : .manual(p.defaultValue)
        }
        self.settings = s
    }

    // MARK: Reading

    /// The current setting (the target, even while a dial is still animating toward it).
    public func setting(_ parameter: CameraParameter) -> DialSetting {
        settings[parameter] ?? .auto(metered: nil)
    }

    /// The device's supported range for a parameter (defaults to ``CameraParameter/defaultRange``).
    public func range(_ parameter: CameraParameter) -> ClosedRange<Double> {
        ranges[parameter] ?? parameter.defaultRange
    }

    /// Restricts a dial to what the device supports (e.g. ISO 32...3200, zoom 0.5...15).
    public func setRange(_ range: ClosedRange<Double>, for parameter: CameraParameter) {
        ranges[parameter] = range
    }

    // MARK: Coach

    /// Shows coach-applied settings: the strip expands each changed dial in strip order, glides it
    /// to the new value in amber with `why` as a caption, then settles back to the user's dial.
    /// Pass the values the camera actually applied (clamped), not the raw tool arguments.
    public func coachApply(_ changes: [CameraParameter: DialSetting], why: String?, at now: Date = Date()) {
        let ordered = parameters.filter { changes[$0] != nil }
            + changes.keys.filter { !parameters.contains($0) }.sorted { $0.rawValue < $1.rawValue }
        guard !ordered.isEmpty else { return }
        // Steps of an interrupted sequence that never started still get to play, after the new ones.
        let carried = (sequence?.steps ?? []).filter { $0.start > now && changes[$0.parameter] == nil }.map(\.parameter)
        let interval = reduceMotion ? 0.3 : Self.stepInterval
        var steps: [CoachSequence.Step] = []
        for (i, p) in (ordered + carried).enumerated() {
            steps.append(.init(parameter: p, start: now.addingTimeInterval(Double(i) * interval)))
        }
        for (i, p) in (ordered + carried).enumerated() {
            let from = displayedPosition(p, at: now)
            let to: Double
            if let target = changes[p] {
                let toValue = target.value ?? range(p).clamp(p.value(at: from))
                to = clampPosition(p.position(for: range(p).clamp(toValue)), p)
                settings[p] = target
            } else {
                to = motions[p]?.glide.to ?? from   // carried over: same target, new slot
            }
            let v = motions[p]?.glide.velocity(at: now) ?? 0
            motions[p] = DialMotion(
                glide: Glide(from: from, to: to, velocity: v, start: steps[i].start,
                             spring: reduceMotion ? .snappy : .glide, epsilon: 0.02),
                coach: true)
            dragging[p] = nil
        }
        let lastStepEnd = steps.map { motions[$0.parameter]!.glide.end }.max() ?? now
        let end = max(lastStepEnd, steps.last!.start.addingTimeInterval(0.5)).addingTimeInterval(Self.holdAfter)
        sequence = CoachSequence(start: now, steps: steps, why: why?.isEmpty == true ? nil : why, end: end)
        scheduleSettle()
    }

    /// Convenience for a `set_camera` result: maps ISO, shutter, EV, focus, white balance, tint and
    /// zoom onto the dials and plays them with `settings.why`.
    public func coachApply(_ applied: CameraSettings, at now: Date = Date()) {
        var changes: [CameraParameter: DialSetting] = [:]
        func auto(_ n: AutoNumber?, _ p: CameraParameter) {
            guard let n else { return }
            changes[p] = n.isAuto ? .auto(metered: setting(p).value) : .manual(n.number ?? p.defaultValue)
        }
        auto(applied.iso, .iso)
        auto(applied.shutter, .shutter)
        auto(applied.focus, .focus)
        auto(applied.wbKelvin, .whiteBalance)
        if let ev = applied.ev { changes[.ev] = .manual(ev) }
        if let tint = applied.tint { changes[.tint] = .manual(tint) }
        if let zoom = applied.zoom { changes[.zoom] = .manual(zoom) }
        coachApply(changes, why: applied.why, at: now)
    }

    // MARK: Camera feedback

    /// Feeds the camera's live value while a dial is in AUTO (call at most ~10 times a second).
    /// The dimmed dial follows it; manual dials ignore it.
    public func updateMetered(_ parameter: CameraParameter, value: Double, at now: Date = Date()) {
        guard case .auto = setting(parameter), dragging[parameter] == nil else { return }
        settings[parameter] = .auto(metered: value)
        let to = clampPosition(parameter.position(for: value), parameter)
        let from = displayedPosition(parameter, at: now)
        if let m = motions[parameter], m.coach, now < m.glide.end { return }  // let the coach finish
        guard abs(to - from) > 0.05 else { return }
        motions[parameter] = DialMotion(
            glide: Glide(from: from, to: to, velocity: motions[parameter]?.glide.velocity(at: now) ?? 0,
                         start: now, spring: .lift, epsilon: 0.02),
            coach: false)
        scheduleSettle()
    }

    /// Sets a value without coach styling (e.g. restoring state). Animates unless `animated` is false.
    public func set(_ parameter: CameraParameter, to setting: DialSetting, animated: Bool = true, at now: Date = Date()) {
        settings[parameter] = setting
        guard let v = setting.value else { return }
        let to = clampPosition(parameter.position(for: v), parameter)
        if animated {
            motions[parameter] = DialMotion(
                glide: Glide(from: displayedPosition(parameter, at: now), to: to, start: now,
                             spring: .snappy, epsilon: 0.02),
                coach: false)
            scheduleSettle()
        } else {
            motions[parameter] = nil
        }
    }

    // MARK: User

    /// Expands a dial (or collapses it with `nil`). Ends a running coach choreography's takeover.
    public func select(_ parameter: CameraParameter?) {
        if let s = sequence { sequence = s.endingSelection() }
        selection = parameter
    }

    /// Switches a dial between AUTO and manual (manual starts from the value on screen).
    public func toggleAuto(_ parameter: CameraParameter, at now: Date = Date()) {
        guard parameter.supportsAuto else { return }
        let new: DialSetting
        switch setting(parameter) {
        case .auto(let m):
            let pos = displayedPosition(parameter, at: now)
            _ = m
            let v = parameter.detentValue(at: pos)
            new = .manual(v)
            snap(parameter, to: parameter.position(for: v), at: now)
        case .manual(let v):
            new = .auto(metered: v)
        }
        settings[parameter] = new
        report(parameter, new)
    }

    func beginDrag(_ parameter: CameraParameter, at now: Date) -> Double {
        let pos = displayedPosition(parameter, at: now)
        motions[parameter] = nil
        dragging[parameter] = pos
        if let s = sequence { sequence = s.endingSelection() }
        if parameters.contains(parameter) { selection = parameter }   // keep the grabbed dial open
        if setting(parameter).isAuto {
            settings[parameter] = .manual(parameter.detentValue(at: pos))
            report(parameter, settings[parameter]!)
        }
        return pos
    }

    func drag(_ parameter: CameraParameter, to raw: Double) {
        let (lo, hi) = positionBounds(parameter)
        let banded: Double
        if raw < lo { banded = lo - rubberBand(lo - raw) } else if raw > hi { banded = hi + rubberBand(raw - hi) } else { banded = raw }
        dragging[parameter] = banded
        let detent = parameter.detentValue(at: min(max(banded, lo), hi))
        if settings[parameter] != .manual(detent) {
            settings[parameter] = .manual(detent)
            report(parameter, .manual(detent))
        }
    }

    /// Ends a drag: flings coast with scroll-view deceleration and land on a detent.
    func endDrag(_ parameter: CameraParameter, velocity: Double, at now: Date) {
        guard let from = dragging[parameter] else { return }
        dragging[parameter] = nil
        let (lo, hi) = positionBounds(parameter)
        let fling = abs(velocity) > 2
        let projected = fling ? from + velocity / 4 : from
        let target = min(max(projected.rounded(), ceil(lo)), floor(hi))
        motions[parameter] = DialMotion(
            glide: Glide(from: from, to: target, velocity: fling ? velocity : 0, start: now,
                         spring: fling ? .coast : .snappy, epsilon: 0.01),
            coach: false)
        let value = DialSetting.manual(parameter.detentValue(at: target))
        settings[parameter] = value
        report(parameter, value)
        scheduleSettle()
    }

    // MARK: Presentation (pure functions of time)

    /// Dial position on screen at `date`.
    func displayedPosition(_ parameter: CameraParameter, at date: Date) -> Double {
        if let d = dragging[parameter] { return d }
        if let m = motions[parameter] { return m.glide.value(at: date) }
        let v = setting(parameter).value ?? parameter.defaultValue
        return clampPosition(parameter.position(for: v), parameter)
    }

    /// Value on screen at `date` (snapped to the nearest marked detent while moving).
    func displayedValue(_ parameter: CameraParameter, at date: Date) -> Double {
        if dragging[parameter] == nil, motions[parameter] == nil || motions[parameter]!.glide.end <= date,
           let v = setting(parameter).value {
            return v
        }
        return parameter.detentValue(at: displayedPosition(parameter, at: date))
    }

    /// True while the user moves the dial (drag or fling): detent haptics play only then.
    func isUserMoving(_ parameter: CameraParameter, at date: Date) -> Bool {
        if dragging[parameter] != nil { return true }
        if let m = motions[parameter], !m.coach, date < m.glide.end { return true }
        return false
    }

    /// 0...1: how strongly a dial shows the coach's amber at `date`.
    func coachAmount(_ parameter: CameraParameter, at date: Date) -> Double {
        guard let s = sequence, let step = s.steps.first(where: { $0.parameter == parameter }),
              motions[parameter]?.coach == true, date >= step.start else { return 0 }
        let fadeIn = min(1, date.timeIntervalSince(step.start) / 0.12)
        let fadeOut = 1 - min(1, max(0, date.timeIntervalSince(s.end) / 0.45))
        return fadeIn * fadeOut
    }

    /// The dial the strip shows at `date`: the coach's current step, else the user's selection.
    func presentedSelection(at date: Date) -> CameraParameter? {
        if let s = sequence, s.selectionActive, date < s.end {
            return (s.steps.last { $0.start <= date } ?? s.steps.first)?.parameter
        }
        return selection
    }

    /// The step index of the current choreography at `date` (drives the coach haptic).
    func coachStepIndex(at date: Date) -> Int? {
        guard let s = sequence, date >= s.start, date < s.end else { return nil }
        return s.steps.lastIndex { $0.start <= date }
    }

    /// The coach's caption and its opacity at `date`.
    func caption(at date: Date) -> (text: String, opacity: Double)? {
        guard let s = sequence, let why = s.why else { return nil }
        let t = date.timeIntervalSince(s.start)
        let out = date.timeIntervalSince(s.end) + 0.1
        guard t >= 0, out < 0.45 else { return nil }
        let opacity = min(1, t / CoachDuration.base) * (1 - min(1, max(0, out / 0.45)))
        return (why, CoachEase.outCurve(opacity))
    }

    /// True while anything is moving at `date` (the timeline pauses otherwise).
    func isAnimating(at date: Date) -> Bool {
        if !dragging.isEmpty { return true }
        if motions.values.contains(where: { date < $0.glide.end }) { return true }
        if let s = sequence, date < s.end.addingTimeInterval(0.5) { return true }
        return false
    }

    // MARK: Internals

    private func snap(_ parameter: CameraParameter, to position: Double, at now: Date) {
        motions[parameter] = DialMotion(
            glide: Glide(from: displayedPosition(parameter, at: now), to: clampPosition(position, parameter),
                         start: now, spring: .snappy, epsilon: 0.01),
            coach: false)
        scheduleSettle()
    }

    private func report(_ parameter: CameraParameter, _ setting: DialSetting) {
        guard lastReported[parameter] != setting else { return }
        lastReported[parameter] = setting
        onUserChange?(parameter, setting)
    }

    private func positionBounds(_ p: CameraParameter) -> (Double, Double) {
        let r = range(p)
        return (p.position(for: r.lowerBound), p.position(for: r.upperBound))
    }

    private func clampPosition(_ pos: Double, _ p: CameraParameter) -> Double {
        let (lo, hi) = positionBounds(p)
        return min(max(pos, lo), hi)
    }

    private func rubberBand(_ overshoot: Double) -> Double {
        let d = 4.0
        return (1 - 1 / (overshoot * 0.55 / d + 1)) * d
    }

    /// Drops finished motions once everything has settled so the timeline can pause.
    private func scheduleSettle() {
        settleTask?.cancel()
        let ends = motions.values.map(\.glide.end) + [sequence?.end.addingTimeInterval(0.5)].compactMap { $0 }
        guard let last = ends.max() else { return }
        let delay = max(0, last.timeIntervalSinceNow) + 0.05
        settleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            let now = Date()
            self.motions = self.motions.filter { now < $0.value.glide.end }
            if let s = self.sequence, now >= s.end.addingTimeInterval(0.45) { self.sequence = nil }
            if !self.motions.isEmpty || self.sequence != nil { self.scheduleSettle() }
        }
    }
}

struct DialMotion: Equatable {
    var glide: Glide
    var coach: Bool
}

/// A coach choreography: dials expand and glide one after another, then the strip settles back.
struct CoachSequence: Equatable {
    struct Step: Equatable {
        var parameter: CameraParameter
        var start: Date
    }
    var start: Date
    var steps: [Step]
    var why: String?
    var end: Date
    /// False once the user takes over the strip (taps a chip, grabs a dial).
    var selectionActive = true

    func endingSelection() -> CoachSequence {
        var s = self
        s.selectionActive = false
        return s
    }
}

extension ClosedRange where Bound == Double {
    func clamp(_ v: Double) -> Double { Swift.min(Swift.max(v, lowerBound), upperBound) }
}
