import Accelerate
import AVFAudio
import Foundation

// PCM plumbing for Live audio, kept free of AVAudioEngine so it can be unit-tested with
// synthetic buffers: mic buffers → 16 kHz mono PCM16 in fixed 40 ms chunks, Gemini's
// 24 kHz PCM16 → Float32 buffers for AVAudioPlayerNode, and RMS levels for meters.

/// Sample formats and conversions used by Gemini Live audio.
public enum LivePCM {
    /// Mic audio sent to Gemini: 16 kHz mono PCM16 LE.
    public static let inputRate: Double = 16_000
    /// Speech from Gemini: 24 kHz mono PCM16 LE.
    public static let outputRate: Double = 24_000

    /// Float32 mono at `rate`, the format the player node is connected with.
    static func floatFormat(rate: Double) -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
    }

    /// PCM16 LE bytes → a Float32 buffer (−1…1). A trailing odd byte is ignored.
    static func floatBuffer(pcm16 data: Data, rate: Double = outputRate) -> AVAudioPCMBuffer? {
        let frames = data.count / 2
        guard frames > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: floatFormat(rate: rate), frameCapacity: AVAudioFrameCount(frames)),
              let dst = buf.floatChannelData?[0] else { return nil }
        data.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Int16.self)
            vDSP_vflt16(src.baseAddress!, 1, dst, 1, vDSP_Length(frames))
        }
        var scale: Float = 1 / 32768
        vDSP_vsmul(dst, 1, &scale, dst, 1, vDSP_Length(frames))
        buf.frameLength = AVAudioFrameCount(frames)
        return buf
    }

    /// Float samples → PCM16 LE bytes, clipped to −1…1.
    static func int16Data(_ samples: UnsafeBufferPointer<Float>) -> Data {
        let n = samples.count
        guard n > 0, let base = samples.baseAddress else { return Data() }
        var clipped = [Float](repeating: 0, count: n)
        var lo: Float = -1, hi: Float = 32767.0 / 32768.0
        vDSP_vclip(base, 1, &lo, &hi, &clipped, 1, vDSP_Length(n))
        var scale: Float = 32768
        vDSP_vsmul(clipped, 1, &scale, &clipped, 1, vDSP_Length(n))
        var out = Data(count: n * 2)
        out.withUnsafeMutableBytes { raw in
            vDSP_vfixr16(clipped, 1, raw.bindMemory(to: Int16.self).baseAddress!, 1, vDSP_Length(n))
        }
        return out
    }

    /// Root-mean-square of float samples (0 for silence, ~0.707 for a full-scale sine).
    static func rms(_ samples: UnsafeBufferPointer<Float>) -> Float {
        guard let base = samples.baseAddress, !samples.isEmpty else { return 0 }
        var r: Float = 0
        vDSP_rmsqv(base, 1, &r, vDSP_Length(samples.count))
        return r
    }

    /// RMS of PCM16 LE bytes, normalized to 0…1.
    static func rms(pcm16 data: Data) -> Float {
        let n = data.count / 2
        guard n > 0 else { return 0 }
        var floats = [Float](repeating: 0, count: n)
        data.withUnsafeBytes { raw in
            vDSP_vflt16(raw.bindMemory(to: Int16.self).baseAddress!, 1, &floats, 1, vDSP_Length(n))
        }
        return floats.withUnsafeBufferPointer { rms($0) } / 32768
    }

    /// A meter-friendly 0…1 value from an RMS (−50 dBFS → 0, 0 dBFS → 1).
    public static func meterLevel(rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        return max(0, min(1, (db + 50) / 50))
    }
}

/// Converts mic buffers (any sample rate, any channel count, float or int) into 16 kHz mono
/// PCM16 chunks of exactly `chunkBytes` (40 ms = 1280 bytes by default: the Live API best
/// practices ask for 20-40 ms chunks; 100 ms chunks delay end-of-speech detection by up to 60 ms).
/// Not thread-safe: use from the single tap thread.
final class LiveCaptureConverter {
    let inputFormat: AVAudioFormat
    let chunkBytes: Int
    private let monoFormat: AVAudioFormat
    private let outFormat: AVAudioFormat
    private let resampler: AVAudioConverter
    /// For non-float or interleaved inputs: input → mono Float32 at the input rate.
    private let preConverter: AVAudioConverter?
    private var scratch: AVAudioPCMBuffer?
    private var pending = Data()

