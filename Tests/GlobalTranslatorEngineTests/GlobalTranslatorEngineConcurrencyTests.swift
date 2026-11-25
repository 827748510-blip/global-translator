import Foundation
import Testing
import GlobalTranslatorCapture
@testable import GlobalTranslatorCore
@testable import GlobalTranslatorEngine

extension GlobalTranslatorEngineTests {
    @Test
    func lateOlderRevisionCannotProduceOutput() async throws {
        let backend = LateBackend()
        let coordinator = TranslationCoordinator(backends: [backend], permissions: SystemPermissionController(snapshotProvider: { .allGranted }))
        let first = Task {
            try await coordinator.translate(
                snapshot: makeSnapshot(regions: [makeRegion(text: "first")], revision: 1),
                backend: .local,
                modelIdentifier: "m",
                visionFallbackEnabled: false
            )
        }
        for _ in 0..<100 where await backend.requestCount == 0 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let second = try await coordinator.translate(
            snapshot: makeSnapshot(regions: [makeRegion(text: "second")], revision: 2),
            backend: .local,
            modelIdentifier: "m",
            visionFallbackEnabled: false
        )
        #expect(second.windowRevision == 2)
        await backend.releaseFirst()
        do {
            _ = try await first.value
            Issue.record("expected stale revision")
        } catch let error as TranslationCoordinatorError {
            #expect(error == .staleRevision)
        }
    }

    @Test
    func staleDelayedResultCannotPopulateCache() async throws {
        let backend = LateBackend()
        let cache = TranslationCache()
        let coordinator = TranslationCoordinator(backends: [backend], cache: cache, permissions: SystemPermissionController(snapshotProvider: { .allGranted }))
        let first = Task {
            try await coordinator.translate(
                snapshot: makeSnapshot(regions: [makeRegion(text: "same")], revision: 1),
                backend: .local,
                modelIdentifier: "m",
                visionFallbackEnabled: false
            )
        }
        for _ in 0..<100 where await backend.requestCount == 0 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        coordinator.invalidate(revision: 2)
        await backend.releaseFirst()
        do {
            _ = try await first.value
            Issue.record("expected stale revision")
        } catch let error as TranslationCoordinatorError {
            #expect(error == .staleRevision)
        }
        let key = TranslationCacheKey(source: "same", backend: .local, model: "m", targetLanguage: "zh-Hans")
        #expect(await cache.value(for: key) == nil)
    }

    @Test
    @MainActor
    func schedulerDebouncesBurstAndDeliversOnMainActor() async throws {
        let backend = RecordingBackend(kind: .local) { request, _ in
            TranslationResult(windowRevision: request.windowRevision, translations: [
                Translation(segmentId: request.items[0].id, simplifiedChineseText: "好")
            ])
        }
        let coordinator = TranslationCoordinator(backends: [backend], permissions: SystemPermissionController(snapshotProvider: { .allGranted }))
        let collector = OutputCollector()
        let scheduler = RealtimeTranslationScheduler(coordinator: coordinator) { output in
            collector.append(output)
        }
        scheduler.submit(snapshot: makeSnapshot(regions: [makeRegion(text: "one")], revision: 1), backend: .local, modelIdentifier: "m", visionFallbackEnabled: false)
        scheduler.submit(snapshot: makeSnapshot(regions: [makeRegion(text: "two")], revision: 2), backend: .local, modelIdentifier: "m", visionFallbackEnabled: false)
        // Wait for the debounced submission to land instead of assuming a fixed
        // 450 ms is enough; on a loaded machine the scheduler can still be one
        // tick away when that sleep ends. The trailing window then confirms the
        // burst was collapsed into a single request.
        for _ in 0..<400 where await backend.requests.isEmpty {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        try await Task.sleep(nanoseconds: 450_000_000)
        #expect(await backend.requests.count == 1)
        #expect(collector.values().map(\.windowRevision) == [2])
    }

    @Test
    @MainActor
    func schedulerEnforcesFourHertzDispatchSpacing() async throws {
        let clock = TestMonotonicClock()
        let sleeper = AdvancingSleeper(clock: clock)
        let backend = TimestampedBackend(clock: clock)
        let coordinator = TranslationCoordinator(backends: [backend], clock: clock, permissions: SystemPermissionController(snapshotProvider: { .allGranted }))
        let scheduler = RealtimeTranslationScheduler(
            coordinator: coordinator,
            clock: clock,
            sleeper: sleeper
        ) { _ in }
        scheduler.submit(snapshot: makeSnapshot(regions: [makeRegion(text: "one")], revision: 1), backend: .local, modelIdentifier: "m", visionFallbackEnabled: false)
        for _ in 0..<1_000 where await backend.timestamps.isEmpty {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(await backend.timestamps.count == 1)
        scheduler.submit(snapshot: makeSnapshot(regions: [makeRegion(text: "two")], revision: 2), backend: .local, modelIdentifier: "m", visionFallbackEnabled: false)
        for _ in 0..<1_000 where await backend.timestamps.count < 2 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let timestamps = await backend.timestamps
        #expect(timestamps.count == 2)
        if timestamps.count == 2 {
            #expect(timestamps[1] - timestamps[0] >= 0.25)
        }
    }

    @Test
    func cloudMultiBatchExecutesWithBoundedConcurrency() async throws {
        let backend = ConcurrentMeasuringBackend(kind: .deepSeekCloud)
        let batcher = TranslationBatcher(maximumItems: 2, maximumSourceCharacters: 4_000)
        let coordinator = TranslationCoordinator(
            backends: [backend],
            batcher: batcher,
            permissions: SystemPermissionController(snapshotProvider: { .allGranted })
        )
        let regions = (0..<10).map { makeRegion(text: "Cloud label \($0)", y: CGFloat(500 - $0 * 30)) }
        let output = try await coordinator.translate(
            snapshot: makeSnapshot(regions: regions, revision: 1),
            backend: .deepSeekCloud,
            modelIdentifier: AppConfiguration.defaultDeepSeekModel,
            visionFallbackEnabled: false
        )
        #expect(output.translations.count == 10)
        #expect(output.metrics.batchCount == 5)
        #expect(await backend.maxInFlight > 1)
        #expect(await backend.maxInFlight <= 3)
    }
}

private actor ConcurrentMeasuringBackend: TranslationBackend {
    let kind: BackendKind
    private var inFlight = 0
    private(set) var maxInFlight = 0

    init(kind: BackendKind) {
        self.kind = kind
    }

    func healthCheck() async -> BackendHealth {
        BackendHealth(status: .healthy, message: "ok")
    }

    func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        defer { inFlight -= 1 }
        try await Task.sleep(for: .milliseconds(30))
        return TranslationResult(
            windowRevision: request.windowRevision,
            translations: request.items.map { Translation(segmentId: $0.id, simplifiedChineseText: "云:" + $0.sourceText) }
        )
    }
}
