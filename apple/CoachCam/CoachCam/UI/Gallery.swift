import CoachAPI
import CoachModels
import CoachUI
import SwiftUI
import UIKit

// This session's shots as a dark 3-column contact sheet, newest first, keepers floated to the top
// with a small warm dot and a faint inner glow. No labels. Live: refreshes when Core reports a
// shot change, so verdicts and scores light up as they land.

/// Shots taken since `since` (falls back to the latest 24 when there are none yet). Tap → `onOpen`.
struct SessionRoll: View {
    private let client: CoachClient
    private let since: Date
    private let onOpen: (Shot) -> Void
    @State private var roll = RollModel()
    @Environment(\.dismiss) private var dismiss

    init(client: CoachClient, since: Date, onOpen: @escaping (Shot) -> Void) {
        self.client = client
        self.since = since
        self.onOpen = onOpen
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    var body: some View {
        ZStack(alignment: .topTrailing) {
            GXColor.void.ignoresSafeArea()
            ScrollView {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(roll.items) { item in
                        Button { onOpen(item.shot) } label: {
                            RollCell(image: roll.thumbs[item.id], keeper: item.keeper, dim: roll.hasKeepers && !item.keeper)
                        }
                        .buttonStyle(.plain)
                        .task { await roll.loadThumb(item.shot, client: client) }
                    }
                }
                .padding(.top, 52)
                .padding(.horizontal, 2)
                .animation(CoachEase.out(CoachDuration.slow), value: roll.items.map(\.id))
            }
            .scrollIndicators(.hidden)

            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(GXColor.label)
                    .frame(width: 44, height: 44)
            }
            .padding(.trailing, 6)

            if let error = roll.error {
                Text(error).font(CoachFont.label).foregroundStyle(GXColor.signal)
                    .multilineTextAlignment(.center).padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !roll.loaded {
                ProgressView().tint(GXColor.label).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .preferredColorScheme(.dark)
        .presentationBackground(GXColor.void)
        .presentationDragIndicator(.visible)
        .task { await roll.run(client: client, since: since) }
    }
}

/// One square, matte cell.
private struct RollCell: View {
    let image: UIImage?
    let keeper: Bool
    let dim: Bool

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .background(GXColor.night)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                        .opacity(dim ? 0.72 : 1)
                        .transition(.opacity)
                }
            }
            .clipped()
            .overlay {
                if keeper {  // faint warm light along the inner edge
                    Rectangle().strokeBorder(RollModel.warm.opacity(0.45), lineWidth: 2).blur(radius: 3).clipped()
                }
            }
            .overlay(alignment: .topTrailing) {
                if keeper {
                    Circle().fill(RollModel.warm).frame(width: 7, height: 7)
                        .shadow(color: RollModel.warm.opacity(0.6), radius: 4)
                        .padding(7)
                }
            }
            .contentShape(Rectangle())
            .animation(CoachEase.out(), value: image != nil)
    }
}

@MainActor @Observable
final class RollModel {
    struct Item: Identifiable, Hashable {
        let shot: Shot
        let keeper: Bool
        var id: String { shot.id }
    }

    static let warm = Color(red: 1.0, green: 0.80, blue: 0.36)
    /// Score fallback threshold: mean of lighting and composition on Core's 1–5 scale (= 7/10).
    static let keeperScore = 3.5
    static let fallbackCount = 24

    private(set) var items: [Item] = []
    private(set) var thumbs: [String: UIImage] = [:]
    private(set) var loaded = false
    private(set) var error: String?
    var hasKeepers: Bool { items.contains(where: \.keeper) }

    @ObservationIgnored private var fetching: Set<String> = []
    @ObservationIgnored private var pending: Task<Void, Never>?

    /// Loads once, then reloads (coalesced) whenever Core reports a shot change, until cancelled.
    func run(client: CoachClient, since: Date) async {
        await reload(client: client, since: since)
        do {
            for try await event in client.events() {
                switch event {
                case .shot, .shotDeleted: scheduleReload(client: client, since: since)
                default: break
                }
            }
        } catch is CancellationError {
        } catch {
            self.error = "live updates stopped: \(error.localizedDescription)"
        }
        pending?.cancel()
    }

    private func scheduleReload(client: CoachClient, since: Date) {
        guard pending == nil else { return }
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await self?.reload(client: client, since: since)
            self?.pending = nil
        }
    }

    func reload(client: CoachClient, since: Date) async {
        do {
            // One raw fetch: `Shot` doesn't carry `assets.review`, so decode it alongside.
            let data = try await client.assetData("/api/shots?limit=60")
            let list = try JSONDecoder().decode(ShotList.self, from: data)
            let verdicts = (try? JSONDecoder().decode(ReviewIndex.self, from: data))?.verdicts ?? [:]
            let cutoff = since.addingTimeInterval(-5)  // phone vs Mac clock slack
            var shots = list.shots.filter { ($0.createdDate ?? .distantPast) >= cutoff }
            if shots.isEmpty { shots = Array(list.shots.prefix(Self.fallbackCount)) }
            shots.sort { ($0.createdDate ?? .distantPast) > ($1.createdDate ?? .distantPast) }
            let all = shots.map { Item(shot: $0, keeper: Self.isKeeper($0, verdict: verdicts[$0.id])) }
            items = all.filter(\.keeper) + all.filter { !$0.keeper }
            error = nil
        } catch {
            self.error = "couldn't load shots: \(error.localizedDescription)"
        }
        loaded = true
    }

    /// Keeper: the instant review's verdict when the shot has one (`assets.review.verdict == "keeper"`);
    /// otherwise the score stage (`assets.score.summary`): mean of lighting and composition ≥ 3.5 of 5.
    static func isKeeper(_ shot: Shot, verdict: String?) -> Bool {
        if let verdict { return verdict == "keeper" }
        let s = shot.assets.score.summaryScores
        let parts = ["lighting", "composition"].compactMap { s[$0] }
        guard shot.assets.score.status == .done, !parts.isEmpty else { return false }
        return parts.reduce(0, +) / Double(parts.count) >= keeperScore
    }

    func loadThumb(_ shot: Shot, client: CoachClient) async {
        guard thumbs[shot.id] == nil, !fetching.contains(shot.id) else { return }
        fetching.insert(shot.id)
        defer { fetching.remove(shot.id) }
        let path = shot.assets.thumb.url ?? shot.assets.image.url
            ?? "/api/shots/" + (shot.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"])) ?? shot.id) + "/thumb.jpg"
        guard let data = try? await client.assetData(path), let img = UIImage(data: data) else { return }
        thumbs[shot.id] = await img.byPreparingForDisplay() ?? img
    }
}

/// Just `shots[].assets.review.verdict` (written by server/review.py when a review is attached).
private struct ReviewIndex: Decodable {
    struct Entry: Decodable {
        struct Assets: Decodable {
            struct Review: Decodable { let verdict: String? }
            let review: Review?
        }
        let id: String
        let assets: Assets?
    }
    let shots: [Entry]

    var verdicts: [String: String] {
        var out: [String: String] = [:]
        for s in shots { if let v = s.assets?.review?.verdict { out[s.id] = v } }
        return out
    }
}
