import Foundation
import Testing
@testable import GlobalTranslatorApp
import GlobalTranslatorCapture
import GlobalTranslatorCore
import GlobalTranslatorEngine
import GlobalTranslatorRuntime

extension ApplicationControllerTests {
    @Test
    func deferredTranslationWaitsForMatchingPageRecapture() async throws {
        let fixture = FlickerFixture()
        let controller = try await startFlickerController(fixture, renderImmediately: false)
        let output = fixture.output(revision: 1)
        fixture.monitor.emit(fixture.window(revision: 2))
        fixture.scheduler.emit(output)
        #expect(fixture.overlay.translations.isEmpty)
        try await waitForCapture { fixture.overlay.translations.count == 2 }
        #expect(fixture.overlay.translations.count == 2)
        #expect(fixture.overlay.translations.allSatisfy { $0.region.windowRevision == 2 })
        #expect(fixture.scheduler.value?.submitCount == 1)
        await controller.stop()
    }

    @Test
    func protectionEventForReusedRequestStillCancelsAfterPageRefresh() async throws {
        let fixture = FlickerFixture()
        let eventBox = EngineEventBox()
        let controller = ApplicationController(
            paths: try RuntimePaths(validatingRoot: temporaryRoot()),
            components: makeComponents(
                monitor: fixture.monitor,
                overlayFactory: { fixture.overlay },
                capture: fixture.capture,
                schedulerBox: fixture.scheduler,
                engineEventBox: eventBox
            )
        )
        try await controller.start()
        await waitForStartupHealthCheck(controller)
        controller.session?.start()
        fixture.monitor.emit(fixture.window(revision: 1))
        try await waitForCapture { fixture.scheduler.value?.submitCount == 1 }
        let output = fixture.output(revision: 1)
        let cancellations = fixture.scheduler.value?.cancelCount ?? 0
        fixture.monitor.emit(fixture.window(revision: 2))
        try await waitForCapture { fixture.capture.count == 2 }
        eventBox.emit(.captureBlocked(reason: .protected(.secureInput), windowRevision: 1))
        try await waitForCapture { (fixture.scheduler.value?.cancelCount ?? 0) > cancellations }
        #expect((fixture.scheduler.value?.cancelCount ?? 0) > cancellations)
        fixture.scheduler.emit(output)
        #expect(fixture.overlay.translations.isEmpty)
        await controller.stop()
    }

    @Test
    func unchangedPageRefreshKeepsInFlightTranslationAndUsesLatestCoordinates() async throws {
        let fixture = FlickerFixture()
        let controller = try await startFlickerController(fixture, renderImmediately: false)
        let originalOutput = fixture.output(revision: 1)
        let cancellations = fixture.scheduler.value?.cancelCount
        fixture.capture.setOffset(40)
        fixture.monitor.emit(fixture.window(revision: 2))
        try await waitForCapture { fixture.capture.count == 2 }
        for _ in 0..<20 { await Task.yield() }
        #expect(fixture.scheduler.value?.submitCount == 1)
        #expect(fixture.scheduler.value?.cancelCount == cancellations)
        fixture.scheduler.emit(originalOutput)
        #expect(fixture.overlay.translations.count == 2)
        #expect(fixture.overlay.translations.first?.region.screenFrame.minY == 340)
        #expect(fixture.overlay.translations.first?.region.windowRevision == 2)
        await controller.stop()
    }

    @Test
    func outputArrivingBeforeRecaptureCannotRenderChangedPage() async throws {
        let fixture = FlickerFixture()
        let controller = try await startFlickerController(fixture, renderImmediately: false)
        let originalOutput = fixture.output(revision: 1)
        fixture.capture.setTexts(["A different page"])
        fixture.monitor.emit(fixture.window(revision: 2))
        fixture.scheduler.emit(originalOutput)
        #expect(fixture.overlay.translations.isEmpty)
        try await waitForCapture { fixture.scheduler.value?.submitCount == 2 }
        #expect(fixture.scheduler.value?.submitCount == 2)
        #expect(fixture.overlay.translations.isEmpty)
        fixture.scheduler.emit(originalOutput)
        #expect(fixture.overlay.translations.isEmpty)
        fixture.scheduler.emit(fixture.output(revision: 2))
        #expect(fixture.overlay.translations.map(\.region.sourceText) == ["A different page"])
        await controller.stop()
    }

