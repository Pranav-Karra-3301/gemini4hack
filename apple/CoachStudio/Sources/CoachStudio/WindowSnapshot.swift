import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// QA only (`-snapshotDir`): saves PNGs of CoachStudio's own main window. An app may capture its
/// own windows without screen-recording permission; `CGWindowListCreateImage` is unavailable to
/// Swift in the macOS 15+ SDK, so it's looked up at runtime.
@MainActor
enum WindowSnapshot {
    private typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
    private static let createImage: CreateImage? = {
        guard let h = dlopen(nil, RTLD_NOW), let sym = dlsym(h, "CGWindowListCreateImage") else { return nil }
        return unsafeBitCast(sym, to: CreateImage.self)
    }()
    private static var counter = 0

    /// Writes `<dir>/<nn>_<label>.png`; returns the path.
    @discardableResult
    static func save(_ label: String) -> String? {
        guard let dir = StudioAutomation.snapshotDir,
              let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain && $0.title != "Core Log" }),
              let create = createImage else { return nil }
        // .optionIncludingWindow = 1 << 3, .boundsIgnoreFraming = 1 << 0, .bestResolution = 1 << 3
        // A sheet is its own window: capture it instead when one is up.
        let target = window.attachedSheet ?? window
        guard let img = create(.null, 1 << 3, UInt32(target.windowNumber), (1 << 0) | (1 << 3))?.takeRetainedValue()
        else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        counter += 1
        let url = dir.appendingPathComponent(String(format: "%02d_%@.png", counter, label))
        guard let dst = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, img, nil)
        CGImageDestinationFinalize(dst)
        return url.path
    }
}
