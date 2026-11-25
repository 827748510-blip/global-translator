import Accelerate
import Darwin
import Foundation

/// 16 kHz mono PCM helpers for on-device Whisper.cpp. Audio never leaves
/// process memory except a short-lived local WAV scratch file.
public enum AudioPCM {
    public static let whisperSampleRate = 16_000

    public static func int16Array(from data: Data) -> [Int16] {
        guard data.count >= 2 else { return [] }
        let count = data.count / 2
        #if _endian(little)
        return data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return [] }
            return [Int16](unsafeUninitializedCapacity: count) { dest, initializedCount in
                memcpy(dest.baseAddress!, base, count * MemoryLayout<Int16>.size)
                initializedCount = count
            }
        }
        #else
        return data.withUnsafeBytes { raw in
            var samples = [Int16](repeating: 0, count: count)
            for index in 0..<count {
                let offset = index * 2
                let little = UInt16(raw[offset]) | (UInt16(raw[offset + 1]) << 8)
                samples[index] = Int16(bitPattern: little)
            }
            return samples
        }
        #endif
    }

    public static func data(from samples: [Int16]) -> Data {
        guard !samples.isEmpty else { return Data() }
        #if _endian(little)
        return samples.withUnsafeBytes { Data($0) }
        #else
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            var le = UInt16(bitPattern: sample).littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        return data
        #endif
    }

    public static func mixToMonoInt16(floatSamples: [Float], channels: Int) -> [Int16] {
        let channelCount = max(channels, 1)
        guard !floatSamples.isEmpty else { return [] }
        if channelCount == 1 {
            return floatSamples.withUnsafeBufferPointer { floatBufferToInt16($0) }
        }
        let frames = floatSamples.count / channelCount
        guard frames > 0 else { return [] }
        var monoFloats = [Float](repeating: 0, count: frames)
        let scale = 1.0 / Float(channelCount)
        floatSamples.withUnsafeBufferPointer { src in
            guard let base = src.baseAddress else { return }
            monoFloats.withUnsafeMutableBufferPointer { dst in
                guard let dstBase = dst.baseAddress else { return }
                if channelCount == 2 {
                    vDSP_vadd(base, 2, base.advanced(by: 1), 2, dstBase, 1, vDSP_Length(frames))
                } else {
                    for ch in 0..<channelCount {
                        vDSP_vadd(base.advanced(by: ch), vDSP_Stride(channelCount), dstBase, 1, dstBase, 1, vDSP_Length(frames))
                    }
                }
                var factor = scale
                vDSP_vsmul(dstBase, 1, &factor, dstBase, 1, vDSP_Length(frames))
            }
        }
        return monoFloats.withUnsafeBufferPointer { floatBufferToInt16($0) }
    }

    public static func mixPlanarToMonoInt16(channels: [[Float]]) -> [Int16] {
        guard let first = channels.first, !first.isEmpty else { return [] }
        let frames = first.count
        if channels.count == 1 {
            return first.withUnsafeBufferPointer { floatBufferToInt16($0) }
        }
        var monoFloats = [Float](repeating: 0, count: frames)
        monoFloats.withUnsafeMutableBufferPointer { dst in
            guard let dstBase = dst.baseAddress else { return }
            for channel in channels {
                let count = min(frames, channel.count)
                guard count > 0 else { continue }
                channel.withUnsafeBufferPointer { src in
                    guard let base = src.baseAddress else { return }
                    vDSP_vadd(base, 1, dstBase, 1, dstBase, 1, vDSP_Length(count))
                }
            }
            var factor = 1.0 / Float(max(channels.count, 1))
            vDSP_vsmul(dstBase, 1, &factor, dstBase, 1, vDSP_Length(frames))
        }
        return monoFloats.withUnsafeBufferPointer { floatBufferToInt16($0) }
    }

    private static func floatBufferToInt16(_ buffer: UnsafeBufferPointer<Float>) -> [Int16] {
        guard let base = buffer.baseAddress, !buffer.isEmpty else { return [] }
        let count = buffer.count
        var clipped = [Float](repeating: 0, count: count)
        var low: Float = -1
        var high: Float = 1
        var scale: Float = 32767
        clipped.withUnsafeMutableBufferPointer { dst in
            guard let dstBase = dst.baseAddress else { return }
            vDSP_vclip(base, 1, &low, &high, dstBase, 1, vDSP_Length(count))
            vDSP_vsmul(dstBase, 1, &scale, dstBase, 1, vDSP_Length(count))
        }
        return [Int16](unsafeUninitializedCapacity: count) { dest, initializedCount in
            for i in 0..<count {
                dest[i] = Int16(clipped[i].rounded())
            }
            initializedCount = count
        }
    }

    public static func resampleLinear(samples: [Int16], fromRate: Int, toRate: Int) -> [Int16] {
        guard fromRate > 0, toRate > 0, !samples.isEmpty else { return samples }
        if fromRate == toRate { return samples }
        let ratio = Double(fromRate) / Double(toRate)
        let outputCount = max(1, Int((Double(samples.count) / ratio).rounded(.down)))
        var output = [Int16]()
        output.reserveCapacity(outputCount)
        for index in 0..<outputCount {
            let sourceIndex = Double(index) * ratio
            let left = Int(sourceIndex)
            let right = min(left + 1, samples.count - 1)
            let fraction = sourceIndex - Double(left)
            let mixed = Double(samples[left]) * (1 - fraction) + Double(samples[right]) * fraction
            output.append(Int16(clamping: Int(mixed.rounded())))
        }
        return output
    }

    public static func rms(_ samples: [Int16]) -> Double {
        guard !samples.isEmpty else { return 0 }
        var floats = [Float](repeating: 0, count: samples.count)
        samples.withUnsafeBufferPointer { src in
            vDSP_vflt16(src.baseAddress!, 1, &floats, 1, vDSP_Length(samples.count))
        }
        var sumSq: Float = 0
        vDSP_svesq(floats, 1, &sumSq, vDSP_Length(samples.count))
        return sqrt(Double(sumSq) / Double(samples.count)) / 32768.0
    }

    public static func isSilent(_ samples: [Int16], threshold: Double = 0.01) -> Bool {
        rms(samples) < threshold
    }

    public static func wavData(pcm16Mono: [Int16], sampleRate: Int = whisperSampleRate) -> Data {
        let maxSamples = (Int(UInt32.max) - 36) / 2
        let slice = pcm16Mono.count > maxSamples ? Array(pcm16Mono.prefix(maxSamples)) : pcm16Mono
        return wavData(pcm16MonoData: data(from: slice), sampleRate: sampleRate)
    }

    public static func wavData(pcm16MonoData: Data, sampleRate: Int = whisperSampleRate) -> Data {
        let clampedRate = max(1, min(sampleRate, 384_000))
        let maxDataBytes = Int(UInt32.max) - 36
        let usableBytes = min((pcm16MonoData.count / 2) * 2, maxDataBytes)
        var data = Data(capacity: 44 + usableBytes)
        func ascii(_ value: String) { data.append(contentsOf: value.utf8) }
        func u16(_ value: UInt16) {
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        func u32(_ value: UInt32) {
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        ascii("RIFF")
        u32(UInt32(36 + usableBytes))
        ascii("WAVE")
        ascii("fmt ")
        u32(16)
        u16(1)
        u16(1)
        u32(UInt32(clampedRate))
        u32(UInt32(clampedRate * 2))
        u16(2)
        u16(16)
        ascii("data")
        u32(UInt32(usableBytes))
        if usableBytes == pcm16MonoData.count {
            data.append(pcm16MonoData)
        } else if usableBytes > 0 {
            data.append(pcm16MonoData.prefix(usableBytes))
        }
        return data
    }

    public static func clampToInt16(_ value: Float) -> Int16 {
        let clipped = max(-1, min(1, value))
        return Int16((clipped * 32767).rounded())
    }
}
