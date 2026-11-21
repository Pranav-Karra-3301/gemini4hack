// swift-tools-version: 6.0
// CoachKit: shared code for the CoachCam (iPhone) and CoachStudio (Mac) apps.
// Targets are owned by different builders; keep each target's files inside its own folder.
import PackageDescription

let package = Package(
    name: "CoachKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "CoachModels", targets: ["CoachModels"]),
        .library(name: "CoachAPI", targets: ["CoachAPI"]),
        .library(name: "CoachLive", targets: ["CoachLive"]),
        .library(name: "CoachEdit", targets: ["CoachEdit"]),
        .library(name: "CoachUI", targets: ["CoachUI"]),
    ],
    targets: [
        // Codable models for docs/CORE_API.md (shots, assets, recipe, sliders, live token, tools).
        .target(name: "CoachModels", swiftSettings: [.swiftLanguageMode(.v5)]),
        // HTTP client, SSE events, Bonjour discovery, pairing.
        .target(name: "CoachAPI", dependencies: ["CoachModels"], swiftSettings: [.swiftLanguageMode(.v5)]),
        // Gemini Live session over an ephemeral token: WebSocket, audio in/out, frames, tool calls.
        .target(name: "CoachLive", dependencies: ["CoachModels", "CoachAPI"], swiftSettings: [.swiftLanguageMode(.v5)]),
        // Core Image renderer for edit recipes (incl. depth blur and subject/background light).
        .target(name: "CoachEdit", dependencies: ["CoachModels"], swiftSettings: [.swiftLanguageMode(.v5)]),
        // Design tokens and shared controls: dials (camera) and slider rows (editor).
        .target(name: "CoachUI", dependencies: ["CoachModels"], resources: [.process("Resources")],
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "CoachKitTests", dependencies: ["CoachModels", "CoachAPI", "CoachLive", "CoachEdit", "CoachUI"],
                    swiftSettings: [.swiftLanguageMode(.v5), .define("COACHUI_TESTS")]),
    ]
)
