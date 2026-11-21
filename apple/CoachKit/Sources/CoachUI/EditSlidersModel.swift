import Foundation
import Observation
import CoachModels

/// State for the editor's sliders: values, the user's scrubs, and the coach's guided edits.
///
/// The coach drives it through ``coachStep(_:index:of:at:)`` (one `edit_step` tool call: returns
/// when the glide lands, ~0.6 s), ``coachSet(_:why:at:)`` (`set_sliders`) and ``play(_:)`` (a whole
/// `/edit/suggest` result, one slider at a time). The panel scrolls to and spotlights each step.
/// Render the photo from ``displayedValue(_:at:)`` to follow the glide frame by frame, and save
/// ``values``.
@MainActor
@Observable
public final class EditSlidersModel {
    /// The coach's current step: which slider, why, and the region to highlight.
    public struct Spotlight: Equatable, Sendable {
        public var slider: Slider
        public var why: String
        public var region: String?
        /// 1-based position in a guided edit, with the step count.
        public var index: Int?
        public var count: Int?
        public var start: Date
    }

    /// Sliders this editor shows, in display order.
    public let sliders: [Slider]
    /// Target values (missing = default; a missing `focusDepth` means auto).
    public private(set) var values: [Slider: Double] = [:]
    /// The coach's current step, while it lasts.
    public private(set) var spotlight: Spotlight?
    /// One-line summary of a guided edit or a `set_sliders` call, shown in the panel header.
    public private(set) var banner: String?
    /// Called for user changes only (scrubs, resets), with the snapped value (`nil` = auto).
    @ObservationIgnored public var onUserChange: (@MainActor (Slider, Double?) -> Void)?
    /// Set from `accessibilityReduceMotion`: coach glides become quick snaps.
    public var reduceMotion = false

    /// How long a coach step's "why" stays after the glide lands, when no next step replaces it.
    public static let spotlightHold = 2.4
    /// Pause between steps of a guided edit, so each "why" can be read.
    public static let stepPause = 0.9

    private var motions: [Slider: SliderMotion] = [:]
    private var scrubbing: [Slider: Double] = [:]
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var settleTask: Task<Void, Never>?
    @ObservationIgnored private var spotlightTask: Task<Void, Never>?

    /// - Parameters:
    ///   - sliders: sliders to show (default: all of CORE_API.md §4, in editing order).
    ///   - values: starting values (e.g. a saved recipe's).
    public init(sliders: [Slider] = Slider.allCases, values: [Slider: Double] = [:]) {
        self.sliders = sliders
        self.values = values.reduce(into: [:]) { $0[$1.key] = $1.key.spec.snap($1.value) }
    }

    /// The target value; `nil` only for an auto `focusDepth`.
    public func value(_ slider: Slider) -> Double? {
        values[slider] ?? slider.spec.defaultValue
    }

    /// The value on screen at `date` (follows coach glides and flings), for live previews.
    public func displayedValue(_ slider: Slider, at date: Date = Date()) -> Double? {
        if scrubbing[slider] == nil, motions[slider] == nil || date >= motions[slider]!.glide.end {
            return value(slider)
        }
        if slider == .focusDepth, values[slider] == nil, scrubbing[slider] == nil { return nil }
        return slider.spec.value(normalized: displayedPosition(slider, at: date))
    }

    // MARK: Coach

    /// Plays one guided step: spotlights the slider, glides it to `step.value` with an amber trail
    /// and shows `step.why`. Returns the applied (clamped, snapped) value when the glide lands.
    @discardableResult
    public func coachStep(_ step: EditStep, index: Int? = nil, of count: Int? = nil, at now: Date = Date()) async -> Double? {
        let (applied, landing) = beginCoachStep(step, index: index, of: count, at: now)
        await sleep(until: landing)
        return applied
    }

    /// Starts a coach step without waiting: returns the applied value and when the glide lands.
    public func beginCoachStep(_ step: EditStep, index: Int?, of count: Int?, at now: Date) -> (Double?, Date) {
        let applied = startCoachGlide(step.slider, to: step.value, at: now)
        spotlight = Spotlight(slider: step.slider, why: step.why, region: step.region,
                              index: index, count: count, start: now)
        let landing = motions[step.slider]?.glide.end ?? now
        scheduleSpotlightClear(after: landing.addingTimeInterval(Self.spotlightHold))
        return (applied, landing)
    }

