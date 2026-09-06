import AppKit
import Foundation
import Testing
@testable import GlobalTranslatorApp
import GlobalTranslatorCore
import GlobalTranslatorCapture
import GlobalTranslatorEngine
import GlobalTranslatorRuntime
import GlobalTranslatorUI

@MainActor
struct ConfigurationPersistenceTests {
    @Test
    func queuedConfigurationSavesLatestRevisionOnly() async throws {
        let store = RecordingConfigurationStore()
        let persistence = ConfigurationPersistence(store: store)
        var first = AppConfiguration()
        first.localModel = "first"
        var latest = first
        latest.localModel = "latest"

        persistence.enqueue(first)
        persistence.enqueue(latest)
        try await persistence.flush()

        let saves = await store.saved
        #expect(saves.last?.localModel == "latest")
        #expect(saves.count >= 1)
    }
}

@MainActor
struct ApplicationControllerTests {
    @Test
    func redundantRootNotificationKeepsValidatedOverlayVisible() async throws {
        let monitor = FakeWindowMonitor()
        let overlay = FakeOverlay()
        let schedulerBox = SchedulerBox()
        let controller = ApplicationController(paths: try RuntimePaths(validatingRoot: temporaryRoot()), components: makeComponents(monitor: monitor, overlay: overlay, capture: SingleRegionCapturePipeline(), schedulerBox: schedulerBox))
        try await controller.start()
        await waitForStartupHealthCheck(controller)
        controller.session?.start()
        let frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        monitor.emit(ActiveWindowDescriptor(pid: 42, bundleIdentifier: "qa", frame: frame, revision: 1))
        try await waitForCapture { schedulerBox.value?.submitCount == 1 }
        let region = TextRegion(id: UUID(), sourceText: "hello", screenFrame: CGRect(x: 20, y: 20, width: 80, height: 20), confidence: 1, source: .accessibility, windowRevision: 1)
        schedulerBox.emit(EngineOutput(windowRevision: 1, translations: [RenderedTranslation(region: region, text: "你好")], metrics: EngineMetrics(inputRegionCount: 1, eligibleRegionCount: 1, cacheHitCount: 0, batchCount: 1, translatedRegionCount: 1, durationMilliseconds: 1, status: .success)))
        let hides = overlay.hideCount
        monitor.emit(ActiveWindowDescriptor(pid: 42, bundleIdentifier: "qa", frame: frame, revision: 2, invalidatesOverlay: false))
        #expect(overlay.hideCount == hides)
        await controller.stop()
    }

    @Test
    func productionSchedulerDoesNotDebounceAfterCaptureAlreadyDebounced() throws {
        let components = ApplicationControllerComponents.production(paths: RuntimePaths(root: temporaryRoot()))
        let coordinator = TranslationCoordinator(backends: [])
        let scheduler = try #require(components.schedulerFactory(coordinator, { _ in }, { _ in }) as? RealtimeTranslationScheduler)
        #expect(scheduler.debounceInterval == 0)
    }

    @Test
    func completedLocalGenerationSurvivesAGapBetweenDisplayTasks() async throws {
        let transport = DelayedEchoTransport()
        let factory = LiveTranslationBackendFactory(transport: transport)
        let backend = try factory.makeBackend(kind: .local, configuration: AppConfiguration(backend: .local, localModel: "test"), credentials: RecordingCredentialStore(value: nil))
        let first = TranslationRequest(windowRevision: 1, items: [TranslationItem(id: UUID(), sourceText: "hello")])
        let firstTask = Task { try? await backend.translate(first) }
        for _ in 0..<200 where await transport.calls == 0 { await Task.yield() }
        firstTask.cancel()
        _ = await firstTask.value
        let second = TranslationRequest(windowRevision: 2, items: [TranslationItem(id: UUID(), sourceText: "hello")])
        let result = try await backend.translate(second)
        #expect(await transport.calls == 1)
        #expect(result.translations.first?.segmentId == second.items.first?.id)
    }

