// Unit tests for CoachLive: Live API message encoding/decoding, the frame throttle and luma
// diff, JPEG encoding, PCM conversion (synthetic buffers) and the playback level envelope.
// Needs "CoachLive" in the CoachKitTests target's dependencies; compiled out until then.
#if canImport(CoachLive)
import AVFAudio
import CoreGraphics
import CoreImage
import CoreVideo
import ImageIO
import Testing
@testable import CoachLive

@Suite struct CoachLiveProtocolTests {
    private func object(_ s: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any])
    }

    @Test func setupEncoding() throws {
        #expect(try LiveClientMessage.setup(resumeHandle: nil).json() == #"{"setup":{"sessionResumption":{}}}"#)
        #expect(try LiveClientMessage.setup(resumeHandle: "").json() == #"{"setup":{"sessionResumption":{}}}"#)
        let o = try object(LiveClientMessage.setup(resumeHandle: "h/1+2").json())
        let resumption = (o["setup"] as? [String: Any])?["sessionResumption"] as? [String: Any]
        #expect(resumption?["handle"] as? String == "h/1+2")
    }

    @Test func realtimeAudioAndVideoEncoding() throws {
        let pcm = Data((0..<3200).map { UInt8($0 & 0xFF) })
        let a = try object(LiveClientMessage.audio(pcm).json())
        let audio = (a["realtimeInput"] as? [String: Any])?["audio"] as? [String: Any]
        #expect(audio?["mimeType"] as? String == "audio/pcm;rate=16000")
        #expect(Data(base64Encoded: audio?["data"] as? String ?? "") == pcm)

        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0xFF, 0xD9])
        let v = try object(LiveClientMessage.video(jpeg: jpeg).json())
        let video = (v["realtimeInput"] as? [String: Any])?["video"] as? [String: Any]
        #expect(video?["mimeType"] as? String == "image/jpeg")
        #expect(Data(base64Encoded: video?["data"] as? String ?? "") == jpeg)

        let end = try object(LiveClientMessage.audioStreamEnd.json())
        #expect((end["realtimeInput"] as? [String: Any])?["audioStreamEnd"] as? Bool == true)
    }

    @Test func textEncodingEscapes() throws {
        let text = "Move \"left\"\nthen hold — 好 / ok"
        let o = try object(LiveClientMessage.text(text).json())
        #expect((o["realtimeInput"] as? [String: Any])?["text"] as? String == text)
    }

    @Test func contextEncoding() throws {
        let o = try object(LiveClientMessage.context("[state] ISO 640").json())
        let cc = try #require(o["clientContent"] as? [String: Any])
        #expect(cc["turnComplete"] as? Bool == false)
        let turns = try #require(cc["turns"] as? [[String: Any]])
        #expect(turns.first?["role"] as? String == "user")
        let parts = try #require(turns.first?["parts"] as? [[String: Any]])
        #expect(parts.first?["text"] as? String == "[state] ISO 640")
    }

    @Test func toolResponseEncoding() throws {
        struct Applied: Codable { var iso: Int; var shutter: Double }
        let r1 = LiveFunctionResponse(id: "c1", name: "set_camera",
                                      response: try LiveFunctionResponse.object(encoding: ["ok": true]),
                                      scheduling: .silent)
        let r2 = LiveFunctionResponse(id: "c2", name: "guide",
                                      response: try LiveFunctionResponse.object(encoding: Applied(iso: 400, shutter: 0.008)),
                                      scheduling: .whenIdle)
        let r3 = LiveFunctionResponse(id: "c3", name: "take_photo", response: LiveFunctionResponse.object(from: "done"),
                                      scheduling: nil)
        let o = try object(LiveClientMessage.toolResponse([r1, r2, r3]).json())
        let list = try #require((o["toolResponse"] as? [String: Any])?["functionResponses"] as? [[String: Any]])
        #expect(list.count == 3)
        #expect(list[0]["id"] as? String == "c1")
        #expect(list[0]["name"] as? String == "set_camera")
        #expect((list[0]["response"] as? [String: Any])?["ok"] as? Bool == true)
        #expect(list[0]["scheduling"] as? String == "SILENT")
        #expect((list[1]["response"] as? [String: Any])?["iso"] as? Int == 400)
        #expect(list[1]["scheduling"] as? String == "WHEN_IDLE")
        #expect((list[2]["response"] as? [String: Any])?["result"] as? String == "done")
        #expect(list[2]["scheduling"] == nil)
        #expect(LiveScheduling.interrupt.rawValue == "INTERRUPT")
    }

    @Test func serverContentAudioAndTranscripts() throws {
        let a1 = Data([1, 0, 2, 0]), a2 = Data([3, 0])
        let json = """
        {"serverContent":{"modelTurn":{"parts":[
          {"inlineData":{"mimeType":"audio/pcm;rate=24000","data":"\(a1.base64EncodedString())"}},
          {"text":"thinking…","thought":true},
          {"inlineData":{"mimeType":"audio/pcm;rate=24000","data":"\(a2.base64EncodedString())"}}]},
          "outputTranscription":{"text":"Step left."},
          "inputTranscription":{"text":"which way"},
          "turnComplete":true,"generationComplete":true},
         "usageMetadata":{"totalTokenCount":12}}
        """
        let m = try LiveServerMessage(json: Data(json.utf8))
        #expect(m.audio == [a1, a2])
        #expect(m.text == [])
        #expect(m.outputTranscript == "Step left.")
        #expect(m.inputTranscript == "which way")
        #expect(m.turnComplete)
        #expect(m.generationComplete)
        #expect(!(m.interrupted))
        #expect(!(m.setupComplete))

        let i = try LiveServerMessage(json: Data(#"{"serverContent":{"interrupted":true}}"#.utf8))
        #expect(i.interrupted)
        #expect(try LiveServerMessage(json: Data(#"{"setupComplete":{}}"#.utf8)).setupComplete)
    }

    @Test func toolCallAndCancellation() throws {
        let json = """
        {"toolCall":{"functionCalls":[
          {"id":"a","name":"guide","args":{"direction":"left","strength":"small"}},
          {"id":"b","name":"take_photo"}]}}
        """
        let m = try LiveServerMessage(json: Data(json.utf8))
        #expect(m.toolCalls.map(\.id) == ["a", "b"])
        #expect(m.toolCalls.map(\.name) == ["guide", "take_photo"])
        let args = LiveToolArgs.dictionary(m.toolCalls[0].argsJSON)
        #expect(args["direction"] as? String == "left")
        #expect(args["strength"] as? String == "small")
        #expect(m.toolCalls[1].argsJSON == "{}")
        struct Guide: Decodable { var direction: String }
        #expect(try LiveToolArgs.decode(Guide.self, from: m.toolCalls[0].argsJSON).direction == "left")

        let c = try LiveServerMessage(json: Data(#"{"toolCallCancellation":{"ids":["a","b"]}}"#.utf8))
        #expect(c.cancelledToolCallIDs == ["a", "b"])
    }

    @Test func goAwayAndResumption() throws {
        #expect(try LiveServerMessage(json: Data(#"{"goAway":{"timeLeft":"9.5s"}}"#.utf8)).goAwayTimeLeft == 9.5)
        #expect(try LiveServerMessage(json: Data(#"{"goAway":{}}"#.utf8)).goAwayTimeLeft == 0)
        #expect(try LiveServerMessage(json: Data(#"{"setupComplete":{}}"#.utf8)).goAwayTimeLeft == nil)

        let ok = try LiveServerMessage(json: Data(#"{"sessionResumptionUpdate":{"newHandle":"H1","resumable":true}}"#.utf8))
        #expect(ok.resumeHandle == "H1")
        let no = try LiveServerMessage(json: Data(#"{"sessionResumptionUpdate":{"newHandle":"H2","resumable":false}}"#.utf8))
        #expect(no.resumeHandle == nil)
        let empty = try LiveServerMessage(json: Data(#"{"sessionResumptionUpdate":{"resumable":true}}"#.utf8))
        #expect(empty.resumeHandle == nil)
        #expect(throws: (any Error).self) { try LiveServerMessage(json: Data("[1]".utf8)) }
    }

    @Test func credentialParsing() throws {
        let body = #"{"token":"auth_tokens/x","model":"gemini-3.8-live","ws_url":"wss://example.com/ws?access_token=x","expire_time":"2026-11-21T10:00:00.5Z","new_session_expire_time":"2026-11-21T09:31:00Z"}"#
        let c = try LiveCredential(coreTokenJSON: Data(body.utf8))
        #expect(c.wsURL.host == "example.com")
        #expect(c.model == "gemini-3.8-live")
        let exp = try #require(c.expireTime)
        let newSession = try #require(c.newSessionExpireTime)
        #expect(!(c.isExpired(now: newSession.addingTimeInterval(-60))))
        #expect(c.isExpired(now: newSession.addingTimeInterval(-1)))
        #expect(exp > newSession)
        #expect(throws: (any Error).self) { try LiveCredential(coreTokenJSON: Data("{}".utf8)) }
    }
}

@Suite struct CoachLiveFrameTests {
    /// A synthetic scene: horizontal gradient plus a bright square at (sx, sy).
    static func scene(width: Int = 640, height: Int = 480, square: (Int, Int)? = (100, 100), noise: UInt8 = 0,
                      seed: UInt64 = 1) -> CGImage {
        var rng = CoachLiveRNG(seed: seed)
        var px = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                var v = Int(x * 200 / width)
                if let (sx, sy) = square, x >= sx, x < sx + 120, y >= sy, y < sy + 120 { v = 250 }
                if noise > 0 { v += Int(rng.next() % UInt64(noise)) - Int(noise / 2) }
                let c = UInt8(clamping: v)
                let i = (y * width + x) * 4
                px[i] = c; px[i + 1] = c; px[i + 2] = c
            }
        }
        let ctx = CGContext(data: &px, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        return ctx.makeImage()!
    }

    @Test func throttleRateAndChangeDetection() {
        let a = LumaThumbnail(cgImage: Self.scene())!
        let aNoisy = LumaThumbnail(cgImage: Self.scene(noise: 6, seed: 7))!
        let b = LumaThumbnail(cgImage: Self.scene(square: (400, 300)))!

        var t = FrameThrottle()
        #expect(t.offer(a, at: 0) == .send)            // first frame always goes
        #expect(!(t.isDue(at: 0.5)))
        #expect(t.offer(b, at: 0.5) == .tooSoon)       // ≤ 1 fps even if changed
        #expect(t.offer(aNoisy, at: 1.1) == .unchanged) // sensor noise isn't a change
        #expect(t.offer(b, at: 1.2) == .tooSoon)       // recheck interval after an unchanged frame
        #expect(t.offer(b, at: 1.4) == .send)          // the subject moved
        #expect(t.offer(b, at: 5) == .unchanged)
        t.reset()
        #expect(t.offer(b, at: 5.1) == .send)          // after reset the next frame goes

        var stale = FrameThrottle(maxStaleInterval: 10)
        #expect(stale.offer(a, at: 0) == .send)
        #expect(stale.offer(a, at: 5) == .unchanged)
        #expect(stale.offer(a, at: 10) == .send)       // keep the model's view fresh

        let d = a.difference(to: b)
        #expect(d.changedFraction > 0.04)
        #expect(a.difference(to: aNoisy).mean < 0.02)
    }

    @Test func thumbnailsAgreeAcrossSources() throws {
        let img = Self.scene(width: 1280, height: 720)
        let fromCG = try #require(LumaThumbnail(cgImage: img))
        let jpeg = try #require(LiveFrameEncoder.jpeg(from: img, maxDimension: 1280, quality: 0.8))
        let fromJPEG = try #require(LumaThumbnail(imageData: jpeg))
        let bgra = try #require(Self.pixelBuffer(from: img, format: kCVPixelFormatType_32BGRA))
        let fromBGRA = try #require(LumaThumbnail(pixelBuffer: bgra))
        let yuv = try #require(Self.pixelBuffer(from: img, format: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange))
        let fromYUV = try #require(LumaThumbnail(pixelBuffer: yuv))
        #expect(fromCG.difference(to: fromJPEG).mean < 0.02)
        #expect(fromCG.difference(to: fromBGRA).mean < 0.03)
        #expect(fromCG.difference(to: fromYUV).mean < 0.03)
    }

    @Test func jpegEncodingSizes() throws {
        let wide = Self.scene(width: 2000, height: 1000)
        let j = try #require(LiveFrameEncoder.jpeg(from: wide))
        #expect(try Self.size(j).0 == 768)
        #expect(try Self.size(j).1 == 384)
        let small = Self.scene(width: 320, height: 240)
        #expect(try Self.size(#require(LiveFrameEncoder.jpeg(from: small))).0 == 320)

        let pb = try #require(Self.pixelBuffer(from: Self.scene(width: 1920, height: 1080),
                                                 format: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange))
        let upright = try #require(LiveFrameEncoder.jpeg(from: pb))
        #expect(try Self.size(upright).0 == 768)
        #expect(try Self.size(upright).1 == 432)
        let portrait = try #require(LiveFrameEncoder.jpeg(from: pb, orientation: .right))
        #expect(try Self.size(portrait).0 == 432)
        #expect(try Self.size(portrait).1 == 768)
        #expect(portrait.count < 120_000)
    }

    @Test func throttleCostIsSmall() throws {
        let pb = try #require(Self.pixelBuffer(from: Self.scene(width: 1920, height: 1080),
                                                 format: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange))
        let t0 = Date()
        for _ in 0..<100 { _ = LumaThumbnail(pixelBuffer: pb) }
        let thumbMs = Date().timeIntervalSince(t0) * 10
        let t1 = Date()
        for _ in 0..<10 { _ = LiveFrameEncoder.jpeg(from: pb) }
        let jpegMs = Date().timeIntervalSince(t1) * 100
        print("CoachLive frame cost: luma thumbnail \(String(format: "%.3f", thumbMs)) ms, JPEG 1080p→768 \(String(format: "%.1f", jpegMs)) ms")
        #expect(thumbMs < 5)
    }

    // MARK: helpers

    static func size(_ jpeg: Data) throws -> (Int, Int) {
        let src = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
        return (props[kCGImagePropertyPixelWidth] as? Int ?? 0, props[kCGImagePropertyPixelHeight] as? Int ?? 0)
    }

    static func pixelBuffer(from image: CGImage, format: OSType) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        guard CVPixelBufferCreate(nil, image.width, image.height, format, attrs, &pb) == kCVReturnSuccess,
              let pb else { return nil }
        LiveFrameEncoder.ciContext.render(CIImage(cgImage: image), to: pb)
        return pb
    }
}

@Suite struct CoachLivePCMTests {
    private func sine(rate: Double, channels: AVAudioChannelCount, frames: Int, freq: Double, amp: Float,
                      offset: Int) -> AVAudioPCMBuffer {
        let f = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
        let b = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: AVAudioFrameCount(frames))!
        b.frameLength = AVAudioFrameCount(frames)
        for c in 0..<Int(channels) {
            let p = b.floatChannelData![c]
            for i in 0..<frames {
                // Channel 1+ is out of phase garbage: only channel 0 must be used.
                let v = amp * Float(sin(2 * .pi * freq * Double(offset + i) / rate))
                p[i] = c == 0 ? v : -v * 0.3
            }
        }
        return b
    }

    private func analyze(_ chunks: [Data]) -> (samples: [Int16], rms: Float, crossingsPerSecond: Double) {
        var s: [Int16] = []
        for c in chunks { c.withUnsafeBytes { s.append(contentsOf: $0.bindMemory(to: Int16.self)) } }
        let steady = Array(s.dropFirst(800)) // skip resampler priming
        let rms = sqrt(steady.reduce(0) { $0 + Float($1) * Float($1) } / Float(max(1, steady.count))) / 32768
        var crossings = 0
        for i in 1..<steady.count where (steady[i - 1] < 0) != (steady[i] < 0) { crossings += 1 }
        return (s, rms, Double(crossings) / (Double(steady.count) / 16_000))
    }

    @Test func captureConverter48kStereoFloat() throws {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let conv = try #require(LiveCaptureConverter(inputFormat: fmt))
        #expect(conv.chunkBytes == 1280) // 40 ms
        var chunks: [Data] = []
        var offset = 0
        for _ in 0..<47 { // 47 × 1024 frames ≈ 1.003 s
            chunks += conv.process(sine(rate: 48_000, channels: 2, frames: 1024, freq: 440, amp: 0.5, offset: offset))
            offset += 1024
        }
        #expect(chunks.allSatisfy { $0.count == 1280 })
        #expect(chunks.count >= 24)
        #expect(chunks.count <= 25)
        let a = analyze(chunks)
        #expect(abs(Double(a.rms) - Double(0.5 / sqrt(2))) <= Double(0.02))
        #expect(abs(Double(a.crossingsPerSecond) - Double(880)) <= Double(20))
    }

    @Test func captureConverterInt16Interleaved44k() throws {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 44_100, channels: 1, interleaved: true)!
        let conv = try #require(LiveCaptureConverter(inputFormat: fmt))
        var chunks: [Data] = []
        var offset = 0
        for _ in 0..<20 {
            let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 4410)!
            b.frameLength = 4410
            let p = b.int16ChannelData![0]
            for i in 0..<4410 { p[i] = Int16(8000 * sin(2 * .pi * 1000 * Double(offset + i) / 44_100)) }
            offset += 4410
            chunks += conv.process(b)
        }
        #expect(chunks.count >= 48) // 2 s in 40 ms chunks, minus resampler latency
        let a = analyze(chunks)
        #expect(abs(Double(a.rms) - 8000.0 / 32768.0 / sqrt(2.0)) <= Double(0.01))
        #expect(abs(Double(a.crossingsPerSecond) - Double(2000)) <= Double(30))
        let rest = conv.drain()?.count ?? 0
        #expect(rest < 1280 && rest % 2 == 0) // leftover below one chunk
        #expect(conv.drain() == nil)
    }

    @Test func playbackConversionRoundTripAndClipping() throws {
        let floats: [Float] = [0, 0.5, -0.5, 1.5, -1.5, 0.25]
        let data = floats.withUnsafeBufferPointer { LivePCM.int16Data($0) }
        #expect(data.count == 12)
        let buf = try #require(LivePCM.floatBuffer(pcm16: data))
        #expect(buf.format.sampleRate == 24_000)
        #expect(Int(buf.frameLength) == 6)
        let p = buf.floatChannelData![0]
        #expect(abs(Double(p[1]) - Double(0.5)) <= Double(0.001))
        #expect(abs(Double(p[2]) - Double(-0.5)) <= Double(0.001))
        #expect(abs(Double(p[3]) - Double(1)) <= 0.001)   // clipped
        #expect(abs(Double(p[4]) - Double(-1)) <= 0.001)  // clipped
        #expect(LivePCM.floatBuffer(pcm16: Data([1])) == nil)
        #expect(LivePCM.rms(pcm16: Data(repeating: 0, count: 100)) == 0)
        #expect(LivePCM.meterLevel(rms: 1) == 1)
        #expect(LivePCM.meterLevel(rms: 0.001) == 0)
    }

    @MainActor @Test func liveAudioIsInertBeforeStart() {
        // No engine start (that needs a mic): audio arriving early must be dropped safely.
        let audio = LiveAudio()
        audio.enqueue(pcm24k: Data(count: 4801))
        audio.flush()
        audio.isOutputMuted = true
        audio.isMicMuted = true
        #expect(audio.currentOutputLevel == 0)
        #expect(!audio.isRunning && !audio.isPlaying)
        audio.stop()
    }

    @Test func levelEnvelopeFollowsPlayhead() {
        var env = LevelEnvelope(window: 480)
        let loud = [Float](repeating: 0.5, count: 960), quiet = [Float](repeating: 0.1, count: 480)
        loud.withUnsafeBufferPointer { env.append($0, start: 0) }
        quiet.withUnsafeBufferPointer { env.append($0, start: 960) }
        let l10 = env.level(at: 10), l500 = env.level(at: 500), l1000 = env.level(at: 1000)
        #expect(abs(l10 - 0.5) <= 0.001)
        #expect(abs(l500 - 0.5) <= 0.001)
        #expect(abs(l1000 - 0.1) <= 0.001)
        #expect(env.starts.count == 1) // earlier windows pruned
        let l2000 = env.level(at: 2000)
        #expect(l2000 == 0)
    }
}

/// Deterministic noise for synthetic frames.
struct CoachLiveRNG {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
#endif
