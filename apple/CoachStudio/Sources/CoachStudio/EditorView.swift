import AppKit
import SwiftUI
import UniformTypeIdentifiers
import CoachAPI
import CoachModels
import CoachUI

/// The editor: live CoachEdit preview in the middle, Paper-style sliders on the right, optional
/// details on the left, and the coach dock (Coach me / guided steps / Talk) over the photo.
struct EditorView: View {
    @Environment(LibraryStore.self) private var library
    @State private var model: EditorModel
    @State private var talk = TalkController()
    @State private var showDetails = StudioAutomation.showDetails
    @State private var show3D = false
    @State private var goal = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(shotID: String, client: CoachClient) {
        _model = State(initialValue: EditorModel(shotID: shotID, client: client))
    }

    var body: some View {
        HStack(spacing: 0) {
            if showDetails {
                DetailsPanel(model: model, open3D: { show3D = true })
                    .frame(width: 290)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                Divider().overlay(CoachColor.paper.opacity(0.06))
            }
            canvas
            Divider().overlay(CoachColor.paper.opacity(0.06))
            sidebar.frame(width: 330)
        }
        .background(CoachColor.ink)
        .animation(CoachEase.out(CoachDuration.base), value: showDetails)
        .toolbar { toolbar }
        .navigationTitle(title)
        .task {
            model.sliders.reduceMotion = reduceMotion
            await model.load(initial: library.shot(model.shotID))
        }
        .onChange(of: library.shot(model.shotID)) { _, s in if let s { model.update(s) } }
        .onChange(of: model.sliders.values) { _, _ in talk.userEdited() }
        .onDisappear { talk.stop(); model.endGuide() }
        .sheet(isPresented: $show3D) {
            SplatViewerSheet(model: model)
        }
        .task(id: "snapshots") { await snapshotLoop() }
        .task(id: "auto3d") {
            guard StudioAutomation.open3D else { return }
            while model.source == nil { try? await Task.sleep(nanoseconds: 300_000_000) }
            show3D = true
            for (delay, label) in [(4.0, "3d_loading"), (14.0, "3d_scene"), (30.0, "3d_later")] {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1e9))
                WindowSnapshot.save(label)
            }
        }
        .task(id: "autotalk") {
            guard StudioAutomation.talkText != nil else { return }
            while model.source == nil || model.masks.isEmpty { try? await Task.sleep(nanoseconds: 300_000_000) }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            talk.start(editor: model)
        }
    }

    private var title: String {
        if let d = model.shot?.createdDate {
            return d.formatted(date: .abbreviated, time: .shortened)
        }
        return model.shotID
    }

    // MARK: Canvas

    private var canvas: some View {
        GeometryReader { geo in
            let insets = EditorModel.CanvasInsets()
            let fit = model.fitRect(in: geo.size, insets: insets)
            ZStack(alignment: .topLeading) {
                PreviewCanvas(model: model, insets: insets)
                if (model.crop ?? .full).isIdentity {
                    RegionOverlay(model: model, fit: fit)
                }
                if model.showBefore {
                    Text("BEFORE")
                        .font(CoachFont.mono(11, weight: .semibold))
                        .tracking(CoachFont.labelTracking(11))
                        .foregroundStyle(CoachColor.paper)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .coachGlass(cornerRadius: 10)
                        .offset(x: fit.minX + 12, y: fit.minY + 12)
                        .transition(.opacity)
                }
                if model.source == nil {
                    loadingState.frame(width: geo.size.width, height: geo.size.height)
                }
                VStack(spacing: 12) {
                    Spacer()
                    CoachCaption(model: model, talk: talk)
                    CoachDock(model: model, talk: talk, goal: $goal)
                }
                .padding(.bottom, 18)
                .frame(width: geo.size.width, height: geo.size.height)
                if let toast = model.toast {
                    Text(toast)
                        .font(CoachFont.mono(11.5))
                        .foregroundStyle(CoachColor.paper)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .coachGlass(cornerRadius: 12)
                        .frame(width: geo.size.width)
                        .padding(.top, 14)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(CoachEase.out(CoachDuration.base), value: model.toast)
            .animation(CoachEase.out(CoachDuration.fast), value: model.showBefore)
        }
        .frame(minWidth: 520, minHeight: 480)
    }

    @ViewBuilder private var loadingState: some View {
        if let err = model.loadError {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 26))
                Text(err).font(CoachFont.mono(12)).multilineTextAlignment(.center)
            }
            .foregroundStyle(CoachColor.paper62)
        } else {
            ProgressView().controlSize(.small).tint(CoachColor.paper55)
        }
    }

    // MARK: Sidebar (sliders)

    private var sidebar: some View {
        VStack(spacing: 0) {
            subjectRow
                .padding(.horizontal, 16).padding(.vertical, 12)
                .background(CoachColor.ink.opacity(0.35))
                .overlay(alignment: .bottom) { Rectangle().fill(CoachColor.paper.opacity(0.07)).frame(height: 1) }
            EditSliderPanel(model: model.sliders)
                .frame(maxHeight: .infinity)
            sidebarFooter
        }
        .background(CoachColor.graphite.opacity(0.55))
    }

    private var subjectRow: some View {
        HStack(spacing: 8) {
            Text("SUBJECT")
                .font(CoachFont.mono(10.5)).tracking(CoachFont.labelTracking(10.5))
                .foregroundStyle(CoachColor.paper55)
            Spacer()
            Menu {
                ForEach(model.subjectCandidates) { r in
                    Button {
                        model.subject = r.id
                        model.selectedRegion = r.id
                    } label: {
                        Text("\(r.id.uppercased()) · \(r.note.prefix(48))")
                    }
                }
                if model.subjectCandidates.isEmpty { Text("Masks are still being made…") }
            } label: {
                HStack(spacing: 6) {
                    Circle().fill(model.subject == nil ? CoachColor.paper45 : CoachColor.safelight).frame(width: 6, height: 6)
                    Text(model.subject.map { $0.uppercased() } ?? (model.shot?.assets.masks.status.isInProgress == true ? "MASKING…" : "NONE"))
                        .font(CoachFont.mono(11, weight: .semibold))
                        .foregroundStyle(CoachColor.paper)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .onHover { inside in model.selectedRegion = inside ? model.subject : nil }
        }
    }

    private var sidebarFooter: some View {
        HStack(spacing: 8) {
            Button { model.resetAll() } label: {
                Label("Reset", systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(StudioButtonStyle(kind: .quiet))
            .disabled(model.sliders.values.isEmpty)
            Spacer()
            if PreviewCanvas.Coordinator.lastEncodeMs > 0 {
                Text(String(format: "frame %.1f ms", PreviewCanvas.Coordinator.lastEncodeMs))
                    .font(CoachFont.mono(10)).foregroundStyle(CoachColor.paper45)
            }
            Button { Task { await model.save() } } label: {
                Text(model.saving ? "Saving…" : (model.isDirty ? "Save" : "Saved"))
            }
            .buttonStyle(StudioButtonStyle(kind: model.isDirty ? .primary : .quiet))
            .disabled(!model.isDirty || model.saving)
            .keyboardShortcut("s", modifiers: .command)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(CoachColor.ink.opacity(0.35))
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Toggle(isOn: $showDetails) { Label("Details", systemImage: "info.circle") }
                .keyboardShortcut("i", modifiers: .command)
                .help("Capture settings, scores, depth, 3D (⌘I)")
            Toggle(isOn: Bindable(model).showRegions) { Label("Regions", systemImage: "viewfinder") }
                .keyboardShortcut("r", modifiers: .command)
                .help("Show Argon's regions (⌘R)")
            Toggle(isOn: Bindable(model).showBefore) { Label("Before", systemImage: "square.split.2x1") }
                .keyboardShortcut("\\", modifiers: [])
                .help("Before / after (\\)")
            Button { export() } label: { Label("Export JPEG", systemImage: "square.and.arrow.up") }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(model.source == nil || model.exporting)
                .help("Export a full-size JPEG (⌘E)")
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.jpeg]
        panel.nameFieldStringValue = "\(model.shotID)-edit.jpg"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.export(to: url) }
    }

    // MARK: QA snapshots

    private func snapshotLoop() async {
        guard StudioAutomation.snapshotDir != nil else { return }
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        WindowSnapshot.save("editor_open")
        var shots = 0
        var idleAfterActivity = 0
        while !Task.isCancelled && shots < 60 {
            try? await Task.sleep(nanoseconds: UInt64(StudioAutomation.snapshotEvery * 1e9))
            let busy = model.thinking || model.guide?.autoplay == true || talk.isActive
            if busy {
                let label = model.guide.map { "guide_step\($0.index + 1)of\($0.count)" }
                    ?? (model.thinking ? "thinking" : "talk_\(talk.toolCount)tools")
                WindowSnapshot.save(label)
                shots += 1
                idleAfterActivity = 0
            } else if shots > 0 && idleAfterActivity < 2 {
                idleAfterActivity += 1
                WindowSnapshot.save("settled")
            }
        }
    }
}

