import CoreGraphics
import Foundation
import ImageIO
import GlobalTranslatorCapture
import GlobalTranslatorCore

public actor TranslationCoordinator {
    public let cache: TranslationCache
    public let circuitBreaker: CircuitBreaker
    public let batcher: TranslationBatcher

    private let backends: [BackendKind: any TranslationBackend]
    private let targetLanguage: String
    private let clock: any MonotonicClock
    private let eventSink: EngineEventSink?
    private let cropPreparer: CloudCropPreparer
    private let permissions: any PermissionControlling
    private let revisionGate = RevisionGate()

    private var selectedKind: BackendKind?
    private var selectedModelIdentifier: String?
    private var latestRevision: UInt64 = 0
    private var configurationGeneration: UInt64 = 0
    private var _state: EngineState = .off

    public init(
        backends: [any TranslationBackend],
        cache: TranslationCache = TranslationCache(),
        circuitBreaker: CircuitBreaker? = nil,
        batcher: TranslationBatcher = TranslationBatcher(),
        targetLanguage: String = "zh-Hans",
        clock: any MonotonicClock = SystemMonotonicClock(),
        eventSink: EngineEventSink? = nil,
        cropPreparer: CloudCropPreparer = CloudCropPreparer(),
        permissions: any PermissionControlling = SystemPermissionController()
    ) {
        var backendMap: [BackendKind: any TranslationBackend] = [:]
        for backend in backends where backendMap[backend.kind] == nil {
            backendMap[backend.kind] = backend
        }
        self.backends = backendMap
        self.cache = cache
        self.clock = clock
        self.circuitBreaker = circuitBreaker ?? CircuitBreaker(clock: clock)
        self.batcher = batcher
        self.targetLanguage = targetLanguage
        self.eventSink = eventSink
        self.cropPreparer = cropPreparer
        self.permissions = permissions
    }

    public var state: EngineState {
        _state
    }

    public func selectBackend(kind: BackendKind, modelIdentifier: String) async {
        await switchSelection(kind: kind, modelIdentifier: modelIdentifier)
        if backends[kind] == nil || modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            setState(.backendError)
        } else if _state != .translating {
            setState(.listening)
        }
    }

    public func clearCache() async {
        configurationGeneration &+= 1
        await cancelPendingRequests()
        await cache.removeAll()
        await circuitBreaker.reset()
    }

    public func cancelPendingRequests() async {
        for backend in backends.values { await backend.cancelOutstandingRequests() }
    }

    nonisolated func invalidate(revision: UInt64) {
        revisionGate.mark(revision)
    }

    public func translate(
        snapshot: CaptureSnapshot,
        backend kind: BackendKind,
        modelIdentifier: String,
        visionFallbackEnabled: Bool
    ) async throws -> EngineOutput {
        try Task.checkCancellation()
        try validateCapturePermission(snapshot)
        let model = modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            setState(.backendError)
            emit(.failed(status: .invalidConfiguration))
            throw TranslationCoordinatorError.invalidModel
        }
        guard let backend = backends[kind] else {
            setState(.backendError)
            emit(.failed(status: .invalidConfiguration))
            throw TranslationCoordinatorError.backendNotConfigured(kind)
        }

        let generationBeforeSelection = configurationGeneration
        let selectionChanged = selectedKind != kind || selectedModelIdentifier != model
        await switchSelection(kind: kind, modelIdentifier: model)
        let generation = configurationGeneration
        let expectedGeneration = selectionChanged ? generationBeforeSelection &+ 1 : generationBeforeSelection
        guard generation == expectedGeneration,
              selectedKind == kind,
              selectedModelIdentifier == model else {
            emit(.failed(status: .cancelled))
            throw TranslationCoordinatorError.staleRevision
        }
        let revision = snapshot.descriptor.revision
        guard revision >= latestRevision else {
            emit(.failed(status: .cancelled))
            throw TranslationCoordinatorError.staleRevision
        }
        latestRevision = revision
        revisionGate.mark(revision)
        setState(.translating)
        emit(.snapshotReceived(regionCount: snapshot.regions.count, windowRevision: revision))
        let startedAt = clock.now()

        let plan = batcher.plan(regions: snapshot.regions)
        var textByRegionID: [UUID: String] = [:]
        var pendingEntries: [TranslationBatchEntry] = []
        var cacheHitCount = 0
        for entry in plan.entries {
            try ensureCurrent(revision: revision, generation: generation)
            let key = TranslationCacheKey(
                source: entry.sourceText,
                backend: kind,
                model: model,
                targetLanguage: targetLanguage
            )
            if let cached = await cache.value(for: key) {
                try ensureCurrent(revision: revision, generation: generation)
                for region in entry.regions {
                    textByRegionID[region.id] = cached
                }
                cacheHitCount += entry.regions.count
            } else {
                pendingEntries.append(entry)
            }
        }

        let requestBatcher = kind == .local
            ? TranslationBatcher(maximumItems: min(3, batcher.maximumItems), maximumSourceCharacters: batcher.maximumSourceCharacters)
            : batcher
        let batches = requestBatcher.makeBatches(from: pendingEntries, windowRevision: revision)
        let vision = makeVisionImages(
            snapshot: snapshot,
            backendKind: kind,
            backend: backend,
            enabled: visionFallbackEnabled,
            entries: pendingEntries
        )
        let textOnlyVision = vision.requested && (!vision.available || vision.imagesByID.isEmpty)

        for batch in batches {
            try ensureCurrent(revision: revision, generation: generation)
            do {
                try await circuitBreaker.check()
                try ensureCurrent(revision: revision, generation: generation)
            } catch let error as TranslationCoordinatorError {
                if case .circuitOpen = error {
                    setState(.circuitOpen)
                    emit(.failed(status: .circuitOpen))
                }
                throw error
            }

            let batchImages = batch.request.items.compactMap { vision.imagesByID[$0.id] }
            let result: TranslationResult
            do {
                try validateCapturePermission(snapshot)
                result = try await send(
                    batch.request,
                    to: backend,
                    images: batchImages,
                    allowVision: vision.available && !batchImages.isEmpty
                )
                try ensureCurrent(revision: revision, generation: generation)
                try validateCapturePermission(snapshot)
                try validateTranslationResult(result, expectedRequest: batch.request)
            } catch let error as CaptureError {
                throw error
            } catch let error as TranslationCoordinatorError {
                throw error
            } catch {
                try ensureCurrent(revision: revision, generation: generation)
                let translationError = error as? TranslationError ?? .networkFailure
                await circuitBreaker.recordFailure(translationError)
                try ensureCurrent(revision: revision, generation: generation)
                setState(.backendError)
                emit(.failed(status: engineFailureStatus(for: translationError)))
                throw error
            }

            await circuitBreaker.recordSuccess()
            try ensureCurrent(revision: revision, generation: generation)
            let resultByID = Dictionary(uniqueKeysWithValues: result.translations.map { ($0.segmentId, $0.simplifiedChineseText) })
            for entry in batch.entries {
                guard let translated = resultByID[entry.item.id] else {
                    throw TranslationError.invalidResponse("translation ID is missing")
                }
                let key = TranslationCacheKey(
                    source: entry.sourceText,
                    backend: kind,
                    model: model,
                    targetLanguage: targetLanguage
                )
                try ensureCurrent(revision: revision, generation: generation)
                await cache.insert(translated, for: key)
                try ensureCurrent(revision: revision, generation: generation)
                for region in entry.regions {
                    textByRegionID[region.id] = translated
                }
            }
            emit(.batchCompleted(itemCount: batch.request.items.count))
        }

        try ensureCurrent(revision: revision, generation: generation)
        try validateCapturePermission(snapshot)
        let rendered: [RenderedTranslation] = plan.orderedRegions.compactMap { region in
            guard let text = textByRegionID[region.id] else { return nil }
            return RenderedTranslation(region: region, text: text)
        }
        let durationMilliseconds = max(0, Int(((clock.now() - startedAt) * 1_000).rounded()))
        let status: EngineMetricStatus
        if textOnlyVision {
            status = .textOnly
        } else if batches.isEmpty && cacheHitCount > 0 {
            status = .cacheOnly
        } else {
            status = .success
        }
        let metrics = EngineMetrics(
            inputRegionCount: snapshot.regions.count,
            eligibleRegionCount: plan.eligibleRegionCount,
            cacheHitCount: cacheHitCount,
            batchCount: batches.count,
            translatedRegionCount: rendered.count,
            durationMilliseconds: durationMilliseconds,
            status: status
        )
        setState(.listening)
        emit(.completed(metrics: metrics))
        return EngineOutput(windowRevision: revision, translations: rendered, metrics: metrics)
    }

    private func validateCapturePermission(_ snapshot: CaptureSnapshot) throws {
        do {
            try permissions.snapshot.validateCapture(source: snapshot.source)
        } catch let error as CaptureError {
            if case .protected = error {
                setState(.listening)
            } else {
                setState(.missingPermission)
            }
            emit(.captureBlocked(reason: error, windowRevision: snapshot.descriptor.revision))
            throw error
        }
    }

    private func switchSelection(kind: BackendKind, modelIdentifier: String) async {
        let changed = selectedKind != kind || selectedModelIdentifier != modelIdentifier
        selectedKind = kind
        selectedModelIdentifier = modelIdentifier
        guard changed else { return }
        configurationGeneration &+= 1
        await cancelPendingRequests()
        await cache.removeAll()
        await circuitBreaker.reset()
    }

    private func send(
        _ request: TranslationRequest,
        to backend: any TranslationBackend,
        images: [VisionTranslationImage],
        allowVision: Bool
    ) async throws -> TranslationResult {
        if allowVision, let visionBackend = backend as? any VisionTranslationBackend {
            return try await visionBackend.translate(request, images: images)
        }
        return try await backend.translate(request)
    }

    private func makeVisionImages(
        snapshot: CaptureSnapshot,
        backendKind: BackendKind,
        backend: any TranslationBackend,
        enabled: Bool,
        entries: [TranslationBatchEntry]
    ) -> (requested: Bool, available: Bool, imagesByID: [UUID: VisionTranslationImage]) {
        guard enabled,
              backendKind == .deepSeekCloud,
              snapshot.source == .visionOCR,
              let image = snapshot.capturedImage else {
            return (false, false, [:])
        }
        let lowConfidence = cropPreparer.prepare(
            image: image,
            regions: entries.flatMap(\.regions),
            windowFrame: snapshot.descriptor.frame
        )
        guard !lowConfidence.isEmpty else {
            return (false, backend is any VisionTranslationBackend, [:])
        }
        let available = backend is any VisionTranslationBackend
        var imagesByID: [UUID: VisionTranslationImage] = [:]
        var representativeIDByRegionID: [UUID: UUID] = [:]
        for entry in entries {
            for region in entry.regions {
                representativeIDByRegionID[region.id] = entry.item.id
            }
        }
        for crop in lowConfidence.prefix(DeepSeekBackend.maximumVisionImages) {
            guard let data = Self.encodePNG(crop.image),
                  data.count >= 8,
                  Array(data.prefix(8)) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] else {
                continue
            }
            let segmentID = representativeIDByRegionID[crop.regionID] ?? crop.regionID
            guard imagesByID[segmentID] == nil else { continue }
            imagesByID[segmentID] = VisionTranslationImage(segmentId: segmentID, pngData: data)
        }
        return (true, available, imagesByID)
    }

    private static func encodePNG(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private func ensureCurrent(revision: UInt64, generation: UInt64) throws {
        try Task.checkCancellation()
        guard latestRevision == revision,
              revisionGate.latest == revision,
              configurationGeneration == generation else {
            throw TranslationCoordinatorError.staleRevision
        }
    }

    private func setState(_ state: EngineState) {
        _state = state
        emit(.stateChanged(state))
    }

    private func emit(_ event: EngineEvent) {
        eventSink?(event)
    }

}

final class RevisionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    var latest: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func mark(_ revision: UInt64) {
        lock.lock()
        if revision > value {
            value = revision
        }
        lock.unlock()
    }

    func withCurrent(_ revision: UInt64, _ operation: () -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard value == revision else { return false }
        operation()
        return true
    }
}
