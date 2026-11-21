import CoachUI
import SwiftUI
import UIKit

/// The edited photo full screen, like Photos: pinch up to 6x, double-tap toggles 1x / 2.5x at the
/// tap point, pan when zoomed; pull down (at 1x) or the close key to go back. Shows `image` at once
/// and swaps in the high-resolution render from `hiRes` when it lands. No text.
struct PhotoDetailView: View {
    let image: UIImage
    let hiRes: () async -> UIImage?
    let onClose: () -> Void
    @State private var sharp: UIImage?
    @State private var pull: CGFloat = 0

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(red: 0.035, green: 0.035, blue: 0.04)
                .opacity(1 - Double(min(pull / 320, 0.6)))
                .ignoresSafeArea()
            ZoomingImage(image: sharp ?? image, pull: $pull, onClose: onClose)
                .ignoresSafeArea()
            RoundKey(symbol: "chevron.down", label: "Close", action: onClose)
                .padding(.leading, 18)
                .padding(.top, max(ScreenInsets.top, 12) + 4)
                .opacity(1 - Double(min(pull / 120, 1)))
                .ignoresSafeArea()
        }
        .statusBarHidden()
        .task {
            if let img = await hiRes() { sharp = img }
        }
    }
}

/// UIScrollView zoom (pinch, pan, double-tap) around one image view.
private struct ZoomingImage: UIViewRepresentable {
    let image: UIImage
    @Binding var pull: CGFloat
    let onClose: () -> Void

    func makeUIView(context: Context) -> ZoomScrollView {
        let v = ZoomScrollView()
        v.setImage(image)
        return v
    }

    func updateUIView(_ v: ZoomScrollView, context: Context) {
        v.onPull = { p in pull = p }
        v.onClose = onClose
        if v.imageView.image !== image { v.setImage(image) }
    }
}

final class ZoomScrollView: UIScrollView, UIScrollViewDelegate {
    let imageView = UIImageView()
    var onPull: ((CGFloat) -> Void)?
    var onClose: (() -> Void)?
    private var fittedFor: CGSize = .zero
    private var fittedAspect: CGFloat = 0
    private var closing = false

    static let maxZoom: CGFloat = 6
    static let doubleTapZoom: CGFloat = 2.5

    init() {
        super.init(frame: .zero)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = Self.maxZoom
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        alwaysBounceVertical = true
        decelerationRate = .fast
        backgroundColor = .clear
        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// A new image with the same aspect (the high-res render) keeps the zoom and position.
    func setImage(_ img: UIImage) {
        imageView.image = img
        let aspect = img.size.height > 0 ? img.size.width / img.size.height : 0
        if abs(aspect - fittedAspect) > 0.001 { fittedFor = .zero }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != fittedFor, bounds.width > 0, bounds.height > 0 { fit() }
    }

    private func fit() {
        guard let img = imageView.image, img.size.width > 0, img.size.height > 0 else { return }
        fittedFor = bounds.size
        fittedAspect = img.size.width / img.size.height
        zoomScale = 1
        let s = min(bounds.width / img.size.width, bounds.height / img.size.height)
        imageView.frame = CGRect(x: 0, y: 0, width: img.size.width * s, height: img.size.height * s)
        contentSize = imageView.frame.size
        center()
        contentOffset = CGPoint(x: -contentInset.left, y: -contentInset.top)
    }

    /// Keeps the image centred when it is smaller than the screen.
    private func center() {
        let dx = max(0, (bounds.width - contentSize.width) / 2)
        let dy = max(0, (bounds.height - contentSize.height) / 2)
        contentInset = UIEdgeInsets(top: dy, left: dx, bottom: dy, right: dx)
    }

    private var atRest: Bool { zoomScale <= minimumZoomScale + 0.01 }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { center() }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !closing else { return }
        onPull?(atRest ? max(0, -(contentOffset.y + contentInset.top)) : 0)
    }

    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                   targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        guard atRest, !closing else { return }
        let pulled = -(contentOffset.y + contentInset.top)
        if pulled > 100 || (pulled > 24 && velocity.y < -1.2) {
            closing = true
            targetContentOffset.pointee = contentOffset
            UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.6)
            onClose?()
        }
    }

    @objc private func doubleTapped(_ g: UITapGestureRecognizer) {
        if !atRest {
            setZoomScale(minimumZoomScale, animated: true)
            return
        }
        let p = g.location(in: imageView)
        let w = bounds.width / Self.doubleTapZoom, h = bounds.height / Self.doubleTapZoom
        zoom(to: CGRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h), animated: true)
    }
}
