import CoreGraphics
import Foundation

public enum SelectionTranslationDecision: Equatable, Sendable {
    case skip
    case alreadyTargetLanguage
    /// CamelCase / product-name lists. Show a soft “无需翻译” popover; do not call the model.
    case noTranslationNeeded
    case translate
}

public enum SelectionPointerPhase: Equatable, Sendable {
    case down
    case dragged
    case up
}

public enum SelectionPointerAction: Equatable, Sendable {
    case cancelPending
    case scheduleSettle
    case ignore
}

/// Mouse-up selection must not pop while the button is still down. Down and
/// drag cancel any pending settle; a matching up schedules one. Up with no
/// prior down is ignored so a swallowed menu press cannot resettle.
public struct SelectionPointerState: Equatable, Sendable {
    public private(set) var isButtonDown = false
    /// True when this press included a drag. Click-without-drag is not a
    /// selection: no clipboard fallback, and AX `.unavailable` must not spawn
    /// a sticky status.
    public private(set) var didDrag = false

    public init() {}

    public mutating func handle(_ phase: SelectionPointerPhase) -> SelectionPointerAction {
        switch phase {
        case .down:
            isButtonDown = true
            didDrag = false
            return .cancelPending
        case .dragged:
            if isButtonDown { didDrag = true }
            return isButtonDown ? .cancelPending : .ignore
        case .up:
            let wasDown = isButtonDown
            isButtonDown = false
            return wasDown ? .scheduleSettle : .ignore
        }
    }
}

/// Generation token so a late debounce fire after a newer gesture is ignored.
public struct SelectionSettleGate: Equatable, Sendable {
    private var generation: UInt64 = 0

    public init() {}

    /// Drop in-flight settle work without issuing a new token.
    public mutating func invalidate() {
        generation &+= 1
    }

    public mutating func next() -> UInt64 {
        invalidate()
        return generation
    }

    public func isCurrent(_ token: UInt64) -> Bool {
        token == generation
    }
}

public enum SelectionPopoverStatus: Equatable, Sendable {
    case loading
    case optimizing
    case translated
    case optimized
    case alreadyChinese
    case noTranslationNeeded
    case unavailable
    case failed
}

public struct SelectionTranslationOutcome: Equatable, Sendable {
    public let text: String
    public let sourceWasTruncated: Bool

    public init(text: String, sourceWasTruncated: Bool = false) {
        self.text = text
        self.sourceWasTruncated = sourceWasTruncated
    }
}

public struct SelectionSourcePlan: Equatable, Sendable {
    public let chunks: [String]
    public let didTruncate: Bool
    public let originalCharacterCount: Int
    public let usedCharacterCount: Int

    public init(
        chunks: [String],
        didTruncate: Bool,
        originalCharacterCount: Int,
        usedCharacterCount: Int
    ) {
        self.chunks = chunks
        self.didTruncate = didTruncate
        self.originalCharacterCount = originalCharacterCount
        self.usedCharacterCount = usedCharacterCount
    }
}

public struct SelectionPopoverContent: Equatable, Sendable {
    public var original: String
    public var originalPreview: String
    public var translation: String
    public var status: SelectionPopoverStatus
    public var screenFrame: CGRect
    /// Hard-cap leftover after chunking: show a Chinese note, never pretend the cut was the full text.
    public var sourceWasTruncated: Bool

    public init(
        original: String,
        originalPreview: String,
        translation: String,
        status: SelectionPopoverStatus,
        screenFrame: CGRect,
        sourceWasTruncated: Bool = false
    ) {
        self.original = original
        self.originalPreview = originalPreview
        self.translation = translation
        self.status = status
        self.screenFrame = screenFrame
        self.sourceWasTruncated = sourceWasTruncated
    }

    public var displayTranslation: String {
        switch status {
        case .loading:
            return "翻译中…"
        case .optimizing:
            return SelectionTranslateSupport.optimizingCopy
        case .alreadyChinese:
            return SelectionTranslateSupport.alreadyChineseCopy
        case .noTranslationNeeded:
            return translation.isEmpty ? SelectionTranslateSupport.noTranslationNeededCopy : translation
        case .unavailable:
            return translation.isEmpty ? "无法读取所选文字" : translation
        case .failed:
            return translation.isEmpty ? "翻译失败" : translation
        case .translated:
            return Self.translatedDisplay(translation, sourceWasTruncated: sourceWasTruncated)
        case .optimized:
            return translation
        }
    }

    public static func translatedDisplay(_ translation: String, sourceWasTruncated: Bool) -> String {
        guard sourceWasTruncated else { return translation }
        let note = SelectionTranslateSupport.truncatedSourceCopy
        let body = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? note : body + "\n\n" + note
    }

    public var allowsCopy: Bool {
        switch status {
        case .translated, .alreadyChinese, .noTranslationNeeded, .optimized:
            return !copyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .loading, .optimizing, .unavailable, .failed:
            return false
        }
    }

