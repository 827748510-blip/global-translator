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
struct SelectionTranslateControllerTests {
    private func snapshot(_ text: String, bundle: String = "com.apple.TextEdit") -> SelectedTextSnapshot {
        SelectedTextSnapshot(
            text: text,
            screenFrame: CGRect(x: 80, y: 200, width: 100, height: 16),
            source: .accessibility,
            bundleIdentifier: bundle
        )
    }

    private func makeController(
        reader: FakeSelectedTextReader,
        popover: FakeSelectionPopover,
        translator: StubSelectionTranslator,
        permission: FakePermissionController = FakePermissionController(snapshot: .allGranted)
    ) -> SelectionTranslateController {
        SelectionTranslateController(
            reader: reader,
            popover: popover,
            monitor: NullSelectionPointerMonitor(),
            permissions: permission,
            logger: RecordingLogger(),
            translator: { translator },
            ownBundleIdentifiers: ["com.maodashu.global-translator"],
            settleDelay: .milliseconds(5),
            alreadyChineseDismissDelay: .milliseconds(30)
        )
    }

    private func select(_ controller: SelectionTranslateController, at point: CGPoint = CGPoint(x: 90, y: 210)) {
        controller.handlePointer(SelectionPointerPhase.down, location: point)
        controller.handlePointer(SelectionPointerPhase.up, location: point)
    }

    @Test
    func mouseUpShowsTranslationFromMockBackend() async throws {
        let reader = FakeSelectedTextReader(result: .snapshot(snapshot("Hello world")))
        let popover = FakeSelectionPopover()
        let translator = StubSelectionTranslator()
        translator.result = "你好，世界"
        let controller = makeController(reader: reader, popover: popover, translator: translator)
        controller.setEnabled(true)
        select(controller)
        try await waitUntil { popover.currentContent?.status == .translated }
        #expect(translator.texts == ["Hello world"])
        #expect(popover.currentContent?.displayTranslation == "你好，世界")
        #expect(popover.currentContent?.originalPreview == "Hello world")
        #expect(popover.currentContent?.allowsCopy == true)
    }

    @Test
    func draggingDoesNotReadUntilMouseUpSettles() async throws {
        let reader = FakeSelectedTextReader(result: .snapshot(snapshot("Hello world")))
        let popover = FakeSelectionPopover()
        let translator = StubSelectionTranslator()
        let controller = makeController(reader: reader, popover: popover, translator: translator)
        controller.setEnabled(true)
        controller.handlePointer(SelectionPointerPhase.down, location: CGPoint(x: 10, y: 10))
        controller.handlePointer(SelectionPointerPhase.dragged, location: CGPoint(x: 20, y: 12))
        controller.handlePointer(SelectionPointerPhase.dragged, location: CGPoint(x: 40, y: 14))
        try await Task.sleep(for: .milliseconds(20))
        #expect(reader.readCount == 0)
        #expect(popover.currentContent == nil)
        controller.handlePointer(SelectionPointerPhase.up, location: CGPoint(x: 40, y: 14))
        try await waitUntil { popover.currentContent?.status == .translated }
        #expect(reader.readCount == 1)
        #expect(translator.texts == ["Hello world"])
    }

    @Test
    func filterSkipDoesNotShowPopoverOrCallBackend() async throws {
        let reader = FakeSelectedTextReader(result: .snapshot(snapshot("https://example.com/path")))
        let popover = FakeSelectionPopover()
        let translator = StubSelectionTranslator()
        let controller = makeController(reader: reader, popover: popover, translator: translator)
        controller.setEnabled(true)
        select(controller)
        try await Task.sleep(for: .milliseconds(25))
        #expect(translator.texts.isEmpty)
        #expect(popover.currentContent == nil)
        #expect(popover.shown.isEmpty)
    }

    @Test
    func simplifiedChineseShowsAlreadyChineseWithoutCallingBackend() async throws {
        let reader = FakeSelectedTextReader(result: .snapshot(snapshot("你好世界")))
        let popover = FakeSelectionPopover()
        let translator = StubSelectionTranslator()
        let controller = makeController(reader: reader, popover: popover, translator: translator)
        controller.setEnabled(true)
        select(controller)
        try await waitUntil { popover.currentContent?.status == .alreadyChinese }
        #expect(translator.texts.isEmpty)
        #expect(popover.currentContent?.displayTranslation == "已是中文")
        try await waitUntil { popover.currentContent == nil }
    }

    @Test
    func toggleOffStopsMonitoringAndHidesPopover() async throws {
        let reader = FakeSelectedTextReader(result: .snapshot(snapshot("Hello world")))
        let popover = FakeSelectionPopover()
        let translator = StubSelectionTranslator()
        let controller = makeController(reader: reader, popover: popover, translator: translator)
        controller.setEnabled(true)
        select(controller)
        try await waitUntil { popover.currentContent?.status == .translated }
        controller.setEnabled(false)
        #expect(popover.currentContent == nil)
        reader.setResult(.snapshot(snapshot("Another sentence")))
        select(controller)
        try await Task.sleep(for: .milliseconds(25))
        #expect(translator.texts == ["Hello world"])
    }

