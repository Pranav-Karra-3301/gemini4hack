import AVFAudio
import CoreImage
import Foundation
import Observation
import CoachAPI
import CoachEdit
import CoachLive
import CoachModels

/// Talk to edit an opened shot: an edit-mode Gemini Live session (Core mints the token with the
/// shot's regions, masks, looks and current sliders baked into the prompt). Gemini drives the
/// recipe through the edit tools (`edit_step`, `set_sliders`, `add_mask`, `set_layer`,
/// `remove_layer`, `apply_look`, `set_look_strength`, ...); each call is answered with what was
/// actually applied, the way the Mac's `TalkController` does. The shot viewer renders `recipe`
/// with `EditRenderer`; masks and looks the tools need are fetched and registered on `renderer`.
@MainActor
@Observable
final class VoiceEdit {
    enum State: Equatable { case idle, connecting, live, failed(String) }

    private(set) var state: State = .idle
    /// The session is open (connecting or live): the mic key shows on.
    var isLive: Bool { state == .connecting || state == .live }
    /// What Gemini is saying in the current exchange (its output transcript).
    private(set) var caption: String?
    /// What the user said in the current exchange.
    private(set) var heard: String?
    /// The edit: global sliders, local layers and the look. Render this.
    private(set) var recipe: EditRecipe = .identity
    /// `compare` tool: show the original while true.
    private(set) var showBefore = false
    /// `select_region` tool: a region id to highlight, or nil.
    private(set) var highlight: String?
    /// The layer `set_layer` edits when it omits `layer_id` (the one `add_mask` just added).
    private(set) var selectedLayer: String?
    /// A slow tool in flight ("look" while a new look is designed, 10 to 20 s), else nil.
    private(set) var working: String?

    var values: [String: Double] { recipe.namedValues }
    var layers: [EditLayer] { recipe.layers ?? [] }
    var look: LookRef? { recipe.look }

    /// Masks and looks are registered here as tools need them. Set it before `start`, or call
    /// `register(into:)` once the viewer has made its renderer.
    @ObservationIgnored weak var renderer: EditRenderer?

    @ObservationIgnored private var client: CoachClient?
    @ObservationIgnored private var shotID: String?
    @ObservationIgnored private var session: LiveSession?
    @ObservationIgnored private var audio: LiveAudio?
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var toolChain: Task<Void, Never>?
    @ObservationIgnored private var glideTask: Task<Void, Never>?
    @ObservationIgnored private var lineDone = false
    @ObservationIgnored private var seeded = false
    @ObservationIgnored private var maskURLs: [String: String] = [:]
    @ObservationIgnored private var maskAreas: [String: Double] = [:]
    @ObservationIgnored private var loadedMasks: [String: CIImage] = [:]
    @ObservationIgnored private var looksList: [LookRow] = []
    @ObservationIgnored private var loadedLooks: [String: EditLook] = [:]
    @ObservationIgnored private var lookNames: [String: String] = [:]
    @ObservationIgnored private var photoSize = CGSize(width: 3, height: 4)

    // MARK: Public API

    /// Opens the session for `shotID` and starts the mic. Returns once connected (or failed).
    func start(client: CoachClient, shotID: String) async {
        guard !isLive else { return }
        self.client = client
        self.shotID = shotID
        state = .connecting
        caption = nil; heard = nil; lineDone = false
        let assets = Task { await self.loadShot(client: client, shotID: shotID) }

        let session = LiveSession()
        self.session = session
        let audio = LiveAudio()
        self.audio = audio
        eventsTask = Task { [weak self] in
            for await ev in session.events { self?.handle(ev) }
        }
        let micOK = await LiveAudio.requestMicrophoneAccess()
        if micOK { audio.attach(to: session) } else { session.audioOutput = audio }
        await assets.value  // the token's prompt should see the shot's saved edit
        // Reads the recipe at mint time (also on re-mints after a reconnect).
        let mint: @Sendable () async throws -> LiveTokenResponse = { [weak self] in
            let (values, subject, context) = await self?.tokenState() ?? (nil, nil, "")
            return try await client.liveToken(.edit(shotId: shotID, context: context, values: values, subject: subject))
        }
        do {
            async let mic: Void = startAudio(audio)
            try await session.start(liveToken: mint)
            await mic
            if self.session === session, state == .connecting { state = .live }
        } catch {
            if self.session === session {
                state = .failed(Self.describe(error))
                teardown()
            }
        }
    }

