import AppKit
import CoreImage
import Foundation
import Metal
import Observation
import CoachAPI
import CoachEdit
import CoachModels
import CoachUI

/// One open shot in the editor: its images (photo, depth, masks), analysis (regions, scores,
/// suggestion), the slider state, and the guided "Coach me" sequence.
@MainActor
@Observable
final class EditorModel {
    /// One Metal device + CIContext for the whole app (creating a context costs ~50 ms).
    static let device: MTLDevice? = MTLCreateSystemDefaultDevice()
    static let renderer = EditRenderer(device: device)
    static let displaySpace = CGColorSpace(name: CGColorSpace.displayP3)!

    let shotID: String
    let client: CoachClient
    let sliders = EditSlidersModel()

    private(set) var shot: Shot?
    /// The analysis-size photo (`image.jpg`, long side 1536): what depth and masks align with.
    /// Kept as the same instance for every render so CoachEdit's depth caches hit.
    private(set) var source: CIImage?
    private(set) var depth: CIImage?
    private(set) var masks: [String: CIImage] = [:]
    /// Mask PNGs (raw bytes) for the overlays.
    private(set) var maskImages: [String: Data] = [:]
    @ObservationIgnored private var washes: [String: NSImage] = [:]
    private(set) var regions: [Region] = []
    private(set) var regionsModel: String?
    private(set) var score: ScoreReport?
    private(set) var savedSuggestion: EditSuggestion?
    private(set) var savedRecipe: EditRecipe = .identity
    private(set) var loadError: String?

    /// Region whose mask drives subject/background light and the default focus depth.
    var subject: String?
    var crop: Crop?
    /// Show the original (hold "Before", or `compare` from the coach).
    var showBefore = false
    /// Region boxes and labels on the photo.
    var showRegions = false
    /// A region picked by the user or `select_region`.
    var selectedRegion: String?

    // Guided edit
    private(set) var guide: Guide?
    private(set) var thinking = false
    private(set) var thinkingSince: Date?
    private(set) var lastSuggestMs: Int?

    /// A transient status line ("Saved", "Exported to …").
    private(set) var toast: String?
    private(set) var saving = false
    private(set) var exporting = false

    @ObservationIgnored private var guideTask: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var loadingAssets = Set<String>()

    struct Guide: Equatable {
        var suggestion: EditSuggestion
        /// The step on screen; -1 before the first.
        var index: Int
        var autoplay: Bool
        /// Slider values when the guide started (prev walks back to these).
        var base: [Slider: Double]
        /// "Suggested by Core" or the typed goal.
        var origin: String
        var count: Int { suggestion.steps.count }
        var isFinished: Bool { index >= count - 1 }
        var step: EditStep? { suggestion.steps.indices.contains(index) ? suggestion.steps[index] : nil }
    }

    init(shotID: String, client: CoachClient) {
        self.shotID = shotID
        self.client = client
        sliders.onUserChange = { [weak self] _, _ in self?.userTookOver() }
    }

    // MARK: Derived

    var recipe: EditRecipe { EditRecipe(values: sliders.values, subject: subject, crop: crop) }
    /// Unsaved changes. The subject alone only counts once some slider uses it.
    var isDirty: Bool {
        let r = recipe
        if r.values != savedRecipe.values { return true }
        if (r.crop ?? .full) != (savedRecipe.crop ?? .full) { return true }
        return !r.values.isEmpty && r.subject != savedRecipe.subject
    }
    var subjectMask: CIImage? { subject.flatMap { masks[$0] } }

    /// The region to highlight now: the coach's current step, else the user's pick.
    var highlightedRegion: String? {
        if let r = sliders.spotlight?.region, regions.contains(where: { $0.id == r }) { return r }
        return selectedRegion
    }

    /// The tinted overlay for a region's mask (amber; red for distractions), made once.
    func maskWash(_ rid: String) -> NSImage? {
        let key = rid + (region(rid)?.isRemove == true ? "-x" : "")
        if let w = washes[key] { return w }
        guard let d = maskImages[rid] else { return nil }
        let color = region(rid)?.isRemove == true ? NSColor(red: 1, green: 0.30, blue: 0.24, alpha: 1)
                                                  : NSColor(red: 1, green: 0.647, blue: 0.239, alpha: 1)
        let w = MaskWash.make(maskPNG: d, color: color)
        washes[key] = w
        return w
    }

    func region(_ id: String?) -> Region? { id.flatMap { id in regions.first { $0.id == id } } }

    /// Regions that have a mask (usable as the subject).
    var subjectCandidates: [Region] { regions.filter { masks[$0.id] != nil || maskImages[$0.id] != nil } }

    /// Source aspect after crop (w / h).
    var aspect: CGFloat? {
        guard let s = source else { return nil }
        let c = crop ?? .full
        return (s.extent.width * c.w) / max(1, s.extent.height * c.h)
    }

