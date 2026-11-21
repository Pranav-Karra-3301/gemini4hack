import SwiftUI

/// A damped spring (stiffness / damping / mass), evaluated analytically so time-driven views and
/// SwiftUI animations share one feel. Presets are the JS springs from DESIGN.md §3.
public struct CoachSpring: Hashable, Sendable {
    public var stiffness: Double
    public var damping: Double
    public var mass: Double

    public init(stiffness: Double, damping: Double, mass: Double = 1) {
        self.stiffness = stiffness
        self.damping = damping
        self.mass = mass
    }

    /// 520/34/1: controls snapping to a detent.
    public static let snappy = CoachSpring(stiffness: 520, damping: 34)
    /// 380/22/1: ~10% overshoot, for things that arrive (chips, dots).
    public static let pop = CoachSpring(stiffness: 380, damping: 22)
    /// 220/26/1: lifts and focus moves.
    public static let lift = CoachSpring(stiffness: 220, damping: 26)
    /// 90/15/1: the coach moving a control. Slow enough to watch, settles in ~0.6 s.
    public static let glide = CoachSpring(stiffness: 90, damping: 15)
    /// Critically damped at 4/s: a fling that decelerates like a scroll view, then lands on a detent.
    public static let coast = CoachSpring(stiffness: 16, damping: 8)

    /// The same spring as a SwiftUI animation.
    public var animation: Animation {
        .interpolatingSpring(mass: mass, stiffness: stiffness, damping: damping, initialVelocity: 0)
    }

    /// Displacement from the target and velocity at time `t` (s), starting at displacement `x0`
    /// with velocity `v0` (units/s).
    public func evaluate(x0: Double, v0: Double, t: Double) -> (x: Double, v: Double) {
        let w0 = (stiffness / mass).squareRoot()
        let zeta = damping / (2 * (stiffness * mass).squareRoot())
        if zeta < 0.999 {
            let wd = w0 * (1 - zeta * zeta).squareRoot()
            let a = x0, b = (v0 + zeta * w0 * x0) / wd
            let e = exp(-zeta * w0 * t), c = cos(wd * t), s = sin(wd * t)
            let x = e * (a * c + b * s)
            let v = e * ((b * wd - zeta * w0 * a) * c - (a * wd + zeta * w0 * b) * s)
            return (x, v)
        } else if zeta <= 1.001 {
            let b = v0 + w0 * x0
            let e = exp(-w0 * t)
            return (e * (x0 + b * t), e * (b - w0 * (x0 + b * t)))
        } else {
            let r = (zeta * zeta - 1).squareRoot()
            let r1 = -w0 * (zeta - r), r2 = -w0 * (zeta + r)
            let c2 = (v0 - r1 * x0) / (r2 - r1), c1 = x0 - c2
            let e1 = exp(r1 * t), e2 = exp(r2 * t)
            return (c1 * e1 + c2 * e2, c1 * r1 * e1 + c2 * r2 * e2)
        }
    }

    /// Time (s) until the motion stays within `epsilon` of the target, capped at 4 s.
    public func settleTime(x0: Double, v0: Double, epsilon: Double) -> Double {
        let dt = 1.0 / 120
        var lastOutside = 0.0
        var t = 0.0
        while t <= 4 {
            let (x, v) = evaluate(x0: x0, v0: v0, t: t)
            if abs(x) > epsilon || abs(v) > epsilon * 8 { lastOutside = t }
            t += dt
        }
        return min(4, lastOutside + dt)
    }
}

/// One spring-driven move from `from` to `to`, sampled by time. Retarget by starting a new glide
/// from `value(at:)` with `velocity(at:)`, so motion is always interruptible and never queued.
struct Glide: Sendable, Equatable {
    var from: Double
    var to: Double
    var velocity: Double
    var start: Date
    var spring: CoachSpring
    var duration: Double

    init(from: Double, to: Double, velocity: Double = 0, start: Date, spring: CoachSpring, epsilon: Double) {
        self.from = from
        self.to = to
        self.velocity = velocity
        self.start = start
        self.spring = spring
        self.duration = from == to && velocity == 0
            ? 0 : spring.settleTime(x0: from - to, v0: velocity, epsilon: epsilon)
    }

    var end: Date { start.addingTimeInterval(duration) }

    func value(at date: Date) -> Double {
        let t = date.timeIntervalSince(start)
        if t <= 0 { return from }
        if t >= duration { return to }
        return to + spring.evaluate(x0: from - to, v0: velocity, t: t).x
    }

    func velocity(at date: Date) -> Double {
        let t = date.timeIntervalSince(start)
        if t <= 0 || t >= duration { return t <= 0 ? velocity : 0 }
        return spring.evaluate(x0: from - to, v0: velocity, t: t).v
    }

    /// 0 before the start, 1 once settled.
    func progress(at date: Date) -> Double {
        guard duration > 0 else { return 1 }
        return min(1, max(0, date.timeIntervalSince(start) / duration))
    }
}
