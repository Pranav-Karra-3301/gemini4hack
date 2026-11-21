import Foundation
import Observation
import CoachAPI
import CoachModels

/// Finds or starts Coach Core and keeps an eye on it.
///
/// On launch it asks `/api/health`. If Core answers, it's used as is (and never stopped by us).
/// Otherwise CoachStudio starts it as a child process
/// (`uv run --no-sync uvicorn app:app --host 0.0.0.0 --port 8787` in `server/`, `COACH_LAN=1`),
/// captures its output for the log window, and stops it on quit.
@MainActor
@Observable
final class CoreSupervisor {
    enum Phase: Equatable {
        case checking
        /// Core answers. `ownedByUs` = we started it.
        case running(ownedByUs: Bool)
        case starting
        case failed(String)
    }

    private(set) var phase: Phase = .checking
    private(set) var health: Health?
    /// Last health round trip.
    private(set) var healthMs: Int?
    private(set) var logLines: [String] = []
    /// Bumped on every appended log chunk (the log view scrolls on it).
    private(set) var logVersion = 0

    let client: CoachClient
    let baseURL: URL

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var monitorTask: Task<Void, Never>?
    @ObservationIgnored private var partialLine = ""
    private static let maxLogLines = 4000

    init(baseURL: URL = StudioConfig.coreURL) {
        self.baseURL = baseURL
        self.client = CoachClient(baseURL: baseURL)
    }

    var isUp: Bool { if case .running = phase { return true } else { return false } }
    var ownsProcess: Bool { process != nil }

    /// Model warmth for the status pill: "warm" when every heavy model is loaded.
    var warmth: String {
        guard let models = health?.models else { return isUp ? "up" : "offline" }
        let states = ["depth", "segment"].compactMap { models[$0]?.stringValue }
        if states.contains("error") { return "error" }
        if states.isEmpty { return "up" }
        if states.allSatisfy({ $0 == "warm" }) { return "warm" }
        if states.contains("warm") { return "warming" }
        return "cold"
    }

    func boot() async {
        guard monitorTask == nil else { return }
        phase = .checking
        appendLog("CoachStudio: checking Core at \(baseURL.absoluteString)")
        if await probe() {
            phase = .running(ownedByUs: false)
            appendLog("CoachStudio: Core is already running; using it (it keeps running when CoachStudio quits).")
        } else {
            await start()
        }
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard let self else { return }
                await self.tick()
            }
        }
    }

    /// One health poll; restarts nothing (a crashed child shows as failed with its log).
    private func tick() async {
        let ok = await probe()
        switch phase {
        case .running where !ok:
            phase = process == nil ? .failed("Core stopped answering") : .starting
        case .checking, .failed, .starting:
            if ok { phase = .running(ownedByUs: process != nil) }
        default: break
        }
    }

    @discardableResult
    private func probe() async -> Bool {
        let t0 = Date()
        do {
            let h = try await client.health()
            health = h
            healthMs = Int(Date().timeIntervalSince(t0) * 1000)
            return h.ok
        } catch {
            healthMs = nil
            return false
        }
    }

    /// Starts Core as a child process and waits (up to 90 s) for health.
    func start() async {
        guard process == nil else { return }
        guard let uv = StudioConfig.findUV() else {
            phase = .failed("uv not found on PATH or in /opt/homebrew/bin")
            appendLog("CoachStudio: uv not found; install it (brew install uv) or start Core yourself.")
            return
        }
        let dir = StudioConfig.serverDir
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("app.py").path) else {
            phase = .failed("server/ not found at \(dir.path)")
            appendLog("CoachStudio: no app.py in \(dir.path); pass -serverDir <path>.")
            return
        }
        phase = .starting
        let p = Process()
        p.executableURL = uv
        p.arguments = ["run", "--no-sync", "uvicorn", "app:app", "--host", "0.0.0.0", "--port", String(StudioConfig.corePort)]
        p.currentDirectoryURL = dir
        var env = ProcessInfo.processInfo.environment
        env["COACH_LAN"] = "1"
        env["COACH_PORT"] = String(StudioConfig.corePort)  // what /api/pair and Bonjour advertise
        env["PYTHONUNBUFFERED"] = "1"
        env["PATH"] = (env["PATH"].map { $0 + ":" } ?? "") + "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else { h.readabilityHandler = nil; return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in self?.appendLog(chunk: text) }
        }
        p.terminationHandler = { [weak self] proc in
            let code = proc.terminationStatus
            Task { @MainActor in
                guard let self else { return }
                self.appendLog("CoachStudio: Core exited (status \(code)).")
                self.process = nil
                if case .running = self.phase {} else if case .starting = self.phase {
                    self.phase = .failed("Core exited with status \(code); see the log")
                }
            }
        }
        appendLog("CoachStudio: starting Core: \(uv.path) \(p.arguments!.joined(separator: " "))  (in \(dir.path), COACH_LAN=1)")
        do {
            try p.run()
        } catch {
            phase = .failed("couldn't start uv: \(error.localizedDescription)")
            return
        }
        process = p
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline, process != nil {
            if await probe() {
                phase = .running(ownedByUs: true)
                appendLog("CoachStudio: Core is up.")
                return
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        if process != nil { phase = .failed("Core didn't answer within 90 s; see the log") }
    }

    /// Stops the child process if we started it: SIGINT (uvicorn's graceful stop, uv forwards it),
    /// then SIGTERM, then SIGKILL. Blocks up to ~5 s; called from `applicationWillTerminate`.
    func stopIfOwned() {
        monitorTask?.cancel()
        guard let p = process, p.isRunning else { return }
        let pid = p.processIdentifier
        p.interrupt()
        if !wait(p, seconds: 3.5) {
            p.terminate()
            if !wait(p, seconds: 1.5) { kill(pid, SIGKILL) }
        }
        process = nil
    }

    private func wait(_ p: Process, seconds: Double) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while p.isRunning && Date() < end { usleep(50_000) }
        return !p.isRunning
    }

    // MARK: Log

    func appendLog(_ line: String) {
        logLines.append(line)
        trimLog()
    }

    private func appendLog(chunk: String) {
        let text = partialLine + chunk
        var lines = text.components(separatedBy: "\n")
        partialLine = lines.removeLast()
        // tqdm-style progress bars redraw with \r: keep the last state only.
        logLines.append(contentsOf: lines.map { $0.components(separatedBy: "\r").last(where: { !$0.isEmpty }) ?? "" })
        trimLog()
    }

    private func trimLog() {
        if logLines.count > Self.maxLogLines { logLines.removeFirst(logLines.count - Self.maxLogLines) }
        logVersion &+= 1
    }
}