    /// Space around the photo in the canvas. The bottom keeps the coach caption and dock off the
    /// photo so the image is never covered while you edit.
    struct CanvasInsets: Equatable {
        var top: CGFloat = 24, side: CGFloat = 28, bottom: CGFloat = 150
        func scaled(_ k: CGFloat) -> CanvasInsets { CanvasInsets(top: top * k, side: side * k, bottom: bottom * k) }
    }

    /// Where the photo sits inside a canvas of `size` (aspect fit, centered in the free area).
    /// Top-left origin, in the same units as `size`.
    func fitRect(in size: CGSize, insets: CanvasInsets = CanvasInsets()) -> CGRect {
        guard let a = aspect, size.width > 0, size.height > 0 else { return .zero }
        let avail = CGSize(width: max(1, size.width - 2 * insets.side), height: max(1, size.height - insets.top - insets.bottom))
        var w = avail.width, h = w / a
        if h > avail.height { h = avail.height; w = h * a }
        return CGRect(x: (size.width - w) / 2, y: insets.top + (avail.height - h) / 2, width: w, height: h)
    }

    /// Slider values on screen at `date` (follows coach glides frame by frame), and whether any
    /// slider is still moving.
    func displayedRecipe(at date: Date) -> (EditRecipe, moving: Bool) {
        var r = EditRecipe(subject: subject, crop: crop)
        var moving = false
        for s in sliders.sliders {
            let shown = sliders.displayedValue(s, at: date)
            if shown != sliders.value(s) { moving = true }
            r.set(s, shown)
        }
        return (r, moving)
    }

    /// The frame for the canvas: rendered to fit `size` pixels, centered on ink.
    func frame(size: CGSize, insets: CanvasInsets, at date: Date) -> (CIImage, moving: Bool) {
        let bg = CIImage(color: CIColor(red: 0.031, green: 0.031, blue: 0.039)).cropped(to: CGRect(origin: .zero, size: size))
        guard let source else { return (bg, false) }
        let fit = fitRect(in: size, insets: insets)
        let side = Int(ceil(max(fit.width, fit.height)))
        guard side > 8 else { return (bg, false) }
        let (live, moving) = displayedRecipe(at: date)
        let image: CIImage
        if showBefore {
            image = Self.renderer.render(source: source, depth: nil, subjectMask: nil,
                                         recipe: EditRecipe(crop: crop), quality: .preview(maxSide: side))
        } else {
            image = Self.renderer.render(source: source, depth: depth, subjectMask: subjectMask,
                                         recipe: live, quality: .preview(maxSide: side))
        }
        let e = image.extent
        let k = min(fit.width / e.width, fit.height / e.height)
        // CI is bottom-left origin; the destination is flipped by CoachEdit, so place by fit rect
        // measured from the top.
        let placed = image
            .transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .transformed(by: CGAffineTransform(scaleX: k, y: k))
            .transformed(by: CGAffineTransform(translationX: fit.minX, y: size.height - fit.maxY))
        return (placed.composited(over: bg), moving)
    }

    // MARK: Loading

    func load(initial: Shot?) async {
        if let initial { shot = initial }
        do {
            let s = try await client.shot(id: shotID)
            shot = s
            if let edit = s.edit {
                savedRecipe = edit
                sliders.load(edit.values)
                subject = edit.subject
                crop = edit.crop
            }
            guard let path = s.assets.image.url ?? s.assets.original.url else {
                loadError = "This shot has no image yet."
                return
            }
            let data = try await client.assetData(path)
            source = await Task.detached(priority: .userInitiated) { EditRenderer.sourceImage(data: data) }.value
            if source == nil { loadError = "Couldn't decode the photo." }
            await loadAnalysis(s)
        } catch {
            loadError = describe(error)
        }
    }

    /// A newer record from the library's event stream: pick up stages that finished since.
    func update(_ s: Shot) {
        guard s.id == shotID, s != shot else { return }
        shot = s
        Task { await loadAnalysis(s) }
    }

