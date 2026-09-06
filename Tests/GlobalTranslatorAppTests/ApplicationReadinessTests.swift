import Foundation
import Testing
@testable import GlobalTranslatorApp
import GlobalTranslatorCapture
import GlobalTranslatorCore
import GlobalTranslatorEngine
import GlobalTranslatorRuntime
import GlobalTranslatorUI

extension ApplicationControllerTests {
    @Test
    func rebuiltSessionAcceptsFirstRevisionWithoutAcceptingOldSessionOutput() async throws {
        let controller = ApplicationController(
            paths: try RuntimePaths(validatingRoot: temporaryRoot()),
            components: makeComponents(overlayFactory: { OverlayPanelController(visibleFramesProvider: { [] }) })
        )
        try await controller.start()
        await waitForStartupHealthCheck(controller)
        let oldOverlay = try #require(controller.overlay as? OverlayPanelController)
        oldOverlay.update(translations: [], revision: 50)

        controller.selectBackend(.local)
        await waitForStartupHealthCheck(controller)
        let newOverlay = try #require(controller.overlay as? OverlayPanelController)
        newOverlay.update(translations: [], revision: 1)

        #expect(newOverlay.currentRevision == 1)
        #expect(newOverlay !== oldOverlay)
        #expect(oldOverlay.currentRevision == 50)
        await controller.stop()
    }

    @Test(arguments: [CaptureSource.accessibility, .visionOCR])
    func onePermissionCanRenderItsOwnCaptureSource(source: CaptureSource) async throws {
        let permission = FakePermissionController(snapshot: PermissionSnapshot(
            accessibilityTrusted: source == .accessibility,
            screenCaptureAuthorized: source == .visionOCR,
            secureInputEnabled: false,
            sessionLocked: false
        ))
        let monitor = FakeWindowMonitor()
        let overlay = FakeOverlay()
        let scheduler = SchedulerBox()
        let capture = ReadinessCapturePipeline(source: source)
        let controller = ApplicationController(
            paths: try RuntimePaths(validatingRoot: temporaryRoot()),
            components: makeComponents(permission: permission, monitor: monitor, overlay: overlay, capture: capture, schedulerBox: scheduler)
        )
        try await controller.start()
        await waitForStartupHealthCheck(controller)
        controller.session?.start()
        monitor.emit(readinessWindow())
        try await waitForCapture { scheduler.value?.submitCount == 1 }
        #expect(scheduler.value?.submitCount == 1)
        scheduler.emit(readinessOutput(source: source))

        #expect(overlay.lastTranslations.count == 1)
        #expect(controller.viewModel.status == .listening)
        #expect(monitor.visualUpdatesEnabled == (source == .visionOCR))
        await controller.stop()
    }

    @Test(arguments: [true, false])
    func protectionBeginningDuringCapturePreventsSchedulerSubmission(secureInput: Bool) async throws {
        let permission = FakePermissionController(snapshot: .allGranted)
        let capture = ReadinessCapturePipeline(source: .accessibility) {
            permission.update(PermissionSnapshot(
                accessibilityTrusted: true, screenCaptureAuthorized: true,
                secureInputEnabled: secureInput, sessionLocked: !secureInput
            ))
        }
        let monitor = FakeWindowMonitor()
        let scheduler = SchedulerBox()
        let controller = ApplicationController(
            paths: try RuntimePaths(validatingRoot: temporaryRoot()),
            components: makeComponents(permission: permission, monitor: monitor, capture: capture, schedulerBox: scheduler)
        )
        try await controller.start()
        await waitForStartupHealthCheck(controller)
        controller.session?.start()
        monitor.emit(readinessWindow())
        try await waitForCapture { capture.didCapture }
        for _ in 0..<20 { await Task.yield() }

        #expect(capture.didCapture)
        #expect(scheduler.value?.submitCount == 0)
        #expect(!monitor.visualUpdatesEnabled)
        await controller.stop()
    }

