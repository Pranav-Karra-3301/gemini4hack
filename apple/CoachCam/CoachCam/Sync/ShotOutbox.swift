import CoachAPI
import CoachModels
import CoreGraphics
import Foundation
import Network
import Observation
import Photos

/// Durable upload queue: each shot is written to Application Support/Outbox (`<id>.jpg` +
/// `<id>.json`) before any network call, so nothing is lost offline or if the app is killed.
actor ShotOutbox {
    struct Entry: Codable, Sendable {
        var id: String
        var created: Date
        var meta: ShotMeta
        /// The instant review streamed at the shutter; sent as meta `review_id` so Core attaches it.
        var reviewID: String?
        var attempts: Int = 0
        var lastError: String?
    }

    enum DrainResult: Sendable {
        case done
        /// Couldn't reach Core; retry later.
        case offline(String)
        /// The pairing token was refused; needs pairing again.
        case unauthorized
    }

    private let dir: URL
    private let failedDir: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dir = base.appendingPathComponent("Outbox", isDirectory: true)
        failedDir = dir.appendingPathComponent("Failed", isDirectory: true)
        try? FileManager.default.createDirectory(at: failedDir, withIntermediateDirectories: true)
    }

    func add(jpeg: Data, meta: ShotMeta, reviewID: String? = nil) throws -> Entry {
        let id = "\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(6))"
        let e = Entry(id: id, created: Date(), meta: meta, reviewID: reviewID)
        try jpeg.write(to: dir.appendingPathComponent("\(id).jpg"), options: .atomic)
        try JSONEncoder().encode(e).write(to: dir.appendingPathComponent("\(id).json"), options: .atomic)
        return e
    }

    func entries() -> [Entry] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(Entry.self, from: Data(contentsOf: $0)) }
            .sorted { $0.created < $1.created }
    }

    var count: Int { entries().count }

    /// Uploads everything queued, oldest first. Stops at the first network failure.
    func drain(client: CoachClient, uploaded: @Sendable (Entry, Shot) async -> Void) async -> DrainResult {
        for var e in entries() {
            let jpgURL = dir.appendingPathComponent("\(e.id).jpg")
            guard let jpeg = try? Data(contentsOf: jpgURL) else { remove(e.id); continue }
            do {
                let shot = try await CoreExtras.uploadShot(client: client, jpeg: jpeg, meta: e.meta,
                                                           extra: e.reviewID.map { ["review_id": $0] } ?? [:])
                remove(e.id)
                await uploaded(e, shot)
            } catch let err as CoachError {
                switch err {
                case .unauthorized:
                    return .unauthorized
                case .server(let status, _) where (400..<500).contains(status) && status != 408 && status != 429:
                    // Core will never take this one (bad image, too big): park it, keep going.
                    park(e.id)
                case .decoding:
                    remove(e.id)        // Core answered 2xx; the shot is there.
                case .notFound:
                    return .offline("This Coach Core has no shot library (update it)")
                default:
                    e.attempts += 1
                    e.lastError = err.localizedDescription
                    try? JSONEncoder().encode(e).write(to: dir.appendingPathComponent("\(e.id).json"), options: .atomic)
                    return .offline(err.localizedDescription)
                }
            } catch {
                return .offline(error.localizedDescription)
            }
        }
        return .done
    }

    private func remove(_ id: String) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(id).jpg"))
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(id).json"))
    }

    private func park(_ id: String) {
        for ext in ["jpg", "json"] {
            try? FileManager.default.moveItem(at: dir.appendingPathComponent("\(id).\(ext)"),
                                              to: failedDir.appendingPathComponent("\(id).\(ext)"))
        }
    }
}

/// Sync state for the UI (the dot on the last-shot thumbnail) and the retry loop.
@MainActor
@Observable
final class SyncModel {
    enum Status: Equatable { case idle, uploading, synced, queued, failed(String) }

    private(set) var status: Status = .idle
    private(set) var pending = 0
    private(set) var lastThumb: CGImage?
    private(set) var lastShotID: String?
    private(set) var lastUploadMs: Int?

    @ObservationIgnored let outbox = ShotOutbox()
    @ObservationIgnored var clientProvider: (() -> CoachClient?)?
    @ObservationIgnored var onUnauthorized: (() -> Void)?
    @ObservationIgnored var onNetworkBack: (() -> Void)?
    /// A shot reached Core (outbox entry id, the new record).
    @ObservationIgnored var onUploaded: ((String, Shot) -> Void)?
    /// An upload couldn't reach Core (the app looks for it again, e.g. over the other link).
    @ObservationIgnored var onOffline: ((String) -> Void)?
    /// Uploads wait while a hold is open (the shutter's review, so Core can attach it).
    @ObservationIgnored private var holds: Set<Int> = []
    @ObservationIgnored private var nextHold = 0
    @ObservationIgnored private var draining = false
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var backoff: TimeInterval = 2
    @ObservationIgnored private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in
                self?.onNetworkBack?()
                self?.kick()
            }
        }
        monitor.start(queue: DispatchQueue(label: "coachcam.net"))
        Task { pending = await outbox.count }
    }

    /// Queues a shot (on disk first) and starts uploading. Returns the outbox entry id.
    @discardableResult
    func enqueue(jpeg: Data, meta: ShotMeta, reviewID: String? = nil, thumbnail: CGImage?) async -> String? {
        lastThumb = thumbnail ?? lastThumb
        let id: String
        do {
            id = try await outbox.add(jpeg: jpeg, meta: meta, reviewID: reviewID).id
        } catch {
            status = .failed("Couldn't save the shot: \(error.localizedDescription)")
            return nil
        }
        pending = await outbox.count
        backoff = 2
        kick()
        return id
    }

    /// Pauses uploads until `release(_:)` or `seconds` pass. Returns the hold's id.
    func hold(seconds: Double) -> Int {
        nextHold += 1
        let id = nextHold
        holds.insert(id)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            self?.release(id)
        }
        return id
    }

    func release(_ id: Int) {
        guard holds.remove(id) != nil else { return }
        if holds.isEmpty { kick() }
    }

    /// Uploads now if there's anything queued and a client.
    func kick() {
        guard holds.isEmpty else { return }
        guard !draining, let client = clientProvider?() else {
            if pending > 0 && clientProvider?() == nil { status = .queued }
            return
        }
        draining = true
        retryTask?.cancel()
        Task {
            if await outbox.count > 0 { status = .uploading }
            let t0 = Date()
            let result = await outbox.drain(client: client) { entry, shot in
                await self.didUpload(entry.id, shot, since: t0)
            }
            pending = await outbox.count
            draining = false
            switch result {
            case .done:
                backoff = 2
                if status == .uploading { status = .synced }
            case .unauthorized:
                status = .queued
                onUnauthorized?()
            case .offline(let m):
                status = pending > 0 ? .queued : .failed(m)
                scheduleRetry()
                onOffline?(m)
            }
        }
    }

    private func didUpload(_ entryID: String, _ shot: Shot, since t0: Date) {
        lastShotID = shot.id
        lastUploadMs = Int(Date().timeIntervalSince(t0) * 1000)
        onUploaded?(entryID, shot)
    }

    private func scheduleRetry() {
        let delay = backoff
        backoff = min(backoff * 2, 60)
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.kick()
        }
    }
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
