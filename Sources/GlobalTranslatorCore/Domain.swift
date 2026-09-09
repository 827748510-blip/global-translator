import Foundation
import CoreGraphics

public enum BackendKind: String, Codable, Sendable, Equatable, Hashable {
    case deepSeekCloud
    case local

    /// Same copy as Settings 「翻译后端」.
    public var displayTitle: String {
        switch self {
        case .deepSeekCloud: return "DeepSeek 云端"
        case .local: return "本地模型"
        }
    }
}

public enum BackendHealthStatus: String, Codable, Sendable, Equatable {
    case healthy
    case unavailable
    case invalidCredentials
    case modelUnavailable
    case invalidConfiguration
}

public struct BackendHealth: Codable, Equatable, Sendable {
    public let status: BackendHealthStatus
    public let message: String
    public let availableModels: [String]

    public init(
        status: BackendHealthStatus,
        message: String,
        availableModels: [String] = []
    ) {
        self.status = status
        self.message = message
        self.availableModels = availableModels
    }
}

public enum RegionSource: String, Codable, Sendable, Equatable {
    case accessibility
    case visionOCR
}

public struct TextRegion: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let sourceText: String
    public let screenFrame: CGRect
    public let confidence: Float
    public let source: RegionSource
    public let windowRevision: UInt64

    public init(
        id: UUID,
        sourceText: String,
        screenFrame: CGRect,
        confidence: Float,
        source: RegionSource,
        windowRevision: UInt64
    ) {
        self.id = id
        self.sourceText = sourceText
        self.screenFrame = screenFrame
        self.confidence = confidence
        self.source = source
        self.windowRevision = windowRevision
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case sourceText
        case screenFrame
        case confidence
        case source
        case windowRevision
    }

    private enum FrameKeys: String, CodingKey {
        case x
        case y
        case width
        case height
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        sourceText = try container.decode(String.self, forKey: .sourceText)
        let frame = try container.nestedContainer(keyedBy: FrameKeys.self, forKey: .screenFrame)
        screenFrame = CGRect(
            x: try frame.decode(CGFloat.self, forKey: .x),
            y: try frame.decode(CGFloat.self, forKey: .y),
            width: try frame.decode(CGFloat.self, forKey: .width),
            height: try frame.decode(CGFloat.self, forKey: .height)
        )
        confidence = try container.decode(Float.self, forKey: .confidence)
        source = try container.decode(RegionSource.self, forKey: .source)
        windowRevision = try container.decode(UInt64.self, forKey: .windowRevision)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(sourceText, forKey: .sourceText)
        var frame = container.nestedContainer(keyedBy: FrameKeys.self, forKey: .screenFrame)
        try frame.encode(screenFrame.origin.x, forKey: .x)
        try frame.encode(screenFrame.origin.y, forKey: .y)
        try frame.encode(screenFrame.size.width, forKey: .width)
        try frame.encode(screenFrame.size.height, forKey: .height)
        try container.encode(confidence, forKey: .confidence)
        try container.encode(source, forKey: .source)
        try container.encode(windowRevision, forKey: .windowRevision)
    }

    public static func == (lhs: TextRegion, rhs: TextRegion) -> Bool {
        lhs.id == rhs.id &&
            lhs.sourceText == rhs.sourceText &&
            lhs.screenFrame.origin.x == rhs.screenFrame.origin.x &&
            lhs.screenFrame.origin.y == rhs.screenFrame.origin.y &&
            lhs.screenFrame.size.width == rhs.screenFrame.size.width &&
            lhs.screenFrame.size.height == rhs.screenFrame.size.height &&
            lhs.confidence == rhs.confidence &&
            lhs.source == rhs.source &&
            lhs.windowRevision == rhs.windowRevision
    }
}

public struct TranslationItem: Codable, Equatable, Sendable {
    public let id: UUID
    public let sourceText: String

    public init(id: UUID, sourceText: String) {
        self.id = id
        self.sourceText = sourceText
    }
}

/// How local backends treat a translation that copies the Latin source.
public enum CopiedSourcePolicy: String, Codable, Equatable, Sendable {
    /// Overlay, 滑词, and health checks: echo is `invalidResponse`.
    case reject
    /// Webpage / extension-bridge batches: keep the source as success.
    case keep
}

public struct TranslationRequest: Codable, Equatable, Sendable {
    public let windowRevision: UInt64
    public let items: [TranslationItem]
    public let copiedSourcePolicy: CopiedSourcePolicy

    public init(
        windowRevision: UInt64,
        items: [TranslationItem],
        copiedSourcePolicy: CopiedSourcePolicy = .reject
    ) {
        self.windowRevision = windowRevision
        self.items = items
        self.copiedSourcePolicy = copiedSourcePolicy
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        windowRevision = try container.decode(UInt64.self, forKey: .windowRevision)
        items = try container.decode([TranslationItem].self, forKey: .items)
        copiedSourcePolicy = try container.decodeIfPresent(CopiedSourcePolicy.self, forKey: .copiedSourcePolicy) ?? .reject
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(windowRevision, forKey: .windowRevision)
        try container.encode(items, forKey: .items)
        try container.encode(copiedSourcePolicy, forKey: .copiedSourcePolicy)
    }

    private enum CodingKeys: String, CodingKey {
        case windowRevision, items, copiedSourcePolicy
    }
}

public struct Translation: Codable, Equatable, Sendable {
    public let segmentId: UUID
    public let simplifiedChineseText: String

    public init(segmentId: UUID, simplifiedChineseText: String) {
        self.segmentId = segmentId
        self.simplifiedChineseText = simplifiedChineseText
    }
}

public struct TranslationResult: Codable, Equatable, Sendable {
    public let windowRevision: UInt64
    public let translations: [Translation]

    public init(windowRevision: UInt64, translations: [Translation]) {
        self.windowRevision = windowRevision
        self.translations = translations
    }
}

public enum TranslationError: Error, Equatable, Sendable {
    case invalidRequest(String)
    case missingCredential
    case unauthorized
    case forbidden
    case rateLimited(retryAfter: TimeInterval?)
    case serverFailure(statusCode: Int)
    case timeout
    case networkFailure
    case redirectRejected
    case modelUnavailable
    case invalidConfiguration(String)
    case invalidResponse(String)
}

public protocol TranslationBackend: Sendable {
    var kind: BackendKind { get }
    func healthCheck() async -> BackendHealth
    func translate(_ request: TranslationRequest) async throws -> TranslationResult
    func completePlain(system: String, user: String) async throws -> String
    func cancelOutstandingRequests() async
}

public extension TranslationBackend {
    func cancelOutstandingRequests() async {}
    func completePlain(system: String, user: String) async throws -> String {
        throw TranslationError.invalidConfiguration("plain completion is not supported")
    }
}

public struct VisionTranslationImage: Equatable, Sendable {
    public let segmentId: UUID
    public let pngData: Data
    public let mime = "image/png"

    public init(segmentId: UUID, pngData: Data) {
        self.segmentId = segmentId
        self.pngData = pngData
    }
}

public protocol VisionTranslationBackend: TranslationBackend {
    func translate(
        _ request: TranslationRequest,
        images: [VisionTranslationImage]
    ) async throws -> TranslationResult
}
