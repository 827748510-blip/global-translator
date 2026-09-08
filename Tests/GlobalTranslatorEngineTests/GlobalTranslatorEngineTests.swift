import CoreGraphics
import Foundation
import Testing
@testable import GlobalTranslatorCapture
@testable import GlobalTranslatorCore
@testable import GlobalTranslatorEngine

struct GlobalTranslatorEngineTests {
    @Test
    func localBatchesBoundMetadataOverheadWithoutDroppingRegions() async throws {
        let regions = (0..<13).map { makeRegion(text: "Visible label \($0)", y: CGFloat(100 + $0 * 25)) }
        let backend = RecordingBackend(kind: .local) { request, _ in
            TranslationResult(windowRevision: request.windowRevision, translations: request.items.map { Translation(segmentId: $0.id, simplifiedChineseText: "译文") })
        }
        let coordinator = TranslationCoordinator(backends: [backend], permissions: SystemPermissionController(snapshotProvider: { .allGranted }))
        let output = try await coordinator.translate(snapshot: makeSnapshot(regions: regions, revision: 1), backend: .local, modelIdentifier: "test", visionFallbackEnabled: false)
        #expect(output.translations.count == 13)
        // Local models translate more reliably with small batches.
        #expect(await backend.requests.map { $0.items.count } == [3, 3, 3, 3, 1])
    }

    @Test
    func pageTextLocalBatchesAreSingleItemsSoDensePagesDoNotTripTheCircuit() async throws {
        let regions = (0..<30).map { makeRegion(text: "Visible label \($0)", y: CGFloat(100 + $0 * 25)) }
        let backend = RecordingBackend(kind: .local) { request, _ in
            TranslationResult(windowRevision: request.windowRevision, translations: request.items.map {
                Translation(segmentId: $0.id, simplifiedChineseText: "译文")
            })
        }
        let breaker = CircuitBreaker()
        let coordinator = TranslationCoordinator(
            backends: [backend],
            circuitBreaker: breaker,
            permissions: SystemPermissionController(snapshotProvider: { .allGranted })
        )
        let output = try await coordinator.translate(
            snapshot: makeSnapshot(regions: regions, revision: 0, source: .pageText),
            backend: .local,
            modelIdentifier: "test",
            visionFallbackEnabled: false
        )
        #expect(output.translations.count == 30)
        #expect(await backend.requests.map { $0.items.count } == Array(repeating: 1, count: 30))
        #expect(!(await breaker.isOpen))
    }