    func stop() {
        session?.stop()
        teardown()
        state = .idle
    }

    /// Makes "Edit for Me" (or a saved edit) the starting point. While live, Gemini is told.
    func seed(values: [String: Double], layers: [EditLayer] = [], look: LookRef? = nil) {
        var r = EditRecipe(values: SliderValues.clamped(SliderValues.parse(values.mapValues { .number($0) })),
                           subject: recipe.subject, crop: recipe.crop)
        r.layers = layers.isEmpty ? nil : Array(layers.prefix(EditLayer.maxCount))
        r.look = look
        seed(recipe: r)
    }

    func seed(recipe r: EditRecipe) {
        glideTask?.cancel()
        recipe = r
        seeded = true
        selectedLayer = r.layers?.last?.id
        Task { await ensureAssets(for: r) }
        if state == .live { session?.sendContext("[edit] " + stateSummary()) }
    }

    /// Registers every mask and look loaded so far (for a renderer made after `start`).
    func register(into renderer: EditRenderer) {
        self.renderer = renderer
        for (name, m) in loadedMasks { renderer.register(mask: m, named: name) }
        for look in loadedLooks.values { renderer.register(look: look) }
    }

    // MARK: Session plumbing

    private func startAudio(_ audio: LiveAudio) async {
        do {
            try await audio.start()
            let s = AVAudioSession.sharedInstance()
            if s.currentRoute.outputs.contains(where: { $0.portType == .builtInReceiver }) {
                try? s.overrideOutputAudioPort(.speaker)
            }
        } catch {
            print("CoachCam[voice-edit] audio unavailable: \(error)")
        }
    }

    private func teardown() {
        audio?.stop()
        audio = nil
        session = nil
        toolChain?.cancel()
        toolChain = nil
    }

    private func handle(_ ev: LiveEvent) {
        switch ev {
        case .status(let s):
            switch s {
            case .connecting: if state != .live { state = .connecting }
            case .live: state = .live
            case .reconnecting: break
            case .closed: if case .failed = state {} else { state = .idle; teardown() }
            case .error(let m): state = .failed(m); teardown()
            }
        case .toolCall(let id, let name, let argsJSON):
            let prev = toolChain
            toolChain = Task { [weak self] in
                await prev?.value
                await self?.run(id: id, name: name, argsJSON: argsJSON)
            }
        case .toolCallCancelled:
            break
        case .inputTranscript(let t):
            newExchangeIfNeeded()
            heard = (heard ?? "") + t
        case .outputTranscript(let t):
            if lineDone { caption = nil; lineDone = false }
            caption = (caption ?? "") + t
        case .turnComplete:
            lineDone = true
        case .speaking, .interrupted, .audio:
            break
        case .reconnected:
            state = .live
            session?.sendContext("[edit] " + stateSummary())
        }
    }

    private func newExchangeIfNeeded() {
        if lineDone { heard = nil; caption = nil; lineDone = false }
    }

    // MARK: Tools