    @Test
    func identicalLocalRequestsReuseGenerationAcrossDisplayCancellation() async throws {
        let transport = DelayedEchoTransport()
        let factory = LiveTranslationBackendFactory(transport: transport)
        let backend = try factory.makeBackend(kind: .local, configuration: AppConfiguration(backend: .local, localModel: "test"), credentials: RecordingCredentialStore(value: nil))
        let first = TranslationRequest(windowRevision: 1, items: [TranslationItem(id: UUID(), sourceText: "hello")])
        let second = TranslationRequest(windowRevision: 2, items: [TranslationItem(id: UUID(), sourceText: "hello")])
        let firstTask = Task { try? await backend.translate(first) }
        for _ in 0..<200 where await transport.calls == 0 { await Task.yield() }
        let secondTask = Task { try await backend.translate(second) }
        firstTask.cancel()
        let result = try await secondTask.value
        _ = await firstTask.value
        #expect(await transport.calls == 1)
        #expect(result.windowRevision == 2)
        #expect(result.translations.first?.segmentId == second.items.first?.id)
    }

    @Test(arguments: [CaptureError.unsupported, CaptureError.permissionRequired(.screenCapture)])
    func transientWindowCaptureFailureRequestsRefreshButPermissionsDoNot(error: CaptureError) async throws {
        let monitor = FakeWindowMonitor()
        let controller = ApplicationController(paths: try RuntimePaths(validatingRoot: temporaryRoot()), components: makeComponents(monitor: monitor, capture: CaptureErrorPipeline(error: error)))
        try await controller.start()
        await waitForStartupHealthCheck(controller)
        controller.session?.start()
        monitor.emit(ActiveWindowDescriptor(pid: 42, bundleIdentifier: "qa", frame: CGRect(x: 0, y: 0, width: 800, height: 600), revision: 1))
        try await waitForCapture { controller.viewModel.status == .error || controller.viewModel.status == .missingPermission }
        #expect(monitor.captureRefreshRequests == (error == .unsupported ? 1 : 0))
        await controller.stop()
    }

    @Test
    func captureWaitsForLayoutToSettleBeforeReading() async throws {
        let monitor = FakeWindowMonitor()
        let capture = RecordingCaptureRevisions()
        let controller = ApplicationController(paths: try RuntimePaths(validatingRoot: temporaryRoot()), components: makeComponents(monitor: monitor, capture: capture))
        try await controller.start()
        await waitForStartupHealthCheck(controller)
        controller.session?.start()
        monitor.emit(ActiveWindowDescriptor(pid: 42, bundleIdentifier: "qa", frame: CGRect(x: 0, y: 0, width: 800, height: 600), revision: 1))
        try await Task.sleep(for: .milliseconds(20))
        monitor.emit(ActiveWindowDescriptor(pid: 42, bundleIdentifier: "qa", frame: CGRect(x: 100, y: 0, width: 800, height: 600), revision: 2))
        try await Task.sleep(for: .milliseconds(180))
        #expect(await capture.revisions == [2])
        await controller.stop()
    }

    @Test(arguments: [CaptureSource.accessibility, .visionOCR])
    func visualChangeMonitoringTracksBothAXAndOCRWindows(source: CaptureSource) async throws {
        let monitor = FakeWindowMonitor()
        let controller = ApplicationController(paths: try RuntimePaths(validatingRoot: temporaryRoot()), components: makeComponents(monitor: monitor, capture: FakeCapturePipeline(source: source)))
        try await controller.start()
        await waitForStartupHealthCheck(controller)
        controller.session?.start()
        monitor.emit(ActiveWindowDescriptor(pid: 42, bundleIdentifier: "qa", frame: CGRect(x: 0, y: 0, width: 800, height: 600), revision: 1))
        try await waitForCapture { monitor.visualUpdateCalls > 0 }
        #expect(monitor.visualUpdatesEnabled)
        await controller.stop()
    }

    @Test(arguments: [true, false])
    func protectedCaptureRecoversWithoutAXNotificationUnlessStopped(stopBeforeRecovery: Bool) async throws {
        let permission = FakePermissionController(snapshot: .allGranted)
        let monitor = FakeWindowMonitor()
        let controller = ApplicationController(
            paths: try RuntimePaths(validatingRoot: temporaryRoot()),
            components: makeComponents(permission: permission, monitor: monitor, capture: CaptureErrorPipeline(error: .protected(.secureInput)))
        )
        try await controller.start()
        await waitForStartupHealthCheck(controller)
        controller.session?.start()
        let initialStarts = monitor.startCount
        permission.update(PermissionSnapshot(accessibilityTrusted: true, screenCaptureAuthorized: true, secureInputEnabled: true, sessionLocked: false))
        monitor.emit(ActiveWindowDescriptor(pid: 42, bundleIdentifier: "qa", frame: CGRect(x: 0, y: 0, width: 800, height: 600), revision: 1))
        try await Task.sleep(for: .milliseconds(450))
        #expect(monitor.startCount == initialStarts)
        if stopBeforeRecovery { controller.session?.stop() }
        permission.update(.allGranted)
        try await Task.sleep(for: .milliseconds(500))
        #expect(monitor.startCount == initialStarts + (stopBeforeRecovery ? 0 : 1))
        await controller.stop()
    }

