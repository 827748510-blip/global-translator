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

/// Explainable features of a single press→drag→release gesture. Only geometry
/// and timing are recorded — never the selected text or any app content.
public struct SelectionGestureFeatures: Equatable, Sendable {
    /// Largest straight-line distance from the press point.
    public let maxOffset: CGFloat
    /// Accumulated path length travelled while the button was down.
    public let totalTravel: CGFloat
    /// Number of mouse-dragged samples seen during the press.
    public let dragEventCount: Int
    /// Press-to-release duration in seconds.
    public let duration: TimeInterval
    /// Longest gap between two consecutive samples (a hand resting mid-drag).
    public let longestStall: TimeInterval

    public static let empty = SelectionGestureFeatures()

    public init(
        maxOffset: CGFloat = 0,
        totalTravel: CGFloat = 0,
        dragEventCount: Int = 0,
        duration: TimeInterval = 0,
        longestStall: TimeInterval = 0
    ) {
        self.maxOffset = maxOffset
        self.totalTravel = totalTravel
        self.dragEventCount = dragEventCount
        self.duration = duration
        self.longestStall = longestStall
    }
}

/// Three-way classification so a plain click or a window/scrollbar drag is
/// never treated as a text selection.
public enum SelectionGestureVerdict: String, Equatable, Sendable {
    /// Click, or movement below the selection thresholds.
    case click
    /// Short, continuous drag with enough movement: treat as a text selection.
    case textSelection
    /// Long drag, or a drag that stalled mid-way: window / scrollbar / slider.
    case nonTextDrag
}

/// Thresholds for `SelectionGestureVerdict`. Biased toward low false positives:
/// a missed popover is a nuisance, a stray "无法读取所选文字" over someone's
/// editor is worse.
public enum SelectionGestureThresholds {
    public static let minOffset: CGFloat = 4
    public static let minTravel: CGFloat = 8
    public static let maxDuration: TimeInterval = 3.0
    public static let maxStall: TimeInterval = 1.2
}

/// Consecutive "dragged but nothing readable" outcomes pause auto-surfacing so
/// the red status line and the ⌘C borrow cannot loop on an app that never
/// exposes a selection. Recovers on the next readable selection, or after a
/// cooldown so the feature is not permanently disabled.
public struct SelectionReadingDegradeState: Equatable, Sendable {
    public static let failureThreshold = 3
    public static let cooldown: TimeInterval = 30

    public private(set) var consecutiveFailures = 0
    public private(set) var degradedUntil: TimeInterval?

    public init() {}

    public func isDegraded(at timestamp: TimeInterval) -> Bool {
        guard let degradedUntil else { return false }
        return timestamp < degradedUntil
    }

    /// Returns true when this failure flips the state into degraded mode.
    @discardableResult
    public mutating func recordFailure(at timestamp: TimeInterval) -> Bool {
        if let until = degradedUntil {
            if timestamp < until {
                // Already degraded: keep the existing cooldown, do not slide it.
                return false
            }
            // Cooldown elapsed: give the app one fresh chance before re-tripping.
            degradedUntil = nil
            consecutiveFailures = 0
        }
        consecutiveFailures += 1
        guard consecutiveFailures >= Self.failureThreshold else { return false }
        degradedUntil = timestamp + Self.cooldown
        return true
    }

    public mutating func recordSuccess() {
        consecutiveFailures = 0
        degradedUntil = nil
    }
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
    /// Features of the most recent gesture, used to classify click vs drag.
    public private(set) var gestureFeatures = SelectionGestureFeatures.empty

    private var pressLocation: CGPoint?
    private var lastLocation: CGPoint?
    private var pressTimestamp: TimeInterval?
    private var lastTimestamp: TimeInterval?
    private var travel: CGFloat = 0
    private var maxOffset: CGFloat = 0
    private var dragEvents = 0
    private var longestStall: TimeInterval = 0

    public init() {}

