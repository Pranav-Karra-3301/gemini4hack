import CoreImage
import Foundation
@testable import CoachEdit

/// Test inputs for CoachEdit: the sample photos plus depth and a subject mask per photo.
/// With COACH_IT=1, depth comes from Core's /api/depth and the mask from /api/regions + /api/masks
/// (cached under /tmp/lc_qa/edit_cache); otherwise a synthetic depth ramp and an ellipse mask.
enum CoachEditFixtures {
    static let repo = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    static let samplesDir = repo.appendingPathComponent("web/public/samples")
    static let outDir = URL(fileURLWithPath: "/tmp/lc_qa")
    static let cacheDir = URL(fileURLWithPath: "/tmp/lc_qa/edit_cache")
    static let core = URL(string: ProcessInfo.processInfo.environment["COACH_CORE"] ?? "http://127.0.0.1:8787")!
    static var integration: Bool { ProcessInfo.processInfo.environment["COACH_IT"] == "1" }

    struct Sample {
        let name: String
        let source: CIImage
        let depth: CIImage?
        let mask: CIImage?
        let real: Bool
    }

    static func sampleNames() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: samplesDir.path)) ?? []
        return files.filter { $0.hasSuffix(".jpg") }.map { String($0.dropLast(4)) }.sorted()
    }

    static func load(_ name: String) async -> Sample? {
        let url = samplesDir.appendingPathComponent(name + ".jpg")
        guard let data = try? Data(contentsOf: url), let src = EditRenderer.sourceImage(data: data) else { return nil }
        if integration, let (d, m) = await coreInputs(name: name, jpeg: data) {
            return Sample(name: name, source: src, depth: d, mask: m, real: true)
        }
        let (d, m) = synthetic(size: src.extent.size)
        return Sample(name: name, source: src, depth: d, mask: m, real: false)
    }

    /// Depth ramp (far at the top, near at the bottom) with an ellipse "subject" at 2.5 m.
    static func synthetic(size: CGSize) -> (CIImage?, CIImage?) {
        let w = 384, h = max(8, Int((384 * size.height / size.width).rounded()))
        var meters = [Float](repeating: 0, count: w * h)
        var mask = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let fy = Float(y) / Float(h - 1) // 0 = top
                var d = 20 * pow(1.5 / 20, fy)
                let ex = (Float(x) / Float(w) - 0.5) / 0.18, ey = (fy - 0.55) / 0.3
                if ex * ex + ey * ey < 1 { d = 2.5; mask[y * w + x] = 1 }
                meters[y * w + x] = d
            }
        }
        let depth = EditRenderer.depthImage(meters: meters, width: w, height: h)
        return (depth, DepthFocus.image(fromPlane: mask, width: w, height: h))
    }

    // MARK: - Core

    static func coreInputs(name: String, jpeg: Data) async -> (CIImage, CIImage?)? {
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let depthBin = cacheDir.appendingPathComponent(name + ".depth.f32")
        let depthMeta = cacheDir.appendingPathComponent(name + ".depth.json")
        let maskPNG = cacheDir.appendingPathComponent(name + ".mask.png")
        if !FileManager.default.fileExists(atPath: depthBin.path) {
            guard let (body, resp) = await post("/api/depth", fields: [], jpeg: jpeg),
                  let w = Int(resp.value(forHTTPHeaderField: "X-Depth-Width") ?? ""),
                  let h = Int(resp.value(forHTTPHeaderField: "X-Depth-Height") ?? ""),
                  body.count == w * h * 4 else { return nil }
            try? body.write(to: depthBin)
            try? JSONSerialization.data(withJSONObject: ["width": w, "height": h]).write(to: depthMeta)
        }
        guard let metaData = try? Data(contentsOf: depthMeta),
              let meta = try? JSONSerialization.jsonObject(with: metaData) as? [String: Int],
              let w = meta["width"], let h = meta["height"],
              let bin = try? Data(contentsOf: depthBin) else { return nil }
        let meters = bin.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        guard let depth = EditRenderer.depthImage(meters: meters, width: w, height: h) else { return nil }

        if !FileManager.default.fileExists(atPath: maskPNG.path) {
            if let (rb, _) = await post("/api/regions", fields: [], jpeg: jpeg),
               let rj = try? JSONSerialization.jsonObject(with: rb) as? [String: Any],
               let regions = rj["regions"] as? [[String: Any]], !regions.isEmpty {
                let focus = regions.first { ($0["tag"] as? String) == "focus" } ?? regions[0]
                let regionsJSON = String(data: try! JSONSerialization.data(withJSONObject: [focus]), encoding: .utf8)!
                if let (mb, _) = await post("/api/masks", fields: [("regions", regionsJSON)], jpeg: jpeg),
                   let mj = try? JSONSerialization.jsonObject(with: mb) as? [String: Any],
                   let masks = mj["masks"] as? [String: [String: Any]],
                   let id = focus["id"] as? String, let png = masks[id]?["png"] as? String,
                   let comma = png.firstIndex(of: ","),
                   let bytes = Data(base64Encoded: String(png[png.index(after: comma)...])) {
                    try? bytes.write(to: maskPNG)
                }
            }
        }
        let mask = (try? Data(contentsOf: maskPNG)).flatMap(EditRenderer.maskImage(pngData:))
        return (depth, mask)
    }

    static func post(_ path: String, fields: [(String, String)], jpeg: Data) async -> (Data, HTTPURLResponse)? {
        let boundary = "coachedit-\(UUID().uuidString)"
        var body = Data()
        func add(_ s: String) { body.append(s.data(using: .utf8)!) }
        for (k, v) in fields {
            add("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n")
        }
        add("--\(boundary)\r\nContent-Disposition: form-data; name=\"image\"; filename=\"img.jpg\"\r\n")
        add("Content-Type: image/jpeg\r\n\r\n")
        body.append(jpeg)
        add("\r\n--\(boundary)--\r\n")
        var req = URLRequest(url: core.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        guard let (data, resp) = try? await URLSession.shared.upload(for: req, from: body),
              let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        return (data, http)
    }
}