    @Test
    func currentEngineProtectionEventPausesAndRecoversButOldEventIsIgnored() async throws {
        let permission = FakePermissionController(snapshot: .allGranted)
        let monitor = FakeWindowMonitor()
        let events = EngineEventBox()
        let scheduler = SchedulerBox()
        let controller = ApplicationController(
            paths: try RuntimePaths(validatingRoot: temporaryRoot()),
            components: makeComponents(permission: permission, monitor: monitor, capture: ReadinessCapturePipeline(source: .accessibility), schedulerBox: scheduler, engineEventBox: events)
        )
        try await controller.start()
        await waitForStartupHealthCheck(controller)
        controller.session?.start()
        monitor.emit(readinessWindow())
        try await waitForCapture { scheduler.value?.submitCount == 1 }
        let cancellations = scheduler.value?.cancelCount
        events.emit(.captureBlocked(reason: .protected(.secureInput), windowRevision: 0))
        for _ in 0..<20 { await Task.yield() }
        #expect(scheduler.value?.cancelCount == cancellations)
        #expect(monitor.visualUpdatesEnabled)

        let starts = monitor.startCount
        permission.update(PermissionSnapshot(accessibilityTrusted: true, screenCaptureAuthorized: true, secureInputEnabled: true, sessionLocked: false))
        events.emit(.captureBlocked(reason: .protected(.secureInput), windowRevision: 1))
        try await waitForCapture { !monitor.visualUpdatesEnabled }
        #expect(!monitor.visualUpdatesEnabled)
        #expect((scheduler.value?.cancelCount ?? 0) > (cancellations ?? 0))
        permission.update(.allGranted)
        try await waitForCapture { monitor.startCount > starts }
        #expect(monitor.startCount == starts + 1)
        await controller.stop()
    }

    @Test
    func capturePermissionFailureNamesTheMissingPermission() async throws {
        let permission = FakePermissionController(snapshot: PermissionSnapshot(accessibilityTrusted: true, screenCaptureAuthorized: false, secureInputEnabled: false, sessionLocked: false))
        let monitor = FakeWindowMonitor()
        let controller = ApplicationController(
            paths: try RuntimePaths(validatingRoot: temporaryRoot()),
            components: makeComponents(permission: permission, monitor: monitor, capture: CaptureErrorPipeline(error: .permissionRequired(.screenCapture)))
        )
        try await controller.start()
        await waitForStartupHealthCheck(controller)
        controller.session?.start()
        monitor.emit(readinessWindow())
        try await waitForCapture { controller.viewModel.status == .missingPermission }
        #expect(controller.viewModel.healthMessage == "当前内容需要屏幕录制权限，请授权后重试")
        await controller.stop()
    }
}

private func readinessWindow() -> ActiveWindowDescriptor {
    ActiveWindowDescriptor(pid: 42, bundleIdentifier: "qa", frame: CGRect(x: 0, y: 0, width: 800, height: 600), revision: 1)
}

private func readinessRegion(source: CaptureSource) -> TextRegion {
    TextRegion(id: UUID(), sourceText: "Save changes", screenFrame: CGRect(x: 40, y: 40, width: 120, height: 24), confidence: 1,
               source: source == .accessibility ? .accessibility : .visionOCR, windowRevision: 1)
}

private func readinessOutput(source: CaptureSource) -> EngineOutput {
    EngineOutput(windowRevision: 1, translations: [RenderedTranslation(region: readinessRegion(source: source), text: "保存更改")],
                 metrics: EngineMetrics(inputRegionCount: 1, eligibleRegionCount: 1, cacheHitCount: 0, batchCount: 1, translatedRegionCount: 1, durationMilliseconds: 1, status: .success))
}

private final class ReadinessCapturePipeline: CapturePipelining, @unchecked Sendable {
    let source: CaptureSource
    let onCapture: @Sendable () -> Void
    private let lock = NSLock()
    private var captured = false
    var didCapture: Bool { lock.withLock { captured } }

    init(source: CaptureSource, onCapture: @escaping @Sendable () -> Void = {}) {
        self.source = source
        self.onCapture = onCapture
    }

    func capture(_ descriptor: ActiveWindowDescriptor) async throws -> CaptureSnapshot {
        onCapture()
        lock.withLock { captured = true }
        return CaptureSnapshot(window: CapturedWindow(descriptor: descriptor, regions: [readinessRegion(source: source)], source: source))
    }
}