    /// Classifies the last completed gesture. Only meaningful after an `up`
    /// that followed a `down`; otherwise it reports `.click`.
    public var gestureVerdict: SelectionGestureVerdict {
        guard didDrag else { return .click }
        let features = gestureFeatures
        let moved =
            features.maxOffset >= SelectionGestureThresholds.minOffset
            || features.totalTravel >= SelectionGestureThresholds.minTravel
        guard moved, features.dragEventCount >= 1 else { return .click }
        if features.duration > SelectionGestureThresholds.maxDuration
            || features.longestStall > SelectionGestureThresholds.maxStall {
            return .nonTextDrag
        }
        return .textSelection
    }

    /// Phase-only transitions (no geometry): equivalent to a gesture too short
    /// to be a selection. Kept for callers and tests that only track state.
    public mutating func handle(_ phase: SelectionPointerPhase) -> SelectionPointerAction {
        handle(phase, at: nil, timestamp: nil)
    }

    /// Full sampling. `location` and `timestamp` are optional so a caller with
    /// only phase information still gets a valid (`.click`) verdict.
    public mutating func handle(
        _ phase: SelectionPointerPhase,
        at location: CGPoint?,
        timestamp: TimeInterval?
    ) -> SelectionPointerAction {
        switch phase {
        case .down:
            isButtonDown = true
            didDrag = false
            resetGesture()
            pressLocation = location
            lastLocation = location
            pressTimestamp = timestamp
            lastTimestamp = timestamp
            return .cancelPending
        case .dragged:
            guard isButtonDown else { return .ignore }
            didDrag = true
            dragEvents += 1
            accumulate(location: location, timestamp: timestamp)
            updateFeatures(duration: elapsed(since: pressTimestamp, to: timestamp))
            return .cancelPending
        case .up:
            let wasDown = isButtonDown
            isButtonDown = false
            guard wasDown else { return .ignore }
            updateFeatures(duration: elapsed(since: pressTimestamp, to: timestamp))
            return .scheduleSettle
        }
    }

    private mutating func accumulate(location: CGPoint?, timestamp: TimeInterval?) {
        if let location {
            if let pressLocation {
                let offset = hypot(location.x - pressLocation.x, location.y - pressLocation.y)
                maxOffset = max(maxOffset, offset)
            }
            if let lastLocation {
                travel += hypot(location.x - lastLocation.x, location.y - lastLocation.y)
            }
            lastLocation = location
        }
        if let timestamp, let lastTimestamp {
            longestStall = max(longestStall, timestamp - lastTimestamp)
        }
        if let timestamp { lastTimestamp = timestamp }
    }

    private func elapsed(since start: TimeInterval?, to end: TimeInterval?) -> TimeInterval {
        guard let start, let end, end > start else { return 0 }
        return end - start
    }

    private mutating func resetGesture() {
        gestureFeatures = .empty
        travel = 0
        maxOffset = 0
        dragEvents = 0
        longestStall = 0
    }