    @Test(arguments: [true, false])
    func lateTranslationCannotRenderDuringSecureInputOrLock(secureInput: Bool) async throws {
        let permission = FakePermissionController(snapshot: .allGranted)
        let monitor = FakeWindowMonitor()
        let overlay = FakeOverlay()
        let schedulerBox = SchedulerBox()
        let controller = ApplicationController(
            paths: try RuntimePaths(validatingRoot: temporaryRoot()),
            components: makeComponents(permission: permission, monitor: monitor, overlay: overlay, schedulerBox: schedulerBox)
        )
        try await controller.start()
        await waitForStartupHealthCheck(controller)
        controller.session?.start()
        monitor.emit(ActiveWindowDescriptor(pid: 42, bundleIdentifier: "qa", frame: CGRect(x: 0, y: 0, width: 800, height: 600), revision: 1))
        permission.update(PermissionSnapshot(accessibilityTrusted: true, screenCaptureAuthorized: true, secureInputEnabled: secureInput, sessionLocked: !secureInput))
        let region = TextRegion(id: UUID(), sourceText: "Test", screenFrame: CGRect(x: 20, y: 20, width: 80, height: 20), confidence: 1, source: .accessibility, windowRevision: 1)
        schedulerBox.emit(EngineOutput(windowRevision: 1, translations: [RenderedTranslation(region: region, text: "测试")], metrics: EngineMetrics(inputRegionCount: 1, eligibleRegionCount: 1, cacheHitCount: 0, batchCount: 1, translatedRegionCount: 1, durationMilliseconds: 1, status: .success)))
        #expect(overlay.lastTranslations.isEmpty)
        await controller.stop()
    }

    @Test
    func localStartupDoesNotReadCloudKeychain() async throws {
        let gate = HealthCheckGate()
        let credentials = RecordingCredentialStore(value: "stored-key")
        let controller = ApplicationController(
            paths: try RuntimePaths(validatingRoot: temporaryRoot()),
            components: makeComponents(
                store: RecordingConfigurationStore(configuration: AppConfiguration(backend: .local, localModel: "local-test")),
                credentials: credentials,
                backendFactory: GatedBackendFactory(gate: gate)
            )
        )
        try await controller.start()
        #expect(credentials.readCount == 0)
        await gate.release(BackendHealth(status: .healthy, message: "ok"))
        await controller.stop()
    }

    @Test
    func startReturnsBeforeBackendHealthCheckFinishes() async throws {
        let gate = HealthCheckGate()
        let factory = GatedBackendFactory(gate: gate)
        let completion = CompletionProbe()
        let controller = ApplicationController(
            paths: try RuntimePaths(validatingRoot: temporaryRoot()),
            components: makeComponents(backendFactory: factory)
        )

        let startTask = Task { @MainActor in
            try await controller.start()
            await completion.markCompleted()
        }
        await gate.waitUntilStarted()
        for _ in 0..<20 { await Task.yield() }

        #expect(await completion.completed)

        await gate.release(BackendHealth(status: .healthy, message: "ok"))
        try await startTask.value
        await controller.stop()
    }

    @Test
    func backendHealthCompletingAfterStopCannotMutateApplicationState() async throws {
        let gate = HealthCheckGate()
        let factory = GatedBackendFactory(gate: gate)
        let monitor = FakeWindowMonitor()
        let persisted = AppConfiguration(autoTranslateEnabled: true)
        let controller = ApplicationController(
            paths: try RuntimePaths(validatingRoot: temporaryRoot()),
            components: makeComponents(
                store: RecordingConfigurationStore(configuration: persisted),
                credentials: RecordingCredentialStore(value: "stored-key"),
                backendFactory: factory,
                monitor: monitor
            )
        )

        let startTask = Task { @MainActor in try await controller.start() }
        await gate.waitUntilStarted()
        await controller.stop()
        await gate.release(BackendHealth(status: .healthy, message: "ok"))
        try await startTask.value
        for _ in 0..<20 { await Task.yield() }

        #expect(!controller.started)
        #expect(!controller.viewModel.backendReady)
        #expect(controller.viewModel.status == MenuBarStatus.off)
        #expect(monitor.startCount == 0)
        #expect(controller.session == nil)
        #expect(controller.callbackBox == nil)
    }

