import Foundation
import ImageIO
import Observation
import Photos
import UIKit

/// One shot on this phone: `Documents/Shots/<id>.jpg` (the edit source) plus the camera's own
/// file `<id>.photo` (HEIF, with depth when the camera captured it).
struct LocalShot: Identifiable, Hashable, Sendable {
    let id: String
    let takenAt: Date
    let jpegURL: URL
    let fileURL: URL?
}

/// The camera roll of this app: every shot kept in the app's documents, newest first, so the
/// gallery survives relaunches. Thumbnails are made on demand with ImageIO and cached.
@MainActor
@Observable
final class ShotStore {
    private(set) var shots: [LocalShot] = []
    /// The newest shot's thumbnail (the roll button).
    private(set) var lastThumb: CGImage?

    @ObservationIgnored private let dir: URL
    @ObservationIgnored private var thumbs: [String: CGImage] = [:]

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        dir = docs.appendingPathComponent("Shots", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        reload()
    }

    func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey])) ?? []
        let fileSet = Set(files.map(\.lastPathComponent))
        shots = files.filter { $0.pathExtension == "jpg" }.map { url in
            let id = url.deletingPathExtension().lastPathComponent
            let date = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let file = dir.appendingPathComponent("\(id).photo")
            return LocalShot(id: id, takenAt: date, jpegURL: url, fileURL: fileSet.contains(file.lastPathComponent) ? file : nil)
        }
        .sorted { $0.takenAt > $1.takenAt }
        lastThumb = shots.first.flatMap { thumbnail($0, side: 240) }
    }

    /// Saves a capture; returns the new shot. `thumbnail` (from the camera) shows on the roll
    /// button right away.
    @discardableResult
    func add(jpeg: Data, file: Data?, thumbnail: CGImage?) -> LocalShot? {
        let id = Self.idFormatter.string(from: Date()) + "-" + UUID().uuidString.prefix(4)
        let jpegURL = dir.appendingPathComponent("\(id).jpg")
        let fileURL = dir.appendingPathComponent("\(id).photo")
        do {
            try jpeg.write(to: jpegURL, options: .atomic)
            if let file { try file.write(to: fileURL, options: .atomic) }
        } catch {
            print("CoachCam[shots] save failed: \(error)")
            return nil
        }
        let shot = LocalShot(id: id, takenAt: Date(), jpegURL: jpegURL, fileURL: file != nil ? fileURL : nil)
        shots.insert(shot, at: 0)
        let thumb = thumbnail ?? Self.makeThumb(url: jpegURL, side: 240)
        if let thumb { thumbs[id + "@240"] = thumb }
        lastThumb = thumb
        return shot
    }

    func delete(_ shot: LocalShot) {
        try? FileManager.default.removeItem(at: shot.jpegURL)
        if let f = shot.fileURL { try? FileManager.default.removeItem(at: f) }
        shots.removeAll { $0.id == shot.id }
        lastThumb = shots.first.flatMap { thumbnail($0, side: 240) }
    }

    /// A cached thumbnail (longest side `side` px, upright).
    func thumbnail(_ shot: LocalShot, side: Int) -> CGImage? {
        let key = "\(shot.id)@\(side)"
        if let t = thumbs[key] { return t }
        let t = Self.makeThumb(url: shot.jpegURL, side: side)
        thumbs[key] = t
        return t
    }

    nonisolated static func makeThumb(url: URL, side: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: side,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    private static let idFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()
}

/// Saves the camera's own file (HEIF, with depth in portrait) to the photo library (add-only).
enum PhotoLibrarySaver {
    static func save(_ data: Data) async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
            }
        } catch {
            print("CoachCam: save to Photos failed: \(error)")
        }
    }
}