    private mutating func updateFeatures(duration: TimeInterval) {
        gestureFeatures = SelectionGestureFeatures(
            maxOffset: maxOffset,
            totalTravel: travel,
            dragEventCount: dragEvents,
            duration: duration,
            longestStall: longestStall
        )
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
    /// Screenshot translate reuses this popover but does not offer 优化提示词.
    public var allowsPromptOptimize: Bool
    /// Screenshot MVP only needs copy; 翻译 retry stays on 滑词.
    public var allowsRetranslate: Bool
    /// 截图翻译把区域图保存到文件后，弹层展示的路径提示（~ 缩写）。滑词没有。
    public var savedImagePath: String?

    public init(
        original: String,
        originalPreview: String,
        translation: String,
        status: SelectionPopoverStatus,
        screenFrame: CGRect,
        sourceWasTruncated: Bool = false,
        allowsPromptOptimize: Bool = true,
        allowsRetranslate: Bool = true,
        savedImagePath: String? = nil
    ) {
        self.original = original
        self.originalPreview = originalPreview
        self.translation = translation
        self.status = status
        self.screenFrame = screenFrame
        self.sourceWasTruncated = sourceWasTruncated
        self.allowsPromptOptimize = allowsPromptOptimize
        self.allowsRetranslate = allowsRetranslate
        self.savedImagePath = savedImagePath
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
        allowsRetranslate && !original.isEmpty && status != .unavailable
    }

    public var showsOptimizeAction: Bool {
        allowsPromptOptimize && !original.isEmpty && status != .unavailable
    }

    public func asScreenshotResult() -> SelectionPopoverContent {
        var copy = self
        copy.allowsPromptOptimize = false
        copy.allowsRetranslate = false
        return copy
    }

    public var showsActionButtons: Bool {
        showsTranslateAction || showsOptimizeAction || allowsCopy
    }

    public var copyText: String {
        status == .alreadyChinese || status == .noTranslationNeeded ? original : translation
    }

    /// 保存截图后的路径提示（仅截图翻译；滑词没有）。home 缩写为 ~。
    public var savedImageHint: String? {
        guard let savedImagePath, !savedImagePath.isEmpty else { return nil }
        return SelectionTranslateSupport.savedImageCopyPrefix
            + SelectionTranslateSupport.displayPath(savedImagePath)
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
    /// A structured local/cloud request that fails on parse or quality gets one
    /// plain-text retry. Longer chunks stay on the structured path because the
    /// plain fallback budget (1024 tokens) could silently truncate them.
    public static let plainFallbackMaxCharacters = 600
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
    public static let savedImageCopyPrefix = "已保存到 "

    /// Abbreviates a path for display: home becomes ~. Pure string + home dir,
    /// shared by the settings caption and the popover hint.
    public static func displayPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    public static func truncatedOriginal(_ text: String, limit: Int = originalPreviewLimit) -> String {
        let compact = text.split(whereSeparator: { $0.isNewline }).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard compact.count > limit else { return compact }
        let end = compact.index(compact.startIndex, offsetBy: limit)
        return String(compact[..<end]) + "…"
    }

    /// Plain fallback replies are model prose, not schema-bound JSON. Strip
    /// wrapping quotes / labels so 「"Figma（设计工具）"」 and 「译文：…」 do not
    /// land in the popover or the copy buffer verbatim. Code fences and think
    /// tags are already removed by the transport parsers.
    public static func cleanPlainFallback(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for _ in 0..<2 {
            guard text.count >= 2 else { break }
            let pairs: [(Character, Character)] = [("\"", "\""), ("“", "”"), ("「", "」")]
            guard pairs.contains(where: { text.first == $0.0 && text.last == $0.1 }) else { break }
            text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for label in ["译文：", "译文:", "翻译：", "翻译:", "简体中文：", "简体中文:"] {
            if text.hasPrefix(label) {
                text = String(text.dropFirst(label.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        return text
    }

    /// True for short brand / product / technology names ("Figma", "Mac
    /// Studio", "npm"), false for sentences. Used only after a plain fallback
    /// echoes the source: a term becomes 「专有名词，无需翻译」, while an echoed
    /// sentence stays an honest failure.
    public static func isProperNounPhrase(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 64 else { return false }
        guard !value.contains(where: { "。！？.!?".contains($0) }) else { return false }
        let tokens = value
            .split(whereSeparator: { $0.isWhitespace || "+/|&,".contains($0) })
            .filter { !$0.isEmpty }
        guard (1...4).contains(tokens.count) else { return false }
        if tokens.count == 1 {
            let token = String(tokens[0])
            // One short word: brands (Figma), lowercase tech names (npm, pnpm),
            // camel case / all caps / version-like names. Only consulted after
            // the model already echoed the source, so the worst case is a soft
            // 「专有名词，无需翻译」 instead of a red failure.
            return token.count > 1 && token.count <= 12
        }
        return tokens.allSatisfy { token in
            let value = String(token)
            guard let first = value.first else { return false }
            return first.isUppercase || first.isNumber || value.contains(where: { $0.isUppercase })
        }
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
