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

public struct SelectionPopoverContent: Equatable, Sendable {
    public var original: String
    public var originalPreview: String
    public var translation: String
    public var status: SelectionPopoverStatus
    public var screenFrame: CGRect

    public init(
        original: String,
        originalPreview: String,
        translation: String,
        status: SelectionPopoverStatus,
        screenFrame: CGRect
    ) {
        self.original = original
        self.originalPreview = originalPreview
        self.translation = translation
        self.status = status
        self.screenFrame = screenFrame
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
        case .translated, .optimized:
            return translation
        }
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

    public static func translated(original: String, translation: String, screenFrame: CGRect) -> SelectionPopoverContent {
        SelectionPopoverContent(
            original: original,
            originalPreview: SelectionTranslateSupport.truncatedOriginal(original),
            translation: translation,
            status: .translated,
            screenFrame: screenFrame
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
    public static let maxSourceCharacters = 4_000
    public static let originalPreviewLimit = 80
    public static let alreadyChineseCopy = "已是中文"
    public static let noTranslationNeededCopy = "专有名词，无需翻译"
    public static let defaultTargetLanguage = "zh-Hans"
    public static let optimizingCopy = "优化中…"
    public static let optimizeFailedCopy = "优化失败"
    public static let missingDeepSeekKeyCopy = "请到设置填写 DeepSeek API Key 并测试连接"
    public static let copyFeedbackMilliseconds = 1_500

    public static func truncatedOriginal(_ text: String, limit: Int = originalPreviewLimit) -> String {
        let compact = text.split(whereSeparator: { $0.isNewline }).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard compact.count > limit else { return compact }
        let end = compact.index(compact.startIndex, offsetBy: limit)
        return String(compact[..<end]) + "…"
    }

    public static func cappedSource(_ text: String) -> String {
        if text.count <= maxSourceCharacters { return text }
        let end = text.index(text.startIndex, offsetBy: maxSourceCharacters)
        return String(text[..<end])
    }

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
