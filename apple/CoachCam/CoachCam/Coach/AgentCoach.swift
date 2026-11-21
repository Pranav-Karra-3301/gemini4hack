import CoachAPI
import CoachLive
import CoachModels
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO

/// The coaching brain for the on-phone agent loop (Gemini 4, function calling): the system
/// prompt and the camera tools, ported from Core's `server/live_setup.py` and `server/cam.py`.
enum CoachBrain {
    static let moves = ["left", "right", "up", "down", "closer", "back", "rotate_left", "rotate_right", "hold"]

    static let system = """
    You are Coach, a calm photographer friend helping someone take a great photo with their phone. \
    Each turn you get the newest viewfinder frame and the camera's state. You act through tools; \
    the tools matter more than words. The user cannot read anything: your text reply is SPOKEN \
    aloud. Reply with no text at all unless a short line really helps: at most 8 words, warm, \
    never narrate tool calls, never describe the scene unless asked, never repeat a line.

    Tools drive the camera screen:
    - guide: makes the viewfinder border glow toward the way the user should move the camera. \
    Use it for every direction. "hold" when the framing is right. With every move (not hold), \
    also pass subject_box (where the subject is now) and target_box (where it should end up), \
    each [x0, y0, x1, y1] from 0 to 1, top-left origin, on the frame as you see it. The \
    viewfinder draws a quiet ghost frame at target_box and slides the tracked subject toward it, \
    so the user sees HOW FAR to move: shift the target box for left/right/up/down, make it \
    SMALLER than the subject box for back and BIGGER for closer (e.g. half the size = a big step \
    back). Keep the spoken line short ("Take a step back"); the frame shows how much.
    - set_camera: turns the real dials (mode, zoom, ISO, shutter, EV, focus, white balance); the \
    dial visibly rolls to the value. Pass only what should change.
    - set_intent: the shot's kind and subject. Call it for every NEW shot.
    - shot_ready: true when the frame is good enough to shoot (the shutter glows). This is \
    "that's it": call it with guide "hold" AND reply with the text "That's it. Take it." (or 2 to \
    4 similar words) in the same turn. Then \
    stay quiet: while it stays ready, call nothing and say nothing.
    - user_reaction: only when the user just said something about the shot or your advice.
    - take_photo: ONLY when the user asks you to take the picture. Never on your own.

    What is the shot now? Look at the newest frame first and compare it with the subject you last \
    set. If it shows a different subject or place, it is a NEW shot: call set_intent, drop all \
    earlier advice, never mention the old subject, coach the new one from scratch. The same \
    subject reframed (closer, lower, new angle) is the same shot. The subject is the one thing the \
    photo is about. If the user says what they want, coach toward exactly that; if they point the \
    camera elsewhere without a word, follow the camera.

    Capture mode: the state names the current mode. "photo" is the default and fits almost \
    everything: buildings, architecture, streets, rooms, landscapes, groups, people in a place, \
    documents, and any scene where the setting matters. A person being in the frame is NOT a \
    reason for portrait. Switch to "portrait" (~2x with depth) only when ONE person, pet or object \
    clearly IS the whole photo: a close head-and-shoulders or a single subject 0.3-2 m away filling \
    much of the frame with background you'd want soft, or when the user asks for it. If the mode \
    is already portrait and the shot is a building, scene, group or wide view, set "photo". \
    "night" only for genuinely dark scenes; "macro" only for tiny things a few cm away. Never \
    switch modes back and forth: change mode at most once per subject, and say why in a few words.

    Coach toward ready, ONE instruction at a time, most important first: 1) subject clear and \
    whole; 2) no clutter crossing or crowding it; 3) placement (a third, or centred for a single \
    symmetric object) and level lines; 4) light and exposure. Object or food on a table: fill at \
    least a third of the frame; upright things from their own height, flat things from straight \
    above. Portrait: eyes on the upper third, never crop at joints. Landscape: horizon on a third \
    and level. Document: straight on, all four corners in. Never flip to the opposite direction \
    unless the frame changed.

    On-screen hint: every guide call carries `hint`, ONE line of at most 32 characters that a \
    person can read at a glance and act on, naming the move and, when it helps, why in 2-3 words \
    ("Tilt up to fit the building", "A little left, off the pole"). Plain words, no numbers or \
    units, no "please". The spoken line can be the same words. What the user just said always \
    outranks what you see: if they asked for something, the hint and the move serve that first.

    Converge. Good enough is ready: call shot_ready true as soon as the essentials are right; \
    after a couple of fixes that worked, it is ready. At most TWO spoken tips per subject before \
    ready (the glow can keep guiding silently). If the view moves off a ready framing, call \
    shot_ready false and guide back.

    When the user speaks ("The user said: ..."), always answer with at least one tool call and a \
    few spoken words. "Hmm, no" means change the plan (user_reaction disappointed, then a clearly \
    different move). "That's good" means user_reaction pleased, guide hold, shot_ready true. \
    "Brighter", "it's too orange", "blur the background" are set_camera changes: make them and \
    say what you changed.

    \(cameraSettings)

    \(directions)

    One turn = a few tool calls at once (usually guide plus maybe set_camera or set_intent), then \
    stop. Don't call the same tool twice in a turn.
    """