    @Test
    func invalidateRefreshKeepsInFlightTranslationForIdenticalContent() async throws {
        let fixture = FlickerFixture()
        let controller = try await startFlickerController(fixture, renderImmediately: false)
        let originalOutput = fixture.output(revision: 1)
        let cancellations = fixture.scheduler.value?.cancelCount
        fixture.capture.setOffset(60)
        fixture.monitor.emit(ActiveWindowDescriptor(pid: 42, bundleIdentifier: "qa.editor", windowID: 17, frame: CGRect(x: 0, y: 0, width: 800, height: 600), revision: 2, invalidatesOverlay: true))
        try await waitForCapture { fixture.capture.count == 2 }
        for _ in 0..<20 { await Task.yield() }
        #expect(fixture.scheduler.value?.submitCount == 1)
        #expect(fixture.scheduler.value?.cancelCount == cancellations)
        fixture.scheduler.emit(originalOutput)
        #expect(fixture.overlay.translations.count == 2)
        #expect(fixture.overlay.translations.first?.region.screenFrame.minY == 360)
        #expect(fixture.overlay.translations.first?.region.windowRevision == 2)
        await controller.stop()
    }

    @Test
    func browserWindowTranslatesInPageWithoutBubbles() async throws {
        let fixture = FlickerFixture()
        let inPage = FakeInPageTranslator(available: true)
        let store = RecordingConfigurationStore(configuration: AppConfiguration(
            autoTranslateEnabled: true, backend: .local, localModel: "test",
            translatedBundleIDs: ["com.google.Chrome"]))
        let controller = ApplicationController(
            paths: try RuntimePaths(validatingRoot: temporaryRoot()),
            components: makeComponents(
                store: store,
                monitor: fixture.monitor,
                overlayFactory: { fixture.overlay },
                coordinator: TranslatingCoordinator(),
                capture: fixture.capture,
                schedulerBox: fixture.scheduler,
                inPage: inPage
            )
        )
        try await controller.start()
        await waitForStartupHealthCheck(controller)
        controller.session?.start()
        fixture.monitor.emit(ActiveWindowDescriptor(pid: 42, bundleIdentifier: "com.google.Chrome", windowID: 17, frame: CGRect(x: 0, y: 0, width: 800, height: 600), revision: 1, invalidatesOverlay: true))
        try await waitForCapture { !inPage.applied.isEmpty }
        let applied = inPage.applied
        #expect(applied.count == 1)
        #expect(applied.first?.first?.text.contains("你好") == true)
        #expect(applied.first?.first?.nodeID == "n1")
        #expect(fixture.overlay.translations.isEmpty)
        #expect(fixture.scheduler.value?.submitCount == 0)
        #expect(fixture.capture.count == 0)
        await controller.stop()
    }

