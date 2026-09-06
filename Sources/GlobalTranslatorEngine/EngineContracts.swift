import Foundation
import GlobalTranslatorCapture
import GlobalTranslatorCore

public struct RenderedTranslation: Codable, Identifiable, Equatable, Sendable {
    public let region: TextRegion
    public let text: String

    public var id: UUID { region.id }

    public init(region: TextRegion, text: String) {
        self.region = region
        self.text = text
    }
}

public enum EngineState: String, Codable, Equatable, Sendable {
    case off
    case listening
    case translating
    case missingPermission
    case backendError
    case circuitOpen
}

public enum EngineMetricStatus: String, Codable, Equatable, Sendable {
    case success
    case cacheOnly
    case textOnly
    case stale
    case missingPermission
    case backendError
    case circuitOpen
}

public struct EngineMetrics: Codable, Equatable, Sendable {
    public let inputRegionCount: Int
    public let eligibleRegionCount: Int
    public let cacheHitCount: Int
    public let batchCount: Int
    public let translatedRegionCount: Int
    public let durationMilliseconds: Int
    public let status: EngineMetricStatus

    public init(
        inputRegionCount: Int,
        eligibleRegionCount: Int,
        cacheHitCount: Int,
        batchCount: Int,
        translatedRegionCount: Int,
        durationMilliseconds: Int,
        status: EngineMetricStatus
    ) {
        self.inputRegionCount = inputRegionCount
        self.eligibleRegionCount = eligibleRegionCount
        self.cacheHitCount = cacheHitCount
        self.batchCount = batchCount
        self.translatedRegionCount = translatedRegionCount
        self.durationMilliseconds = durationMilliseconds
        self.status = status
    }
}

public struct EngineOutput: Codable, Equatable, Sendable {
    public let windowRevision: UInt64
    public let translations: [RenderedTranslation]
    public let metrics: EngineMetrics

    public init(windowRevision: UInt64, translations: [RenderedTranslation], metrics: EngineMetrics) {
        self.windowRevision = windowRevision
        self.translations = translations
        self.metrics = metrics
    }
}

public enum EngineFailureStatus: String, Codable, Equatable, Sendable {
    case missingCredential
    case unauthorized
    case forbidden
    case rateLimited
    case serverFailure
    case timeout
    case networkFailure
    case redirectRejected
    case modelUnavailable
    case invalidConfiguration
    case invalidRequest
    case invalidResponse
    case cancelled
    case circuitOpen
    case unknown
}

public enum EngineEvent: Codable, Equatable, Sendable {
    case stateChanged(EngineState)
    case snapshotReceived(regionCount: Int, windowRevision: UInt64)
    case batchCompleted(itemCount: Int)
    case completed(metrics: EngineMetrics)
    case failed(status: EngineFailureStatus)
    case captureBlocked(reason: CaptureError, windowRevision: UInt64)

    private enum CodingKeys: String, CodingKey {
        case type
        case state
        case regionCount
        case windowRevision
        case itemCount
        case metrics
        case status
        case reason
    }

    private enum EventType: String, Codable {
        case stateChanged
        case snapshotReceived
        case batchCompleted
        case completed
        case failed
        case captureBlocked
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .stateChanged(let state):
            try container.encode(EventType.stateChanged, forKey: .type)
            try container.encode(state, forKey: .state)
        case .snapshotReceived(let regionCount, let windowRevision):
            try container.encode(EventType.snapshotReceived, forKey: .type)
            try container.encode(regionCount, forKey: .regionCount)
            try container.encode(windowRevision, forKey: .windowRevision)
        case .batchCompleted(let itemCount):
            try container.encode(EventType.batchCompleted, forKey: .type)
            try container.encode(itemCount, forKey: .itemCount)
        case .completed(let metrics):
            try container.encode(EventType.completed, forKey: .type)
            try container.encode(metrics, forKey: .metrics)
        case .failed(let status):
            try container.encode(EventType.failed, forKey: .type)
            try container.encode(status, forKey: .status)
        case .captureBlocked(let reason, let revision):
            try container.encode(EventType.captureBlocked, forKey: .type)
            try container.encode(reason, forKey: .reason)
            try container.encode(revision, forKey: .windowRevision)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(EventType.self, forKey: .type) {
        case .stateChanged:
            self = .stateChanged(try container.decode(EngineState.self, forKey: .state))
        case .snapshotReceived:
            self = .snapshotReceived(
                regionCount: try container.decode(Int.self, forKey: .regionCount),
                windowRevision: try container.decode(UInt64.self, forKey: .windowRevision)
            )
        case .batchCompleted:
            self = .batchCompleted(itemCount: try container.decode(Int.self, forKey: .itemCount))
        case .completed:
            self = .completed(metrics: try container.decode(EngineMetrics.self, forKey: .metrics))
        case .failed:
            self = .failed(status: try container.decode(EngineFailureStatus.self, forKey: .status))
        case .captureBlocked:
            self = .captureBlocked(
                reason: try container.decode(CaptureError.self, forKey: .reason),
                windowRevision: try container.decode(UInt64.self, forKey: .windowRevision)
            )
        }
    }
}

public typealias EngineEventSink = @Sendable (EngineEvent) -> Void

public enum TranslationCoordinatorError: Error, Equatable, Sendable {
    case backendNotConfigured(BackendKind)
    case invalidModel
    case staleRevision
    case circuitOpen(retryAfter: TimeInterval)
    case visionUnavailable
}