    @Test
    func invalidConfigurationFallsBackWithoutOverwritingAndPushesSafeState() async throws {
        let store = RecordingConfigurationStore(loadError: ConfigStoreError.invalidData)
        let credentials = RecordingCredentialStore(value: nil)
        let permission = FakePermissionController(snapshot: .allGranted)
        let factory = StubBackendFactory(health: BackendHealth(status: .invalidCredentials, message: "secret"))
        let monitor = FakeWindowMonitor()
        let components = ApplicationControllerComponents(
            configurationStore: store,
            credentialStore: credentials,
            permissionController: permission,
            backendFactory: factory,
            monitorFactory: { _ in monitor },
            capturePipelineFactory: { _ in FakeCapturePipeline() },
            statusItemFactory: { _ in FakeStatusItem() },
            overlayFactory: { FakeOverlay() },
            coordinatorFactory: { _, _ in FakeCoordinator() },
            schedulerFactory: { _, _, _ in FakeScheduler() },
            logger: RecordingLogger()
        )
        let controller = ApplicationController(paths: try RuntimePaths(validatingRoot: temporaryRoot()), components: components)

        try await controller.start()
        await waitForStartupHealthCheck(controller)

        #expect(controller.configuration == AppConfiguration())
        #expect(controller.viewModel.selectedBackend == .deepSeekCloud)
        #expect(!controller.viewModel.keyConfigured)
        #expect(controller.viewModel.permissionSnapshot == .allGranted)
        #expect(controller.viewModel.healthMessage != nil)
        #expect(!controller.viewModel.healthMessage!.contains("secret"))
        #expect(await store.saved.isEmpty)
    }

    @Test
    func persistedAutomaticTranslationStartsOnlyWhenPermissionAndHealthAreReady() async throws {
        let persisted = AppConfiguration(autoTranslateEnabled: true)
        let store = RecordingConfigurationStore(configuration: persisted)
        let credentials = RecordingCredentialStore(value: "stored-key")
        let monitor = FakeWindowMonitor()
        let controller = ApplicationController(
            paths: try RuntimePaths(validatingRoot: temporaryRoot()),
            components: makeComponents(
                store: store,
                credentials: credentials,
                monitor: monitor
            )
        )

        try await controller.start()
        await waitForStartupHealthCheck(controller)

        #expect(monitor.startCount == 1)
        #expect(controller.viewModel.isAutomaticTranslationEnabled)
    }

    @Test
    func persistedAutomaticTranslationRemainsOffWhenPermissionMissing() async throws {
        let persisted = AppConfiguration(autoTranslateEnabled: true)
        let store = RecordingConfigurationStore(configuration: persisted)
        let permission = FakePermissionController(snapshot: PermissionSnapshot(
            accessibilityTrusted: false,
            screenCaptureAuthorized: false,
            secureInputEnabled: false,
            sessionLocked: false
        ))
        let monitor = FakeWindowMonitor()
        let controller = ApplicationController(
            paths: try RuntimePaths(validatingRoot: temporaryRoot()),
            components: makeComponents(store: store, permission: permission, monitor: monitor)
        )

        try await controller.start()
        await waitForStartupHealthCheck(controller)

        #expect(monitor.startCount == 0)
        #expect(!controller.viewModel.isAutomaticTranslationEnabled)
        #expect(controller.viewModel.healthMessage == "需要辅助功能或屏幕录制权限才能开启自动翻译")
    }

    @Test
    func permissionRequestRefreshesAgainAfterTheSystemPromptCompletes() async throws {
        let denied = PermissionSnapshot(
            accessibilityTrusted: false,
            screenCaptureAuthorized: false,
            secureInputEnabled: false,
            sessionLocked: false
        )
        let permission = FakePermissionController(snapshot: denied)
        let controller = ApplicationController(
            paths: try RuntimePaths(validatingRoot: temporaryRoot()),
            components: makeComponents(permission: permission)
        )
        try await controller.start()
        await waitForStartupHealthCheck(controller)

        controller.requestPermission(.accessibility)
        try await Task.sleep(for: .milliseconds(150))
        permission.update(.allGranted)
        try await Task.sleep(for: .milliseconds(200))

        #expect(controller.viewModel.permissionSnapshot.accessibilityTrusted)
        #expect(permission.accessibilityRequestCount == 1)
        await controller.stop()
    }

