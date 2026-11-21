import SwiftUI
import WebKit
import CoachUI

/// The existing web 3D viewer (`web/3d.html`, served by Vite) in a sheet, opened on this shot's
/// photo: after the page loads, the app hands it the JPEG through the page's own file input (the
/// bytes come from Core natively, so there's no CORS hop).
struct SplatViewerSheet: View {
    let model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var status = "Loading the 3D viewer…"
    @State private var failed = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("3D").font(CoachFont.mono(12, weight: .semibold)).tracking(CoachFont.labelTracking(12))
                    .foregroundStyle(CoachColor.paper)
                Text(status).font(CoachFont.mono(11)).foregroundStyle(failed ? CoachColor.signal : CoachColor.paper45)
                    .lineLimit(1)
                Spacer()
                Button("Close") { dismiss() }
                    .buttonStyle(StudioButtonStyle(kind: .quiet))
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(CoachColor.graphite)
            WebView3D(url: StudioConfig.webURL.appendingPathComponent("3d.html"),
                      imageData: { await imageData() },
                      status: { s, bad in
                          status = s; failed = bad
                          if StudioAutomation.snapshotDir != nil {
                              FileHandle.standardError.write(Data("[3d] \(bad ? "ERR " : "")\(s)\n".utf8))
                          }
                      })
        }
        .frame(minWidth: 1000, idealWidth: 1200, minHeight: 700, idealHeight: 800)
        .background(CoachColor.ink)
    }

    private func imageData() async -> Data? {
        guard let path = model.shot?.assets.image.url else { return nil }
        return try? await model.client.assetData(path)
    }
}

private struct WebView3D: NSViewRepresentable {
    let url: URL
    let imageData: @MainActor () async -> Data?
    let status: @MainActor (String, Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        if StudioAutomation.snapshotDir != nil {  // QA: collect page errors for the trace
            let js = "window.__errs=[];addEventListener('error',e=>__errs.push(String(e.message)));addEventListener('unhandledrejection',e=>__errs.push(String(e.reason)));"
            config.userContentController.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.setValue(false, forKey: "drawsBackground")
        web.load(URLRequest(url: url))
        return web
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        let parent: WebView3D
        private var injected = false
        init(_ parent: WebView3D) { self.parent = parent }

        nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            MainActor.assumeIsolated {
                parent.status("Page loaded", false)
                inject(webView)
            }
        }

        nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            MainActor.assumeIsolated { parent.status("Load failed: \(error.localizedDescription)", true) }
        }

        nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            MainActor.assumeIsolated {
                parent.status("The 3D page crashed; reloading", true)
                injected = false
                webView.reload()
            }
        }

        nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            MainActor.assumeIsolated {
                parent.status("Couldn't reach \(parent.url.host ?? "") (\(error.localizedDescription)). Start the web app: cd web && npm run dev", true)
            }
        }

        private func inject(_ web: WKWebView) {
            guard !injected else { return }
            injected = true
            Task { @MainActor in
                guard let data = await parent.imageData() else {
                    parent.status("No photo to send to the viewer", true)
                    return
                }
                parent.status("Building the scene…", false)
                let js = """
                const bin = atob(b64);
                const bytes = new Uint8Array(bin.length);
                for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
                const file = new File([bytes], name, { type: 'image/jpeg' });
                // The page wires its file input after a top-level await, which can finish after
                // the load event: re-send until the upload progress moves (or the view changes).
                const pct = () => document.getElementById('up-pct')?.textContent ?? '0%';
                for (let i = 0; i < 25; i++) {
                    const input = document.getElementById('file');
                    if (input) {
                        const dt = new DataTransfer();
                        dt.items.add(file);
                        input.files = dt.files;
                        input.dispatchEvent(new Event('change', { bubbles: true }));
                    }
                    await new Promise((r) => setTimeout(r, 400));
                    if (pct() !== '0%' || document.body.dataset.view !== 'upload') return 'ok';
                }
                return 'the page never picked up the photo';
                """
                do {
                    let r = try await web.callAsyncJavaScript(js, arguments: ["b64": data.base64EncodedString(), "name": "shot.jpg"],
                                                              contentWorld: .page)
                    parent.status((r as? String) == "ok" ? "" : "The viewer didn't accept the photo (\(r ?? "nil"))", (r as? String) != "ok")
                    if StudioAutomation.snapshotDir != nil {
                        for delay in [3.0, 10.0, 20.0] {
                            try? await Task.sleep(nanoseconds: UInt64(delay * 1e9))
                            let probe = "JSON.stringify({view: document.body.dataset.view, w: innerWidth, h: innerHeight, text: document.body.innerText.slice(0, 160), errs: (window.__errs||[]).slice(0, 5)})"
                            let v = try? await web.evaluateJavaScript(probe)
                            FileHandle.standardError.write(Data("[3d probe] \(v ?? "nil")\n".utf8))
                            // Web content lives in another process, so window captures show it
                            // black: snapshot the page itself.
                            if let img = try? await web.takeSnapshot(configuration: nil),
                               let tiff = img.tiffRepresentation,
                               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]),
                               let dir = StudioAutomation.snapshotDir {
                                try? png.write(to: dir.appendingPathComponent("web3d_\(Int(delay))s.png"))
                            }
                        }
                    }
                } catch {
                    parent.status("Couldn't hand the photo to the viewer: \(error.localizedDescription)", true)
                }
            }
        }
    }
}
