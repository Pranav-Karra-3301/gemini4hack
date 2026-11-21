import CoachModels
import CoreImage
import Foundation

/// A 3D LUT from a `.cube` file (Adobe/Resolve format, red fastest), sRGB in and out
/// (CORE_API.md §6). Applied with `CIColorCubeWithColorSpace`; strength mixes the table with
/// identity on the CPU, cached per strength bucket (1/100), so a strength drag is one GPU pass.
/// Immutable and thread-safe.
public final class CubeLUT: @unchecked Sendable {
    /// Entries per axis (Core sends 33).
    public let size: Int
    public let title: String?
    /// size³ RGB triples, red fastest then green then blue (the `.cube` order).
    public let table: [Float]

    private let lock = NSLock()
    private var cache: [(bucket: Int, data: Data)] = []
    private static let cacheLimit = 6

    public enum ParseError: Error, Equatable {
        case missingSize
        case unsupported(String)
        case badLine(Int)
        case wrongCount(expected: Int, got: Int)
    }

    /// Parses `.cube` text: `TITLE`, `LUT_3D_SIZE` (2...64), optional `DOMAIN_MIN 0 0 0` /
    /// `DOMAIN_MAX 1 1 1`, `#` comments, then size³ `r g b` rows.
    public init(cube text: String) throws {
        var size = 0
        var title: String?
        var values: [Float] = []
        var lineNo = 0
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            lineNo += 1
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let head = parts.first else { continue }
            if let first = head.first, first.isNumber || first == "-" || first == "." || first == "+" {
                guard parts.count == 3, let r = Float(parts[0]), let g = Float(parts[1]), let b = Float(parts[2]),
                      r.isFinite, g.isFinite, b.isFinite else { throw ParseError.badLine(lineNo) }
                values.append(r); values.append(g); values.append(b)
                continue
            }
            switch head.uppercased() {
            case "TITLE":
                title = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            case "LUT_3D_SIZE":
                guard parts.count == 2, let n = Int(parts[1]), (2...64).contains(n) else {
                    throw ParseError.unsupported(line)
                }
                size = n
            case "LUT_1D_SIZE":
                throw ParseError.unsupported("1D LUT")
            case "DOMAIN_MIN", "DOMAIN_MAX":
                let want: Float = head.uppercased() == "DOMAIN_MIN" ? 0 : 1
                let v = parts.dropFirst().compactMap { Float($0) }
                guard v.count == 3, v.allSatisfy({ abs($0 - want) < 1e-6 }) else { throw ParseError.unsupported(line) }
            default:
                continue // LUT_IN_VIDEO_RANGE etc.: ignore unknown keywords
            }
        }
        guard size > 0 else { throw ParseError.missingSize }
        let expected = size * size * size * 3
        guard values.count == expected else { throw ParseError.wrongCount(expected: expected / 3, got: values.count / 3) }
        self.size = size
        self.title = title
        self.table = values
    }

    /// Loads a `.cube` file.
    public convenience init(contentsOf url: URL) throws {
        try self.init(cube: String(contentsOf: url, encoding: .utf8))
    }

    /// A LUT from raw RGB triples (red fastest), e.g. built in code.
    public init(size: Int, table: [Float], title: String? = nil) {
        precondition(size >= 2 && table.count == size * size * size * 3)
        self.size = size; self.table = table; self.title = title
    }

    /// The identity LUT (output = input).
    public static func identity(size: Int = 33) -> CubeLUT {
        var t = [Float](repeating: 0, count: size * size * size * 3)
        let d = Float(size - 1)
        for b in 0..<size { for g in 0..<size { for r in 0..<size {
            let i = ((b * size + g) * size + r) * 3
            t[i] = Float(r) / d; t[i + 1] = Float(g) / d; t[i + 2] = Float(b) / d
        } } }
        return CubeLUT(size: size, table: t, title: "identity")
    }

    /// Quantizes strength to 1/100 (the LUT cache key).
    static func bucket(_ strength: Double) -> Int {
        guard strength.isFinite else { return 100 }
        return Int((min(max(strength, 0), 1) * 100).rounded())
    }

    /// `inputCubeData` for `CIColorCubeWithColorSpace`: RGBA float32, `identity + (lut - identity) * strength`.
    /// Cached per strength bucket.
    public func cubeData(strength: Double) -> Data {
        let key = Self.bucket(strength)
        lock.lock()
        if let i = cache.firstIndex(where: { $0.bucket == key }) {
            let hit = cache.remove(at: i)
            cache.insert(hit, at: 0)
            lock.unlock()
            return hit.data
        }
        lock.unlock()
        let s = Float(key) / 100
        let n = size, count = n * n * n
        let d = Float(n - 1)
        var rgba = [Float](repeating: 1, count: count * 4)
        table.withUnsafeBufferPointer { t in
            rgba.withUnsafeMutableBufferPointer { o in
                for i in 0..<count {
                    let r = Float(i % n) / d, g = Float((i / n) % n) / d, b = Float(i / (n * n)) / d
                    o[i * 4] = r + (t[i * 3] - r) * s
                    o[i * 4 + 1] = g + (t[i * 3 + 1] - g) * s
                    o[i * 4 + 2] = b + (t[i * 3 + 2] - b) * s
                }
            }
        }
        let data = rgba.withUnsafeBytes { Data($0) }
        lock.lock()
        cache.insert((key, data), at: 0)
        if cache.count > Self.cacheLimit { cache.removeLast() }
        lock.unlock()
        return data
    }

    static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Applies the LUT at `strength` (0 returns `image`). Input is converted to sRGB for the lookup
    /// and back to the working space, as the `.cube` expects.
    public func apply(to image: CIImage, strength: Double = 1) -> CIImage {
        guard Self.bucket(strength) > 0 else { return image }
        return image.applyingFilter("CIColorCubeWithColorSpace", parameters: [
            "inputCubeDimension": size,
            "inputCubeData": cubeData(strength: strength),
            "inputColorSpace": Self.srgb,
        ])
    }
}