    init?(inputFormat: AVAudioFormat, chunkDuration: TimeInterval = 0.04) {
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { return nil }
        self.inputFormat = inputFormat
        chunkBytes = Int(LivePCM.inputRate * chunkDuration) * 2
        monoFormat = LivePCM.floatFormat(rate: inputFormat.sampleRate)
        guard let out = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: LivePCM.inputRate,
                                      channels: 1, interleaved: true),
              let rs = AVAudioConverter(from: monoFormat, to: out) else { return nil }
        outFormat = out
        resampler = rs
        if inputFormat.commonFormat == .pcmFormatFloat32 && !inputFormat.isInterleaved {
            preConverter = nil
        } else {
            guard let pc = AVAudioConverter(from: inputFormat, to: monoFormat) else { return nil }
            pc.downmix = true
            preConverter = pc
        }
    }

    /// Feeds one buffer; returns every complete chunk now available (often zero or one).
    func process(_ buffer: AVAudioPCMBuffer) -> [Data] {
        guard buffer.frameLength > 0, let mono = monoBuffer(buffer) else { return [] }
        let capacity = AVAudioFrameCount((Double(mono.frameLength) * LivePCM.inputRate / inputFormat.sampleRate).rounded(.up)) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return [] }
        var fed = false
        var error: NSError?
        let status = resampler.convert(to: out, error: &error) { _, inputStatus in
            if fed { inputStatus.pointee = .noDataNow; return nil }
            fed = true
            inputStatus.pointee = .haveData
            return mono
        }
        guard status != .error, out.frameLength > 0, let p = out.int16ChannelData?[0] else { return [] }
        pending.append(UnsafeBufferPointer(start: p, count: Int(out.frameLength)))
        var chunks: [Data] = []
        while pending.count >= chunkBytes {
            chunks.append(pending.prefix(chunkBytes))
            pending.removeFirst(chunkBytes)
        }
        // Keep `pending` compact (removeFirst on Data can leave a sliced startIndex).
        if pending.startIndex != 0 { pending = Data(pending) }
        return chunks.map { Data($0) }
    }

    /// Whatever is buffered below a full chunk (call when the mic stops).
    func drain() -> Data? {
        defer { pending.removeAll() }
        return pending.isEmpty ? nil : Data(pending)
    }

    /// Channel 0 as mono Float32 (no copy when the input already is mono Float32).
    private func monoBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if let pre = preConverter {
            guard let out = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameLength) else { return nil }
            do { try pre.convert(to: out, from: buffer) } catch { return nil }
            return out
        }
        if buffer.format.channelCount == 1 { return buffer }
        // Voice processing can report several channels (macOS); channel 0 is the processed mic.
        if scratch == nil || scratch!.frameCapacity < buffer.frameLength {
            scratch = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: max(buffer.frameLength, 4096))
        }
        guard let s = scratch, let src = buffer.floatChannelData?[0], let dst = s.floatChannelData?[0] else { return nil }
        dst.update(from: src, count: Int(buffer.frameLength))
        s.frameLength = buffer.frameLength
        return s
    }
}

/// Loudness over time of scheduled playback, so the meter shows what is audible *now* rather
/// than what just arrived from the network. Frames are counted on the player's 24 kHz timeline.
struct LevelEnvelope {
    /// 20 ms windows at 24 kHz.
    let window: Int64
    private(set) var starts: [Int64] = []
    private(set) var levels: [Float] = []

    init(window: Int64 = 480) { self.window = window }

    /// Records RMS per window for `samples` starting at player frame `start`.
    mutating func append(_ samples: UnsafeBufferPointer<Float>, start: Int64) {
        var offset = 0
        while offset < samples.count {
            let n = min(Int(window), samples.count - offset)
            let slice = UnsafeBufferPointer(rebasing: samples[offset..<(offset + n)])
            starts.append(start + Int64(offset))
            levels.append(LivePCM.rms(slice))
            offset += n
        }
    }

    /// RMS at player frame `t` (0 when nothing is scheduled there). Drops windows before `t`.
    mutating func level(at t: Int64) -> Float {
        var drop = 0
        while drop < starts.count && starts[drop] + window <= t { drop += 1 }
        if drop > 0 {
            starts.removeFirst(drop)
            levels.removeFirst(drop)
        }
        guard let first = starts.first, first <= t else { return 0 }
        return levels[0]
    }

    mutating func reset() {
        starts.removeAll()
        levels.removeAll()
    }
}
