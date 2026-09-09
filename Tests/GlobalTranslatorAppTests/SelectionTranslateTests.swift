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
            unavailableDismissDelay: .milliseconds(30)
        )
    }

    private func select(_ controller: SelectionTranslateController, at point: CGPoint = CGPoint(x: 90, y: 210)) {
        controller.handlePointer(SelectionPointerPhase.down, location: point)
        controller.handlePointer(SelectionPointerPhase.up, location: point)
    }

    private func dragSelect(_ controller: SelectionTranslateController, at point: CGPoint = CGPoint(x: 90, y: 210)) {
        controller.handlePointer(SelectionPointerPhase.down, location: point)
        controller.handlePointer(SelectionPointerPhase.dragged, location: CGPoint(x: point.x + 16, y: point.y))
        controller.handlePointer(SelectionPointerPhase.up, location: CGPoint(x: point.x + 16, y: point.y))
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
        #expect(popover.currentContent?.showsOptimizeAction == true)
        try await Task.sleep(for: .milliseconds(40))
        #expect(popover.currentContent?.status == .alreadyChinese)
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
    func clickWithoutDragDoesNotShowUnavailableStatus() async throws {
        let reader = FakeSelectedTextReader(result: .unavailable)
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
    func dragThenUnavailableShowsBriefStatusThenAutoDismisses() async throws {
        let reader = FakeSelectedTextReader(result: .unavailable)
        let popover = FakeSelectionPopover()
        let translator = StubSelectionTranslator()
        let controller = makeController(reader: reader, popover: popover, translator: translator)
        controller.setEnabled(true)
        dragSelect(controller)
        try await waitUntil { popover.currentContent?.status == .unavailable }
        #expect(translator.texts.isEmpty)
        #expect(popover.currentContent?.displayTranslation == "无法读取所选文字")
        try await waitUntil { popover.currentContent == nil }
        #expect(popover.dismissCount >= 1)
    }

    @Test
    func unavailableDismissesImmediatelyOnPointerDown() async throws {
        let reader = FakeSelectedTextReader(result: .unavailable)
        let popover = FakeSelectionPopover()
        let translator = StubSelectionTranslator()
        let controller = makeController(reader: reader, popover: popover, translator: translator)
        controller.setEnabled(true)
        dragSelect(controller)
        try await waitUntil { popover.currentContent?.status == .unavailable }
        controller.handlePointer(SelectionPointerPhase.down, location: CGPoint(x: 10, y: 10))
        #expect(popover.currentContent == nil)
        let shownCount = popover.shown.count
        try await Task.sleep(for: .milliseconds(50))
        #expect(popover.currentContent == nil)
        #expect(popover.shown.count == shownCount)
    }

    @Test
    func unavailableDismissesImmediatelyOnEscape() async throws {
        let reader = FakeSelectedTextReader(result: .unavailable)
        let popover = FakeSelectionPopover()
        let translator = StubSelectionTranslator()
        let controller = makeController(reader: reader, popover: popover, translator: translator)
        controller.setEnabled(true)
        dragSelect(controller)
        try await waitUntil { popover.currentContent?.status == .unavailable }
        popover.simulateUserDismiss()
        #expect(popover.currentContent == nil)
        let shownCount = popover.shown.count
        try await Task.sleep(for: .milliseconds(50))
        #expect(popover.currentContent == nil)
        #expect(popover.shown.count == shownCount)
    }

    @Test
    func emptySelectionDismissesUnavailableStatus() async throws {
        let reader = FakeSelectedTextReader(result: .unavailable)
        let popover = FakeSelectionPopover()
        let translator = StubSelectionTranslator()
        let controller = makeController(reader: reader, popover: popover, translator: translator)
        controller.setEnabled(true)
        dragSelect(controller)
        try await waitUntil { popover.currentContent?.status == .unavailable }
        reader.setResult(.empty)
        controller.handlePointer(SelectionPointerPhase.up, location: CGPoint(x: 10, y: 10))
        try await waitUntil { popover.currentContent == nil }
        let shownCount = popover.shown.count
        try await Task.sleep(for: .milliseconds(50))
        #expect(popover.currentContent == nil)
        #expect(popover.shown.count == shownCount)
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

    @Test
    func userDismissDoesNotRedisplayTheSameSelectionUntilItChanges() async throws {
        let reader = FakeSelectedTextReader(result: .snapshot(snapshot("Hello world")))
        let popover = FakeSelectionPopover()
        let translator = StubSelectionTranslator()
        translator.result = "你好，世界"
        let controller = makeController(reader: reader, popover: popover, translator: translator)
        controller.setEnabled(true)
        select(controller)
        try await waitUntil { popover.currentContent?.status == .translated }
        popover.simulateUserDismiss()
        #expect(popover.currentContent == nil)
        select(controller)
        try await Task.sleep(for: .milliseconds(40))
        #expect(popover.currentContent == nil)

        reader.setResult(.snapshot(snapshot("Another sentence")))
        translator.result = "另一句"
        select(controller)
        try await waitUntil { popover.currentContent?.original == "Another sentence" }
        #expect(popover.currentContent?.displayTranslation == "另一句")

        popover.simulateUserDismiss()
        reader.setResult(.empty)
        select(controller)
        try await Task.sleep(for: .milliseconds(25))
        reader.setResult(.snapshot(snapshot("Another sentence")))
        select(controller)
        try await waitUntil { popover.currentContent?.status == .translated }
        #expect(popover.currentContent?.original == "Another sentence")
    }

    @Test
    func dragCancelsInFlightTranslationAndDoesNotShowStaleResult() async throws {
        let reader = FakeSelectedTextReader(result: .snapshot(snapshot("Hello world")))
        let popover = FakeSelectionPopover()
        let translator = StubSelectionTranslator()
        translator.delay = .milliseconds(250)
        translator.result = "你好，世界"
        let controller = makeController(reader: reader, popover: popover, translator: translator)
        controller.setEnabled(true)
        select(controller)
        try await waitUntil { popover.currentContent?.status == .loading }
        controller.handlePointer(SelectionPointerPhase.down, location: CGPoint(x: 10, y: 10))
        controller.handlePointer(SelectionPointerPhase.dragged, location: CGPoint(x: 20, y: 12))
        #expect(popover.currentContent == nil)
        try await Task.sleep(for: .milliseconds(300))
        #expect(popover.currentContent == nil)
        #expect(!popover.shown.contains(where: { $0.status == .translated }))
    }

    @Test
    func dragWithEmptyAXShowsClipboardFallbackPopover() async throws {
        let reader = FakeSelectedTextReader(result: .empty)
        reader.clipboardFallbackSnapshot = snapshot("Hello from Feishu", bundle: "com.electron.lark")
        let popover = FakeSelectionPopover()
        let translator = StubSelectionTranslator()
        translator.result = "你好，飞书"
        let controller = makeController(reader: reader, popover: popover, translator: translator)
        controller.setEnabled(true)
        dragSelect(controller)
        try await waitUntil { popover.currentContent?.status == .translated }
        #expect(reader.lastAllowClipboardFallback)
        #expect(reader.clipboardFallbackUseCount == 1)
        #expect(translator.texts == ["Hello from Feishu"])
        #expect(popover.currentContent?.displayTranslation == "你好，飞书")
    }

    @Test
    func dragWithEmptyAXChineseClipboardShowsAlreadyChinese() async throws {
        let reader = FakeSelectedTextReader(result: .empty)
        reader.clipboardFallbackSnapshot = snapshot("一个女孩站在雨里", bundle: "com.electron.lark")
        let popover = FakeSelectionPopover()
        let translator = StubSelectionTranslator()
        let controller = makeController(reader: reader, popover: popover, translator: translator)
        controller.setEnabled(true)
        dragSelect(controller)
        try await waitUntil { popover.currentContent?.status == .alreadyChinese }
        #expect(reader.clipboardFallbackUseCount == 1)
        #expect(translator.texts.isEmpty)
        #expect(popover.currentContent?.displayTranslation == "已是中文")
        #expect(popover.currentContent?.showsOptimizeAction == true)
    }

    @Test
    func clickWithoutDragAndEmptyAXDoesNotUseClipboardOrShowPopover() async throws {
        let reader = FakeSelectedTextReader(result: .empty)
        reader.clipboardFallbackSnapshot = snapshot("should-not-use", bundle: "com.electron.lark")
        let popover = FakeSelectionPopover()
        let translator = StubSelectionTranslator()
        let controller = makeController(reader: reader, popover: popover, translator: translator)
        controller.setEnabled(true)
        select(controller)
        try await Task.sleep(for: .milliseconds(25))
        #expect(reader.readCount == 1)
        #expect(!reader.lastAllowClipboardFallback)
        #expect(reader.clipboardFallbackUseCount == 0)
        #expect(translator.texts.isEmpty)
        #expect(popover.currentContent == nil)
        #expect(popover.shown.isEmpty)
    }

    @Test
    func ownAppClipboardFallbackIsStillSkipped() async throws {
        let reader = FakeSelectedTextReader(result: .empty)
        reader.clipboardFallbackSnapshot = snapshot("Hello from self", bundle: "com.maodashu.global-translator")
        let popover = FakeSelectionPopover()
        let translator = StubSelectionTranslator()
        let controller = makeController(reader: reader, popover: popover, translator: translator)
        controller.setEnabled(true)
        dragSelect(controller)
        try await Task.sleep(for: .milliseconds(25))
        #expect(reader.clipboardFallbackUseCount == 1)
        #expect(translator.texts.isEmpty)
        #expect(popover.currentContent == nil)
    }

    @Test
    func optimizeButtonRewritesChineseDraftWithoutTranslating() async throws {
        let reader = FakeSelectedTextReader(result: .snapshot(snapshot("一个女孩站在雨里")))
        let popover = FakeSelectionPopover()
        let translator = StubSelectionTranslator()
        translator.optimizeResult = "主体：一位女孩站在雨中街道，电影感布光，中景，约束：写实、无字幕。"
        let controller = makeController(reader: reader, popover: popover, translator: translator)
        controller.setEnabled(true)
        select(controller)
        try await waitUntil { popover.currentContent?.status == .alreadyChinese }
        popover.simulateOptimize()
        try await waitUntil { popover.currentContent?.status == .optimized }
        #expect(translator.texts.isEmpty)
        #expect(translator.optimizedTexts == ["一个女孩站在雨里"])
        #expect(popover.currentContent?.displayTranslation == translator.optimizeResult)
        #expect(popover.currentContent?.allowsCopy == true)
        #expect(popover.currentContent?.copyText == translator.optimizeResult)
    }

    @Test
    func optimizeAfterTranslateDoesNotRecallTranslate() async throws {
        let reader = FakeSelectedTextReader(result: .snapshot(snapshot("Hello world")))
        let popover = FakeSelectionPopover()
        let translator = StubSelectionTranslator()
        translator.result = "你好，世界"
        translator.optimizeResult = "A young woman in rain, cinematic lighting, medium shot."
        let controller = makeController(reader: reader, popover: popover, translator: translator)
        controller.setEnabled(true)
        select(controller)
        try await waitUntil { popover.currentContent?.status == .translated }
        popover.simulateOptimize()
        try await waitUntil { popover.currentContent?.status == .optimized }
        #expect(translator.texts == ["Hello world"])
        #expect(translator.optimizedTexts == ["Hello world"])
        #expect(popover.currentContent?.displayTranslation == translator.optimizeResult)
        popover.simulateTranslate()
        try await waitUntil { popover.currentContent?.status == .translated }
        #expect(translator.texts == ["Hello world", "Hello world"])
        #expect(translator.optimizedTexts == ["Hello world"])
        #expect(popover.currentContent?.displayTranslation == "你好，世界")
    }

    @Test
    func delayedTranslateDoesNotOverwriteOptimize() async throws {
        let reader = FakeSelectedTextReader(result: .snapshot(snapshot("Hello world")))
        let popover = FakeSelectionPopover()
        let translator = StubSelectionTranslator()
        translator.delay = .milliseconds(250)
        translator.result = "你好，世界"
        translator.optimizeResult = "cinematic rain portrait, medium shot"
        let controller = makeController(reader: reader, popover: popover, translator: translator)
        controller.setEnabled(true)
        select(controller)
        try await waitUntil { popover.currentContent?.status == .loading }
        popover.simulateOptimize()
        try await waitUntil { popover.currentContent?.status == .optimized }
        try await Task.sleep(for: .milliseconds(300))
        #expect(popover.currentContent?.status == .optimized)
        #expect(popover.currentContent?.displayTranslation == translator.optimizeResult)
        #expect(!popover.shown.suffix(2).contains(where: { $0.status == .translated }))
    }

    @Test
    func translateDuringChineseOptimizeKeepsAlreadyChineseAndDropsLateOptimize() async throws {
        let reader = FakeSelectedTextReader(result: .snapshot(snapshot("一个女孩站在雨里")))
        let popover = FakeSelectionPopover()
        let translator = StubSelectionTranslator()
        translator.delay = .milliseconds(250)
        translator.optimizeResult = "主体：一位女孩站在雨中街道，电影感布光。"
        let controller = makeController(reader: reader, popover: popover, translator: translator)
        controller.setEnabled(true)
        select(controller)
        try await waitUntil { popover.currentContent?.status == .alreadyChinese }
        popover.simulateOptimize()
        try await waitUntil { popover.currentContent?.status == .optimizing }
        popover.simulateTranslate()
        #expect(popover.currentContent?.status == .alreadyChinese)
        #expect(popover.currentContent?.displayTranslation == "已是中文")
        try await Task.sleep(for: .milliseconds(300))
        #expect(popover.currentContent?.status == .alreadyChinese)
        #expect(popover.currentContent?.displayTranslation == "已是中文")
        #expect(!popover.shown.contains(where: { $0.status == .optimized }))
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
        #expect(try await session.optimizePrompt("一个女孩站在雨里") == "优化 一个女孩站在雨里")
        await controller.stop()
    }
}