    private func loadAnalysis(_ s: Shot) async {
        let a = s.assets
        await withTaskGroup(of: Void.self) { group in
            if depth == nil, a.depth.isReady, let url = a.depth.url, claim("depth") {
                group.addTask { @MainActor in
                    if let d = try? await self.client.assetData(url) {
                        self.depth = await Task.detached { EditRenderer.depthImage(pngData: d) }.value
                    }
                    self.loadingAssets.remove("depth")
                }
            }
            if regions.isEmpty, a.regions.isReady, let url = a.regions.url, claim("regions") {
                group.addTask { @MainActor in
                    if let r = try? await self.client.assetJSON(url, as: RegionsResponse.self) {
                        self.regions = r.regions
                        self.regionsModel = r.model
                    }
                    self.loadingAssets.remove("regions")
                }
            }
            if score == nil, a.score.isReady, let url = a.score.url, claim("score") {
                group.addTask { @MainActor in
                    self.score = try? await self.client.assetJSON(url, as: ScoreReport.self)
                    self.loadingAssets.remove("score")
                }
            }
            if savedSuggestion == nil, a.suggest.isReady, let url = a.suggest.url, claim("suggest") {
                group.addTask { @MainActor in
                    self.savedSuggestion = try? await self.client.assetJSON(url, as: EditSuggestion.self)
                    self.loadingAssets.remove("suggest")
                }
            }
            if a.masks.status == .done, let urls = a.masks.urls {
                for (rid, url) in urls where masks[rid] == nil && claim("mask-\(rid)") {
                    group.addTask { @MainActor in
                        if let d = try? await self.client.assetData(url) {
                            let ci = await Task.detached { EditRenderer.maskImage(pngData: d) }.value
                            if let ci { self.masks[rid] = ci }
                            self.maskImages[rid] = d
                        }
                        self.loadingAssets.remove("mask-\(rid)")
                    }
                }
            }
        }
        if subject == nil || masks[subject!] == nil && a.masks.status == .done {
            let preferred = savedSuggestion?.subject ?? savedRecipe.subject
            if let p = preferred, masks[p] != nil { subject = p }
            else if subject == nil { subject = regions.first(where: { $0.isFocus && masks[$0.id] != nil })?.id }
        }
        if StudioAutomation.autoCoach, !autoCoachDone, savedSuggestion != nil || a.suggest.status == .error
            || StudioAutomation.coachGoal != nil, source != nil {
            autoCoachDone = true
            coachMe(goal: StudioAutomation.coachGoal)
        }
    }
    @ObservationIgnored private var autoCoachDone = false

    private func claim(_ key: String) -> Bool { loadingAssets.insert(key).inserted }

    // MARK: Coach me (guided edit)

    /// Plays Core's suggestion as a guided sequence. Without a goal and from the untouched photo it
    /// uses the precomputed `suggest.json` (instant); otherwise it asks `POST edit/suggest` with the
    /// current values and the typed goal (~4 s on gemini-4-hydrogen).
    func coachMe(goal: String? = nil) {
        let goal = goal?.trimmingCharacters(in: .whitespacesAndNewlines)
        let typed = (goal?.isEmpty == false) ? goal : nil
        if typed == nil, let s = savedSuggestion, sliders.values == savedRecipe.values || sliders.values.isEmpty {
            startGuide(s, origin: "Core's suggestion")
            return
        }
        guard !thinking else { return }
        thinking = true
        thinkingSince = Date()
        endGuide(keepValues: true)
        Task {
            defer { thinking = false; thinkingSince = nil }
            let t0 = Date()
            do {
                let s = try await client.suggestEdit(shotID: shotID, current: recipe, goal: typed)
                lastSuggestMs = Int(Date().timeIntervalSince(t0) * 1000)
                guard !s.steps.isEmpty else { flash("The coach had nothing to change."); return }
                startGuide(s, origin: typed.map { "“\($0)”" } ?? "Fresh suggestion")
            } catch {
                flash("Coach me failed: \(describe(error))")
            }
        }
    }

    func startGuide(_ s: EditSuggestion, origin: String) {
        guideTask?.cancel()
        sliders.cancelGuide()
        if let subj = s.subject, masks[subj] != nil || maskImages[subj] != nil { subject = subj }
        guide = Guide(suggestion: s, index: -1, autoplay: true, base: sliders.values, origin: origin)
        runAutoplay()
    }

    private func runAutoplay() {
        guideTask?.cancel()
        guideTask = Task { [weak self] in
            // A beat so the summary can be read before the first move.
            try? await Task.sleep(nanoseconds: 700_000_000)
            while let self, !Task.isCancelled, let g = self.guide, g.autoplay, !g.isFinished {
                await self.goTo(g.index + 1)
                guard !Task.isCancelled, let why = self.guide?.step?.why else { break }
                let read = min(3.2, max(1.4, Double(why.count) * 0.045))
                try? await Task.sleep(nanoseconds: UInt64((EditSlidersModel.stepPause + read) * 1e9))
            }
            if let self, !Task.isCancelled, self.guide?.isFinished == true {
                self.guide?.autoplay = false
                await self.afterAutomaticGuide()
            }
        }
    }

