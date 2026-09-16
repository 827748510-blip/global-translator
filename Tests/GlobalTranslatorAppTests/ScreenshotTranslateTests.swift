import AppKit
import Foundation
import Testing
@testable import GlobalTranslatorApp
import GlobalTranslatorCapture
import GlobalTranslatorCore
import GlobalTranslatorEngine
import GlobalTranslatorRuntime
import GlobalTranslatorUI

@MainActor
struct ScreenshotTranslateControllerTests {
    private func waitUntil(_ condition: @escaping () -> Bool, timeout: TimeInterval = 1) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(condition())
    }

    @Test
    func hotkeyCapturesOCRAndShowsTranslationWithoutAutoCopy() async throws {
        var copied: [String] = []
        let selector = FakeRegionSelector()
        let ocr = FakeRegionOCR()
        ocr.text = "Hello world"
        let popover = FakeSelectionPopover()
        let translator = StubSelectionTranslator()
        translator.result = "你好，世界"
        let registrar = RecordingHotkeyRegistrar()
        let controller = ScreenshotTranslateController(
            selector: selector,
            capturer: FakeRegionCapturer(),
            ocr: ocr,
            popover: popover,
            permissions: FakePermissionController(snapshot: .allGranted),
            logger: RecordingLogger(),
            registrar: registrar,
            translator: { translator },
            backendReadiness: { .ready },
            pasteboardWriter: { copied.append($0) }
        )
        controller.startHotkey()
        #expect(registrar.registered[ScreenshotTranslateSupport.hotkeyID] == .screenshotTranslateDefault)
        controller.handleHotkey()
        try await waitUntil { popover.currentContent?.status == .translated }
        #expect(selector.selectCount == 1)
        #expect(ocr.callCount == 1)
        #expect(translator.texts == ["Hello world"])
        #expect(popover.currentContent?.original == "Hello world")
        #expect(popover.currentContent?.displayTranslation == "你好，世界")
        #expect(popover.currentContent?.allowsCopy == true)
        #expect(popover.currentContent?.showsOptimizeAction == false)
        #expect(popover.currentContent?.showsTranslateAction == false)
        #expect(copied.isEmpty)
        controller.stopHotkey()
        #expect(registrar.registered.isEmpty)
    }

    @Test
    func autoCopyWritesTranslationWhenEnabled() async throws {
        var copied: [String] = []
        let popover = FakeSelectionPopover()
        let translator = StubSelectionTranslator()
        translator.result = "你好，世界"
        let controller = ScreenshotTranslateController(
            selector: FakeRegionSelector(),
            capturer: FakeRegionCapturer(),
            ocr: FakeRegionOCR(),
            popover: popover,
            permissions: FakePermissionController(snapshot: .allGranted),
            logger: RecordingLogger(),
            registrar: RecordingHotkeyRegistrar(),
            translator: { translator },
            backendReadiness: { .ready },
            pasteboardWriter: { copied.append($0) }
        )
        controller.setAutoCopy(true)
        controller.handleHotkey()
        try await waitUntil { popover.currentContent?.status == .translated }
        #expect(copied == ["你好，世界"])
    }

    @Test
    func missingScreenCaptureShowsExplicitMessage() async throws {
        let popover = FakeSelectionPopover()
        let selector = FakeRegionSelector()
        let permission = FakePermissionController(snapshot: PermissionSnapshot(
            accessibilityTrusted: true,
            screenCaptureAuthorized: false,
            secureInputEnabled: false,
            sessionLocked: false
        ))
        let controller = ScreenshotTranslateController(
            selector: selector,
            capturer: FakeRegionCapturer(),
            ocr: FakeRegionOCR(),
            popover: popover,
            permissions: permission,
            logger: RecordingLogger(),
            registrar: RecordingHotkeyRegistrar(),
            translator: { StubSelectionTranslator() },
            backendReadiness: { .ready },
            requestScreenCapture: { _ = permission.requestScreenCapturePermission() }
        )
        controller.handleHotkey()
        try await waitUntil { popover.currentContent?.status == .failed }
        #expect(popover.currentContent?.displayTranslation == ScreenshotTranslateSupport.missingScreenCaptureCopy)
        #expect(selector.selectCount == 0)
        #expect(permission.screenCaptureRequestCount == 1)
    }

    @Test
    func emptyRegionShowsExplicitMessage() async throws {
        let selector = FakeRegionSelector()
        selector.result = .completed(CGRect(x: 10, y: 10, width: 2, height: 2))
        let popover = FakeSelectionPopover()
        let ocr = FakeRegionOCR()
        let logger = RecordingLogger()
        let controller = ScreenshotTranslateController(
            selector: selector,
            capturer: FakeRegionCapturer(),
            ocr: ocr,
            popover: popover,
            permissions: FakePermissionController(snapshot: .allGranted),
            logger: logger,
            registrar: RecordingHotkeyRegistrar(),
            translator: { StubSelectionTranslator() },
            backendReadiness: { .ready }
        )
        controller.handleHotkey()
        try await waitUntil { popover.currentContent?.status == .failed }
        #expect(popover.currentContent?.displayTranslation == ScreenshotTranslateSupport.emptyRegionCopy)
        #expect(ocr.callCount == 0)
        #expect(logger.records.contains(where: { $0.0 == "screenshot_region_empty" }))
        #expect(!logger.records.contains(where: { $0.0 == "screenshot_cancelled" }))
    }

    @Test
    func emptyOCRShowsExplicitMessage() async throws {
        let ocr = FakeRegionOCR()
        ocr.text = "   "
        let popover = FakeSelectionPopover()
        let translator = StubSelectionTranslator()
        let controller = ScreenshotTranslateController(
            selector: FakeRegionSelector(),
            capturer: FakeRegionCapturer(),
            ocr: ocr,
            popover: popover,
            permissions: FakePermissionController(snapshot: .allGranted),
            logger: RecordingLogger(),
            registrar: RecordingHotkeyRegistrar(),
            translator: { translator },
            backendReadiness: { .ready }
        )
        controller.handleHotkey()
        try await waitUntil { popover.currentContent?.status == .failed }
        #expect(popover.currentContent?.displayTranslation == ScreenshotTranslateSupport.ocrEmptyCopy)
        #expect(translator.texts.isEmpty)
    }

    @Test
    func ocrFailureShowsExplicitMessage() async throws {
        let ocr = FakeRegionOCR()
        ocr.error = CaptureError.ocrFailed
        let popover = FakeSelectionPopover()
        let controller = ScreenshotTranslateController(
            selector: FakeRegionSelector(),
            capturer: FakeRegionCapturer(),
            ocr: ocr,
            popover: popover,
            permissions: FakePermissionController(snapshot: .allGranted),
            logger: RecordingLogger(),
            registrar: RecordingHotkeyRegistrar(),
            translator: { StubSelectionTranslator() },
            backendReadiness: { .ready }
        )
        controller.handleHotkey()
        try await waitUntil { popover.currentContent?.status == .failed }
        #expect(popover.currentContent?.displayTranslation == ScreenshotTranslateSupport.ocrFailedCopy)
    }

    @Test
    func captureFailureShowsExplicitMessage() async throws {
        let capturer = FakeRegionCapturer(image: nil)
        let popover = FakeSelectionPopover()
        let ocr = FakeRegionOCR()
        let controller = ScreenshotTranslateController(
            selector: FakeRegionSelector(),
            capturer: capturer,
            ocr: ocr,
            popover: popover,
            permissions: FakePermissionController(snapshot: .allGranted),
            logger: RecordingLogger(),
            registrar: RecordingHotkeyRegistrar(),
            translator: { StubSelectionTranslator() },
            backendReadiness: { .ready }
        )
        controller.handleHotkey()
        try await waitUntil { popover.currentContent?.status == .failed }
        #expect(popover.currentContent?.displayTranslation == ScreenshotTranslateSupport.captureFailedCopy)
        #expect(ocr.callCount == 0)
    }

    @Test
    func missingDeepSeekKeyMatchesSelectionCopy() async throws {
        let popover = FakeSelectionPopover()
        let translator = StubSelectionTranslator()
        let controller = ScreenshotTranslateController(
            selector: FakeRegionSelector(),
            capturer: FakeRegionCapturer(),
            ocr: FakeRegionOCR(),
            popover: popover,
            permissions: FakePermissionController(snapshot: .allGranted),
            logger: RecordingLogger(),
            registrar: RecordingHotkeyRegistrar(),
            translator: { translator },
            backendReadiness: { .missingCloudKey }
        )
        controller.handleHotkey()
        try await waitUntil { popover.currentContent?.status == .failed }
        #expect(popover.currentContent?.displayTranslation == SelectionTranslateSupport.missingDeepSeekKeyCopy)
        #expect(translator.texts.isEmpty)
    }

    @Test
    func localBackendNotReadyShowsOllamaMessage() async throws {
        let popover = FakeSelectionPopover()
        let translator = StubSelectionTranslator()
        let controller = ScreenshotTranslateController(
            selector: FakeRegionSelector(),
            capturer: FakeRegionCapturer(),
            ocr: FakeRegionOCR(),
            popover: popover,
            permissions: FakePermissionController(snapshot: .allGranted),
            logger: RecordingLogger(),
            registrar: RecordingHotkeyRegistrar(),
            translator: { translator },
            backendReadiness: { .localNotReady }
        )
        controller.setBackend(.local)
        controller.handleHotkey()
        try await waitUntil { popover.currentContent?.status == .failed }
        #expect(popover.currentContent?.displayTranslation == ScreenshotTranslateSupport.localBackendNotReadyCopy)
        #expect(translator.texts.isEmpty)
    }

    @Test
    func translationFailureShowsFailedNotGenericServiceCopy() async throws {
        let popover = FakeSelectionPopover()
        let translator = StubSelectionTranslator()
        translator.error = SelectionTranslateError.emptyResult
        let controller = ScreenshotTranslateController(
            selector: FakeRegionSelector(),
            capturer: FakeRegionCapturer(),
            ocr: FakeRegionOCR(),
            popover: popover,
            permissions: FakePermissionController(snapshot: .allGranted),
            logger: RecordingLogger(),
            registrar: RecordingHotkeyRegistrar(),
            translator: { translator },
            backendReadiness: { .ready }
        )
        controller.handleHotkey()
        try await waitUntil { popover.currentContent?.status == .failed }
        #expect(popover.currentContent?.displayTranslation == "翻译失败")
        #expect(popover.currentContent?.displayTranslation != "服务返回异常，请稍后重试")
    }

    @Test
    func cancelledRegionDoesNotShowPopover() async throws {
        let selector = FakeRegionSelector()
        selector.result = .cancelled
        let popover = FakeSelectionPopover()
        let logger = RecordingLogger()
        let controller = ScreenshotTranslateController(
            selector: selector,
            capturer: FakeRegionCapturer(),
            ocr: FakeRegionOCR(),
            popover: popover,
            permissions: FakePermissionController(snapshot: .allGranted),
            logger: logger,
            registrar: RecordingHotkeyRegistrar(),
            translator: { StubSelectionTranslator() },
            backendReadiness: { .ready }
        )
        controller.handleHotkey()
        try await waitUntil { selector.selectCount == 1 }
        try await Task.sleep(for: .milliseconds(20))
        #expect(popover.shown.isEmpty)
        #expect(logger.records.contains(where: { $0.0 == "screenshot_cancelled" }))
        #expect(!logger.records.contains(where: { $0.0 == "screenshot_region_empty" }))
    }

    @Test
    func alreadyChineseOCRDoesNotCallTranslator() async throws {
        let ocr = FakeRegionOCR()
        ocr.text = "你好世界"
        let popover = FakeSelectionPopover()
        let translator = StubSelectionTranslator()
        let controller = ScreenshotTranslateController(
            selector: FakeRegionSelector(),
            capturer: FakeRegionCapturer(),
            ocr: ocr,
            popover: popover,
            permissions: FakePermissionController(snapshot: .allGranted),
            logger: RecordingLogger(),
            registrar: RecordingHotkeyRegistrar(),
            translator: { translator },
            backendReadiness: { .ready }
        )
        controller.handleHotkey()
        try await waitUntil { popover.currentContent?.status == .alreadyChinese }
        #expect(translator.texts.isEmpty)
        #expect(popover.currentContent?.showsOptimizeAction == false)
        #expect(popover.currentContent?.showsTranslateAction == false)
    }

    @Test
    func hotkeyConflictIsSurfaced() {
        let registrar = RecordingHotkeyRegistrar()
        registrar.errorToThrow = .alreadyInUse
        let controller = ScreenshotTranslateController(
            selector: FakeRegionSelector(),
            capturer: FakeRegionCapturer(),
            ocr: FakeRegionOCR(),
            popover: FakeSelectionPopover(),
            permissions: FakePermissionController(snapshot: .allGranted),
            logger: RecordingLogger(),
            registrar: registrar,
            translator: { nil },
            backendReadiness: { .ready }
        )
        controller.startHotkey()
        #expect(controller.lastHotkeyError == KeyboardShortcutSupport.alreadyInUseCopy)
    }
}