    private func run(id: String, name: String, argsJSON: String) async {
        guard let session else { return }
        let args = (try? JSONDecoder().decode([String: JSONValue].self, from: Data(argsJSON.utf8))) ?? [:]
        func answer(_ result: [String: Any], _ scheduling: LiveScheduling = .silent) {
            session.respond(to: id, name: name, result: result, scheduling: scheduling)
        }
        func fail(_ error: String) { answer(["ok": false, "error": error], .whenIdle) }

        switch name {
        case "add_mask":
            await addMask(args, answer: { answer($0, .whenIdle) }, fail: fail)
            return
        case "set_layer":
            setLayer(args, answer: { answer($0) }, fail: fail)
            return
        case "remove_layer":
            guard let lid = args["layer_id"]?.stringValue, layers.contains(where: { $0.id == lid }) else {
                fail("no layer \(args["layer_id"]?.stringValue ?? "")"); return
            }
            var r = recipe
            r.layers = layers.filter { $0.id != lid }
            if r.layers?.isEmpty == true { r.layers = nil }
            if selectedLayer == lid { selectedLayer = r.layers?.last?.id }
            glide(to: r)
            answer(["ok": true, "applied": ["removed": lid]])
            return
        case "apply_look":
            await applyLook(args, answer: { answer($0, .whenIdle) }, fail: fail)
            return
        case "set_look_strength":
            guard let s = args["strength"]?.doubleValue, s.isFinite else { fail("strength must be 0 to 1"); return }
            guard let current = recipe.look else { fail("no look applied; call apply_look first"); return }
            var r = recipe
            r.look = s <= 0.005 ? nil : LookRef(id: current.id, strength: min(max(s, 0.01), 1))
            glide(to: r)
            answer(["ok": true, "applied": ["strength": r.look?.strength ?? 0]])
            return
        default:
            break
        }

        guard let tool = EditTool(FunctionCall(id: id, name: name, args: args)) else {
            fail("unknown tool or bad arguments: \(argsJSON.prefix(200))"); return
        }
        switch tool {
        case .editStep(let step):
            showBefore = false
            highlight = step.region
            var r = recipe
            r.set(step.slider, step.value)
            glide(to: r)
            var out: [String: Any] = ["ok": true, "slider": step.slider.rawValue]
            out["applied"] = [step.slider.rawValue: r.value(step.slider).map { $0 as Any } ?? NSNull()]
            if let reg = step.region { out["region"] = reg }
            // As on the Mac: a guided step waits for its answer, so it gets a turn.
            answer(out, .whenIdle)
        case .setSliders(let values, _):
            showBefore = false
            let r = recipe.applying(values)
            glide(to: r)
            answer(["ok": true, "applied": SliderValues.named(values.keys.reduce(into: [:]) { $0[$1] = r[$1] })])
        case .selectRegion(let reg):
            highlight = reg
            answer(["ok": true, "region": reg.map { $0 as Any } ?? NSNull()])
        case .compare(let side):
            showBefore = side == .before
            answer(["ok": true, "show": side.rawValue])
        case .reset:
            var r = recipe
            r.reset()
            selectedLayer = nil
            glide(to: r)
            answer(["ok": true])
        case .saveEdit:
            guard let client, let shotID else { fail("no shot"); return }
            do {
                _ = try await client.putEdit(shotID: shotID, recipe: recipe)
                answer(["ok": true])
            } catch {
                fail("save failed: \(Self.describe(error))")
            }
        }
    }

