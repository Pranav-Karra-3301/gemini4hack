import Foundation

/// Where Core and the web viewer live. Defaults suit the dev checkout; each can be overridden by
/// an environment variable or a launch argument (`-coreURL http://127.0.0.1:8807`, read through
/// UserDefaults' argument domain).
enum StudioConfig {
    /// Core's base URL. `COACH_CORE_URL` / `-coreURL`, else `http://127.0.0.1:8787`.
    static var coreURL: URL {
        if let s = setting(env: "COACH_CORE_URL", key: "coreURL"), let u = URL(string: s) { return u }
        return URL(string: "http://127.0.0.1:8787")!
    }

    static var corePort: Int { coreURL.port ?? 8787 }

    /// `server/` in the checkout. `COACH_SERVER_DIR` / `-serverDir`, else found relative to this
    /// source file (dev builds) or by walking up from the app bundle.
    static var serverDir: URL {
        if let s = setting(env: "COACH_SERVER_DIR", key: "serverDir") { return URL(fileURLWithPath: s) }
        // apple/CoachStudio/Sources/CoachStudio/StudioConfig.swift → repo/server
        let fromSource = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("server")
        if FileManager.default.fileExists(atPath: fromSource.appendingPathComponent("app.py").path) {
            return fromSource
        }
        var dir = Bundle.main.bundleURL
        for _ in 0..<8 {
            dir.deleteLastPathComponent()
            let cand = dir.appendingPathComponent("server")
            if FileManager.default.fileExists(atPath: cand.appendingPathComponent("app.py").path) { return cand }
        }
        return fromSource
    }

    /// The web demos (Vite). `COACH_WEB_URL` / `-webURL`, else `http://localhost:5320`.
    static var webURL: URL {
        if let s = setting(env: "COACH_WEB_URL", key: "webURL"), let u = URL(string: s) { return u }
        return URL(string: "http://localhost:5320")!
    }

    /// `uv` from PATH, then the usual install locations.
    static func findUV() -> URL? {
        let fm = FileManager.default
        var dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let home = fm.homeDirectoryForCurrentUser.path
        dirs += ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.cargo/bin"]
        for d in dirs {
            let p = (d as NSString).appendingPathComponent("uv")
            if fm.isExecutableFile(atPath: p) { return URL(fileURLWithPath: p) }
        }
        return nil
    }

    private static func setting(env: String, key: String) -> String? {
        if let v = ProcessInfo.processInfo.environment[env], !v.isEmpty { return v }
        if let v = UserDefaults.standard.string(forKey: key), !v.isEmpty { return v }
        return nil
    }
}

/// Dev/QA hooks, all off unless passed as launch arguments (see README "Automation").
enum StudioAutomation {
    /// `-openShot <id|latest>`: open this shot's editor once the library loads.
    static var openShot: String? { UserDefaults.standard.string(forKey: "openShot") }
    /// `-autoCoach YES`: run "Coach me" when the editor opens.
    static var autoCoach: Bool { UserDefaults.standard.bool(forKey: "autoCoach") }
    /// `-coachGoal "make it moody"`: goal for the automatic "Coach me".
    static var coachGoal: String? { UserDefaults.standard.string(forKey: "coachGoal") }
    /// `-talkText "make it warmer"`: start Talk and type this request once the session is live.
    static var talkText: String? { UserDefaults.standard.string(forKey: "talkText") }
    /// `-talkMic NO`: Talk without the microphone/speaker (typed requests only; no permission prompt).
    static var talkMic: Bool {
        UserDefaults.standard.object(forKey: "talkMic") == nil ? true : UserDefaults.standard.bool(forKey: "talkMic")
    }
    /// `-snapshotDir /tmp/x`: write window PNGs there (`-snapshotEvery 0.7` seconds, while a guide
    /// or Talk runs) so QA can see mid-animation frames without screen-recording permission.
    static var snapshotDir: URL? {
        UserDefaults.standard.string(forKey: "snapshotDir").map { URL(fileURLWithPath: $0) }
    }
    static var snapshotEvery: Double {
        let v = UserDefaults.standard.double(forKey: "snapshotEvery")
        return v > 0 ? v : 0.7
    }
    /// `-open3D YES`: open the 3D viewer sheet once the photo loads (snapshots it with `-snapshotDir`).
    static var open3D: Bool { UserDefaults.standard.bool(forKey: "open3D") }
    /// `-saveAfterGuide YES`: `PUT edit` when an automatic guide finishes.
    static var saveAfterGuide: Bool { UserDefaults.standard.bool(forKey: "saveAfterGuide") }
    /// `-exportTo /tmp/x.jpg`: export a full-size JPEG when an automatic guide finishes.
    static var exportTo: URL? { UserDefaults.standard.string(forKey: "exportTo").map { URL(fileURLWithPath: $0) } }
    /// `-showDetails YES`: open the details panel in the editor.
    static var showDetails: Bool { UserDefaults.standard.bool(forKey: "showDetails") }
    /// `-showPairing YES`: open the pairing sheet on launch.
    static var showPairing: Bool { UserDefaults.standard.bool(forKey: "showPairing") }
}