extension ApplicationControllerTests {
    @Test
    func screenshotAutoCopyDefaultsOffAndTogglePersists() async throws {
        let store = RecordingConfigurationStore()
        let controller = ApplicationController(
            paths: try RuntimePaths(validatingRoot: temporaryRoot()),
            components: makeComponents(store: store)
        )
        try await controller.start()
        await waitForStartupHealthCheck(controller)
        #expect(!controller.configuration.autoCopyScreenshotTranslation)
        #expect(!controller.viewModel.autoCopyScreenshotTranslation)
        #expect(controller.configuration.screenshotTranslateHotkey == .screenshotTranslateDefault)
        controller.setAutoCopyScreenshotTranslation(true)
        try await controller.persistence.flush()
        #expect(controller.configuration.autoCopyScreenshotTranslation)
        #expect(await store.saved.last?.autoCopyScreenshotTranslation == true)
        let custom = KeyboardShortcutSpec(keyCode: KeyboardShortcutSpec.KeyCode.r, option: true)
        controller.setScreenshotTranslateHotkey(custom)
        try await controller.persistence.flush()
        #expect(controller.configuration.screenshotTranslateHotkey == custom)
        #expect(await store.saved.last?.screenshotTranslateHotkey == custom)
        await controller.stop()
    }
}
