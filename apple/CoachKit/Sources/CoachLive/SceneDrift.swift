import Foundation

/// Tells, from the thumbnails of the frames sent to Gemini, when the camera points somewhere new.
/// A plain value type fed with (thumbnail, time) samples, so it can be unit-tested with synthetic clocks.
///
/// - **shift**: the picture changed completely versus the subject anchor and stayed changed for
///   `shiftHold` seconds. Reported once, then the current view becomes the new anchor. Sent frames
///   go out at most once a second, so a quick swing away and back holds the "away" frame for only
///   ~1.0–1.25 s and stays below the 1.5 s hold.
/// - **moved**: a moderate change versus the ready anchor (set when the coach said the shot is
///   ready), held for `movedHold` seconds. Reported once, then the ready anchor is cleared.
///
/// Thumbnails are compared after matching exposure (`compare`), so an EV change or auto exposure
/// doesn't count as a new view. Measured on the 8 `web/public/samples/*.jpg` (0.8 centre crops,
/// 16×16 luma, exposure-matched; mean / changedFraction):
/// - different photos (28 pairs): mean ≥ 0.113 (median 0.177), changed ≥ 0.543 (median 0.734)
/// - same photo ×1.15…×1.3 brighter or ×0.8…×0.6 darker: mean ≤ 0.026, changed ≤ 0.051
///   (without exposure matching ×1.3 gives 0.135 / 0.875, i.e. a false "new scene")
/// - shifted 2 %: mean ≤ 0.048, changed ≤ 0.195; shifted 5 %: median 0.075 / 0.33, max 0.110 / 0.551
/// - shifted 10 %: median 0.105 / 0.46; zoomed 0.8→0.7: median 0.074 / 0.35; 0.8→0.9: 0.063 / 0.29
///
/// So shift = changed ≥ 0.50 and mean ≥ 0.10 catches every pair of different photos; big reframes
/// (≥10 %) of the same subject can also trigger it, which the `[scene]` turn tells Gemini to ignore.
/// Moved = changed ≥ 0.25 or mean ≥ 0.06 ignores hand shake (2 %) and exposure, catches ~5 % moves.
public struct SceneDrift: Sendable {
    public enum Event: Sendable, Equatable {
        /// The view changed completely versus the subject anchor (numbers are vs that anchor).
        case shift(mean: Float, changedFraction: Float)
        /// The view moved off the ready framing.
        case moved(mean: Float, changedFraction: Float)
    }

    public var shiftMean: Float = 0.10
    public var shiftChanged: Float = 0.50
    public var shiftHold: TimeInterval = 1.5
    public var movedMean: Float = 0.06
    public var movedChanged: Float = 0.25
    public var movedHold: TimeInterval = 0.6

    public private(set) var subjectAnchor: LumaThumbnail?
    public private(set) var readyAnchor: LumaThumbnail?
    private var subjectPending = false
    private var readyPending = false
    private var shiftSince: TimeInterval?
    private var movedSince: TimeInterval?

    public init() {}

    /// Anchors the subject view. `nil` = use the next sample (no frame sent yet).
    public mutating func anchorSubject(_ thumb: LumaThumbnail?) {
        subjectAnchor = thumb
        subjectPending = thumb == nil
        shiftSince = nil
    }

    /// Anchors the ready framing. `nil` = use the next sample.
    public mutating func anchorReady(_ thumb: LumaThumbnail?) {
        readyAnchor = thumb
        readyPending = thumb == nil
        movedSince = nil
    }

    public mutating func clearReady() {
        readyAnchor = nil
        readyPending = false
        movedSince = nil
    }

    public mutating func clearSubject() {
        subjectAnchor = nil
        subjectPending = false
        shiftSince = nil
    }

    /// Feeds the newest sent thumbnail. Returns at most one event (a shift wins over moved).
    public mutating func observe(_ thumb: LumaThumbnail, at now: TimeInterval) -> Event? {
        if subjectPending { subjectAnchor = thumb; subjectPending = false }
        if readyPending { readyAnchor = thumb; readyPending = false }
        var event: Event?
        if let ready = readyAnchor {
            let d = Self.compare(ready, thumb)
            if d.mean >= movedMean || d.changedFraction >= movedChanged {
                let since = movedSince ?? now
                movedSince = since
                if now - since >= movedHold {
                    event = .moved(mean: d.mean, changedFraction: d.changedFraction)
                    clearReady()
                }
            } else {
                movedSince = nil
            }
        }
        if let anchor = subjectAnchor {
            let d = Self.compare(anchor, thumb)
            if d.mean >= shiftMean && d.changedFraction >= shiftChanged {
                let since = shiftSince ?? now
                shiftSince = since
                if now - since >= shiftHold {
                    event = .shift(mean: d.mean, changedFraction: d.changedFraction)
                    anchorSubject(thumb)
                    clearReady()
                }
            } else {
                shiftSince = nil
            }
        }
        return event
    }

    /// `difference(to:)` after scaling `sample` to the anchor's mean luma (gain 0.5…2), so exposure
    /// changes don't count as a different view.
    public static func compare(_ anchor: LumaThumbnail, _ sample: LumaThumbnail) -> (mean: Float, changedFraction: Float) {
        let ma = Float(anchor.pixels.reduce(0) { $0 + Int($1) }) / Float(anchor.pixels.count)
        let mb = Float(sample.pixels.reduce(0) { $0 + Int($1) }) / Float(sample.pixels.count)
        let gain = min(2, max(0.5, ma / max(mb, 1)))
        guard abs(gain - 1) > 0.01 else { return anchor.difference(to: sample) }
        let scaled = LumaThumbnail(pixels: sample.pixels.map { UInt8(clamping: Int((Float($0) * gain).rounded())) })
        return anchor.difference(to: scaled)
    }
}
