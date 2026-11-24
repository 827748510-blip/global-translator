import Foundation

/// Scene for 优化提示词. Default is workplace/social polish, not image-prompt rewrite.
public enum PromptOptimizeMode: String, Codable, CaseIterable, Equatable, Hashable, Sendable, Identifiable {
    case communicationPolish
    case taskInstruction
    case wordingFix

    public var id: String { rawValue }

    public static let `default`: PromptOptimizeMode = .communicationPolish

    public var title: String {
        switch self {
        case .communicationPolish:
            return "沟通润色"
        case .taskInstruction:
            return "任务指令"
        case .wordingFix:
            return "用词修正"
        }
    }

    public var optimizeAccessibilityHint: String {
        switch self {
        case .communicationPolish:
            return "改得更得体、清晰、有同理心，不改事实、不加承诺"
        case .taskInstruction:
            return "把含糊意图扩写成给 AI 执行的结构化任务说明"
        case .wordingFix:
            return "修正错别字、用词和不得体表达"
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = Self.migrating(from: raw)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// Maps persisted and legacy raw values onto the current three scenes.
    public static func migrating(from rawValue: String) -> PromptOptimizeMode {
        switch rawValue {
        case Self.communicationPolish.rawValue, "professionalReply", "highEQ":
            return .communicationPolish
        case Self.wordingFix.rawValue:
            return .wordingFix
        case Self.taskInstruction.rawValue:
            return .taskInstruction
        default:
            return .communicationPolish
        }
    }
}

public enum SelectionCopyFeedback: Equatable, Sendable {
    case idle
    case copied
    case failed

    public var title: String {
        switch self {
        case .idle:
            return "拷贝"
        case .copied:
            return "已拷贝"
        case .failed:
            return "拷贝失败"
        }
    }
}

public enum SelectionCopyError: Error, Equatable, Sendable {
    case writeFailed
}
