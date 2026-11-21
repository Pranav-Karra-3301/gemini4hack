import CoachModels
import SwiftUI

@main
struct CoachCamApp: App {
    @State private var app = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            CameraScreen()
                .environment(app)
                .preferredColorScheme(.dark)
                .statusBarHidden()
                .persistentSystemOverlays(.hidden)
                .task { await app.launch() }
                // `coach://pair?...` from the system Camera app scanning the Mac's QR.
                .onOpenURL { url in
                    guard let p = Pairing(url: url) else { return }
                    Task { _ = await app.pair(p) }
                }
        }
        .onChange(of: scenePhase) { _, phase in app.scenePhaseChanged(phase) }
    }
}