    public var showsTranslateAction: Bool {
        !original.isEmpty && status != .unavailable
    }

    public var showsOptimizeAction: Bool {
        !original.isEmpty && status != .unavailable
    }

    public var showsActionButtons: Bool {
        showsTranslateAction || showsOptimizeAction || allowsCopy
    }

    public var copyText: String {
        status == .alreadyChinese || status == .noTranslationNeeded ? original : translation
    }

    public static func loading(original: String, screenFrame: CGRect) -> SelectionPopoverContent {
        SelectionPopoverContent(
            original: original,
            originalPreview: SelectionTranslateSupport.truncatedOriginal(original),
            translation: "",
            status: .loading,
            screenFrame: screenFrame
        )
    }

    public static func translated(
        original: String,
        translation: String,
        screenFrame: CGRect,
        sourceWasTruncated: Bool = false
    ) -> SelectionPopoverContent {
        SelectionPopoverContent(
            original: original,
            originalPreview: SelectionTranslateSupport.truncatedOriginal(original),
            translation: translation,
            status: .translated,
            screenFrame: screenFrame,
            sourceWasTruncated: sourceWasTruncated
        )
    }

    public static func optimizing(original: String, screenFrame: CGRect) -> SelectionPopoverContent {
        SelectionPopoverContent(
            original: original,
            originalPreview: SelectionTranslateSupport.truncatedOriginal(original),
            translation: "",
            status: .optimizing,
            screenFrame: screenFrame
        )
    }

    public static func optimized(original: String, prompt: String, screenFrame: CGRect) -> SelectionPopoverContent {
        SelectionPopoverContent(
            original: original,
            originalPreview: SelectionTranslateSupport.truncatedOriginal(original),
            translation: prompt,
            status: .optimized,
            screenFrame: screenFrame
        )
    }

    public static func alreadyChinese(original: String, screenFrame: CGRect) -> SelectionPopoverContent {
        SelectionPopoverContent(
            original: original,
            originalPreview: SelectionTranslateSupport.truncatedOriginal(original),
            translation: SelectionTranslateSupport.alreadyChineseCopy,
            status: .alreadyChinese,
            screenFrame: screenFrame
        )
    }

    public static func noTranslationNeeded(original: String, screenFrame: CGRect) -> SelectionPopoverContent {
        SelectionPopoverContent(
            original: original,
            originalPreview: SelectionTranslateSupport.truncatedOriginal(original),
            translation: SelectionTranslateSupport.noTranslationNeededCopy,
            status: .noTranslationNeeded,
            screenFrame: screenFrame
        )
    }

    public static func unavailable(screenFrame: CGRect, message: String = "无法读取所选文字") -> SelectionPopoverContent {
        SelectionPopoverContent(
            original: "",
            originalPreview: "",
            translation: message,
            status: .unavailable,
            screenFrame: screenFrame
        )
    }

    public static func failed(original: String, message: String, screenFrame: CGRect) -> SelectionPopoverContent {
        SelectionPopoverContent(
            original: original,
            originalPreview: SelectionTranslateSupport.truncatedOriginal(original),
            translation: message,
            status: .failed,
            screenFrame: screenFrame
        )
    }
}

public enum SelectionTranslateSupport {
    public static let settleDelayMilliseconds = 150
    public static let alreadyChineseDismissMilliseconds = 1_500
    public static let unavailableDismissMilliseconds = 1_500
    /// Overlay / page-text per-item limit. Selection translate chunks instead of silently cutting here.
    public static let maxSourceCharacters = 4_000
    /// Paragraph/sentence-aware selection chunks. Fits local context plus scaled `max_tokens`.
    public static let selectionChunkCharacters = 1_800
    /// Hard safety cap after chunking. 15k–22k Seedance prompts fit; leftover shows a Chinese note.
    public static let selectionHardLimitCharacters = 48_000
    public static let originalPreviewLimit = 80
    public static let alreadyChineseCopy = "已是中文"
    public static let noTranslationNeededCopy = "专有名词，无需翻译"
    public static let truncatedSourceCopy = "原文过长，仅翻译了部分内容"
    public static let defaultTargetLanguage = "zh-Hans"
    public static let optimizingCopy = "优化中…"
    public static let optimizeFailedCopy = "优化失败"
    public static let missingDeepSeekKeyCopy = "请到设置填写 DeepSeek API Key 并测试连接"
    public static let copyFeedbackMilliseconds = 1_500
    public static let chunkJoinSeparator = "\n\n"

    public static func truncatedOriginal(_ text: String, limit: Int = originalPreviewLimit) -> String {
        let compact = text.split(whereSeparator: { $0.isNewline }).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard compact.count > limit else { return compact }
        let end = compact.index(compact.startIndex, offsetBy: limit)
        return String(compact[..<end]) + "…"
    }

    /// Optimize-prompt path still uses the 4000-character cap (plain completion is not chunked).
    public static func cappedSource(_ text: String) -> String {
        prefix(text, maxCount: maxSourceCharacters)
    }