    @Test
    func inPageEmptyResultStaysBubbleFreeAndSkipsCooldownWindow() async throws {
        let fixture = FlickerFixture()
        let inPage = FakeInPageTranslator(available: true)
        let logger = RecordingLogger()
        let store = RecordingConfigurationStore(configuration: AppConfiguration(
            autoTranslateEnabled: true, backend: .local, localModel: "test",
            translatedBundleIDs: ["com.google.Chrome"]))
        let controller = ApplicationController(
            paths: try RuntimePaths(validatingRoot: temporaryRoot()),
            components: makeComponents(
                store: store,
                monitor: fixture.monitor,
                overlayFactory: { fixture.overlay },
                capture: fixture.capture,
                schedulerBox: fixture.scheduler,
                logger: logger,
                inPage: inPage
            )
        )
        try await controller.start()
        await waitForStartupHealthCheck(controller)
        controller.session?.start()

        // First invalidate: in-page extract runs, translations come back
        // empty (FakeCoordinator). A healthy channel with nothing to apply
        // must NOT fall back to the bubble pipeline.
        fixture.monitor.emit(ActiveWindowDescriptor(pid: 42, bundleIdentifier: "com.google.Chrome", windowID: 17, frame: CGRect(x: 0, y: 0, width: 800, height: 600), revision: 1, invalidatesOverlay: true))
        try await waitForCapture(timeout: 5) { inPage.extractCount == 1 }
        #expect(inPage.extractCount == 1)
        #expect(inPage.applied.first?.isEmpty == true)
        try await Task.sleep(for: .milliseconds(300))
        #expect(fixture.capture.count == 0)
        #expect(fixture.scheduler.value?.submitCount == 0)
        #expect(fixture.overlay.translations.isEmpty)

        // Invalidates inside the cooldown window skip the in-page channel
        // but still never touch the bubble pipeline.
        fixture.monitor.emit(ActiveWindowDescriptor(pid: 42, bundleIdentifier: "com.google.Chrome", windowID: 17, frame: CGRect(x: 0, y: 0, width: 800, height: 600), revision: 2, invalidatesOverlay: true))
        try await Task.sleep(for: .milliseconds(500))
        #expect(inPage.extractCount == 1)
        #expect(fixture.capture.count == 0)
        #expect(fixture.scheduler.value?.submitCount == 0)
        await controller.stop()
    }

    @Test
    func inPageChannelFailureFallsBackToBubblesWithCooldown() async throws {
        let fixture = FlickerFixture()
        let inPage = FakeInPageTranslator(available: true)
        inPage.extractError = URLError(.cannotConnectToHost)
        let store = RecordingConfigurationStore(configuration: AppConfiguration(
            autoTranslateEnabled: true, backend: .local, localModel: "test",
            translatedBundleIDs: ["com.google.Chrome"]))
        let controller = ApplicationController(
            paths: try RuntimePaths(validatingRoot: temporaryRoot()),
            components: makeComponents(
                store: store,
                monitor: fixture.monitor,
                overlayFactory: { fixture.overlay },
                capture: fixture.capture,
                schedulerBox: fixture.scheduler,
                inPage: inPage
            )
        )
        try await controller.start()
        await waitForStartupHealthCheck(controller)
        controller.session?.start()

        // A genuine channel failure (extract throws) still drops to bubbles.
        fixture.monitor.emit(ActiveWindowDescriptor(pid: 42, bundleIdentifier: "com.google.Chrome", windowID: 17, frame: CGRect(x: 0, y: 0, width: 800, height: 600), revision: 1, invalidatesOverlay: true))
        try await waitForCapture(timeout: 5) { fixture.scheduler.value?.submitCount == 1 }
        #expect(inPage.extractCount == 1)
        #expect(fixture.capture.count == 1)
        #expect(fixture.scheduler.value?.submitCount == 1)
        fixture.scheduler.emit(fixture.output(revision: 1))
        #expect(fixture.overlay.translations.count == 2)

        // During the cooldown the failed channel is not retried and bubbles
        // are not re-captured either — the window stays quiet until the
        // cooldown expires.
        fixture.monitor.emit(ActiveWindowDescriptor(pid: 42, bundleIdentifier: "com.google.Chrome", windowID: 17, frame: CGRect(x: 0, y: 0, width: 800, height: 600), revision: 2, invalidatesOverlay: true))
        try await Task.sleep(for: .milliseconds(500))
        #expect(inPage.extractCount == 1)
        #expect(fixture.capture.count == 1)
        await controller.stop()
    }

