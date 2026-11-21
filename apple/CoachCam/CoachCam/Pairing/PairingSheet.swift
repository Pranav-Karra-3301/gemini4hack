import CoachAPI
import CoachModels
import CoachUI
import SwiftUI
import VisionKit

/// Pair with Coach Core on the Mac: scan its QR (`coach://pair?host=…&port=…&token=…`), or pick a
/// Mac found over Bonjour and type its pairing code. Minimal on purpose (onboarding is designed
/// separately).
struct PairingSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var cores: [DiscoveredCore] = []
    @State private var scanning = false
    @State private var address = ""
    @State private var token = ""
    @State private var busy = false
    @State private var error: String?

    private var canScan: Bool { DataScannerViewController.isSupported && DataScannerViewController.isAvailable }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        scanning = true
                    } label: {
                        Label("Scan the code on your Mac", systemImage: "qrcode.viewfinder")
                    }
                    .disabled(!canScan)
                } footer: {
                    Text(canScan
                         ? "In CoachStudio on your Mac, choose Pair iPhone. You can also scan the code with the Camera app."
                         : "This device can't scan here. Use the Camera app to scan the Mac's code, or enter it below.")
                }
                Section("On this Wi-Fi") {
                    if cores.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Looking for Coach Core…").foregroundStyle(.secondary)
                        }
                    }
                    ForEach(cores) { c in
                        Button {
                            address = "\(c.host):\(c.port)"
                        } label: {
                            LabeledContent(c.name, value: "\(c.host):\(c.port)")
                        }
                    }
                }
                Section {
                    TextField("Address (192.168.1.20:8787)", text: $address)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("Pairing code", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                    Button {
                        guard let p = Pairing(address: address, token: token) else {
                            error = "That address doesn't look right."
                            return
                        }
                        submit(p)
                    } label: {
                        if busy { ProgressView() } else { Text("Connect") }
                    }
                    .disabled(address.isEmpty || busy)
                } header: {
                    Text("Enter manually")
                } footer: {
                    if let error { Text(error).foregroundStyle(CoachColor.signal) }
                }
            }
            .navigationTitle("Pair with your Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Later") { dismiss() } }
            }
            .task {
                for await list in CoachDiscovery().cores() { cores = list }
            }
            .fullScreenCover(isPresented: $scanning) {
                QRScannerView { payload in
                    scanning = false
                    if let p = Pairing(string: payload) { submit(p) } else { error = "That code isn't a Coach pairing code." }
                } onCancel: {
                    scanning = false
                }
                .ignoresSafeArea()
                .onAppear { app.camera.stop() }          // one capture session at a time
                .onDisappear { Task { await app.camera.start() } }
            }
        }
        .tint(CoachColor.safelight)
        .interactiveDismissDisabled(busy)
    }

    private func submit(_ p: Pairing) {
        busy = true
        error = nil
        Task {
            error = await app.pair(p)
            busy = false
        }
    }
}

/// VisionKit QR scanner (live camera, highlights codes). Calls `onCode` with the first `coach://` payload.
struct QRScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UINavigationController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                                qualityLevel: .balanced, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        scanner.navigationItem.title = "Scan the Mac's code"
        scanner.navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .cancel, primaryAction: UIAction { _ in context.coordinator.cancel() })
        let nav = UINavigationController(rootViewController: scanner)
        nav.navigationBar.tintColor = .systemOrange
        DispatchQueue.main.async { try? scanner.startScanning() }
        return nav
    }

    func updateUIViewController(_ vc: UINavigationController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode, onCancel: onCancel) }

    static func dismantleUIViewController(_ vc: UINavigationController, coordinator: Coordinator) {
        (vc.viewControllers.first as? DataScannerViewController)?.stopScanning()
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        let onCancel: () -> Void
        private var done = false

        init(onCode: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
            self.onCode = onCode
            self.onCancel = onCancel
        }

        func cancel() {
            guard !done else { return }
            done = true
            onCancel()
        }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in items {
                guard case .barcode(let b) = item, let s = b.payloadStringValue,
                      s.lowercased().hasPrefix("coach:"), !done else { continue }
                done = true
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                onCode(s)
                return
            }
        }
    }
}