    static let cameraSettings = """
    Settings: ev (-3..3) is the simple brightness fix (raise for a dark subject or backlit face, \
    lower for blown skies). Moving subject: shutter 0.002 or faster; handheld never slower than \
    0.033, raise ISO instead; keep ISO low. "auto" hands a setting back to the camera. focus 0 \
    (near) to 1 (far) or "auto"; prefer focus_x/focus_y on the subject. wb_kelvin 2500..9000: \
    HIGHER makes the photo WARMER (~3200 neutralizes warm bulbs, ~5500 daylight). zoom 0.5 to 10 \
    tightens framing when the user can't step closer. The app answers with the values it \
    actually applied: trust those.
    """

    static let directions = """
    Directions are moves of the CAMERA, judged on the frame exactly as you see it (never \
    mirrored). left/right: pan so more of what lies beyond that edge comes in (subject cut off or \
    crowded at that edge). up: tilt or raise (top cut off, or too much floor). down: tilt or lower \
    (bottom cut off, or too much sky/ceiling). closer: subject too small. back: subject too big or \
    cropped on several sides. rotate_left: level lines slope UP to the right. rotate_right: they \
    slope DOWN to the right. hold: the framing works. People must stay fully in frame; in a \
    selfie every move is a small arm move.
    """

    // MARK: Tools (Gemini function declarations)

    private static func tool(_ name: String, _ description: String,
                             _ props: [String: JSONValue] = [:], required: [String] = []) -> JSONValue {
        var decl: [String: JSONValue] = ["name": .string(name), "description": .string(description)]
        if !props.isEmpty {
            var params: [String: JSONValue] = ["type": .string("OBJECT"), "properties": .object(props)]
            if !required.isEmpty { params["required"] = .array(required.map { .string($0) }) }
            decl["parameters"] = .object(params)
        }
        return .object(decl)
    }

    private static func prop(_ type: String, _ description: String? = nil, enum values: [String]? = nil) -> JSONValue {
        var p: [String: JSONValue] = ["type": .string(type)]
        if let description { p["description"] = .string(description) }
        if let values { p["enum"] = .array(values.map { .string($0) }) }
        return .object(p)
    }

    /// A normalised `[x0, y0, x1, y1]` box.
    private static func box(_ description: String) -> JSONValue {
        .object([
            "type": .string("ARRAY"),
            "items": prop("NUMBER"),
            "description": .string(description),
        ])
    }

    /// A number or the string "auto".
    private static func numOrAuto(_ description: String) -> JSONValue {
        .object([
            "anyOf": .array([prop("NUMBER"), prop("STRING", enum: ["auto"])]),
            "description": .string(description),
        ])
    }