    @Test
    func browserWithoutInPageChannelKeepsBubblePipeline() async throws {
        let fixture = FlickerFixture()
        let inPage = FakeInPageTranslator(available: false)
        let controller = try await startInPageController(fixture, inPage: inPage)
        try await waitForCapture { fixture.scheduler.value?.submitCount == 1 }
        #expect(fixture.scheduler.value?.submitCount == 1)
        #expect(fixture.capture.count == 1)
        let extracts = inPage.extractCount
        #expect(extracts == 0)
        fixture.scheduler.emit(fixture.output(revision: 1))
        #expect(fixture.overlay.translations.count == 2)
        await controller.stop()
    }

    private func startInPageController(_ fixture: FlickerFixture, inPage: FakeInPageTranslator) async throws -> ApplicationController {
        let store = RecordingConfigurationStore(configuration: AppConfiguration(
            autoTranslateEnabled: true, backend: .local, localModel: "test",
            translatedBundleIDs: ["com.google.Chrome"]))
        let controller = ApplicationController(
            paths: try RuntimePaths(validatingRoot: temporaryRoot()),
            components: makeComponents(
                store: store,
                monitor: fixture.monitor,
                overlayFactory: { fixture.overlay },
                capture: fixture.capture,
                schedulerBox: fixture.scheduler,
                inPage: inPage
            )
        )
        try await controller.start()
        await waitForStartupHealthCheck(controller)
        controller.session?.start()
        fixture.monitor.emit(ActiveWindowDescriptor(pid: 42, bundleIdentifier: "com.google.Chrome", windowID: 17, frame: CGRect(x: 0, y: 0, width: 800, height: 600), revision: 1, invalidatesOverlay: true))
        return controller
    }

    @Test
    func unchangedVisualContentKeepsBubblesAndAvoidsRetranslation() async throws {
        let fixture = FlickerFixture()
        let controller = try await startFlickerController(fixture)
        let hideCount = fixture.overlay.hideCount
        let updateCount = fixture.overlay.updateCount
        for revision in 2...4 {
            fixture.monitor.emit(fixture.window(revision: UInt64(revision)))
            try await waitForCapture { fixture.capture.count == revision }
            for _ in 0..<20 { await Task.yield() }
        }
        #expect(fixture.capture.count == 4)
        #expect(fixture.overlay.hideCount == hideCount)
        #expect(fixture.overlay.updateCount == updateCount)
        #expect(fixture.scheduler.value?.submitCount == 1)
        #expect(fixture.overlay.translations.count == 2)
        await controller.stop()
    }

    @Test
    func changingOneRegionKeepsUnchangedBubbleUntilNewTranslationArrives() async throws {
        let fixture = FlickerFixture()
        let controller = try await startFlickerController(fixture)
        let stableID = try #require(fixture.overlay.translations.first?.id)
        let hideCount = fixture.overlay.hideCount
        fixture.capture.setTexts(["Stable text", "Updated text"])
        fixture.monitor.emit(fixture.window(revision: 2))
        try await waitForCapture { fixture.scheduler.value?.submitCount == 2 }
        #expect(fixture.overlay.hideCount == hideCount)
        #expect(fixture.overlay.translations.map(\.region.sourceText) == ["Stable text"])
        #expect(fixture.overlay.translations.first?.id == stableID)

        fixture.scheduler.emit(fixture.output(revision: 2))
        #expect(fixture.overlay.translations.count == 2)
        #expect(fixture.overlay.translations.first?.id == stableID)
        await controller.stop()
    }

    @Test
    func confirmedScrollReusesTranslationAtNewCoordinatesWithoutEmptyFrame() async throws {
        let fixture = FlickerFixture()
        let controller = try await startFlickerController(fixture)
        let ids = fixture.overlay.translations.map(\.id)
        let hides = fixture.overlay.hideCount
        fixture.capture.setOffset(40)
        fixture.monitor.emit(fixture.window(revision: 2))
        try await waitForCapture { fixture.capture.count == 2 }
        for _ in 0..<20 { await Task.yield() }
        #expect(fixture.overlay.hideCount == hides)
        #expect(fixture.overlay.translations.map(\.id) == ids)
        #expect(fixture.overlay.translations.first?.region.screenFrame.minY == 340)
        #expect(fixture.scheduler.value?.submitCount == 1)
        await controller.stop()
    }

