import AppKit
import SwiftUI
import UniformTypeIdentifiers
import CoachAPI
import CoachModels
import CoachUI

/// The shot grid. New shots (from the iPhone or a drop) slide in and their stages fill in live.
struct LibraryView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(CoreSupervisor.self) private var core
    @Binding var path: [String]
    @State private var dropTargeted = false

    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 14)]

    var body: some View {
        ZStack {
            CoachColor.ink.ignoresSafeArea()
            if library.shots.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(library.shots) { shot in
                            ShotCell(shot: shot, client: library.client, isNew: library.fresh.contains(shot.id))
                                .onTapGesture { path.append(shot.id) }
                                .contextMenu {
                                    Button("Open") { path.append(shot.id) }
                                    Divider()
                                    Button("Delete", role: .destructive) { Task { await library.delete(shot.id) } }
                                }
                                .transition(.scale(scale: 0.92).combined(with: .opacity))
                        }
                    }
                    .padding(20)
                    .animation(CoachEase.out(CoachDuration.slow), value: library.shots.map(\.id))
                }
            }
            if dropTargeted {
                RoundedRectangle(cornerRadius: CoachRadius.lg, style: .continuous)
                    .strokeBorder(CoachColor.paper.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [8, 6]))
                    .background(RoundedRectangle(cornerRadius: CoachRadius.lg).fill(CoachColor.paper.opacity(0.04)))
                    .overlay(Text("Drop photos to add them").font(CoachFont.sans(17)).foregroundStyle(CoachColor.paper))
                    .padding(14)
                    .allowsHitTesting(false)
            }
            VStack {
                Spacer()
                if let err = library.error, core.isUp {
                    Text(err).font(CoachFont.mono(11)).foregroundStyle(CoachColor.paper62)
                        .padding(.horizontal, 14).padding(.vertical, 8).coachGlass(cornerRadius: 12)
                        .padding(.bottom, 16)
                } else if library.uploading > 0 {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Uploading \(library.uploading)…").font(CoachFont.mono(11)).foregroundStyle(CoachColor.paper)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8).coachGlass(cornerRadius: 12)
                    .padding(.bottom, 16)
                }
            }
        }
        .onDrop(of: [.fileURL, .image], isTargeted: $dropTargeted) { providers in
            handleDrop(providers)
            return true
        }
        .navigationTitle("Library")
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.on.rectangle.angled").font(.system(size: 38, weight: .light))
                .foregroundStyle(CoachColor.paper45)
            Text(core.isUp ? (library.loaded ? "No shots yet" : "Loading…") : "Waiting for Core…")
                .font(CoachFont.sans(19)).foregroundStyle(CoachColor.paper)
            Text("Shoot with CoachCam on your iPhone (pair it from the toolbar), or drop photos here.")
                .font(CoachFont.sans(13)).foregroundStyle(CoachColor.paper55)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in await library.importFiles([url]) }
                }
            } else if p.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                p.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data else { return }
                    Task { @MainActor in await library.importData(data) }
                }
            }
        }
    }
}

/// One shot: thumbnail, source, scores and the analysis stages filling in.
private struct ShotCell: View {
    let shot: Shot
    let client: CoachClient
    let isNew: Bool
    @State private var thumb: NSImage?
    @State private var hover = false
    @State private var glow = false

    var body: some View {
        // A fixed square; the photo fills it as an overlay so it can't change the cell's size.
        Color(CoachColor.graphite)
        .aspectRatio(1, contentMode: .fit)
        .overlay {
            if let thumb {
                Image(nsImage: thumb).resizable().scaledToFill()
                    .transition(.opacity)
            }
        }
        .overlay {
            LinearGradient(colors: [.clear, CoachColor.ink.opacity(0.85)], startPoint: .center, endPoint: .bottom)
        }
        .overlay(alignment: .bottomLeading) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: shot.meta?.source == "iphone" ? "iphone" : "desktopcomputer")
                        .font(.system(size: 10, weight: .semibold))
                    Text(timeText).font(CoachFont.mono(10.5))
                    Spacer()
                    if shot.edit != nil {
                        Text("EDITED").font(CoachFont.mono(9, weight: .semibold)).tracking(1)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Capsule().fill(CoachColor.paper.opacity(0.16)))
                    }
                }
                .foregroundStyle(CoachColor.paper)
                HStack(spacing: 10) {
                    StageDots(assets: shot.assets)
                    Spacer()
                    let sc = shot.assets.score.summaryScores
                    if let l = sc["lighting"] { ScoreChip(letter: "L", value: l) }
                    if let c = sc["composition"] { ScoreChip(letter: "C", value: c) }
                }
            }
            .padding(10)
        }
        .clipShape(RoundedRectangle(cornerRadius: CoachRadius.thumb, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CoachRadius.thumb, style: .continuous)
                .strokeBorder(glow ? CoachColor.safelight : CoachColor.paper.opacity(hover ? 0.3 : 0.08), lineWidth: glow ? 2 : 1)
        )
        .shadow(color: glow ? CoachColor.safelight.opacity(0.5) : .clear, radius: 14)
        .scaleEffect(hover ? 1.012 : 1)
        .animation(CoachEase.out(CoachDuration.fast), value: hover)
        .onHover { hover = $0 }
        .contentShape(Rectangle())
        .task(id: shot.assets.thumb.url) {
            guard let url = shot.assets.thumb.url ?? shot.assets.image.url else { return }
            let img = await AssetCache.shared.image(url, client: client)
            withAnimation(CoachEase.out(CoachDuration.base)) { thumb = img }
        }
        .task {
            guard isNew else { return }
            withAnimation(CoachEase.out(CoachDuration.base)) { glow = true }
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            withAnimation(CoachEase.out(CoachDuration.slow)) { glow = false }
        }
    }

    private var timeText: String {
        guard let d = shot.meta?.takenDate ?? shot.createdDate else { return shot.id }
        return d.formatted(date: .abbreviated, time: .shortened)
    }
}

/// depth · score · regions · masks · suggest, as dots; the running one pulses with its name.
private struct StageDots: View {
    let assets: ShotAssets
    var body: some View {
        let stages: [(String, AssetStatus)] = [("depth", assets.depth.status), ("score", assets.score.status),
                                               ("regions", assets.regions.status), ("masks", assets.masks.status),
                                               ("suggest", assets.suggest.status)]
        HStack(spacing: 4) {
            ForEach(stages, id: \.0) { s in StatusDot(status: s.1).help("\(s.0): \(s.1.rawValue)") }
            if let running = stages.first(where: { $0.1 == .running }) {
                Text(running.0.uppercased() + "…").font(CoachFont.mono(9)).tracking(1)
                    .foregroundStyle(CoachColor.safelight).padding(.leading, 2)
            } else if let failed = stages.first(where: { $0.1 == .error }) {
                Text(failed.0.uppercased() + " FAILED").font(CoachFont.mono(9)).tracking(1)
                    .foregroundStyle(CoachColor.signal).padding(.leading, 2)
            }
        }
        .animation(CoachEase.out(CoachDuration.base), value: stages.map(\.1))
    }
}

private struct ScoreChip: View {
    let letter: String
    let value: Double
    var body: some View {
        HStack(spacing: 3) {
            Text(letter).font(CoachFont.mono(9)).foregroundStyle(CoachColor.paper45)
            Text(String(format: "%.1f", value)).font(CoachFont.mono(11, weight: .semibold))
                .foregroundStyle(value >= 3.5 ? CoachColor.safelight : CoachColor.paper)
        }
    }
}
