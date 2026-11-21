import AppKit
import CoreImage
import MetalKit
import Observation
import SwiftUI
import CoachEdit

/// The photo, rendered live through CoachEdit into an `MTKView`.
///
/// Draws on demand: it sleeps (no GPU work) until the editor state changes, then redraws; while a
/// slider glides (coach steps, user flings, resets) it runs at display rate and pauses again when
/// everything has landed. Change tracking uses Observation, so SwiftUI doesn't re-run any body
/// per frame.
struct PreviewCanvas: NSViewRepresentable {
    let model: EditorModel
    /// Space around the photo, in points.
    var insets = EditorModel.CanvasInsets()

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> MTKView {
        let v = MTKView(frame: .zero, device: EditorModel.device)
        v.framebufferOnly = false  // Core Image writes into the drawable
        v.colorPixelFormat = .bgra8Unorm
        v.colorspace = EditorModel.displaySpace
        v.clearColor = MTLClearColor(red: 0.031, green: 0.031, blue: 0.039, alpha: 1)
        v.enableSetNeedsDisplay = true
        v.isPaused = true
        v.preferredFramesPerSecond = 120
        v.autoResizeDrawable = true
        v.delegate = context.coordinator
        context.coordinator.view = v
        context.coordinator.insets = insets
        context.coordinator.observe()
        return v
    }

    func updateNSView(_ v: MTKView, context: Context) {
        context.coordinator.insets = insets
        context.coordinator.kick()
    }

    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate {
        let model: EditorModel
        weak var view: MTKView?
        var insets = EditorModel.CanvasInsets()
        private let queue: MTLCommandQueue?
        private var continuous = false
        /// Render stats for the HUD (CPU time to build + encode a frame).
        static var lastEncodeMs: Double = 0

        init(model: EditorModel) {
            self.model = model
            self.queue = EditorModel.device?.makeCommandQueue()
        }

        /// Re-registers after every change (Observation fires once per registration).
        func observe() {
            withObservationTracking {
                _ = model.displayedRecipe(at: Date())
                _ = model.showBefore
                _ = model.source
                _ = model.depth
                _ = model.subjectMask
                _ = model.crop
            } onChange: { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.kick()
                    self.observe()
                }
            }
        }

        func kick() {
            guard let v = view else { return }
            if !continuous { v.needsDisplay = true }
        }

        private func setContinuous(_ on: Bool) {
            guard let v = view, on != continuous else { return }
            continuous = on
            v.enableSetNeedsDisplay = !on
            v.isPaused = !on
        }

        nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            MainActor.assumeIsolated { view.needsDisplay = true }
        }

        nonisolated func draw(in view: MTKView) {
            MainActor.assumeIsolated { render(view) }
        }

        private func render(_ view: MTKView) {
            guard let drawable = view.currentDrawable, let cb = queue?.makeCommandBuffer() else { return }
            let t0 = CACurrentMediaTime()
            let size = view.drawableSize
            let scale = view.window?.backingScaleFactor ?? 2
            let (image, moving) = model.frame(size: size, insets: insets.scaled(scale), at: Date())
            do {
                try EditorModel.renderer.render(image, to: drawable.texture, commandBuffer: cb,
                                                colorSpace: EditorModel.displaySpace)
            } catch {
                return
            }
            cb.present(drawable)
            cb.commit()
            Self.lastEncodeMs = (CACurrentMediaTime() - t0) * 1000
            setContinuous(moving)
        }
    }
}