    private func addMask(_ a: [String: JSONValue], answer: ([String: Any]) -> Void, fail: (String) -> Void) async {
        let target = a["target"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !target.isEmpty else { fail("add_mask needs a target"); return }
        guard layers.count < EditLayer.maxCount else {
            fail("at most \(EditLayer.maxCount) layers; remove one first"); return
        }
        guard let name = await resolveMask(target) else {
            let known = maskURLs.keys.sorted().joined(separator: ", ")
            fail("no mask for \"\(target)\"; masks: \(known.isEmpty ? "none yet" : known)"); return
        }
        var n = layers.count + 1
        while layers.contains(where: { $0.id == "l\(n)" }) { n += 1 }
        let lid = "l\(n)"
        let why = a["why"]?.stringValue ?? ""
        let layer = EditLayer(id: lid, target: String(target.prefix(60)),
                              mask: LayerMask(source: name, feather: 12, edge: .image), why: String(why.prefix(60)))
        var r = recipe
        r.layers = layers + [layer]
        recipe = r
        selectedLayer = lid
        var applied: [String: Any] = ["layer_id": lid, "target": name, "area": maskAreas[name].map { $0 as Any } ?? NSNull()]
        if a["depth_min"]?.doubleValue != nil || a["depth_max"]?.doubleValue != nil {
            applied["note"] = "depth range not supported on this device; the whole mask is used"
        }
        answer(["ok": true, "applied": applied])
    }

    private func setLayer(_ a: [String: JSONValue], answer: ([String: Any]) -> Void, fail: (String) -> Void) {
        let lid = a["layer_id"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? selectedLayer
        guard let lid, let idx = layers.firstIndex(where: { $0.id == lid }) else {
            fail("no layer \(lid ?? "selected"); call add_mask first"); return
        }
        var raw = a["values"]
        if case .string(let s)? = raw, let d = s.data(using: .utf8) { raw = try? JSONDecoder().decode(JSONValue.self, from: d) }
        guard let obj = raw?.objectValue else { fail("set_layer needs values"); return }
        var ls = layers
        for (k, v) in SliderValues.parse(obj) { ls[idx].set(k, v) }
        var r = recipe
        r.layers = ls
        selectedLayer = lid
        showBefore = false
        glide(to: r)
        answer(["ok": true, "applied": ["layer_id": lid, "values": SliderValues.named(ls[idx].values)]])
    }

    private func applyLook(_ a: [String: JSONValue], answer: ([String: Any]) -> Void, fail: (String) -> Void) async {
        guard let client, let shotID else { fail("no shot"); return }
        let strength = min(max(a["strength"]?.doubleValue ?? 0.6, 0.01), 1)
        let variant = a["variant"]?.stringValue == "bold" ? "bold" : "fit"
        let goal = a["goal"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        var row: LookRow?
        if let lid = a["look_id"]?.stringValue { row = looksList.first { $0.id == lid } }
        if row == nil, goal == nil { row = looksList.first { ($0.variant ?? "fit") == variant && $0.goal == nil } }
        do {
            if row == nil {
                working = "look"
                defer { working = nil }
                var req = try CoreExtras.request(client, "/api/shots/\(shotID)/looks", method: "POST", timeout: 60)
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                var body: [String: Any] = ["variant": variant]
                if let goal { body["goal"] = goal }
                req.httpBody = try JSONSerialization.data(withJSONObject: body)
                let (data, resp) = try await URLSession.shared.data(for: req)
                if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw CoreExtras.error(status: http.statusCode, body: data, path: "/api/shots/\(shotID)/looks")
                }
                let made = try JSONDecoder().decode(LookRow.self, from: data)
                looksList.removeAll { $0.id == made.id }
                looksList.append(made)
                row = made
            }
            guard let row else { fail("no look"); return }
            try await loadLook(row)
            var r = recipe
            r.look = LookRef(id: row.id, strength: strength)
            showBefore = false
            glide(to: r, from: { var f = r; f.look = LookRef(id: row.id, strength: 0.01); return f }())
            answer(["ok": true, "applied": ["look_id": row.id, "name": row.name ?? row.id, "strength": strength]])
        } catch {
            fail("look failed: \(Self.describe(error))")
        }
    }

    // MARK: Assets (masks, looks)

    private func loadShot(client: CoachClient, shotID: String) async {
        if let s = try? await client.shot(id: shotID) {
            if let w = s.width, let h = s.height, w > 0, h > 0 { photoSize = CGSize(width: w, height: h) }
            for (rid, url) in s.assets.masks.urls ?? [:] { maskURLs[rid] = url }
            if !seeded, let edit = s.edit { recipe = edit; selectedLayer = edit.layers?.last?.id }
        }
        await loadSemantic(labels: nil, wait: false)
        if let list = try? await client.assetJSON("/api/shots/\(shotID)/looks", as: LookList.self) {
            looksList = list.looks
        }
        await ensureAssets(for: recipe)
    }

    /// Reads the cached semantic masks; `labels` (wait) asks Core to segment those words too.
    private func loadSemantic(labels: [String]?, wait: Bool) async {
        guard let client, let shotID else { return }
        var sem: SemanticMasks?
        if wait {
            guard var req = try? CoreExtras.request(client, "/api/shots/\(shotID)/semantic", method: "POST", timeout: 45)
            else { return }
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["labels": labels ?? []])
            if case let (data, resp)? = try? await URLSession.shared.data(for: req),
               let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                sem = try? JSONDecoder().decode(SemanticMasks.self, from: data)
            }
        } else {
            sem = try? await client.assetJSON("/api/shots/\(shotID)/semantic/semantic.json", as: SemanticMasks.self)
        }
        guard let sem else { return }
        for (name, m) in sem.masks {
            maskURLs[name] = m.url ?? "/api/shots/\(shotID)/semantic/\(name).png"
            if let area = m.area { maskAreas[name] = area }
        }
    }

    /// A mask name for `target`: a known name, a case-insensitive / label match, or (plain words)
    /// a fresh segmentation. "all" is the whole photo. Loads and registers the mask.
    private func resolveMask(_ target: String) async -> String? {
        let t = target.lowercased()
        if t == "all" || t == "whole photo" {
            if loadedMasks["all"] == nil {
                let all = CIImage(color: .white).cropped(to: CGRect(origin: .zero, size: photoSize))
                loadedMasks["all"] = all
                renderer?.register(mask: all, named: "all")
            }
            maskAreas["all"] = 1
            return "all"
        }
        func match() -> String? {
            if maskURLs[target] != nil { return target }
            return maskURLs.keys.first { $0.lowercased() == t }
                ?? maskURLs.keys.first { $0.lowercased().replacingOccurrences(of: "_", with: " ") == t }
        }
        if maskURLs.isEmpty { await loadSemantic(labels: nil, wait: false) }
        var name = match()
        if name == nil {
            await loadSemantic(labels: [target], wait: true)
            name = match()
        }
        guard let name, await loadMask(name) else { return nil }
        return name
    }

