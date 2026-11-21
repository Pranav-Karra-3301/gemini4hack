#if DEBUG
import CoachModels
import Foundation

/// `-demoCoach YES`: plays a scripted coaching moment through the same tool path Gemini uses
/// (CoachSession.runTool → CameraController → dials), without a network. For screenshots and
/// for checking the dial choreography in the simulator.
enum DemoScript {
    struct Step {
        var delay: Double
        var say: String?
        var tool: String?
        var args: [String: JSONValue] = [:]
    }

    static let steps: [Step] = [
        Step(delay: 1.5, tool: "set_intent", args: ["intent": "landscape", "subject": "three on the bench"]),
        Step(delay: 1.2, say: "Raise the phone a little.", tool: "guide", args: ["direction": "up", "strength": "medium"]),
        Step(delay: 2.4, say: "Faster shutter for the waves.",
             tool: "set_camera", args: ["iso": 500, "shutter": 0.002, "wb_kelvin": 6800, "why": "Freeze the waves, warm the sea"]),
        Step(delay: 4.2, say: "Portrait mode, a bit tighter.",
             tool: "set_camera", args: ["mode": "portrait", "zoom": 2, "why": "Tighter on the three of them"]),
        Step(delay: 4.0, say: "Hold it there.", tool: "guide", args: ["direction": "hold"]),
        Step(delay: 0.3, tool: "shot_ready", args: ["ready": true]),
    ]

    @MainActor
    static func run(_ app: AppModel) async {
        let repeatForever = UserDefaults.standard.bool(forKey: "demoLoop")
        repeat {
            for (i, s) in steps.enumerated() {
                try? await Task.sleep(for: .seconds(s.delay))
                if let say = s.say { app.coach.debugSay(say) }
                if let tool = s.tool {
                    await app.coach.runTool(FunctionCall(id: "demo-\(i)", name: tool, args: s.args))
                }
            }
            try? await Task.sleep(for: .seconds(4))
            await app.coach.runTool(FunctionCall(id: "demo-reset", name: "set_camera",
                                                 args: ["mode": "photo", "iso": "auto", "shutter": "auto",
                                                        "wb_kelvin": "auto", "zoom": 1, "why": "Back to auto"]))
            await app.coach.runTool(FunctionCall(id: "demo-unready", name: "shot_ready", args: ["ready": false]))
        } while repeatForever
    }
}
#endif
