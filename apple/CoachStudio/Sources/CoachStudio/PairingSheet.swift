import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import CoachAPI
import CoachModels
import CoachUI

/// `GET /api/pair` as a QR code for CoachCam (`coach://pair?host=…&port=…&token=…`).
struct PairingSheet: View {
    let client: CoachClient
    /// Reloads when Core comes up (the sheet can open before it answers).
    var coreUp: Bool = true
    @Environment(\.dismiss) private var dismiss
    @State private var pairing: Pairing?
    @State private var qr: NSImage?
    @State private var error: String?
    @State private var revealToken = false

    var body: some View {
        VStack(spacing: 18) {
            Text("Pair your iPhone").font(CoachFont.sans(20, weight: .semibold)).foregroundStyle(CoachColor.paper)
            Text("Open CoachCam and scan this code. Both devices need to be on the same Wi-Fi.")
                .font(CoachFont.sans(13)).foregroundStyle(CoachColor.paper62)
                .multilineTextAlignment(.center)
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(CoachColor.paper)
                if let qr {
                    Image(nsImage: qr).interpolation(.none).resizable().scaledToFit().padding(18)
                } else if error == nil {
                    ProgressView().tint(CoachColor.ink)
                } else {
                    Image(systemName: "wifi.exclamationmark").font(.system(size: 40)).foregroundStyle(CoachColor.ink.opacity(0.5))
                }
            }
            .frame(width: 260, height: 260)
            if let p = pairing {
                VStack(spacing: 6) {
                    Text("\(p.host):\(String(p.port))").font(CoachFont.mono(13, weight: .semibold)).foregroundStyle(CoachColor.paper)
                        .textSelection(.enabled)
                    if let t = p.token {
                        Button { revealToken.toggle() } label: {
                            Text(revealToken ? t : "token " + String(repeating: "•", count: 8) + t.suffix(4))
                                .font(CoachFont.mono(11)).foregroundStyle(CoachColor.paper45)
                        }
                        .buttonStyle(.plain)
                        .help("Click to show the token (for typing it in by hand)")
                    }
                }
            }
            if let error {
                Text(error).font(CoachFont.mono(11.5)).foregroundStyle(CoachColor.safelightHot)
                    .multilineTextAlignment(.center).frame(maxWidth: 360)
            }
            HStack {
                Button("Retry") { Task { await load() } }.buttonStyle(StudioButtonStyle(kind: .quiet))
                Button("Done") { dismiss() }.buttonStyle(StudioButtonStyle(kind: .primary)).keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 440)
        .background(CoachColor.graphite)
        .task(id: coreUp) {
            if coreUp { await load() } else { error = "Waiting for Core to start…" }
        }
    }

    private func load() async {
        error = nil
        do {
            let p = try await client.pair()
            pairing = p
            qr = Self.qrImage(p.url.absoluteString)
        } catch let e as CoachError {
            if case .server(409, _) = e {
                error = "Core is running without LAN mode, so the iPhone can't reach it. Quit the Core that's running and let CoachStudio start it (it uses COACH_LAN=1), or run ./dev.sh lan."
            } else {
                error = describe(e)
            }
        } catch {
            self.error = describe(error)
        }
    }

    static func qrImage(_ text: String) -> NSImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage else { return nil }
        let scaled = out.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let ctx = CIContext()
        guard let cg = ctx.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }
}

/// Core's stdout/stderr when CoachStudio started it.
struct CoreLogView: View {
    @Environment(CoreSupervisor.self) private var core

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(core.logLines.enumerated()), id: \.offset) { i, line in
                        Text(line.isEmpty ? " " : line)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(line.hasPrefix("CoachStudio:") ? CoachColor.safelight : CoachColor.paper.opacity(0.8))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(i)
                    }
                }
                .padding(12)
            }
            .onChange(of: core.logVersion) { _, _ in
                proxy.scrollTo(core.logLines.count - 1, anchor: .bottom)
            }
        }
        .background(CoachColor.ink)
        .overlay(alignment: .topTrailing) {
            if case .running(false) = core.phase {
                Text("Core was already running, so its output goes to the terminal that started it.")
                    .font(CoachFont.mono(10.5)).foregroundStyle(CoachColor.paper55)
                    .padding(8).coachGlass(cornerRadius: 10).padding(10)
            }
        }
    }
}
