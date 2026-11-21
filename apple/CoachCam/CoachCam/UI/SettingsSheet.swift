import CoachUI
import SwiftUI

/// Coach, voice, Photos. Deliberately small: the camera is the app.
struct SettingsSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var app = app
        NavigationStack {
            Form {
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
                    LabeledContent("Shots on this phone", value: "\(app.shots.shots.count)")
                } header: {
                    Text("Shots")
                } footer: {
                    Text("Every shot stays in Heliocam on this phone; Save to Photos also adds it to your library.")
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

}
