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
        var heard: String?
        var tool: String?
        var args: [String: JSONValue] = [:]
    }

    static let steps: [Step] = [
        Step(delay: 1.2, tool: "set_intent", args: ["intent": "group", "subject": "friends at the table"]),
        Step(delay: 0.4, heard: "can you make it brighter"),
        Step(delay: 1.6, say: "Step left a little.", tool: "guide", args: ["direction": "left", "strength": "medium"]),
        Step(delay: 0.5, say: "Brighter, and focus on them.",
             tool: "set_camera", args: ["iso": 400, "shutter": 0.008, "focus": 0.78, "why": "Lift the faces, sharpen the table"]),
        Step(delay: 3.2, say: "Hold it there.", tool: "guide", args: ["direction": "hold"]),
        Step(delay: 0.2, tool: "shot_ready", args: ["ready": true]),
        Step(delay: 3.2, tool: "take_photo", args: ["reason": "everyone is smiling"]),
    ]

    @MainActor
    static func run(_ app: AppModel) async {
        let repeatForever = UserDefaults.standard.bool(forKey: "demoLoop")
        repeat {
            for (i, s) in steps.enumerated() {
                try? await Task.sleep(for: .seconds(s.delay))
                if let heard = s.heard { app.coach.debugHeard(heard) }
                if let say = s.say { app.coach.debugSay(say) }
                if let tool = s.tool {
                    await app.coach.runTool(FunctionCall(id: "demo-\(i)", name: tool, args: s.args))
                }
            }
            try? await Task.sleep(for: .seconds(repeatForever ? 16 : 30))
            await app.coach.runTool(FunctionCall(id: "demo-reset", name: "set_camera",
                                                 args: ["mode": "photo", "iso": "auto", "shutter": "auto", "focus": "auto",
                                                        "wb_kelvin": "auto", "zoom": 1, "why": "Back to auto"]))
            await app.coach.runTool(FunctionCall(id: "demo-unready", name: "shot_ready", args: ["ready": false]))
        } while repeatForever
    }
}
#endif