    @Test
    func axUnavailableShowsOneLineStatus() async throws {
        let reader = FakeSelectedTextReader(result: .unavailable)
        let popover = FakeSelectionPopover()
        let translator = StubSelectionTranslator()
        let controller = makeController(reader: reader, popover: popover, translator: translator)
        controller.setEnabled(true)
        select(controller)
        try await waitUntil { popover.currentContent?.status == .unavailable }
        #expect(translator.texts.isEmpty)
        #expect(popover.currentContent?.displayTranslation == "无法读取所选文字")
    }

    @Test
    func emptySelectionDismissesPopover() async throws {
        let reader = FakeSelectedTextReader(result: .snapshot(snapshot("Hello world")))
        let popover = FakeSelectionPopover()
        let translator = StubSelectionTranslator()
        let controller = makeController(reader: reader, popover: popover, translator: translator)
        controller.setEnabled(true)
        select(controller)
        try await waitUntil { popover.currentContent?.status == .translated }
        reader.setResult(.empty)
        select(controller)
        try await waitUntil { popover.currentContent == nil }
    }

    private func waitUntil(_ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(1)
        while !condition(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(condition())
    }
}

extension ApplicationControllerTests {
    @Test
    func selectionTranslateDefaultsOnAndTogglePersists() async throws {
        let store = RecordingConfigurationStore()
        let popover = FakeSelectionPopover()
        let controller = ApplicationController(
            paths: try RuntimePaths(validatingRoot: temporaryRoot()),
            components: makeComponents(store: store, selectionPopover: popover)
        )
        try await controller.start()
        await waitForStartupHealthCheck(controller)
        #expect(controller.configuration.selectionTranslateEnabled)
        #expect(controller.viewModel.isSelectionTranslateEnabled)
        #expect(controller.selectionTranslate?.isEnabled == true)
        controller.setSelectionTranslate(false)
        try await controller.persistence.flush()
        #expect(!controller.configuration.selectionTranslateEnabled)
        #expect(controller.selectionTranslate?.isEnabled == false)
        #expect(await store.saved.last?.selectionTranslateEnabled == false)
        await controller.stop()
    }

    @Test
    func selectionTranslateWorksWhenChromeOverlayIsSkipped() async throws {
        let monitor = FakeWindowMonitor()
        let capture = CountingCapturePipeline()
        let overlay = FakeOverlay()
        let reader = FakeSelectedTextReader(result: .snapshot(SelectedTextSnapshot(
            text: "Hello from Chrome",
            screenFrame: CGRect(x: 40, y: 80, width: 60, height: 14),
            source: .accessibility,
            bundleIdentifier: "com.google.Chrome"
        )))
        let popover = FakeSelectionPopover()
        let store = RecordingConfigurationStore(configuration: AppConfiguration(
            autoTranslateEnabled: true, backend: .local, localModel: "test",
            translatedBundleIDs: ["com.google.Chrome"]))
        let controller = ApplicationController(
            paths: try RuntimePaths(validatingRoot: temporaryRoot()),
            components: makeComponents(
                store: store,
                monitor: monitor,
                overlay: overlay,
                coordinator: TranslatingCoordinator(),
                capture: capture,
                logger: RecordingLogger(),
                selectedTextReader: reader,
                selectionPopover: popover
            )
        )
        try await controller.start()
        await waitForStartupHealthCheck(controller)
        let session = try #require(controller.session)
        #expect(session.isBridgeActive)
        session.start()
        monitor.emit(ActiveWindowDescriptor(
            pid: 42, bundleIdentifier: "com.google.Chrome",
            windowID: 17, frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            revision: 1, invalidatesOverlay: true
        ))
        try await Task.sleep(for: .milliseconds(300))
        #expect(await capture.count == 0)
        #expect(overlay.lastTranslations.isEmpty)
        #expect(try await session.translateSelection("Hello from Chrome") == "你好 Hello from Chrome")
        let selection = try #require(controller.selectionTranslate)
        selection.handlePointer(SelectionPointerPhase.down, location: CGPoint(x: 50, y: 90))
        selection.handlePointer(SelectionPointerPhase.up, location: CGPoint(x: 50, y: 90))
        let deadline = Date().addingTimeInterval(1)
        while popover.currentContent?.status != .translated, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(popover.currentContent?.displayTranslation == "你好 Hello from Chrome")
        await controller.stop()
    }

    @Test
    func translateSelectionDoesNotRequireBridgeOrOverlayRunning() async throws {
        let store = RecordingConfigurationStore(configuration: AppConfiguration(
            autoTranslateEnabled: false, backend: .local, localModel: "test"))
        let controller = ApplicationController(
            paths: try RuntimePaths(validatingRoot: temporaryRoot()),
            components: makeComponents(store: store, coordinator: TranslatingCoordinator())
        )
        try await controller.start()
        await waitForStartupHealthCheck(controller)
        let session = try #require(controller.session)
        #expect(!session.isRunning)
        #expect(!session.isBridgeActive)
        #expect(try await session.translateSelection("Hello there") == "你好 Hello there")
        await controller.stop()
    }
}