    /// Applies several values at once (`set_sliders`), all gliding in amber, with `why` as the banner.
    /// Returns the applied values when the glides land.
    @discardableResult
    public func coachSet(_ changes: [Slider: Double], why: String?, at now: Date = Date()) async -> [Slider: Double] {
        var applied: [Slider: Double] = [:]
        for s in sliders where changes[s] != nil {
            applied[s] = startCoachGlide(s, to: changes[s], at: now)
        }
        banner = why
        spotlight = nil
        let landing = applied.keys.compactMap { motions[$0]?.glide.end }.max() ?? now
        scheduleSpotlightClear(after: landing.addingTimeInterval(Self.spotlightHold))
        await sleep(until: landing)
        return applied
    }

    /// Plays a guided edit (an `/edit/suggest` result): each step in order, spotlighted, with a short
    /// pause to read its "why". A newer `play`, `reset` or user takeover cancels the rest.
    public func play(_ suggestion: EditSuggestion) async {
        generation += 1
        let mine = generation
        banner = suggestion.summary.isEmpty ? nil : suggestion.summary
        let steps = suggestion.steps
        for (i, step) in steps.enumerated() {
            guard generation == mine, !Task.isCancelled else { return }
            await coachStep(step, index: i + 1, of: steps.count)
            if i < steps.count - 1 { await sleep(until: Date().addingTimeInterval(Self.stepPause)) }
        }
    }

    func setBannerForTesting(_ text: String?) { banner = text }

    /// Stops a guided edit after the current step.
    public func cancelGuide() {
        generation += 1
        spotlight = nil
        banner = nil
    }

    // MARK: Values

    /// Replaces all values without animation (e.g. loading a saved recipe).
    public func load(_ newValues: [Slider: Double]) {
        values = newValues.reduce(into: [:]) { $0[$1.key] = $1.key.spec.snap($1.value) }
        motions = [:]
    }

    /// Back to the original: every slider glides home.
    public func reset(at now: Date = Date()) {
        cancelGuide()
        for s in sliders where values[s] != nil {
            let from = displayedPosition(s, at: now)
            values[s] = nil
            motions[s] = SliderMotion(glide: Glide(from: from, to: position(s), start: now, spring: .lift,
                                                   epsilon: 0.002), coach: false)
        }
        scheduleSettle()
    }

    // MARK: User scrubbing

    func beginScrub(_ slider: Slider, at now: Date) -> Double {
        let p = displayedPosition(slider, at: now)
        motions[slider] = nil
        scrubbing[slider] = p
        if spotlight?.slider == slider { cancelGuide() }
        return p
    }

    func scrub(_ slider: Slider, to position: Double) {
        let spec = slider.spec
        var p = min(1, max(0, position))
        // Magnetic default: within 1.5% of the neutral point, stick to it.
        let home = spec.normalized(spec.neutralValue)
        if spec.defaultValue != nil, abs(p - home) < 0.015 { p = home }
        scrubbing[slider] = p
        let v = spec.snap(spec.value(normalized: p))
        if values[slider] != v || (slider == .focusDepth && values[slider] == nil) {
            values[slider] = v == spec.defaultValue ? nil : v
            onUserChange?(slider, v)
        }
    }

    func endScrub(_ slider: Slider) {
        scrubbing[slider] = nil
    }

    /// Double-click / double-tap: back to the default (auto for focus depth).
    func userReset(_ slider: Slider, at now: Date = Date()) {
        let from = displayedPosition(slider, at: now)
        values[slider] = nil
        motions[slider] = SliderMotion(glide: Glide(from: from, to: position(slider), start: now, spring: .snappy,
                                                    epsilon: 0.002), coach: false)
        onUserChange?(slider, slider.spec.defaultValue)
        scheduleSettle()
    }

