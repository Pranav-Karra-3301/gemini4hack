import AppKit
import SwiftUI
import UniformTypeIdentifiers
import CoachAPI
import CoachModels
import CoachUI

@main
struct CoachStudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var core: CoreSupervisor
    @State private var library: LibraryStore

    init() {
        let core = CoreSupervisor()
        _core = State(initialValue: core)
        _library = State(initialValue: LibraryStore(client: core.client))
        AppDelegate.core = core
    }

    var body: some Scene {
        WindowGroup("CoachStudio", id: "main") {
            RootView()
                .environment(core)
                .environment(library)
                .preferredColorScheme(.dark)
                .frame(minWidth: 1100, minHeight: 700)
        }
        .defaultSize(width: 1480, height: 920)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(after: .newItem) {
                Button("Import Photos…") { importPhotos(library) }
                    .keyboardShortcut("o", modifiers: .command)
            }
            CommandMenu("Core") {
                OpenLogButton()
                Button("Pair iPhone…") { NotificationCenter.default.post(name: .showPairing, object: nil) }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
            }
        }

        Window("Core Log", id: "core-log") {
            CoreLogView()
                .environment(core)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 900, height: 560)
    }
}

private struct OpenLogButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Show Core Log") { openWindow(id: "core-log") }
            .keyboardShortcut("l", modifiers: [.command, .shift])
    }
}

@MainActor
func importPhotos(_ library: LibraryStore) {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.image]
    panel.allowsMultipleSelection = true
    panel.message = "Add photos to the Coach library"
    guard panel.runModal() == .OK else { return }
    let urls = panel.urls
    Task { await library.importFiles(urls) }
}

extension Notification.Name {
    static let showPairing = Notification.Name("CoachStudio.showPairing")
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var core: CoreSupervisor?
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `kill`/Ctrl-C from a terminal skip applicationWillTerminate: stop our Core there too.
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler {
                MainActor.assumeIsolated { Self.core?.stopIfOwned() }
                exit(0)
            }
            src.resume()
            signalSources.append(src)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { Self.core?.stopIfOwned() }
    }
}

/// Library → editor navigation, Core boot, and the toolbar's status pill.
struct RootView: View {
    @Environment(CoreSupervisor.self) private var core
    @Environment(LibraryStore.self) private var library
    @State private var path: [String] = []
    @State private var showPairing = StudioAutomation.showPairing
    @State private var autoOpened = false

    var body: some View {
        NavigationStack(path: $path) {
            LibraryView(path: $path)
                .toolbar { libraryToolbar }
                .navigationDestination(for: String.self) { id in
                    EditorView(shotID: id, client: core.client)
                        .toolbar {
                            ToolbarItem(placement: .navigation) { StatusPill() }
                        }
                }
        }
        .background(CoachColor.ink)
        .sheet(isPresented: $showPairing) { PairingSheet(client: core.client, coreUp: core.isUp) }
        .onReceive(NotificationCenter.default.publisher(for: .showPairing)) { _ in showPairing = true }
        .task {
            await core.boot()
            library.start()
        }
        .task(id: "qa-library") {
            guard StudioAutomation.snapshotDir != nil, StudioAutomation.openShot == nil else { return }
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            WindowSnapshot.save(showPairing ? "pairing" : "library")
        }
        .onChange(of: library.shots.first?.id) { _, _ in autoOpen() }
        .onChange(of: library.loaded) { _, _ in autoOpen() }
    }

    @ToolbarContentBuilder private var libraryToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) { StatusPill() }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { showPairing = true } label: { Label("Pair iPhone", systemImage: "qrcode") }
                .help("Show the pairing QR for CoachCam (⇧⌘P)")
            Button { importPhotos(library) } label: { Label("Import", systemImage: "plus") }
                .help("Import photos (⌘O), or drop them on the grid")
        }
    }

    private func autoOpen() {
        guard !autoOpened, let want = StudioAutomation.openShot, library.loaded else { return }
        let id = want == "latest" ? library.shots.first?.id : library.shot(want)?.id
        guard let id else { return }
        autoOpened = true
        path = [id]
    }
}

/// Core status: a dot for model warmth plus the round trip; click for details.
struct StatusPill: View {
    @Environment(CoreSupervisor.self) private var core
    @Environment(\.openWindow) private var openWindow
    @State private var showInfo = false

    var body: some View {
        Button { showInfo.toggle() } label: {
            HStack(spacing: 7) {
                Circle().fill(dotColor).frame(width: 7, height: 7)
                    .shadow(color: core.warmth == "warm" ? CoachColor.safelight.opacity(0.8) : .clear, radius: 4)
                Text(label).font(CoachFont.mono(10.5, weight: .semibold)).tracking(CoachFont.labelTracking(10.5))
                    .foregroundStyle(CoachColor.paper)
                if let ms = core.healthMs, core.isUp {
                    Text("\(ms) ms").font(CoachFont.mono(10)).foregroundStyle(CoachColor.paper45)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(CoachColor.paper.opacity(0.07)))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showInfo, arrowEdge: .bottom) { info }
    }

    private var label: String {
        switch core.phase {
        case .checking: return "CORE · CHECKING"
        case .starting: return "CORE · STARTING"
        case .failed: return "CORE · DOWN"
        case .running: return "CORE · \(core.warmth.uppercased())"
        }
    }

    private var dotColor: Color {
        switch core.phase {
        case .failed: return CoachColor.signal
        case .checking, .starting: return CoachColor.paper45
        case .running:
            switch core.warmth {
            case "warm": return CoachColor.safelight
            case "warming": return CoachColor.safelightHot
            case "error": return CoachColor.signal
            default: return CoachColor.paper
            }
        }
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Coach Core").font(CoachFont.sans(14, weight: .semibold))
            row("URL", core.baseURL.absoluteString)
            switch core.phase {
            case .running(let owned): row("Process", owned ? "started by CoachStudio (stops on quit)" : "already running (left alone)")
            case .failed(let m): row("Problem", m)
            case .starting: row("Process", "starting…")
            case .checking: row("Process", "checking…")
            }
            if let h = core.health {
                row("LAN", h.lan == true ? "on (iPhone can pair)" : "off (loopback only)")
                ForEach((h.models ?? [:]).keys.sorted(), id: \.self) { k in
                    row(k, h.models?[k]?.stringValue ?? "—")
                }
            }
            HStack {
                if case .failed = core.phase {
                    Button("Start Core") { Task { await core.start() } }
                }
                Button("Show Log") { openWindow(id: "core-log") }
                Button("Pair iPhone…") { NotificationCenter.default.post(name: .showPairing, object: nil) }
            }
            .padding(.top, 4)
        }
        .padding(14)
        .frame(width: 330)
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k.uppercased()).font(CoachFont.mono(10)).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
            Text(v).font(CoachFont.mono(11.5)).textSelection(.enabled)
        }
    }
}