    @Test
    func actualWindowSwitchStillHidesPreviousTranslationsImmediately() async throws {
        let fixture = FlickerFixture()
        let controller = try await startFlickerController(fixture)
        fixture.monitor.emit(ActiveWindowDescriptor(pid: 43, bundleIdentifier: "qa.other", windowID: 18, frame: CGRect(x: 0, y: 0, width: 800, height: 600), revision: 2))
        #expect(fixture.overlay.translations.isEmpty)
        await controller.stop()
    }

    private func startFlickerController(_ fixture: FlickerFixture, renderImmediately: Bool = true) async throws -> ApplicationController {
        let controller = ApplicationController(
            paths: try RuntimePaths(validatingRoot: temporaryRoot()),
            components: makeComponents(monitor: fixture.monitor, overlayFactory: { fixture.overlay }, capture: fixture.capture, schedulerBox: fixture.scheduler)
        )
        try await controller.start()
        await waitForStartupHealthCheck(controller)
        controller.session?.start()
        fixture.monitor.emit(fixture.window(revision: 1))
        try await waitForCapture { fixture.scheduler.value?.submitCount == 1 }
        #expect(fixture.scheduler.value?.submitCount == 1)
        if renderImmediately {
            fixture.scheduler.emit(fixture.output(revision: 1))
            #expect(fixture.overlay.translations.count == 2)
        }
        return controller
    }
}

@MainActor
private final class FlickerFixture {
    let monitor = FakeWindowMonitor()
    let scheduler = SchedulerBox()
    let capture = FlickerCapture()
    let overlay = FlickerOverlay()
    func window(revision: UInt64) -> ActiveWindowDescriptor {
        ActiveWindowDescriptor(pid: 42, bundleIdentifier: "qa.editor", windowID: 17, frame: CGRect(x: 0, y: 0, width: 800, height: 600), revision: revision, invalidatesOverlay: revision == 1)
    }
    func output(revision: UInt64) -> EngineOutput {
        let translations = capture.regions.map { RenderedTranslation(region: $0, text: "译文 " + $0.sourceText) }
        return EngineOutput(windowRevision: revision, translations: translations, metrics: EngineMetrics(inputRegionCount: translations.count, eligibleRegionCount: translations.count, cacheHitCount: 0, batchCount: 1, translatedRegionCount: translations.count, durationMilliseconds: 1, status: .success))
    }
}

@MainActor
private final class FlickerOverlay: OverlayControlling {
    private(set) var translations: [RenderedTranslation] = []
    private(set) var hideCount = 0
    private(set) var updateCount = 0
    func update(translations: [RenderedTranslation], revision: UInt64) {
        self.translations = translations
        updateCount += 1
    }
    func hideAll() { translations = []; hideCount += 1 }
}

private final class FlickerCapture: CapturePipelining, @unchecked Sendable {
    private let lock = NSLock()
    private var texts = ["Stable text", "Changing text"]
    private var offset: CGFloat = 0
    private var captures = 0
    private var lastRegions: [TextRegion] = []
    var count: Int { lock.withLock { captures } }
    var regions: [TextRegion] { lock.withLock { lastRegions } }
    func setTexts(_ texts: [String]) { lock.withLock { self.texts = texts } }
    func setOffset(_ offset: CGFloat) { lock.withLock { self.offset = offset } }
    func capture(_ descriptor: ActiveWindowDescriptor) async throws -> CaptureSnapshot {
        let regions = lock.withLock {
            captures += 1
            lastRegions = texts.enumerated().map { index, text in
                TextRegion(id: UUID(), sourceText: text, screenFrame: CGRect(x: 30, y: 300 - CGFloat(index) * 60 + offset, width: 240, height: 28), confidence: 1, source: .accessibility, windowRevision: descriptor.revision)
            }
            return lastRegions
        }
        return CaptureSnapshot(window: CapturedWindow(descriptor: descriptor, regions: regions, source: .accessibility))
    }
}
