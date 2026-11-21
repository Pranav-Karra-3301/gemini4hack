import CoachAPI
import CoachModels
import Foundation
import ImageIO
import Observation
import UniformTypeIdentifiers

/// The instant review at the shutter (CORE_API.md §5): streams `POST /api/review` and holds what
/// the card shows. The verdict appears at `decision`, the first card at `suggestion`, the rest at
/// `final`; the chips fade ~5 s after `final` (or on tap). The first card's `speak` line goes to
/// `speaker` as soon as it arrives (the app says it in the coach's Gemini voice).
@MainActor
@Observable
final class InstantReview {
    private(set) var verdict: ReviewVerdict?
    private(set) var cards: [ReviewCard] = []
    private(set) var working: String?
    private(set) var isFinal = false
    private(set) var visible = false
    /// Bumps per review (the card's identity for transitions).
    private(set) var serial = 0

    /// The first card's camera move while the card is up (an EdgeGlow hint).
    var hint: GuideDirection? { visible ? cards.first?.guide : nil }

    /// Says a review line (with the verdict so far) in the coach's voice.
    @ObservationIgnored var speaker: ((String, ReviewVerdict?) -> Void)?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var hideTask: Task<Void, Never>?

    /// Starts a review of `jpeg` (any size; sent at ≤1024 px). `onSettled` runs once, at `final`
    /// or when the stream ends or fails (the shot upload waits for it so Core can attach the review).
    func start(client: CoachClient, jpeg: Data, context: ReviewContext, speak: Bool, onSettled: @escaping @MainActor () -> Void) {
        task?.cancel()
        hideTask?.cancel()
        visible = false
        verdict = nil
        cards = []
        working = nil
        isFinal = false
        serial += 1
        let serial = self.serial
        task = Task { @MainActor [weak self] in
            var settled = false
            @MainActor func settle() { if !settled { settled = true; onSettled() } }
            defer { settle() }
            let t0 = Date()
            let small = await Task.detached(priority: .userInitiated) { ReviewImage.jpeg(jpeg, maxSide: 1024) }.value
            guard let small, !Task.isCancelled else { return }
            var spoken = false
            do {
                for try await e in CoreExtras.review(client: client, jpeg: small, context: context) {
                    guard let self, self.serial == serial, !Task.isCancelled else { return }
                    #if DEBUG
                    print("CoachCam[review] +\(Int(Date().timeIntervalSince(t0) * 1000))ms \(e)")
                    #endif
                    switch e {
                    case .decision(let v, let card, let w):
                        self.verdict = v
                        self.working = w ?? self.working
                        if let card, self.cards.isEmpty { self.cards = [card] }
                        self.show(for: 8)
                    case .suggestion(let card):
                        self.cards = [card]
                        self.show(for: 8)
                        if speak, !spoken {
                            spoken = true
                            self.speaker?(card.speak ?? card.action, self.verdict)
                        }
                    case .final(let v, let list, let w, let line):
                        self.verdict = v
                        if !list.isEmpty { self.cards = list }
                        self.working = w ?? self.working
                        self.isFinal = true
                        self.show(for: 5)
                        if speak, !spoken, let line { spoken = true; self.speaker?(line, v) }
                        settle()
                    case .done:
                        settle()
                    }
                }
            } catch {
                #if DEBUG
                print("CoachCam[review] failed: \(error)")
                #endif
            }
        }
    }

    func dismiss() {
        hideTask?.cancel()
        visible = false
    }

    private func show(for seconds: Double) {
        visible = true
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.visible = false
        }
    }

    /// A random id Core accepts (`[A-Za-z0-9_-]{1,64}`).
    static func newID() -> String {
        "cam" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16).lowercased()
    }
}

enum ReviewImage {
    /// Upright JPEG with the long side ≤ `maxSide` (quality 0.82).
    static func jpeg(_ data: Data, maxSide: Int) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxSide,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary)
        else { return nil }
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, img, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        return CGImageDestinationFinalize(dst) ? out as Data : nil
    }
}