    @Test
    func savingAPIKeyHealthChecksDraftBeforeKeychainWrite() async throws {
        let store = RecordingConfigurationStore()
        let credentials = RecordingCredentialStore(value: nil)
        let draftFactory = StubBackendFactory(health: BackendHealth(status: .healthy, message: "ok"))
        let components = makeComponents(
            store: store,
            credentials: credentials,
            backendFactory: draftFactory
        )
        let controller = ApplicationController(paths: try RuntimePaths(validatingRoot: temporaryRoot()), components: components)
        try await controller.start()
        await waitForStartupHealthCheck(controller)

        try await controller.saveAPIKey("  draft-key  ")

        #expect(draftFactory.healthCredentials == ["draft-key"])
        #expect(credentials.savedValues == ["draft-key"])
        #expect(controller.viewModel.keyConfigured)
        #expect(!controller.viewModel.keyDraft.contains("draft-key"))
    }

    @Test
    func unhealthyDraftNeverWritesKeychain() async throws {
        let credentials = RecordingCredentialStore(value: nil)
        let factory = StubBackendFactory(health: BackendHealth(status: .unavailable, message: "Bearer sk-secret-123"))
        let controller = ApplicationController(
            paths: try RuntimePaths(validatingRoot: temporaryRoot()),
            components: makeComponents(credentials: credentials, backendFactory: factory)
        )
        try await controller.start()
        await waitForStartupHealthCheck(controller)

        do {
            try await controller.saveAPIKey("draft-key")
            Issue.record("unhealthy key must fail")
        } catch {
            #expect(credentials.savedValues.isEmpty)
            #expect(!controller.viewModel.keyConfigured)
        }
    }

    @Test
    func backendSwitchStopsSessionAndNeverFallsBack() async throws {
        let coordinator = FakeCoordinator()
        let monitor = FakeWindowMonitor()
        let overlay = FakeOverlay()
        let controller = ApplicationController(
            paths: try RuntimePaths(validatingRoot: temporaryRoot()),
            components: makeComponents(
                backendFactory: StubBackendFactory(health: BackendHealth(status: .healthy, message: "ok")),
                monitor: monitor,
                overlay: overlay,
                coordinator: coordinator
            )
        )
        try await controller.start()
        await waitForStartupHealthCheck(controller)
        controller.viewModel.permissionSnapshot = .allGranted
        controller.viewModel.backendReady = true
        controller.viewModel.keyConfigured = true
        controller.viewModel.setAutomaticTranslation(true)
        controller.selectBackend(.local)

        #expect(monitor.stopCount >= 1)
        #expect(overlay.hideCount >= 1)
        #expect(await coordinator.selectedKinds == [])
    }

    @Test
    func automaticTranslationWaitsForHealthyBackendBeforeStartingMonitor() async throws {
        let monitor = FakeWindowMonitor()
        let factory = StubBackendFactory(health: BackendHealth(status: .unavailable, message: "unsafe"))
        let controller = ApplicationController(
            paths: try RuntimePaths(validatingRoot: temporaryRoot()),
            components: makeComponents(backendFactory: factory, monitor: monitor)
        )
        try await controller.start()
        await waitForStartupHealthCheck(controller)
        controller.viewModel.permissionSnapshot = .allGranted
        controller.viewModel.keyConfigured = true
        controller.viewModel.backendReady = true

        controller.setAutomaticTranslation(true)
        for _ in 0..<10 { await Task.yield() }

        #expect(monitor.startCount == 0)
        #expect(!controller.viewModel.isAutomaticTranslationEnabled)
    }