    @discardableResult
    private func loadMask(_ name: String) async -> Bool {
        if loadedMasks[name] != nil { return true }
        guard let client, let url = maskURLs[name], let data = try? await client.assetData(url),
              let img = EditRenderer.maskImage(pngData: data) else { return false }
        loadedMasks[name] = img
        renderer?.register(mask: img, named: name)
        return true
    }

    private func loadLook(_ row: LookRow) async throws {
        if loadedLooks[row.id] != nil { return }
        guard let client, let shotID else { return }
        let data = try await client.assetData(row.lut ?? "/api/shots/\(shotID)/looks/\(row.id)/lut.cube")
        let look = try EditLook(id: row.id, cube: String(decoding: data, as: UTF8.self), effects: row.effects)
        loadedLooks[row.id] = look
        lookNames[row.id] = row.name
        renderer?.register(look: look)
    }

    /// Masks and look a seeded / saved recipe reads.
    private func ensureAssets(for r: EditRecipe) async {
        for name in r.layerMaskNames { await loadMask(name) }
        if let id = r.look?.id, let row = looksList.first(where: { $0.id == id }) { try? await loadLook(row) }
    }

    // MARK: Glide

    /// Animates the recipe to `target` (~0.5 s): sliders, layer values and look strength.
    private func glide(to target: EditRecipe, from start: EditRecipe? = nil) {
        glideTask?.cancel()
        let from = start ?? recipe
        glideTask = Task { [weak self] in
            let steps = 12
            for i in 1...steps {
                let k = Self.ease(Double(i) / Double(steps))
                self?.recipe = Self.mix(from, target, k)
                if i < steps { try? await Task.sleep(nanoseconds: 40_000_000) }
                if Task.isCancelled { return }
            }
            self?.recipe = target
        }
    }

    private static func ease(_ t: Double) -> Double { 1 - pow(1 - t, 3) }

    private static func mix(_ a: EditRecipe, _ b: EditRecipe, _ k: Double) -> EditRecipe {
        var r = b
        for s in Slider.allCases {
            let va = a[s], vb = b[s]
            if va != vb { r.set(s, va + (vb - va) * k) }
        }
        if let lb = b.layers {
            r.layers = lb.map { l in
                var out = l
                let old = a.layers?.first { $0.id == l.id }
                for s in EditLayer.sliders {
                    let va = old?[s] ?? 0, vb = l[s]
                    if va != vb { out.set(s, va + (vb - va) * k) }
                }
                return out
            }
        }
        if let lk = b.look, let old = a.look, old.id == lk.id {
            r.look = LookRef(id: lk.id, strength: max(0.01, old.strength + (lk.strength - old.strength) * k))
        }
        return r
    }

    // MARK: Context

    private func tokenState() -> ([String: Double]?, String?, String) {
        (recipe.namedValues, recipe.subject, stateSummary())
    }

    /// The recipe in a few words, for the token prompt and after seeds / reconnects.
    func stateSummary() -> String {
        let vals = recipe.namedValues.sorted { $0.key < $1.key }.map { k, v in
            "\(k)=\(Slider(name: k)?.spec.format(v) ?? String(format: "%.2f", v))"
        }
        var s = "Edit state: " + (vals.isEmpty ? "all sliders at default" : vals.joined(separator: ", ")) + "."
        if !layers.isEmpty {
            s += " Layers: " + layers.map { l in
                let v = SliderValues.named(l.values).sorted { $0.key < $1.key }.map { "\($0.key)=\(String(format: "%.2f", $0.value))" }
                return "\(l.id) on \(l.mask.source)\(v.isEmpty ? "" : " (" + v.joined(separator: ", ") + ")")"
            }.joined(separator: "; ") + "."
        }
        if let lk = recipe.look {
            s += " Look: \(lk.id)\(lookNames[lk.id].map { " \"\($0)\"" } ?? "") at \(String(format: "%.2f", lk.strength))."
        }
        return s
    }

    static func describe(_ error: Error) -> String { CoachSession.describe(error) }
}

/// A row of `GET /api/shots/{id}/looks` (and the body of `POST .../looks`).
private struct LookRow: Decodable, Sendable {
    var id: String
    var name: String?
    var variant: String?
    var goal: String?
    var lut: String?
    var effects: LookEffects?
}

private struct LookList: Decodable, Sendable {
    var looks: [LookRow]
}
