import Foundation

/// Scene for 优化提示词. Default stays the original generative-image rewrite.
public enum PromptOptimizeMode: String, Codable, CaseIterable, Equatable, Sendable, Identifiable {
    case generativePrompt
    case technicalExpression
    case professionalReply
    case highEQ
    case wordingFix

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .generativePrompt:
            return "生成提示词"
        case .technicalExpression:
            return "技术表达"
        case .professionalReply:
            return "专业回复"
        case .highEQ:
            return "高情商"
        case .wordingFix:
            return "用词修正"
        }
    }

    public var optimizeAccessibilityHint: String {
        switch self {
        case .generativePrompt:
            return "把草稿改写成通用生成提示词"
        case .technicalExpression:
            return "把选区改写成更清晰的技术表达"
        case .professionalReply:
            return "把选区改写成专业得体的回复"
        case .highEQ:
            return "把选区改写成更有同理心的措辞"
        case .wordingFix:
            return "修正错别字、用词和不得体表达"
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
