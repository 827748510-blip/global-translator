import Foundation

/// Parses Server-Sent Events (`data: ...`) lines from arbitrary TCP/HTTP chunks,
/// preserving incomplete UTF-8 or partial line buffers across chunk boundaries.
public struct SSELineParser: Sendable {
    private var buffer = Data()
    public private(set) var sawDataLine = false

    public init() {}

    public mutating func push(_ chunk: Data) -> [String] {
        guard !chunk.isEmpty else { return [] }
        buffer.append(chunk)
        var payloads: [String] = []
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[..<newlineIndex]
            let nextIndex = buffer.index(after: newlineIndex)
            buffer.removeSubrange(buffer.startIndex..<nextIndex)
            if let payload = parseLineData(lineData) {
                payloads.append(payload)
            }
        }
        return payloads
    }

    public mutating func finish() -> [String] {
        guard !buffer.isEmpty else { return [] }
        let trailing = buffer
        buffer.removeAll(keepingCapacity: false)
        if let payload = parseLineData(trailing) {
            return [payload]
        }
        return []
    }

    private mutating func parseLineData(_ rawLine: Data) -> String? {
        var line = rawLine
        if line.last == 0x0D {
            line = line.dropLast()
        }
        guard let decoded = String(data: line, encoding: .utf8) else { return nil }
        guard decoded.hasPrefix("data:") else { return nil }
        sawDataLine = true
        var payload = String(decoded.dropFirst(5))
        if payload.first == " " {
            payload.removeFirst()
        }
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "[DONE]" else { return nil }
        return payload
    }
}

/// Filters `<think>...</think>` reasoning blocks out of streamed token deltas,
/// even when opening or closing tags split across adjacent chunks.
public struct ThinkTagStreamFilter: Sendable {
    private static let openTag = "<think>"
    private static let closeTag = "</think>"

    private var inThink = false
    private var buffer = ""
    private var trimLeadingWhitespace = true

    public init() {}

    public mutating func push(_ delta: String) -> String {
        guard !delta.isEmpty else { return "" }
        buffer.append(delta)
        return drain(flushing: false)
    }

    public mutating func finish() -> String {
        drain(flushing: true)
    }

    private mutating func drain(flushing: Bool) -> String {
        var output = ""
        while !buffer.isEmpty {
            if inThink {
                if let closeRange = buffer.range(of: Self.closeTag, options: .caseInsensitive) {
                    buffer.removeSubrange(buffer.startIndex..<closeRange.upperBound)
                    inThink = false
                    trimLeadingWhitespace = true
                    continue
                }
                if flushing {
                    buffer.removeAll(keepingCapacity: false)
                    break
                }
                let keepCount = Self.matchingSuffixPrefixLength(buffer, tag: Self.closeTag)
                if buffer.count > keepCount {
                    let dropEnd = buffer.index(buffer.endIndex, offsetBy: -keepCount)
                    buffer.removeSubrange(buffer.startIndex..<dropEnd)
                }
                break
            } else {
                if let openRange = buffer.range(of: Self.openTag, options: .caseInsensitive) {
                    let prefix = String(buffer[..<openRange.lowerBound])
                    appendVisible(prefix, to: &output)
                    buffer.removeSubrange(buffer.startIndex..<openRange.upperBound)
                    inThink = true
                    continue
                }
                if flushing {
                    appendVisible(buffer, to: &output)
                    buffer.removeAll(keepingCapacity: false)
                    break
                }
                let keepCount = Self.matchingSuffixPrefixLength(buffer, tag: Self.openTag)
                if keepCount > 0 {
                    let emitEnd = buffer.index(buffer.endIndex, offsetBy: -keepCount)
                    let prefix = String(buffer[..<emitEnd])
                    appendVisible(prefix, to: &output)
                    buffer.removeSubrange(buffer.startIndex..<emitEnd)
                    break
                } else {
                    appendVisible(buffer, to: &output)
                    buffer.removeAll(keepingCapacity: false)
                    break
                }
            }
        }
        return output
    }

    private mutating func appendVisible(_ text: String, to output: inout String) {
        guard !text.isEmpty else { return }
        if trimLeadingWhitespace {
            let trimmed = String(text.drop(while: { $0.isWhitespace || $0.isNewline }))
            guard !trimmed.isEmpty else { return }
            trimLeadingWhitespace = false
            output.append(trimmed)
        } else {
            output.append(text)
        }
    }

    private static func matchingSuffixPrefixLength(_ text: String, tag: String) -> Int {
        let lowerText = text.lowercased()
        let lowerTag = tag.lowercased()
        let maxLen = min(lowerText.count, lowerTag.count - 1)
        guard maxLen > 0 else { return 0 }
        for length in stride(from: maxLen, through: 1, by: -1) {
            if lowerText.hasSuffix(lowerTag.prefix(length)) {
                return length
            }
        }
        return 0
    }
}