    @Test
    func pageTextNetworkFailureDoesNotOpenTheCircuit() async throws {
        let backend = ThrowingBackend(kind: .local, error: .networkFailure)
        let breaker = CircuitBreaker()
        let coordinator = TranslationCoordinator(
            backends: [backend],
            circuitBreaker: breaker,
            permissions: SystemPermissionController(snapshotProvider: { .allGranted })
        )
        let snapshot = makeSnapshot(regions: [makeRegion(text: "Hello world")], revision: 0, source: .pageText)
        for _ in 0..<5 {
            await #expect(throws: TranslationError.networkFailure) {
                _ = try await coordinator.translate(
                    snapshot: snapshot, backend: .local, modelIdentifier: "test", visionFallbackEnabled: false
                )
            }
        }
        #expect(!(await breaker.isOpen))
        #expect(await backend.requestCount == 5)
        #expect(await coordinator.state != .circuitOpen)
    }

    @Test
    func batchesFilteredTextAndRemapsDuplicateRegions() async throws {
        let firstID = UUID()
        let secondID = UUID()
        let descriptor = ActiveWindowDescriptor(
            pid: 42,
            bundleIdentifier: "com.example.editor",
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            revision: 1
        )
        let snapshot = CaptureSnapshot(window: CapturedWindow(
            descriptor: descriptor,
            regions: [
                TextRegion(id: firstID, sourceText: " hello ", screenFrame: CGRect(x: 10, y: 100, width: 80, height: 20), confidence: 1, source: .accessibility, windowRevision: 1),
                TextRegion(id: secondID, sourceText: "hello", screenFrame: CGRect(x: 10, y: 50, width: 80, height: 20), confidence: 1, source: .accessibility, windowRevision: 1),
                TextRegion(id: UUID(), sourceText: "https://example.com", screenFrame: CGRect(x: 0, y: 0, width: 80, height: 20), confidence: 1, source: .accessibility, windowRevision: 1)
            ],
            source: .accessibility
        ))
        let backend = RecordingBackend(kind: .local) { request, _ in
            TranslationResult(windowRevision: request.windowRevision, translations: [
                Translation(segmentId: request.items[0].id, simplifiedChineseText: "你好")
            ])
        }
        let coordinator = TranslationCoordinator(backends: [backend], permissions: SystemPermissionController(snapshotProvider: { .allGranted }))
        let output = try await coordinator.translate(
            snapshot: snapshot,
            backend: .local,
            modelIdentifier: "test-model",
            visionFallbackEnabled: false
        )

        #expect(output.translations.map(\.id) == [firstID, secondID])
        #expect(output.translations.map(\.text) == ["你好", "你好"])
        #expect(output.metrics.batchCount == 1)
        #expect(await backend.requests.count == 1)
        #expect(await backend.requests.first?.items.count == 1)
        #expect(await backend.requests.first?.items.first?.sourceText == "hello")
    }

    @Test
    func batcherRespectsUniqueItemAndCharacterLimitsInReadingOrder() {
        var regions: [TextRegion] = []
        for index in 0..<26 {
            regions.append(makeRegion(text: "word\(index)", x: CGFloat(index), y: 100))
        }
        let batcher = TranslationBatcher()
        let plan = batcher.plan(regions: regions)
        let batches = batcher.makeBatches(from: plan.entries, windowRevision: 1)
        #expect(batches.count == 2)
        #expect(batches[0].request.items.count == 24)
        #expect(batches[1].request.items.count == 2)
        #expect(batches.allSatisfy { $0.request.items.count <= 24 && $0.sourceCharacterCount <= 4_000 })
        #expect(plan.entries.first?.sourceText == "word0")

        let exact = [
            makeRegion(text: String(repeating: "a", count: 2_000), x: 0, y: 100),
            makeRegion(text: String(repeating: "b", count: 2_000), x: 1, y: 100),
            makeRegion(text: "語", x: 2, y: 100)
        ]
        let exactBatches = batcher.makeBatches(from: exact, windowRevision: 1)
        #expect(exactBatches.count == 2)
        #expect(exactBatches[0].sourceCharacterCount == 4_000)
        #expect(exactBatches[1].sourceCharacterCount == 1)
    }

    @Test
    func cacheMapsAHitToEveryCurrentRegionID() async throws {
        let backend = RecordingBackend(kind: .local) { request, _ in
            TranslationResult(windowRevision: request.windowRevision, translations: [
                Translation(segmentId: request.items[0].id, simplifiedChineseText: "你好")
            ])
        }
        let coordinator = TranslationCoordinator(backends: [backend], permissions: SystemPermissionController(snapshotProvider: { .allGranted }))
        _ = try await coordinator.translate(snapshot: makeSnapshot(regions: [makeRegion(text: "hello")], revision: 1), backend: .local, modelIdentifier: "m", visionFallbackEnabled: false)
        let currentID = UUID()
        let output = try await coordinator.translate(snapshot: makeSnapshot(regions: [makeRegion(id: currentID, text: " hello ")], revision: 2), backend: .local, modelIdentifier: "m", visionFallbackEnabled: false)
        #expect(output.translations.map { $0.id } == [currentID])
        #expect(output.translations.first?.text == "你好")
        #expect(output.metrics.cacheHitCount == 1)
        #expect(output.metrics.batchCount == 0)
        #expect(await backend.requests.count == 1)
    }

    @Test
    func switchingBackendClearsMemoryCache() async throws {
        let local = RecordingBackend(kind: .local) { request, _ in
            TranslationResult(windowRevision: request.windowRevision, translations: [
                Translation(segmentId: request.items[0].id, simplifiedChineseText: "本地")
            ])
        }
        let cloud = RecordingBackend(kind: .deepSeekCloud) { request, _ in
            TranslationResult(windowRevision: request.windowRevision, translations: [
                Translation(segmentId: request.items[0].id, simplifiedChineseText: "云端")
            ])
        }
        let coordinator = TranslationCoordinator(backends: [local, cloud], permissions: SystemPermissionController(snapshotProvider: { .allGranted }))
        _ = try await coordinator.translate(snapshot: makeSnapshot(regions: [makeRegion(text: "hello")], revision: 1), backend: .local, modelIdentifier: "local", visionFallbackEnabled: false)
        await coordinator.selectBackend(kind: .deepSeekCloud, modelIdentifier: "cloud")
        let currentID = UUID()
        let output = try await coordinator.translate(
            snapshot: makeSnapshot(regions: [makeRegion(id: currentID, text: "hello")], revision: 2),
            backend: .deepSeekCloud,
            modelIdentifier: "cloud",
            visionFallbackEnabled: false
        )
        #expect(output.translations.first?.text == "云端")
        #expect(output.metrics.cacheHitCount == 0)
        #expect(await local.requests.count == 1)
        #expect(await cloud.requests.count == 1)
    }

    @Test
    func circuitOpensOnThirdFailureAndClosesAfterThirtySeconds() async throws {
        let clock = TestMonotonicClock()
        let breaker = CircuitBreaker(clock: clock)
        await breaker.recordFailure()
        await breaker.recordFailure()
        await breaker.recordFailure()
        #expect(await breaker.isOpen)
        do {
            try await breaker.check()
            Issue.record("expected circuit to be open")
        } catch let error as TranslationCoordinatorError {
            guard case .circuitOpen(let retryAfter) = error else {
                Issue.record("unexpected circuit error")
                return
            }
            #expect(retryAfter == 30)
        }
        clock.advance(by: 30)
        try await breaker.check()
        #expect(!(await breaker.isOpen))
        await breaker.recordSuccess()
        #expect(await breaker.failureCount == 0)
    }

    @Test
    func rateLimitDoesNotRetryOrUseAnotherBackend() async throws {
        let backend = ThrowingBackend(kind: .local, error: .rateLimited(retryAfter: 9))
        let coordinator = TranslationCoordinator(backends: [backend], permissions: SystemPermissionController(snapshotProvider: { .allGranted }))
        do {
            _ = try await coordinator.translate(
                snapshot: makeSnapshot(regions: [makeRegion(text: "hello")], revision: 1),
                backend: .local,
                modelIdentifier: "m",
                visionFallbackEnabled: false
            )
            Issue.record("expected rate limit")
        } catch let error as TranslationError {
            #expect(error == .rateLimited(retryAfter: 9))
        }
        #expect(await backend.requestCount == 1)
    }

    @Test
    func rateLimitRetryAfterImmediatelyOpensCircuitWithoutRetry() async throws {
        let clock = TestMonotonicClock()
        let breaker = CircuitBreaker(clock: clock)
        let backend = ThrowingBackend(kind: .local, error: .rateLimited(retryAfter: 9))
        let coordinator = TranslationCoordinator(backends: [backend], circuitBreaker: breaker, clock: clock, permissions: SystemPermissionController(snapshotProvider: { .allGranted }))
        let snapshot = makeSnapshot(regions: [makeRegion(text: "hello")], revision: 1)
        do {
            _ = try await coordinator.translate(snapshot: snapshot, backend: .local, modelIdentifier: "m", visionFallbackEnabled: false)
            Issue.record("expected rate limit")
        } catch let error as TranslationError {
            #expect(error == .rateLimited(retryAfter: 9))
        }
        do {
            _ = try await coordinator.translate(snapshot: snapshot, backend: .local, modelIdentifier: "m", visionFallbackEnabled: false)
            Issue.record("expected open circuit")
        } catch let error as TranslationCoordinatorError {
            guard case .circuitOpen(let retryAfter) = error else {
                Issue.record("unexpected circuit error")
                return
            }
            #expect(retryAfter == 9)
        }
        #expect(await backend.requestCount == 1)
        clock.advance(by: 9)
        do {
            _ = try await coordinator.translate(snapshot: snapshot, backend: .local, modelIdentifier: "m", visionFallbackEnabled: false)
            Issue.record("expected backend rate limit after cooldown")
        } catch let error as TranslationError {
            #expect(error == .rateLimited(retryAfter: 9))
        }
        #expect(await backend.requestCount == 2)
    }

    @Test
    func missingOrZeroRetryAfterCountsAsNormalFailure() async {
        let clock = TestMonotonicClock()
        let breaker = CircuitBreaker(clock: clock)
        await breaker.recordFailure(.rateLimited(retryAfter: nil))
        await breaker.recordFailure(.rateLimited(retryAfter: 0))
        #expect(await breaker.failureCount == 2)
        #expect(!(await breaker.isOpen))
        await breaker.recordFailure(.networkFailure)
        #expect(await breaker.isOpen)
    }
}
