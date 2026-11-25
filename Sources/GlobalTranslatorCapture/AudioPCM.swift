import Darwin
import Foundation

/// 16 kHz mono PCM helpers for on-device Whisper.cpp. Audio never leaves
/// process memory except a short-lived local WAV scratch file.
public enum AudioPCM {
    public static let whisperSampleRate = 16_000

    public static func int16Array(from data: Data) -> [Int16] {
        guard data.count >= 2 else { return [] }
        let count = data.count / 2
        return data.withUnsafeBytes { raw in
            var samples = [Int16](repeating: 0, count: count)
            for index in 0..<count {
                let offset = index * 2
                let little = UInt16(raw[offset]) | (UInt16(raw[offset + 1]) << 8)
                samples[index] = Int16(bitPattern: little)
            }
            return samples
        }
    }

    public static func data(from samples: [Int16]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            var le = UInt16(bitPattern: sample).littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        return data
    }

    public static func mixToMonoInt16(floatSamples: [Float], channels: Int) -> [Int16] {
        let channelCount = max(channels, 1)
        guard !floatSamples.isEmpty else { return [] }
        if channelCount == 1 {
            return floatSamples.map { clampToInt16($0) }
        }
        let frames = floatSamples.count / channelCount
        var mono = [Int16]()
        mono.reserveCapacity(frames)
        for frame in 0..<frames {
            var sum: Float = 0
            for channel in 0..<channelCount {
                sum += floatSamples[frame * channelCount + channel]
            }
            mono.append(clampToInt16(sum / Float(channelCount)))
        }
        return mono
    }

    public static func mixPlanarToMonoInt16(channels: [[Float]]) -> [Int16] {
        guard let first = channels.first, !first.isEmpty else { return [] }
        let frames = first.count
        var mono = [Int16]()
        mono.reserveCapacity(frames)
        for frame in 0..<frames {
            var sum: Float = 0
            for channel in channels {
                if frame < channel.count { sum += channel[frame] }
            }
            mono.append(clampToInt16(sum / Float(max(channels.count, 1))))
        }
        return mono
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
        var sum = 0.0
        for sample in samples {
            let value = Double(sample) / 32768.0
            sum += value * value
        }
        return sqrt(sum / Double(samples.count))
    }

    public static func isSilent(_ samples: [Int16], threshold: Double = 0.01) -> Bool {
        rms(samples) < threshold
    }

    public static func wavData(pcm16Mono: [Int16], sampleRate: Int = whisperSampleRate) -> Data {
        let clampedRate = max(1, min(sampleRate, 384_000))
        let maxSamples = (Int(UInt32.max) - 36) / 2
        let slice = pcm16Mono.count > maxSamples ? Array(pcm16Mono.prefix(maxSamples)) : pcm16Mono
        let dataSize = slice.count * 2
        var data = Data(capacity: 44 + dataSize)
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
        u32(UInt32(36 + dataSize))
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
        u32(UInt32(dataSize))
        data.append(self.data(from: slice))
        return data
    }

    public static func clampToInt16(_ value: Float) -> Int16 {
        let clipped = max(-1, min(1, value))
        return Int16((clipped * 32767).rounded())
    }
}
