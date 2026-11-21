import CoachUI
import SwiftUI

/// Server, coach voice, Photos, sync. Deliberately small: the camera is the app.
struct SettingsSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var app = app
        NavigationStack {
            Form {
                Section("Mac") {
                    LabeledContent("Heliocam Core", value: linkText)
                    if let p = app.pairing {
                        LabeledContent("Address", value: "\(p.host):\(p.port)")
                    }
                    Button("Pair with a Mac…") {
                        dismiss()
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(350))
                            app.showPairing = true
                        }
                    }
                    if app.pairing != nil {
                        Button("Forget this Mac", role: .destructive) { app.forgetPairing() }
                    }
                }
                Section {
                    Toggle("Live coaching", isOn: Binding(
                        get: { app.coachEnabled },
                        set: { on in
                            app.coachEnabled = on
                            if on { Task { await app.startCoachIfReady() } } else { app.coach.stop() }
                        }))
                    Toggle("Gemini voice", isOn: $app.voiceOn)
                    if let ms = app.coach.connectMs {
                        LabeledContent("Connect time", value: "\(ms) ms")
                    }
                } header: {
                    Text("Heliocam")
                } footer: {
                    Text("With the voice off the mic and Gemini's voice are muted; it still watches, guides with the border, shows tips as a yellow tag and moves the dials.")
                }
                Section {
                    Toggle("Save to Photos", isOn: $app.saveToPhotos)
                    LabeledContent("Waiting to sync", value: "\(app.sync.pending)")
                    if let id = app.sync.lastShotID {
                        LabeledContent("Last synced", value: id)
                    }
                    Button("Sync now") { app.sync.kick() }
                        .disabled(app.sync.pending == 0)
                } header: {
                    Text("Shots")
                } footer: {
                    Text("Every shot is kept on the phone until Heliocam Core has it.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
        .tint(CoachColor.safelight)
    }

    private var linkText: String {
        switch app.link {
        case .unpaired: return "Not paired"
        case .checking: return "Checking…"
        case .online: return "Connected"
        case .offline: return "Offline"
        case .unauthorized: return "Pair again"
        }
    }
}
