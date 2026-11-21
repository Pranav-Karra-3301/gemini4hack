import CoachModels
import CoreImage
import Metal
import XCTest
@testable import CoachEdit

final class CoachEditLookProbeTmp: XCTestCase {
    func testProbePasses() async throws {
        let r = EditRenderer()
        let s = try await LookFixtures.source("img-1216")
        r.register(look: try LookFixtures.look("img-1216_bold"))
        var rec = EditRecipe(values: [.warmth: 10]); rec.look = LookRef(id: "img-1216_bold", strength: 0.8)
        let img = r.render(source: s, depth: nil, subjectMask: nil, recipe: rec, quality: .preview(maxSide: 1280))
        let device = MTLCreateSystemDefaultDevice()!, queue = device.makeCommandQueue()!
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Int(img.extent.width), height: Int(img.extent.height), mipmapped: false)
        d.usage = [.shaderWrite, .shaderRead]
        let tex = device.makeTexture(descriptor: d)!, cb = queue.makeCommandBuffer()!
        try r.render(img, to: tex, commandBuffer: cb); cb.commit(); cb.waitUntilCompleted()
    }

    func testProbeLUTBucketCost() async throws {
        let r = EditRenderer()
        let s = try await LookFixtures.source("img-1216")
        let lut = try LookFixtures.lut("img-1216_bold")
        var t0 = CFAbsoluteTimeGetCurrent()
        for i in 0..<30 { _ = lut.cubeData(strength: 0.1 + Double(i) * 0.02) }
        let cpu = (CFAbsoluteTimeGetCurrent() - t0) * 1000 / 30
        r.register(look: EditLook(id: "l", lut: lut))
        let device = MTLCreateSystemDefaultDevice()!, queue = device.makeCommandQueue()!
        func once(_ st: Double) -> Double {
            var rec = EditRecipe(); rec.look = LookRef(id: "l", strength: st)
            let t = CFAbsoluteTimeGetCurrent()
            let img = r.render(source: s, depth: nil, subjectMask: nil, recipe: rec, quality: .preview(maxSide: 1280))
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Int(img.extent.width), height: Int(img.extent.height), mipmapped: false)
            d.usage = [.shaderWrite, .shaderRead]
            let tex = device.makeTexture(descriptor: d)!, cb = queue.makeCommandBuffer()!
            try! r.render(img, to: tex, commandBuffer: cb); cb.commit(); cb.waitUntilCompleted()
            return (CFAbsoluteTimeGetCurrent() - t) * 1000
        }
        for _ in 0..<5 { _ = once(1) }
        var cached: [Double] = [], fresh: [Double] = [], prebuilt: [Double] = []
        for i in 0..<30 { cached.append(once(1)); fresh.append(once(0.31 + Double(i) * 0.01)) }
        for i in 0..<30 { _ = lut.cubeData(strength: 0.71 + Double(i) * 0.005) } // not in render cache yet
        t0 = CFAbsoluteTimeGetCurrent()
        for i in 0..<6 { prebuilt.append(once(0.71 + Double(24 + i) * 0.005)) }
        func med(_ v: [Double]) -> Double { v.sorted()[v.count / 2] }
        print(String(format: "PROBE cubeData new bucket %.3f ms; render cached bucket %.2f ms, new bucket %.2f ms, CPU-cached but new to CI %.2f ms", cpu, med(cached), med(fresh), med(prebuilt)))
    }
}
