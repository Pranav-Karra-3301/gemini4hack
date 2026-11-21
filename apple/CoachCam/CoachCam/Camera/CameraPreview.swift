import AVFoundation
import SwiftUI
import UIKit

/// Full-bleed `AVCaptureVideoPreviewLayer`. A `RotationCoordinator` keeps the preview level and
/// tells the engine how the phone is held, so photos and Live frames come out upright.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let device: AVCaptureDevice?
    let onCaptureRotation: (CGFloat) -> Void

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspectFill
        v.backgroundColor = .black
        return v
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        view.onCaptureRotation = onCaptureRotation
        if let device { view.attach(device) }
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        var onCaptureRotation: ((CGFloat) -> Void)?
        private var coordinator: AVCaptureDevice.RotationCoordinator?
        private var observations: [NSKeyValueObservation] = []
        private weak var device: AVCaptureDevice?

        func attach(_ device: AVCaptureDevice) {
            guard self.device !== device else { return }
            self.device = device
            let c = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
            coordinator = c
            setPreviewAngle(c.videoRotationAngleForHorizonLevelPreview)
            onCaptureRotation?(c.videoRotationAngleForHorizonLevelCapture)
            observations = [
                c.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) { [weak self] c, _ in
                    let a = c.videoRotationAngleForHorizonLevelPreview
                    DispatchQueue.main.async { self?.setPreviewAngle(a) }
                },
                c.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.new]) { [weak self] c, _ in
                    let a = c.videoRotationAngleForHorizonLevelCapture
                    DispatchQueue.main.async { self?.onCaptureRotation?(a) }
                },
            ]
        }

        private func setPreviewAngle(_ a: CGFloat) {
            guard let conn = previewLayer.connection, conn.isVideoRotationAngleSupported(a) else { return }
            conn.videoRotationAngle = a
        }
    }
}