    @Test
    func currentRevisionOutputReachesOverlayAndStaleCaptureDoesNot() async throws {
        let monitor = FakeWindowMonitor()
        let capture = FakeCapturePipeline()
        let overlay = FakeOverlay()
        let schedulerBox = SchedulerBox()
        let components = makeComponents(
            monitor: monitor,
            overlay: overlay,
            capture: capture,
            schedulerBox: schedulerBox
        )
        let controller = ApplicationController(
            paths: try RuntimePaths(validatingRoot: temporaryRoot()),
            components: components
        )
        try await controller.start()
        await waitForStartupHealthCheck(controller)
        controller.viewModel.permissionSnapshot = .allGranted
        controller.viewModel.backendReady = true
        controller.viewModel.keyConfigured = true
        controller.viewModel.isAutomaticTranslationEnabled = true
        controller.session?.configure(
            backends: [StubBackend(kind: .deepSeekCloud)],
            backend: .deepSeekCloud,
            model: "deepseek-v4-flash-vision-exp",
            visionFallbackEnabled: false
        )
        controller.session?.start()

        let descriptor = ActiveWindowDescriptor(
            pid: 42,
            bundleIdentifier: "com.example.editor",
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            revision: 11
        )
        monitor.emit(descriptor)
        await Task.yield()
        await Task.yield()
        let region = TextRegion(
            id: UUID(),
            sourceText: "hello",
            screenFrame: CGRect(x: 20, y: 20, width: 80, height: 20),
            confidence: 1,
            source: .accessibility,
            windowRevision: 11
        )
        schedulerBox.emit(EngineOutput(
            windowRevision: 11,
            translations: [RenderedTranslation(region: region, text: "你好")],
            metrics: EngineMetrics(inputRegionCount: 1, eligibleRegionCount: 1, cacheHitCount: 0, batchCount: 1, translatedRegionCount: 1, durationMilliseconds: 1, status: .success)
        ))
        #expect(overlay.lastRevision == 11)
        #expect(overlay.lastTranslations.first?.text == "你好")

        schedulerBox.emit(EngineOutput(
            windowRevision: 10,
            translations: [RenderedTranslation(region: region, text: "旧")],
            metrics: EngineMetrics(inputRegionCount: 1, eligibleRegionCount: 1, cacheHitCount: 0, batchCount: 1, translatedRegionCount: 1, durationMilliseconds: 1, status: .success)
        ))
        #expect(overlay.lastTranslations.first?.text == "你好")
    }

    @Test
    func missingOrProtectedWindowKeepsAnEnabledSessionListening() async throws {
        let monitor = FakeWindowMonitor()
        let overlay = FakeOverlay()
        let controller = ApplicationController(
            paths: try RuntimePaths(validatingRoot: temporaryRoot()),
            components: makeComponents(
                monitor: monitor,
                overlay: overlay,
                capture: CaptureErrorPipeline(error: .protected(.protectedWindow))
            )
        )
        try await controller.start()
        await waitForStartupHealthCheck(controller)
        for _ in 0..<20 { await Task.yield() }
        controller.session?.start()

        monitor.emit(nil)
        #expect(controller.viewModel.status == MenuBarStatus.listening)

        monitor.emit(ActiveWindowDescriptor(
            pid: 42,
            bundleIdentifier: "com.example.protected",
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            revision: 1
        ))
        for _ in 0..<20 { await Task.yield() }

        #expect(controller.viewModel.status == MenuBarStatus.listening)
        #expect(overlay.hideCount >= 2)
        await controller.stop()
    }

    @Test
    func staleCaptureFailureCannotOverwriteTheCurrentWindowStatus() async throws {
        let monitor = FakeWindowMonitor()
        let capture = StaleFailureCapturePipeline()
        let controller = ApplicationController(
            paths: try RuntimePaths(validatingRoot: temporaryRoot()),
            components: makeComponents(monitor: monitor, capture: capture)
        )
        try await controller.start()
        await waitForStartupHealthCheck(controller)
        for _ in 0..<20 { await Task.yield() }
        controller.session?.start()

        monitor.emit(ActiveWindowDescriptor(
            pid: 42,
            bundleIdentifier: "com.example.first",
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            revision: 1
        ))
        await capture.waitUntilFirstCaptureStarts()
        monitor.emit(ActiveWindowDescriptor(
            pid: 43,
            bundleIdentifier: "com.example.second",
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            revision: 2
        ))
        for _ in 0..<20 { await Task.yield() }
        await capture.releaseFirstFailure()
        for _ in 0..<20 { await Task.yield() }

        #expect(controller.viewModel.status == .listening)
        await controller.stop()
    }

    @Test
    func unversionedEngineStateCannotOverwriteSessionStatus() async throws {
        let eventBox = EngineEventBox()
        let controller = ApplicationController(
            paths: try RuntimePaths(validatingRoot: temporaryRoot()),
            components: makeComponents(engineEventBox: eventBox)
        )
        try await controller.start()
        await waitForStartupHealthCheck(controller)
        for _ in 0..<20 { await Task.yield() }
        controller.session?.start()

        eventBox.emit(.stateChanged(.backendError))
        for _ in 0..<20 { await Task.yield() }

        #expect(controller.viewModel.status == .listening)
        await controller.stop()
    }