/// A look ready to render: its LUT plus effects. Register it on an `EditRenderer`; recipes then
/// pick it with `recipe.look = LookRef(id:strength:)`.
public struct EditLook: Sendable {
    public var id: String
    public var lut: CubeLUT
    public var effects: LookEffects

    public init(id: String, lut: CubeLUT, effects: LookEffects = .none) {
        self.id = id; self.lut = lut; self.effects = effects
    }

    /// From the `.cube` text of `GET <look.lut>` and the look's `effects`.
    public init(id: String, cube: String, effects: LookEffects?) throws {
        self.init(id: id, lut: try CubeLUT(cube: cube), effects: effects ?? .none)
    }
}

/// Looks registered on one renderer, by id. Thread-safe.
final class LookLibrary: @unchecked Sendable {
    private let lock = NSLock()
    private var looks: [String: EditLook] = [:]

    subscript(id: String) -> EditLook? {
        get { lock.lock(); defer { lock.unlock() }; return looks[id] }
        set { lock.lock(); looks[id] = newValue; lock.unlock() }
    }

    /// The look a recipe asks for, if registered and with a non-zero strength.
    func resolve(_ ref: LookRef?) -> ActiveLook? {
        guard let ref, CubeLUT.bucket(ref.strength) > 0, let look = self[ref.id] else { return nil }
        return ActiveLook(look: look, strength: Double(CubeLUT.bucket(ref.strength)) / 100)
    }
}

/// A registered look plus the recipe's strength (0.01...1, quantized like the LUT cache).
struct ActiveLook {
    let look: EditLook
    let strength: Double
}

extension EditRenderer {
    /// Makes `look` available to recipes whose `look.id` matches (replaces one with the same id).
    /// A recipe naming an unregistered look renders without it.
    public func register(look: EditLook) { looks[look.id] = look }

    /// Forgets a registered look.
    public func removeLook(id: String) { looks[id] = nil }

    /// The registered look with this id.
    public func registeredLook(id: String) -> EditLook? { looks[id] }
}