    /// AX / clipboard read limit. Must be the hard cap so a 15k–22k selection is not silently cut to 4000.
    public static func limitSelectionSource(_ text: String) -> (text: String, didTruncate: Bool) {
        if text.count <= selectionHardLimitCharacters {
            return (text, false)
        }
        return (prefix(text, maxCount: selectionHardLimitCharacters), true)
    }

    public static func prepareSource(_ text: String) -> SelectionSourcePlan {
        let originalCharacterCount = text.count
        let limited = limitSelectionSource(text)
        let chunks = chunkSource(limited.text)
        return SelectionSourcePlan(
            chunks: chunks,
            didTruncate: limited.didTruncate,
            originalCharacterCount: originalCharacterCount,
            usedCharacterCount: limited.text.count
        )
    }

    /// Split near `selectionChunkCharacters` at paragraph, then sentence, then word boundaries.
    public static func chunkSource(
        _ text: String,
        targetCharacters: Int = selectionChunkCharacters
    ) -> [String] {
        let target = max(targetCharacters, 1)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard trimmed.count > target else { return [trimmed] }

        var chunks: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            while start < text.endIndex, text[start].isWhitespace {
                start = text.index(after: start)
            }
            guard start < text.endIndex else { break }
            let remaining = text[start...]
            if remaining.count <= target {
                let piece = String(remaining).trimmingCharacters(in: .whitespacesAndNewlines)
                if !piece.isEmpty { chunks.append(piece) }
                break
            }
            let targetIndex = text.index(start, offsetBy: target)
            let breakIndex = preferredBreakIndex(in: text, start: start, target: targetIndex)
            let end = breakIndex > start ? breakIndex : targetIndex
            let piece = String(text[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty {
                chunks.append(piece)
            }
            if end <= start {
                start = text.index(after: start)
            } else {
                start = end
            }
        }
        return chunks.isEmpty ? [trimmed] : chunks
    }

    public static func joinTranslatedChunks(_ parts: [String]) -> String {
        parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: chunkJoinSeparator)
    }

    private static func prefix(_ text: String, maxCount: Int) -> String {
        if text.count <= maxCount { return text }
        let end = text.index(text.startIndex, offsetBy: maxCount)
        return String(text[..<end])
    }

    private static func preferredBreakIndex(
        in text: String,
        start: String.Index,
        target: String.Index
    ) -> String.Index {
        let window = text[start..<target]
        let minOffset = max(1, window.count / 2)
        if let paragraph = lastMatch("\n\n", in: window, minOffset: minOffset) {
            return paragraph
        }
        if let newline = lastMatch("\n", in: window, minOffset: minOffset) {
            return newline
        }
        if let sentence = lastSentenceBreak(in: window, minOffset: minOffset) {
            return sentence
        }
        if let whitespace = lastWhitespaceBreak(in: window, minOffset: max(1, minOffset / 2)) {
            return whitespace
        }
        return target
    }

    private static func lastMatch(_ needle: String, in window: Substring, minOffset: Int) -> String.Index? {
        guard let range = window.range(of: needle, options: .backwards) else { return nil }
        let offset = window.distance(from: window.startIndex, to: range.lowerBound)
        guard offset >= minOffset else { return nil }
        return range.lowerBound
    }

    private static func lastSentenceBreak(in window: Substring, minOffset: Int) -> String.Index? {
        var match: String.Index?
        var offset = 0
        var index = window.startIndex
        while index < window.endIndex {
            let character = window[index]
            let next = window.index(after: index)
            if Self.sentenceTerminators.contains(character) {
                let boundaryOK: Bool
                if next == window.endIndex {
                    boundaryOK = true
                } else {
                    let following = window[next]
                    boundaryOK = following.isWhitespace || following.isNewline
                }
                if boundaryOK, offset >= minOffset {
                    match = next
                }
            }
            index = next
            offset += 1
        }
        return match
    }

    private static func lastWhitespaceBreak(in window: Substring, minOffset: Int) -> String.Index? {
        var match: String.Index?
        var offset = 0
        var index = window.startIndex
        while index < window.endIndex {
            let character = window[index]
            let next = window.index(after: index)
            if character.isWhitespace, offset >= minOffset {
                match = next
            }
            index = next
            offset += 1
        }
        return match
    }

    private static let sentenceTerminators: Set<Character> = [".", "!", "?", "。", "！", "？"]

    public static func isChineseTarget(_ language: String) -> Bool {
        let value = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value == "zh" ||
            value == "zh-cn" ||
            value == "zh-hans" ||
            value.hasPrefix("zh-hans") ||
            value.hasPrefix("zh-cn")
    }

    public static func fallbackFrame(at mouseLocation: CGPoint) -> CGRect {
        CGRect(x: mouseLocation.x, y: mouseLocation.y - 8, width: 1, height: 16)
    }
}
