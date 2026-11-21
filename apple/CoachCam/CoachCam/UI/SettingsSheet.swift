import CoachAPI
import CoachUI
import SwiftUI

/// Coach, camera, about. Deliberately small: the camera is the app.
struct SettingsSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var app = app
        NavigationStack {
            Form {
                Section {
                    Toggle("Coach", isOn: Binding(
                        get: { app.coachEnabled },
                        set: { on in
                            app.coachEnabled = on
                            if on { Task { await app.startCoachIfReady() } } else { app.coach.stop() }
                        }))
                    Toggle("Gemini voice", isOn: $app.voiceOn)
                        .disabled(!app.coachEnabled)
                } header: {
                    Text("Coach")
                } footer: {
                    Text("Voice off: the coach still guides with the border and the dials.")
                }
                Section {
                    Toggle("Live depth", isOn: $app.liveDepth)
                    Toggle("Save to Photos", isOn: $app.saveToPhotos)
                } header: {
                    Text("Camera")
                } footer: {
                    Text("\(app.shots.shots.count) shots on this phone.")
                }
                Section {
                } header: {
                    Text("About")
                } footer: {
                    Text("Coach: gemini-3.8-live. Edits: \(GeminiDirect.strongModel), \(GeminiDirect.fastModel). Voice: \(GeminiDirect.ttsModel).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color(red: 0.035, green: 0.035, blue: 0.04))
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Color(red: 0.035, green: 0.035, blue: 0.04))
        .preferredColorScheme(.dark)
        .tint(CoachColor.safelight)
    }
}