    @Test
    func currentCaptureSetsTranslatingBeforeSchedulerSubmission() async throws {
        let monitor = FakeWindowMonitor()
        let schedulerBox = SchedulerBox()
        let controller = ApplicationController(
            paths: try RuntimePaths(validatingRoot: temporaryRoot()),
            components: makeComponents(
                monitor: monitor,
                capture: SingleRegionCapturePipeline(),
                schedulerBox: schedulerBox
            )
        )
        try await controller.start()
        await waitForStartupHealthCheck(controller)
        for _ in 0..<20 { await Task.yield() }
        controller.session?.start()

        monitor.emit(ActiveWindowDescriptor(
            pid: 42,
            bundleIdentifier: "com.example.editor",
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            revision: 3
        ))
        for _ in 0..<20 { await Task.yield() }

        try await waitForCapture { schedulerBox.value?.submitCount == 1 }
        #expect(schedulerBox.value?.submitCount == 1)
        #expect(controller.viewModel.status == .translating)
        await controller.stop()
    }

    @Test
    func healthyAutomaticTranslationStartsMonitorAfterRecheck() async throws {
        let monitor = FakeWindowMonitor()
        let controller = ApplicationController(
            paths: try RuntimePaths(validatingRoot: temporaryRoot()),
            components: makeComponents(monitor: monitor)
        )
        try await controller.start()
        await waitForStartupHealthCheck(controller)
        controller.viewModel.permissionSnapshot = .allGranted
        controller.viewModel.keyConfigured = true
        controller.viewModel.backendReady = true

        controller.setAutomaticTranslation(true)
        for _ in 0..<10 { await Task.yield() }

        #expect(monitor.startCount == 1)
        #expect(controller.viewModel.isAutomaticTranslationEnabled)
    }

    @Test
    func localEndpointValidationRejectsRemoteAndKeepsPreviousConfiguration() async throws {
        let controller = ApplicationController(
            paths: try RuntimePaths(validatingRoot: temporaryRoot()),
            components: makeComponents()
        )
        try await controller.start()
        await waitForStartupHealthCheck(controller)
        let previousURL = controller.configuration.localBaseURL

        controller.setLocalConfiguration(baseURL: "https://example.com/v1", model: "remote")

        #expect(controller.configuration.localBaseURL == previousURL)
        #expect(controller.viewModel.healthMessage == ApplicationActionError.localEndpointInvalid.uiSafeDescription)
    }

    @Test
    func disablingAutomaticTranslationCancelsAndHidesOverlay() async throws {
        let monitor = FakeWindowMonitor()
        let overlay = FakeOverlay()
        let controller = ApplicationController(
            paths: try RuntimePaths(validatingRoot: temporaryRoot()),
            components: makeComponents(monitor: monitor, overlay: overlay)
        )
        try await controller.start()
        await waitForStartupHealthCheck(controller)
        controller.viewModel.isAutomaticTranslationEnabled = true
        controller.setAutomaticTranslation(false)

        #expect(monitor.stopCount >= 1)
        #expect(overlay.hideCount >= 1)
        #expect(!controller.viewModel.isAutomaticTranslationEnabled)
    }

    @Test
    func gracefulStopPreservesPreferenceAndReleasesRuntimeCallbacks() async throws {
        let persisted = AppConfiguration(autoTranslateEnabled: true)
        let statusItem = FakeStatusItem()
        let controller = ApplicationController(
            paths: try RuntimePaths(validatingRoot: temporaryRoot()),
            components: makeComponents(
                store: RecordingConfigurationStore(configuration: persisted),
                credentials: RecordingCredentialStore(value: "stored-key"),
                statusItem: statusItem
            )
        )
        try await controller.start()
        await waitForStartupHealthCheck(controller)
        for _ in 0..<20 { await Task.yield() }

        await controller.stop()

        #expect(controller.configuration.autoTranslateEnabled)
        #expect(!controller.viewModel.isAutomaticTranslationEnabled)
        #expect(controller.callbackBox == nil)
        #expect(statusItem.stopCount == 1)
    }

