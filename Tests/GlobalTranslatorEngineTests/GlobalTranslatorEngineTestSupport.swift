import CoreGraphics
import Foundation
import Testing
import GlobalTranslatorCapture
import GlobalTranslatorCore
import GlobalTranslatorEngine

actor RecordingBackend: TranslationBackend {
    let kind: BackendKind
    private let handler: @Sendable (TranslationRequest, [VisionTranslationImage]) -> TranslationResult
    private(set) var requests: [TranslationRequest] = []

    init(kind: BackendKind, handler: @escaping @Sendable (TranslationRequest, [VisionTranslationImage]) -> TranslationResult) {
        self.kind = kind
        self.handler = handler
    }

    func healthCheck() async -> BackendHealth { BackendHealth(status: .healthy, message: "ok") }

    func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        requests.append(request)
        return handler(request, [])
    }
}

actor PlainRecordingBackend: TranslationBackend {
    let kind: BackendKind = .local
    private(set) var translateCount = 0
    private(set) var plains: [(String, String)] = []

    func healthCheck() async -> BackendHealth { BackendHealth(status: .healthy, message: "ok") }

    func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        translateCount += 1
        return TranslationResult(
            windowRevision: request.windowRevision,
            translations: request.items.map { Translation(segmentId: $0.id, simplifiedChineseText: "译文") }
        )
    }

    func completePlain(system: String, user: String) async throws -> String {
        plains.append((system, user))
        return "optimized"
    }
}

actor RecordingHTTPTransport: HTTPTransport {
    let response: HTTPResponse
    private(set) var requests: [URLRequest] = []

    init(response: HTTPResponse) { self.response = response }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        return response
    }
}

final class TestCredentialStore: CredentialStoring, @unchecked Sendable {
    var value: String?

    init(value: String?) { self.value = value }
    func save(apiKey: String) throws { value = apiKey }
    func read() throws -> String? { value }
    func delete() throws { value = nil }
}

actor ThrowingBackend: TranslationBackend {
    let kind: BackendKind
    let error: TranslationError
    private(set) var requestCount = 0

    init(kind: BackendKind, error: TranslationError) {
        self.kind = kind
        self.error = error
    }

    func healthCheck() async -> BackendHealth {
        BackendHealth(status: .healthy, message: "ok")
    }

    func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        requestCount += 1
        throw error
    }
}

final class TestMonotonicClock: MonotonicClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0

    func now() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        value += seconds
        lock.unlock()
    }
}

func makeRegion(
    id: UUID = UUID(),
    text: String,
    x: CGFloat = 0,
    y: CGFloat = 100,
    confidence: Float = 1
) -> TextRegion {
    TextRegion(
        id: id,
        sourceText: text,
        screenFrame: CGRect(x: x, y: y, width: 80, height: 20),
        confidence: confidence,
        source: .accessibility,
        windowRevision: 1
    )
}

func makeSnapshot(
    regions: [TextRegion],
    revision: UInt64,
    source: CaptureSource = .accessibility,
    image: CGImage? = nil
) -> CaptureSnapshot {
    let descriptor = ActiveWindowDescriptor(
        pid: 42,
        bundleIdentifier: "com.example.editor",
        frame: CGRect(x: 0, y: 0, width: 800, height: 600),
        revision: revision
    )
    return CaptureSnapshot(window: CapturedWindow(
        descriptor: descriptor,
        regions: regions,
        source: source,
        capturedImage: image
    ))
}

func makeEngineTestImage() -> CGImage {
    let colorSpace = CGColorSpaceCreateDeviceGray()
    let context = CGContext(
        data: nil,
        width: 64,
        height: 32,
        bitsPerComponent: 8,
        bytesPerRow: 64,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.none.rawValue
    )!
    context.setFillColor(gray: 0.8, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
    return context.makeImage()!
}

actor VisionRecordingBackend: TranslationBackend, VisionTranslationBackend {
    let kind: BackendKind
    private(set) var textRequestCount = 0
    private(set) var visionRequests: [[VisionTranslationImage]] = []

    init(kind: BackendKind) { self.kind = kind }

    func healthCheck() async -> BackendHealth {
        BackendHealth(status: .healthy, message: "ok")
    }

    func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        textRequestCount += 1
        return TranslationResult(windowRevision: request.windowRevision, translations: request.items.map {
            Translation(segmentId: $0.id, simplifiedChineseText: "文本")
        })
    }

    func translate(_ request: TranslationRequest, images: [VisionTranslationImage]) async throws -> TranslationResult {
        visionRequests.append(images)
        return TranslationResult(windowRevision: request.windowRevision, translations: request.items.map {
            Translation(segmentId: $0.id, simplifiedChineseText: "视觉")
        })
    }
}

actor LateBackend: TranslationBackend {
    let kind: BackendKind = .local
    private(set) var requestCount = 0
    private var firstContinuation: CheckedContinuation<TranslationResult, Error>?

    func healthCheck() async -> BackendHealth {
        BackendHealth(status: .healthy, message: "ok")
    }

    func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        requestCount += 1
        if requestCount == 1 {
            return try await withCheckedThrowingContinuation { continuation in
                firstContinuation = continuation
            }
        }
        return TranslationResult(windowRevision: request.windowRevision, translations: request.items.map {
            Translation(segmentId: $0.id, simplifiedChineseText: "新")
        })
    }

    func releaseFirst() {
        firstContinuation?.resume(returning: TranslationResult(
            windowRevision: 1,
            translations: [Translation(segmentId: UUID(), simplifiedChineseText: "旧")]
        ))
        firstContinuation = nil
    }
}

final class OutputCollector: @unchecked Sendable {
    private var outputs: [EngineOutput] = []

    func append(_ output: EngineOutput) {
        outputs.append(output)
    }

    func values() -> [EngineOutput] {
        outputs
    }
}

final class AdvancingSleeper: TranslationSleeper, @unchecked Sendable {
    let clock: TestMonotonicClock

    init(clock: TestMonotonicClock) { self.clock = clock }

    func sleep(for seconds: TimeInterval) async throws {
        clock.advance(by: seconds)
        await Task.yield()
    }
}

actor TimestampedBackend: TranslationBackend {
    let kind: BackendKind = .local
    let clock: TestMonotonicClock
    private(set) var timestamps: [TimeInterval] = []

    init(clock: TestMonotonicClock) { self.clock = clock }

    func healthCheck() async -> BackendHealth {
        BackendHealth(status: .healthy, message: "ok")
    }

    func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        timestamps.append(clock.now())
        return TranslationResult(windowRevision: request.windowRevision, translations: request.items.map {
            Translation(segmentId: $0.id, simplifiedChineseText: "ok")
        })
    }
}

func expectTranslationError(
    _ operation: @escaping () async throws -> TranslationResult
) async {
    do {
        _ = try await operation()
        Issue.record("expected translation error")
    } catch is TranslationError {
    } catch {
        Issue.record("unexpected error type")
    }
}