    static let tools: [JSONValue] = [
        tool("guide",
             "Glow the viewfinder border toward how the user should move the CAMERA, judged on the frame as you see it. 'hold' when the framing is right.",
             ["direction": prop("STRING", enum: moves),
              "strength": prop("STRING", "How far to move.", enum: ["small", "medium", "large"]),
              "subject_box": box("Where the subject is now: [x0, y0, x1, y1], 0-1, top-left origin."),
              "hint": prop("STRING", "The one line shown on screen, max 32 characters, imperative and concrete, about THIS move: 'A little to the right', 'Tilt up to fit the tower', 'Step back for the whole group', 'Hold it there'. If the user just spoke, it answers what they asked."),
              "target_box": box("Where the subject should end up after the move: [x0, y0, x1, y1], 0-1, top-left origin. Smaller than subject_box = step back, bigger = come closer.")],
             required: ["direction"]),
        tool("set_camera",
             "Turn the camera's dials. Pass only what should change; the matching dial rolls to the new value.",
             ["mode": prop("STRING", "photo = default for buildings, scenes, groups and people in a place; portrait ONLY when one close subject is the whole photo; night = dark; macro = a few cm",
                           enum: CoachModels.CaptureMode.allCases.map(\.rawValue)),
              "zoom": prop("NUMBER", "Device zoom factor, 0.5 to 10"),
              "iso": numOrAuto("ISO, e.g. 100 or 800, or \"auto\""),
              "shutter": numOrAuto("Shutter time in seconds, or \"auto\""),
              "ev": prop("NUMBER", "Exposure compensation, -3 to 3"),
              "focus": numOrAuto("Lens position 0 (near) to 1 (far), or \"auto\""),
              "focus_x": prop("NUMBER", "Focus point x, 0 (left) to 1 (right)"),
              "focus_y": prop("NUMBER", "Focus point y, 0 (top) to 1 (bottom)"),
              "wb_kelvin": numOrAuto("White balance 2500 to 9000 K (higher = warmer photo), or \"auto\""),
              "tint": prop("NUMBER", "-50 (green) to 50 (magenta)"),
              "flash": prop("STRING", enum: FlashMode.allCases.map(\.rawValue)),
              "torch": prop("BOOLEAN"),
              "why": prop("STRING", "Why, at most 8 words")]),
        tool("set_intent",
             "Record the current shot: its kind and main subject. Call it for every new shot, not when the same subject is reframed.",
             ["intent": prop("STRING", enum: ShotIntent.allCases.map(\.rawValue)),
              "subject": prop("STRING", "The main subject, at most 4 words")],
             required: ["intent"]),
        tool("shot_ready",
             "Whether the current frame is ready to shoot (the shutter glows). True as soon as the essentials are right (also guide 'hold'): that's it, then go quiet. False when the view moves off it.",
             ["ready": prop("BOOLEAN")], required: ["ready"]),
        tool("user_reaction",
             "Record how the user reacted to the shot or to your advice. Only right after the user said something.",
             ["reaction": prop("STRING", enum: UserReaction.allCases.map(\.rawValue)),
              "heard": prop("STRING", "What the user said, briefly")],
             required: ["reaction"]),
        tool("take_photo",
             "Take the photo now. Only when the user asks for it.",
             ["reason": prop("STRING", "Why, in a few words")]),
    ]
}

// MARK: - Fast inner loop questions (Gemini Decision 1), from server/cam.py DECIDE_QUESTIONS