    @Test
    func captureFailureUsesSafeStatusAndMetadataOnlyLog() async throws {
        let monitor = FakeWindowMonitor()
        let logger = RecordingLogger()
        let controller = ApplicationController(
            paths: try RuntimePaths(validatingRoot: temporaryRoot()),
            components: makeComponents(
                monitor: monitor,
                capture: FailingCapturePipeline(),
                logger: logger
            )
        )
        try await controller.start()
        await waitForStartupHealthCheck(controller)
        controller.session?.start()
        monitor.emit(ActiveWindowDescriptor(
            pid: 42,
            bundleIdentifier: "com.example.foreign",
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            revision: 1
        ))
        for _ in 0..<20 { await Task.yield() }

        try await waitForCapture { controller.viewModel.status == .error }
        #expect(controller.viewModel.status == .error)
        #expect(logger.records.allSatisfy { !$0.1.values.contains { $0.contains("secret") } })
    }

    func makeComponents(
        store: RecordingConfigurationStore = RecordingConfigurationStore(),
        credentials: RecordingCredentialStore = RecordingCredentialStore(value: nil),
        permission: FakePermissionController = FakePermissionController(snapshot: .allGranted),
        backendFactory: any TranslationBackendFactory = StubBackendFactory(health: BackendHealth(status: .healthy, message: "ok")),
        monitor: FakeWindowMonitor = FakeWindowMonitor(),
        overlay: FakeOverlay = FakeOverlay(),
        overlayFactory: OverlayFactory? = nil,
        coordinator: FakeCoordinator = FakeCoordinator(),
        capture: any CapturePipelining = FakeCapturePipeline(),
        schedulerBox: SchedulerBox? = nil,
        engineEventBox: EngineEventBox? = nil,
        statusItem: FakeStatusItem = FakeStatusItem(),
        logger: RecordingLogger = RecordingLogger()
    ) -> ApplicationControllerComponents {
        ApplicationControllerComponents(
            configurationStore: store,
            credentialStore: credentials,
            permissionController: permission,
            backendFactory: backendFactory,
            monitorFactory: { _ in monitor },
            capturePipelineFactory: { _ in capture },
            statusItemFactory: { _ in statusItem },
            overlayFactory: overlayFactory ?? { overlay },
            coordinatorFactory: { _, eventSink in
                engineEventBox?.set(eventSink)
                return coordinator
            },
            schedulerFactory: { _, output, state in
                let scheduler = FakeScheduler(output: output, state: state)
                schedulerBox?.value = scheduler
                return scheduler
            },
            logger: logger
        )
    }

    func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("gt-app-\(UUID().uuidString)", isDirectory: true)
    }

    func waitForCapture(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func waitForStartupHealthCheck(_ controller: ApplicationController) async {
        for _ in 0..<1_000 {
            if controller.backendRefreshTask == nil { return }
            await Task.yield()
        }
        Issue.record("startup backend health check did not settle")
    }
}

@MainActor
struct GlobalTranslatorApplicationTests {
    @Test
    func stoppingNativeEventLoopPostsAnApplicationEventToWakeAppKit() {
        let application = FakeNSApplicationDriver()
        let loop = NSApplicationEventLoop(applicationDriver: application)

        loop.stop()

        #expect(application.stopCount == 1)
        #expect(application.postedEvents.count == 1)
        #expect(application.postedEvents.first?.type == .applicationDefined)
    }

    @Test
    func nativeEventLoopDefersToTheRealNSApplicationRunLoop() async {
        let application = FakeNSApplicationDriver()
        let loop = NSApplicationEventLoop(applicationDriver: application)

        await loop.run(onStarted: {})

        #expect(application.finishLaunchingCount == 1)
        #expect(application.runCount == 1)
    }

    @Test
    func runnerStartsWorkerBeforeControllerAndStopsLoopAfterWorkerStop() async throws {
        let worker = FakeRuntimeWorker()
        let recorder = RunnerEventRecorder()
        let controller = FakeApplicationController(recorder: recorder)
        let loop = FakeEventLoop(onRun: { worker.stop() }, recorder: recorder)
        let runner = GlobalTranslatorApplicationRunner(
            worker: worker,
            controller: controller,
            eventLoop: loop
        )

        try await runner.run()

        #expect(worker.events == ["start", "stop"])
        #expect(controller.events == ["start", "stop"])
        #expect(recorder.events == ["event-loop-run", "controller-start"])
        #expect(loop.prepareCount == 1)
        #expect(loop.runCount == 1)
        #expect(loop.stopCount == 1)
    }
}