    func isScrubbing(_ slider: Slider) -> Bool { scrubbing[slider] != nil }

    // MARK: Presentation (pure functions of time)

    /// Knob position 0...1 on screen at `date`.
    func displayedPosition(_ slider: Slider, at date: Date) -> Double {
        if let s = scrubbing[slider] { return s }
        if let m = motions[slider] { return m.glide.value(at: date) }
        return position(slider)
    }

    /// The coach glide on this slider, if one is visible at `date`.
    func coachMotion(_ slider: Slider, at date: Date) -> Glide? {
        guard let m = motions[slider], m.coach, date >= m.glide.start,
              date < m.glide.end.addingTimeInterval(SliderMotion.afterglow) else { return nil }
        return m.glide
    }

    /// True while this slider moves or glows at `date`.
    func isAnimating(_ slider: Slider, at date: Date) -> Bool {
        if scrubbing[slider] != nil { return true }
        guard let m = motions[slider] else { return false }
        return date < m.glide.end.addingTimeInterval(m.coach ? SliderMotion.afterglow : 0)
    }

    // MARK: Internals

    private func position(_ slider: Slider) -> Double {
        let spec = slider.spec
        guard let v = value(slider) else { return spec.normalized(spec.range.lowerBound) }
        return spec.normalized(v)
    }

    private func startCoachGlide(_ slider: Slider, to value: Double?, at now: Date) -> Double? {
        let spec = slider.spec
        let from = displayedPosition(slider, at: now)
        let velocity = motions[slider]?.glide.velocity(at: now) ?? 0
        scrubbing[slider] = nil
        let applied = value.map { spec.snap($0) }
        values[slider] = applied == spec.defaultValue ? nil : applied
        motions[slider] = SliderMotion(
            glide: Glide(from: from, to: position(slider), velocity: velocity, start: now,
                         spring: reduceMotion ? .snappy : .glide, epsilon: 0.002),
            coach: true)
        scheduleSettle()
        return applied ?? spec.defaultValue
    }

    private func sleep(until date: Date) async {
        let s = date.timeIntervalSinceNow
        guard s > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000))
    }

    private func scheduleSpotlightClear(after date: Date) {
        spotlightTask?.cancel()
        let mine = (spotlight?.start, generation)
        spotlightTask = Task { @MainActor [weak self] in
            await self?.sleep(until: date)
            guard !Task.isCancelled, let self, (self.spotlight?.start, self.generation) == mine else { return }
            self.spotlight = nil
            self.banner = nil
        }
    }

    private func scheduleSettle() {
        settleTask?.cancel()
        guard let last = motions.values.map({ $0.glide.end.addingTimeInterval($0.coach ? SliderMotion.afterglow : 0) }).max()
        else { return }
        settleTask = Task { @MainActor [weak self] in
            await self?.sleep(until: last.addingTimeInterval(0.05))
            guard !Task.isCancelled, let self else { return }
            let now = Date()
            self.motions = self.motions.filter { now < $0.value.glide.end.addingTimeInterval($0.value.coach ? SliderMotion.afterglow : 0) }
            if !self.motions.isEmpty { self.scheduleSettle() }
        }
    }
}

struct SliderMotion: Equatable {
    /// How long the amber trail and knob glow linger after a coach glide lands.
    static let afterglow = 1.4
    var glide: Glide
    var coach: Bool
}

extension SliderSpec {
    /// 0...1 position of a value on the track (focus depth uses a log scale).
    func normalized(_ v: Double) -> Double {
        let r = range
        if slider == .focusDepth {
            return min(1, max(0, log(max(v, r.lowerBound) / r.lowerBound) / log(r.upperBound / r.lowerBound)))
        }
        return min(1, max(0, (v - r.lowerBound) / (r.upperBound - r.lowerBound)))
    }

    /// Value at a 0...1 track position.
    func value(normalized p: Double) -> Double {
        let r = range, t = min(1, max(0, p))
        if slider == .focusDepth { return r.lowerBound * pow(r.upperBound / r.lowerBound, t) }
        return r.lowerBound + t * (r.upperBound - r.lowerBound)
    }
}