extension CoachBrain {
    static let move = GeminiDirect.Choice(
        instructions: "You are a photographer coaching the person holding this camera. Which single move of "
            + "the CAMERA would most improve this photo? Everyone who is part of the shot must end up "
            + "fully in frame (no cropped heads or faces), and place-defining scenery (a landmark, a "
            + "tree tunnel, a sunset, a view) should be shown more, not traded away. In a selfie the "
            + "moves are arm moves. Judge directions on the frame exactly as shown: 'left' means move "
            + "the camera left so more of what is beyond the frame's left edge comes in.",
        criteria: [
            "back": "Move the camera away, or in a selfie extend the arm (zoom out): someone who is part of the shot has a head, face or body cut off at an edge, or the people fill the frame and hide the scenery around them.",
            "closer": "Move the camera toward the subject, or in a selfie bring the phone in: the people or subject are small, with too much empty or distracting space around them, and nobody would get cut off.",
            "down": "Lower the camera or tilt down so more of what is below the BOTTOM edge comes in: the subject is cut off at the bottom (chin, feet, plate) or sits too low, or there is too much empty sky or ceiling above it and no scenery worth showing there.",
            "hold": "Keep the camera where it is: everyone who is part of the shot is fully in frame and the scenery, if any, is shown well.",
            "left": "Pan, step or (in a selfie) swing the arm to the LEFT so more of what is beyond the LEFT edge comes in (everything slides right): someone who is part of the shot is cut off at, or crowded against, the left edge, or the scenery lies to the left.",
            "right": "Pan, step or (in a selfie) swing the arm to the RIGHT so more of what is beyond the RIGHT edge comes in (everything slides left): someone who is part of the shot is cut off at, or crowded against, the right edge, or the scenery lies to the right.",
            "rotate_left": "Roll the camera counter-clockwise: the horizon or other level lines clearly slope UP toward the right side of the frame.",
            "rotate_right": "Roll the camera clockwise: the horizon or other level lines clearly slope DOWN toward the right side of the frame.",
            "up": "Raise the camera or tilt up so more of what is above the TOP edge comes in: a head is cut off at, or crowded against, the top edge, or the place-defining scenery (a landmark, a tree tunnel, a sunset sky) is above the frame or hidden behind the heads; in a selfie, raise the phone and tilt it down a little so the scenery shows above the heads.",
        ])

    /// Core asks this as a true/false ("noul") question; here it is a yes/no choice.
    static let ready = GeminiDirect.Choice(
        instructions: "Is this frame ready to shoot as a good photo of what the user wants?",
        criteria: [
            "yes": "Everyone who is part of the shot is fully in frame (no cropped heads, faces or bodies), the place-defining scenery (if any) shows behind them, and the frame is level, sharp and reasonably exposed; a good photo could be taken right now.",
            "no": "The framing, angle, sharpness or exposure should be fixed first, or there is no clear subject.",
        ])

    static let reaction = GeminiDirect.Choice(
        instructions: "In the audio clip of the user's voice, how does the user feel about the current shot or "
            + "the coach's last suggestion?",
        criteria: [
            "disappointed": "Unhappy or unconvinced: a sigh, 'hmm, no', 'not that', 'I don't like it', a let-down tone.",
            "neutral": "No clear feeling: silence, background noise, or just saying what they want or giving instructions.",
            "pleased": "Happy or approving: 'oh that's good', 'yes, that one', 'perfect', 'love it', an excited or satisfied tone.",
        ])
}

/// Keeps the newest viewfinder frame for the agent loop: a ~512 px JPEG and its 16×16 luma
/// thumbnail, encoded at most every 0.4 s on the camera queue.
final class AgentFrameSink: FrameSink, @unchecked Sendable {
    struct Frame: Sendable {
        var jpeg: Data
        var thumb: LumaThumbnail
        var count: Int
    }

    static let maxDimension = 512
    static let quality = 0.6
    static let interval: TimeInterval = 0.4

    private let lock = NSLock()
    private var _enabled = false
    private var _latest: Frame?
    private var lastEncoded: TimeInterval = 0
    private var count = 0

    var enabled: Bool {
        get { lock.withLock { _enabled } }
        set { lock.withLock { _enabled = newValue; if !newValue { _latest = nil } } }
    }

    var latest: Frame? { lock.withLock { _latest } }

    private func due() -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        return lock.withLock {
            guard _enabled, now - lastEncoded >= Self.interval else { return false }
            lastEncoded = now
            return true
        }
    }

    private func store(_ jpeg: Data?, _ thumb: LumaThumbnail?) {
        guard let jpeg, let thumb else { return }
        lock.withLock {
            count += 1
            _latest = Frame(jpeg: jpeg, thumb: thumb, count: count)
        }
    }

    func offer(pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) {
        guard due() else { return }
        store(LiveFrameEncoder.jpeg(from: pixelBuffer, orientation: orientation,
                                    maxDimension: Self.maxDimension, quality: Self.quality),
              LumaThumbnail(pixelBuffer: pixelBuffer))
    }

    func offer(cgImage: CGImage) {
        guard due() else { return }
        store(LiveFrameEncoder.jpeg(from: cgImage, maxDimension: Self.maxDimension, quality: Self.quality),
              LumaThumbnail(cgImage: cgImage))
    }
}
