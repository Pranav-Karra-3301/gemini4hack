// Apply a .cube with Core Image's CIColorCubeWithColorSpace (as CoachEdit would) and write a PNG.
// usage: swift ci_check.swift in.jpg look.cube out.png [strength]
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

let a = CommandLine.arguments
let strength = a.count > 4 ? Float(a[4])! : 1.0
let lines = try! String(contentsOfFile: a[2], encoding: .utf8).split(separator: "\n")
var n = 0
var rgb: [Float] = []
for l in lines {
    if l.hasPrefix("LUT_3D_SIZE") { n = Int(l.split(separator: " ")[1])! }
    let p = l.split(separator: " ").compactMap { Float($0) }
    if p.count == 3 && !l.hasPrefix("DOMAIN") { rgb += p }
}
// RGBA float32, red fastest: identical order to .cube. Strength = mix with identity (prebaked).
var data = [Float](repeating: 1, count: n * n * n * 4)
for i in 0..<(n * n * n) {
    let r = i % n, g = (i / n) % n, b = i / (n * n)
    let id = [Float(r), Float(g), Float(b)].map { $0 / Float(n - 1) }
    for c in 0..<3 { data[i * 4 + c] = id[c] + (rgb[i * 3 + c] - id[c]) * strength }
}
let cube = Data(bytes: data, count: data.count * 4)
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
let input = CIImage(contentsOf: URL(fileURLWithPath: a[1]))!
let f = CIFilter(name: "CIColorCubeWithColorSpace")!
f.setValue(input, forKey: kCIInputImageKey)
f.setValue(n, forKey: "inputCubeDimension")
f.setValue(cube, forKey: "inputCubeData")
f.setValue(srgb, forKey: "inputColorSpace")
let ctx = CIContext()
let out = f.outputImage!
let cg = ctx.createCGImage(out, from: input.extent, format: .RGBA8, colorSpace: srgb)!
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: a[3]) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, cg, nil)
CGImageDestinationFinalize(dest)
print("ok", n)