    /// Shows step `i` (-1 = before the first): forward one step glides that slider; any other
    /// jump glides every slider that differs to its value at step `i`, then spotlights step `i`.
    func goTo(_ i: Int) async {
        guard var g = guide, i >= -1, i < g.count else { return }
        let steps = g.suggestion.steps
        if i == g.index + 1, let step = steps[safe: i] {
            g.index = i
            guide = g
            await sliders.coachStep(step, index: i + 1, of: g.count)
            return
        }
        // Target values after step i.
        var target = EditRecipe(values: g.base)
        for s in steps.prefix(i + 1) { target.set(s.slider, s.value) }
        var changes: [Slider: Double] = [:]
        var autoFocus = false
        for s in sliders.sliders where sliders.value(s) != target.value(s) {
            if let v = target.value(s) { changes[s] = v } else { autoFocus = true }
        }
        g.index = i
        guide = g
        if autoFocus { await sliders.coachStep(EditStep(slider: .focusDepth, value: nil)) }
        if !changes.isEmpty { await sliders.coachSet(changes, why: nil) }
        if let step = steps[safe: i] { await sliders.coachStep(step, index: i + 1, of: g.count) }
        else { sliders.cancelGuide() }
    }

    func next() {
        guard let g = guide else { return }
        pauseGuide()
        if !g.isFinished { Task { await goTo(g.index + 1) } }
    }

    func prev() {
        guard let g = guide else { return }
        pauseGuide()
        if g.index >= 0 { Task { await goTo(g.index - 1) } }
    }

    func toggleAutoplay() {
        guard var g = guide else { return }
        if g.autoplay { pauseGuide(); return }
        if g.isFinished {  // replay from the start
            g.index = -1
            guide = g
            Task {
                await goTo(-1)
                guide?.autoplay = true
                runAutoplay()
            }
            return
        }
        g.autoplay = true
        guide = g
        runAutoplay()
    }

    /// QA hooks (`-saveAfterGuide`, `-exportTo`), run once.
    private func afterAutomaticGuide() async {
        guard !automationDone, StudioAutomation.autoCoach else { return }
        automationDone = true
        if StudioAutomation.saveAfterGuide { _ = await save() }
        if let url = StudioAutomation.exportTo { await export(to: url) }
        if StudioAutomation.snapshotDir != nil {
            try? await Task.sleep(nanoseconds: 300_000_000)
            WindowSnapshot.save("after_guide")
        }
    }
    @ObservationIgnored private var automationDone = false

    func pauseGuide() {
        guideTask?.cancel()
        guideTask = nil
        guide?.autoplay = false
    }

    /// Closes the guide. `keepValues: false` also walks the sliders back to where it started.
    func endGuide(keepValues: Bool = true) {
        guideTask?.cancel()
        guideTask = nil
        if !keepValues, let g = guide {
            sliders.load(g.base)
        }
        guide = nil
        sliders.cancelGuide()
    }

    private func userTookOver() {
        if guide?.autoplay == true { pauseGuide() }
    }

    // MARK: Edits

    func resetAll() {
        endGuide()
        sliders.reset()
        selectedRegion = nil
    }

    func save() async -> Bool {
        saving = true
        defer { saving = false }
        let r = recipe
        do {
            let s = try await client.putEdit(shotID: shotID, recipe: r)
            shot = s
            savedRecipe = s.edit ?? r
            flash("Saved")
            return true
        } catch {
            flash("Save failed: \(describe(error))")
            return false
        }
    }

    /// Full-resolution JPEG of the current recipe from `original.jpg` (up to 4032 px).
    func export(to url: URL) async {
        exporting = true
        defer { exporting = false }
        let r = recipe
        let t0 = Date()
        do {
            let path = shot?.assets.original.url ?? shot?.assets.image.url ?? "/api/shots/\(shotID)/original.jpg"
            let data = try await client.assetData(path)
            let (depth, mask) = (self.depth, self.subjectMask)
            let jpeg = await Task.detached(priority: .userInitiated) { () -> Data? in
                guard let src = EditRenderer.sourceImage(data: data) else { return nil }
                return await Self.renderer.exportJPEG(source: src, depth: depth, subjectMask: mask, recipe: r)
            }.value
            guard let jpeg else { flash("Export failed: couldn't render"); return }
            try jpeg.write(to: url)
            flash("Exported \(url.lastPathComponent) · \(jpeg.count / 1024) KB · \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
        } catch {
            flash("Export failed: \(describe(error))")
        }
    }

    func requestSplat() async {
        do {
            if let s = try await client.requestSplat(shotID: shotID) { shot = s }
            flash("Making the 3D scene (SHARP, ~7 s)…")
        } catch {
            flash("3D failed: \(describe(error))")
        }
    }

    func flash(_ text: String, seconds: Double = 3.2) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    /// A compact description of the editor state for the Live coach (after reconnects and user edits).
    func stateSummary() -> String {
        let vals = sliders.values.sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.key.rawValue)=\($0.key.spec.format($0.value))" }
        let v = vals.isEmpty ? "all sliders at default" : vals.joined(separator: ", ")
        return "Editor state: \(v). Subject region: \(subject ?? "none")."
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
