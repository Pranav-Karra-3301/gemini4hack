import AppKit
import Foundation
import ImageIO
import Observation
import UniformTypeIdentifiers
import CoachAPI
import CoachModels

/// The shot library: `GET /api/shots`, kept live by `GET /api/events` (new shots from the phone
/// appear instantly and their analysis stages fill in), plus imports (`POST /api/shots`).
@MainActor
@Observable
final class LibraryStore {
    private(set) var shots: [Shot] = []
    private(set) var loaded = false
    private(set) var eventsConnected = false
    private(set) var error: String?
    /// Files being uploaded right now.
    private(set) var uploading = 0
    /// Ids that arrived through events since launch (cells play a short "new" glow).
    private(set) var fresh: Set<String> = []

    let client: CoachClient
    @ObservationIgnored private var eventsTask: Task<Void, Never>?

    init(client: CoachClient) { self.client = client }

    func shot(_ id: String) -> Shot? { shots.first { $0.id == id } }

    /// Loads the list and follows events until cancelled. Safe to call again (no-op while running).
    func start() {
        guard eventsTask == nil else { return }
        eventsTask = Task { [weak self] in
            guard let self else { return }
            await self.refresh()
            while !Task.isCancelled {
                do {
                    for try await event in self.client.events() {
                        self.handle(event)
                    }
                } catch {
                    self.eventsConnected = false
                    if case CoachError.notFound? = error as? CoachError {
                        self.error = "This Core has no shot library (no /api/events). Restart it from the current server/ to sync shots."
                    } else {
                        self.error = "Live updates stopped: \(describe(error))"
                    }
                }
                // events() only ends on 401/404 (no events endpoint yet): retry slowly.
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                await self.refresh()
            }
        }
    }

    func refresh() async {
        do {
            let list = try await client.shots(limit: 200)
            shots = list
            loaded = true
            error = nil
        } catch {
            loaded = true
            self.error = describe(error)
        }
    }

    private func handle(_ event: ShotEvent) {
        switch event {
        case .hello:
            eventsConnected = true
            error = nil
            Task { await refresh() }  // catch anything missed while disconnected
        case .shot(let s):
            upsert(s)
        case .shotDeleted(let id):
            shots.removeAll { $0.id == id }
        case .ping, .other:
            break
        }
    }

    func upsert(_ s: Shot) {
        if let i = shots.firstIndex(where: { $0.id == s.id }) {
            shots[i] = s
        } else {
            shots.insert(s, at: 0)
            shots.sort { $0.id > $1.id }  // ids are time-sortable
            fresh.insert(s.id)
        }
    }

    func delete(_ id: String) async {
        do {
            try await client.deleteShot(id: id)
            shots.removeAll { $0.id == id }
        } catch {
            self.error = describe(error)
        }
    }

    // MARK: Import

    /// Uploads image files (JPEG as is; HEIC/PNG/TIFF re-encoded to JPEG) with whatever EXIF says
    /// about the capture as `meta`.
    func importFiles(_ urls: [URL]) async {
        for url in urls {
            guard let data = try? Data(contentsOf: url) else { continue }
            await importData(data, name: url.lastPathComponent)
        }
    }

    func importData(_ data: Data, name: String = "") async {
        uploading += 1
        defer { uploading -= 1 }
        guard let (jpeg, meta) = Self.prepare(data) else {
            error = "Couldn't read \(name.isEmpty ? "that image" : name)"
            return
        }
        do {
            let s = try await client.uploadShot(jpeg: jpeg, meta: meta)
            upsert(s)
            fresh.insert(s.id)
        } catch {
            self.error = describe(error)
        }
    }

    /// JPEG bytes (originals pass through untouched) and EXIF-derived meta.
    nonisolated static func prepare(_ data: Data) -> (Data, ShotMeta)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(src) as String? else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
        var meta = ShotMeta(source: "mac")
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Double])?.first { meta.iso = iso }
        if let t = exif[kCGImagePropertyExifExposureTime] as? Double { meta.shutter = t }
        if let ev = exif[kCGImagePropertyExifExposureBiasValue] as? Double { meta.ev = ev }
        if let model = tiff[kCGImagePropertyTIFFModel] as? String { meta.device = model }
        if let d = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            let f = DateFormatter()
            f.dateFormat = "yyyy:MM:dd HH:mm:ss"
            f.locale = Locale(identifier: "en_US_POSIX")
            if let date = f.date(from: d) { meta.takenAt = CoachJSON.string(from: date) }
        }
        if type == UTType.jpeg.identifier { return (data, meta) }
        // Re-encode, keeping orientation and metadata.
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImageFromSource(dst, src, 0, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(dst) else { return nil }
        return (out as Data, meta)
    }
}

func describe(_ error: Error) -> String {
    if let e = error as? LocalizedError, let d = e.errorDescription { return d }
    return String(describing: error)
}

/// Downloads and caches asset images (thumbs, masks, depth) by path. Decoding happens off the
/// main actor; concurrent requests for the same path share one download.
actor AssetCache {
    static let shared = AssetCache()
    private var images: [String: NSImage] = [:]
    private var inflight: [String: Task<NSImage?, Never>] = [:]
    private var order: [String] = []

    func image(_ path: String, client: CoachClient) async -> NSImage? {
        if let img = images[path] { return img }
        if let t = inflight[path] { return await t.value }
        let t = Task<NSImage?, Never> {
            guard let data = try? await client.assetData(path) else { return nil }
            return NSImage(data: data)
        }
        inflight[path] = t
        let img = await t.value
        inflight[path] = nil
        if let img {
            images[path] = img
            order.append(path)
            if order.count > 400 { images[order.removeFirst()] = nil }
        }
        return img
    }
}
