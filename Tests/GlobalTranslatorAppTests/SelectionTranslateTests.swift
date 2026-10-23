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
        permission: FakePermissionController = FakePermissionController(snapshot: .allGranted),
        isCloudKeyConfigured: @escaping () -> Bool = { true },
        frontmostBundleIdentifier: @escaping () -> String = { "com.apple.TextEdit" },
        logger: RecordingLogger = RecordingLogger()
    ) -> SelectionTranslateController {
        SelectionTranslateController(
            reader: reader,
            popover: popover,
            monitor: NullSelectionPointerMonitor(),
            permissions: permission,
            logger: logger,
            translator: { translator },
            isCloudKeyConfigured: isCloudKeyConfigured,
            ownBundleIdentifiers: ["com.maodashu.global-translator"],
            frontmostBundleIdentifier: frontmostBundleIdentifier,
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
    func pointerOnSceneMenuDoesNotDismissPopover() async throws {
        let reader = FakeSelectedTextReader(result: .snapshot(snapshot("Hello world")))
        let popover = FakeSelectionPopover()
        let translator = StubSelectionTranslator()
        translator.result = "你好，世界"
        let controller = makeController(reader: reader, popover: popover, translator: translator)
        controller.setEnabled(true)
        select(controller)
        try await waitUntil { popover.currentContent?.status == .translated }
        popover.extraInteractionFrames = [CGRect(x: 400, y: 400, width: 120, height: 80)]
        let dismissesBefore = popover.dismissCount
        controller.handlePointer(.down, location: CGPoint(x: 430, y: 430))
        controller.handlePointer(.up, location: CGPoint(x: 430, y: 430))
        #expect(popover.currentContent?.status == .translated)
        #expect(popover.dismissCount == dismissesBefore)
        controller.handlePointer(.down, location: CGPoint(x: 10, y: 10))
        #expect(popover.currentContent == nil)
        #expect(popover.dismissCount == dismissesBefore + 1)
    }

    @Test
    func sceneMenuReleaseAfterMenuClosesDoesNotResettleSelection() async throws {
        let reader = FakeSelectedTextReader(result: .snapshot(snapshot("Hello world")))
        let popover = FakeSelectionPopover()
        let translator = StubSelectionTranslator()
        translator.result = "你好，世界"
        let controller = makeController(reader: reader, popover: popover, translator: translator)
        controller.setEnabled(true)
        dragSelect(controller)
        try await waitUntil { popover.currentContent?.status == .translated }
        let readsBefore = reader.readCount
        let clipboardBefore = reader.clipboardFallbackUseCount
        let dismissesBefore = popover.dismissCount

        popover.extraInteractionFrames = [CGRect(x: 400, y: 400, width: 120, height: 80)]
        controller.handlePointer(.down, location: CGPoint(x: 430, y: 430))
        popover.extraInteractionFrames = []
        controller.handlePointer(.up, location: CGPoint(x: 430, y: 430))

        try await Task.sleep(for: .milliseconds(40))
        #expect(popover.currentContent?.status == .translated)
        #expect(popover.currentContent?.displayTranslation == "你好，世界")
        #expect(popover.dismissCount == dismissesBefore)
        #expect(reader.readCount == readsBefore)
        #expect(reader.clipboardFallbackUseCount == clipboardBefore)
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
    func simplifiedChineseSelectionTranslatesToEnglish() async throws {
        // 双向互译：简体中文选区直接翻译成英文，仍可「优化提示词」。
        let reader = FakeSelectedTextReader(result: .snapshot(snapshot("你好世界")))
        let popover = FakeSelectionPopover()
        let translator = StubSelectionTranslator()
        translator.result = "Hello world"
        let controller = makeController(reader: reader, popover: popover, translator: translator)
        controller.setEnabled(true)
        select(controller)
        try await waitUntil { popover.currentContent?.status == .translated }
        #expect(translator.texts == ["你好世界"])
        #expect(popover.currentContent?.displayTranslation == "Hello world")
        #expect(popover.currentContent?.showsOptimizeAction == true)
        #expect(popover.currentContent?.allowsCopy == true)
    }

    @Test
    func technicalTokenPhraseShowsSoftCopyWithoutCallingBackend() async throws {
        let phrase = "Swift 6 + SwiftUI + ScreenCaptureKit"
        let reader = FakeSelectedTextReader(result: .snapshot(snapshot(phrase)))
        let popover = FakeSelectionPopover()
        let translator = StubSelectionTranslator()
        translator.error = TranslationError.invalidResponse("translation copied the source")
        let controller = makeController(reader: reader, popover: popover, translator: translator)
        controller.setEnabled(true)
        select(controller)
        try await waitUntil { popover.currentContent?.status == .noTranslationNeeded }
        #expect(translator.texts.isEmpty)
        #expect(popover.currentContent?.displayTranslation == "专有名词，无需翻译")
        #expect(popover.currentContent?.displayTranslation != "服务返回异常，请稍后重试")
        #expect(popover.currentContent?.showsOptimizeAction == true)
        #expect(popover.currentContent?.status != .failed)
        try await Task.sleep(for: .milliseconds(40))
        #expect(popover.currentContent?.status == .noTranslationNeeded)
        popover.simulateTranslate()
        try await waitUntil { popover.currentContent?.status == .failed }
        #expect(translator.texts == [phrase])
        #expect(popover.currentContent?.displayTranslation == "翻译失败")
        #expect(popover.currentContent?.displayTranslation != "服务返回异常，请稍后重试")
        #expect(popover.currentContent?.showsOptimizeAction == true)
    }

    @Test
    func copiedSourceTranslationErrorShowsSoftFailureNotServiceException() async throws {
        let reader = FakeSelectedTextReader(result: .snapshot(snapshot("Hello world")))
        let popover = FakeSelectionPopover()
        let translator = StubSelectionTranslator()
        translator.error = TranslationError.invalidResponse("translation copied the source")
        let controller = makeController(reader: reader, popover: popover, translator: translator)
        controller.setEnabled(true)
        select(controller)
        try await waitUntil { popover.currentContent?.status == .failed }
        #expect(translator.texts == ["Hello world"])
        #expect(popover.currentContent?.displayTranslation == "翻译失败")
        #expect(popover.currentContent?.displayTranslation != "服务返回异常，请稍后重试")
        #expect(popover.currentContent?.showsOptimizeAction == true)
    }

    @Test
    func emptySelectionTranslateResultShowsSoftFailure() async throws {
        let reader = FakeSelectedTextReader(result: .snapshot(snapshot("Hello world")))
        let popover = FakeSelectionPopover()
        let translator = StubSelectionTranslator()
        translator.error = SelectionTranslateError.emptyResult
        let controller = makeController(reader: reader, popover: popover, translator: translator)
        controller.setEnabled(true)
        select(controller)
        try await waitUntil { popover.currentContent?.status == .failed }
        #expect(popover.currentContent?.displayTranslation == "翻译失败")
        #expect(popover.currentContent?.displayTranslation != "服务返回异常，请稍后重试")
        #expect(popover.currentContent?.showsOptimizeAction == true)
    }

    @Test
    func clipboardFallbackTechnicalPhraseStillShowsSoftCopy() async throws {
        let phrase = "Swift 6 + SwiftUI + ScreenCaptureKit"
        let reader = FakeSelectedTextReader(result: .empty)
        reader.clipboardFallbackSnapshot = snapshot(phrase, bundle: "com.electron.lark")
        let popover = FakeSelectionPopover()
        let translator = StubSelectionTranslator()
        let controller = makeController(reader: reader, popover: popover, translator: translator)
        controller.setEnabled(true)
        dragSelect(controller)
        try await waitUntil { popover.currentContent?.status == .noTranslationNeeded }
        #expect(reader.clipboardFallbackUseCount == 1)
        #expect(translator.texts.isEmpty)
        #expect(popover.currentContent?.displayTranslation == "专有名词，无需翻译")
        #expect(popover.currentContent?.displayTranslation != "服务返回异常，请稍后重试")
        #expect(popover.currentContent?.showsOptimizeAction == true)
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
        try await waitUntil({
            popover.currentContent?.status == .translated
                && popover.currentContent?.displayTranslation == "另一句"
        }, timeout: 2)
        #expect(popover.currentContent?.original == "Another sentence")

        popover.simulateUserDismiss()
        reader.setResult(.empty)
        select(controller)
        try await Task.sleep(for: .milliseconds(25))
        reader.setResult(.snapshot(snapshot("Another sentence")))
        select(controller)
        try await waitUntil({
            popover.currentContent?.status == .translated
                && popover.currentContent?.displayTranslation == "另一句"
        }, timeout: 2)
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
    func dragWithEmptyAXChineseClipboardTranslatesToEnglish() async throws {
        // 双向互译：飞书等 Electron App 里拖选中文经剪贴板兜底，同样译成英文。
        let reader = FakeSelectedTextReader(result: .empty)
        reader.clipboardFallbackSnapshot = snapshot("一个女孩站在雨里", bundle: "com.electron.lark")
        let popover = FakeSelectionPopover()
        let translator = StubSelectionTranslator()
        translator.result = "A girl standing in the rain"
        let controller = makeController(reader: reader, popover: popover, translator: translator)
        controller.setEnabled(true)
        dragSelect(controller)
        try await waitUntil { popover.currentContent?.status == .translated }
        #expect(reader.clipboardFallbackUseCount == 1)
        #expect(translator.texts == ["一个女孩站在雨里"])
        #expect(popover.currentContent?.displayTranslation == "A girl standing in the rain")
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
        // Click-without-drag may still AX-poll (TextEdit / dismiss); it must not
        // steal the clipboard or show a popover. Wait for settle so this is not a 25ms race.
        try await waitUntil { reader.readCount >= 1 }
        #expect(reader.clipboardFallbackUseCount == 0)
        #expect(!reader.lastAllowClipboardFallback)
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
        let controller = makeController(
            reader: reader,
            popover: popover,
            translator: translator,
            frontmostBundleIdentifier: { "com.maodashu.global-translator" }
        )
        controller.setEnabled(true)
        dragSelect(controller)
        try await waitUntil { reader.readCount >= 1 }
        #expect(reader.clipboardFallbackUseCount == 0)
        #expect(!reader.lastAllowClipboardFallback)
        #expect(translator.texts.isEmpty)
        #expect(popover.currentContent == nil)
        #expect(popover.shown.isEmpty)
    }

    @Test
    func optimizeButtonRewritesChineseDraftAfterTranslation() async throws {
        // 中文草稿先被译成英文，「优化提示词」仍作用于中文原文。
        let reader = FakeSelectedTextReader(result: .snapshot(snapshot("一个女孩站在雨里")))
        let popover = FakeSelectionPopover()
        let translator = StubSelectionTranslator()
        translator.result = "A girl standing in the rain"
        translator.optimizeResult = "主体：一位女孩站在雨中街道，电影感布光，中景，约束：写实、无字幕。"
        let controller = makeController(reader: reader, popover: popover, translator: translator)
        controller.setEnabled(true)
        select(controller)
        try await waitUntil { popover.currentContent?.status == .translated }
        #expect(translator.texts == ["一个女孩站在雨里"])
        popover.simulateOptimize()
        try await waitUntil { popover.currentContent?.status == .optimized }
        #expect(translator.optimizedTexts == ["一个女孩站在雨里"])
        #expect(translator.optimizedModes == [.communicationPolish])
        #expect(popover.currentContent?.displayTranslation == translator.optimizeResult)
        #expect(popover.currentContent?.allowsCopy == true)
        #expect(popover.currentContent?.copyText == translator.optimizeResult)
    }

    @Test
    func optimizeUsesSelectedSceneMode() async throws {
        let reader = FakeSelectedTextReader(result: .snapshot(snapshot("这段代码写得不清楚")))
        let popover = FakeSelectionPopover()
        let translator = StubSelectionTranslator()
        translator.optimizeResult = "这段实现把错误路径写清楚了。"
        let controller = makeController(reader: reader, popover: popover, translator: translator)
        controller.setEnabled(true)
        controller.setOptimizeMode(.taskInstruction)
        select(controller)
        try await waitUntil { popover.currentContent?.status == .translated }
        popover.simulateOptimize()
        try await waitUntil { popover.currentContent?.status == .optimized }
        #expect(translator.optimizedModes == [.taskInstruction])
        popover.simulateOptimizeMode(.communicationPolish)
        popover.simulateOptimize()
        try await waitUntil { translator.optimizedModes.count == 2 }
        #expect(translator.optimizedModes == [.taskInstruction, .communicationPolish])
        #expect(popover.optimizeMode == .communicationPolish)
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
    func delayedTranslateDoesNotOverwriteChineseOptimize() async throws {
        // 中文选区自动译成英文；翻译在途时点了「优化提示词」，晚到的译文不得覆盖优化结果。
        let reader = FakeSelectedTextReader(result: .snapshot(snapshot("一个女孩站在雨里")))
        let popover = FakeSelectionPopover()
        let translator = StubSelectionTranslator()
        translator.delay = .milliseconds(250)
        translator.result = "A girl standing in the rain"
        translator.optimizeResult = "主体：一位女孩站在雨中街道，电影感布光。"
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
    func settingsBackendWithoutKeyBlocksTranslateAndOptimize() async throws {
        let reader = FakeSelectedTextReader(result: .snapshot(snapshot("Hello world")))
        let popover = FakeSelectionPopover()
        let translator = StubSelectionTranslator()
        translator.result = "你好，世界"
        translator.optimizeResult = "得体的英文"
        var cloudKey = true
        let controller = makeController(
            reader: reader,
            popover: popover,
            translator: translator,
            isCloudKeyConfigured: { cloudKey }
        )
        controller.setBackend(.local)
        controller.setEnabled(true)
        select(controller)
        try await waitUntil { popover.currentContent?.status == .translated }
        #expect(translator.texts == ["Hello world"])

        cloudKey = false
        controller.setBackend(.deepSeekCloud)
        popover.simulateTranslate()
        #expect(popover.currentContent?.status == .failed)
        #expect(popover.currentContent?.displayTranslation == SelectionTranslateSupport.missingDeepSeekKeyCopy)
        #expect(translator.texts == ["Hello world"])

        popover.simulateOptimize()
        #expect(popover.currentContent?.displayTranslation == SelectionTranslateSupport.missingDeepSeekKeyCopy)
        #expect(translator.optimizedTexts.isEmpty)

        cloudKey = true
        controller.setBackend(.local)
        popover.simulateTranslate()
        try await waitUntil { popover.currentContent?.status == .translated }
        #expect(translator.texts == ["Hello world", "Hello world"])
    }

    @Test
    func missingCredentialErrorShowsSettingsTip() async throws {
        let reader = FakeSelectedTextReader(result: .snapshot(snapshot("Hello world")))
        let popover = FakeSelectionPopover()
        let translator = StubSelectionTranslator()
        translator.error = TranslationError.missingCredential
        let controller = makeController(reader: reader, popover: popover, translator: translator)
        controller.setEnabled(true)
        select(controller)
        try await waitUntil { popover.currentContent?.status == .failed }
        #expect(popover.currentContent?.displayTranslation == SelectionTranslateSupport.missingDeepSeekKeyCopy)
        #expect(popover.currentContent?.displayTranslation != "翻译失败")
    }

    @Test
    func deepSeekWithoutKeyShowsTipOnSettleWithoutCallingBackend() async throws {
        let reader = FakeSelectedTextReader(result: .snapshot(snapshot("Hello world")))
        let popover = FakeSelectionPopover()
        let translator = StubSelectionTranslator()
        let controller = makeController(
            reader: reader,
            popover: popover,
            translator: translator,
            isCloudKeyConfigured: { false }
        )
        controller.setBackend(.deepSeekCloud)
        controller.setEnabled(true)
        select(controller)
        try await waitUntil { popover.currentContent?.status == .failed }
        #expect(translator.texts.isEmpty)
        #expect(translator.optimizedTexts.isEmpty)
        #expect(popover.currentContent?.displayTranslation == SelectionTranslateSupport.missingDeepSeekKeyCopy)
    }

    @Test
    func truncatedOutcomeSurfacesChineseNoteWithoutBlockingCopy() async throws {
        let reader = FakeSelectedTextReader(result: .snapshot(snapshot("Hello world")))
        let popover = FakeSelectionPopover()
        let translator = StubSelectionTranslator()
        translator.result = "部分译文"
        translator.sourceWasTruncated = true
        let controller = makeController(reader: reader, popover: popover, translator: translator)
        controller.setEnabled(true)
        select(controller)
        try await waitUntil { popover.currentContent?.status == .translated }
        #expect(popover.currentContent?.sourceWasTruncated == true)
        #expect(popover.currentContent?.displayTranslation.contains("部分译文") == true)
        #expect(popover.currentContent?.displayTranslation.contains(SelectionTranslateSupport.truncatedSourceCopy) == true)
        #expect(popover.currentContent?.copyText == "部分译文")
        #expect(popover.currentContent?.allowsCopy == true)
        #expect(popover.currentContent?.status != .failed)
    }

    @Test
    func slowWindowDragDoesNotSurfaceUnavailableStatus() async throws {
        let reader = FakeSelectedTextReader(result: .unavailable)
        let popover = FakeSelectionPopover()
        let translator = StubSelectionTranslator()
        var clock: TimeInterval = 0
        let controller = makeClockController(
            reader: reader,
            popover: popover,
            translator: translator,
            clock: { clock }
        )
        controller.setEnabled(true)
        controller.handlePointer(.down, location: CGPoint(x: 10, y: 10))
        clock = 0.3
        controller.handlePointer(.dragged, location: CGPoint(x: 90, y: 10))
        clock = 4.0
        controller.handlePointer(.up, location: CGPoint(x: 90, y: 10))
        try await waitUntil { reader.readCount >= 1 }
        #expect(popover.shown.isEmpty)
        #expect(!reader.lastAllowClipboardFallback)
    }

    @Test
    func repeatedUnreadableDragsStopSurfacingAfterThreeFailures() async throws {
        let reader = FakeSelectedTextReader(result: .unavailable)
        let popover = FakeSelectionPopover()
        let translator = StubSelectionTranslator()
        let logger = RecordingLogger()
        var clock: TimeInterval = 0
        let controller = makeClockController(
            reader: reader,
            popover: popover,
            translator: translator,
            logger: logger,
            clock: { clock }
        )
        controller.setEnabled(true)
        for index in 0..<4 {
            clock = TimeInterval(index)
            dragSelect(controller)
            switch index {
            case 0, 1:
                let expected = index + 1
                try await waitUntil { popover.shown.filter { $0.status == .unavailable }.count >= expected }
            case 2:
                try await waitUntil { logger.records.contains { $0.0 == "selection_degraded" } }
            default:
                try await waitUntil { reader.readCount >= 4 }
            }
        }
        let surfaces = popover.shown.filter { $0.status == .unavailable }.count
        #expect(surfaces == SelectionReadingDegradeState.failureThreshold - 1)
    }

    @Test
    func degradedModeStopsBorrowingTheClipboard() async throws {
        let reader = FakeSelectedTextReader(result: .unavailable)
        let popover = FakeSelectionPopover()
        let translator = StubSelectionTranslator()
        let logger = RecordingLogger()
        var clock: TimeInterval = 0
        let controller = makeClockController(
            reader: reader,
            popover: popover,
            translator: translator,
            logger: logger,
            clock: { clock }
        )
        controller.setEnabled(true)
        for index in 0..<SelectionReadingDegradeState.failureThreshold {
            clock = TimeInterval(index)
            dragSelect(controller)
            if index < SelectionReadingDegradeState.failureThreshold - 1 {
                // Wait for the surfaced popover, not just the read count: the
                // reader now returns asynchronously, so a fast next drag can
                // legitimately invalidate the previous result's token.
                let expected = index + 1
                try await waitUntil { popover.shown.filter { $0.status == .unavailable }.count >= expected }
            } else {
                try await waitUntil { logger.records.contains { $0.0 == "selection_degraded" } }
            }
        }
        clock = TimeInterval(SelectionReadingDegradeState.failureThreshold)
        reader.setResult(.empty)
        reader.clipboardFallbackSnapshot = snapshot("Hello from Feishu", bundle: "com.electron.lark")
        dragSelect(controller)
        try await waitUntil { reader.readCount >= SelectionReadingDegradeState.failureThreshold + 1 }
        #expect(reader.clipboardFallbackUseCount == 0)
        #expect(!reader.lastAllowClipboardFallback)
    }

    @Test
    func clicksThatCannotReadDoNotTripDegradedMode() async throws {
        let reader = FakeSelectedTextReader(result: .unavailable)
        let popover = FakeSelectionPopover()
        let translator = StubSelectionTranslator()
        let controller = makeClockController(
            reader: reader,
            popover: popover,
            translator: translator,
            clock: { 0 }
        )
        controller.setEnabled(true)
        // Five clicks that read nothing: only drag-selections may count toward
        // the failure streak, otherwise tapping around locks the feature out.
        for index in 0..<5 {
            controller.handlePointer(.down, location: CGPoint(x: 10, y: 10))
            controller.handlePointer(.up, location: CGPoint(x: 10, y: 10))
            let expected = index + 1
            try await waitUntil { reader.readCount >= expected }
        }
        #expect(popover.shown.isEmpty)
        // Not degraded, so a real drag whose text cannot be read still surfaces.
        dragSelect(controller)
        try await waitUntil { popover.shown.contains { $0.status == .unavailable } }
    }

    @Test
    func noTranslationNeededErrorShowsSoftCopyInsteadOfFailure() async throws {
        let reader = FakeSelectedTextReader(result: .snapshot(snapshot("Figma")))
        let popover = FakeSelectionPopover()
        let translator = StubSelectionTranslator()
        translator.error = SelectionTranslateError.noTranslationNeeded
        let controller = makeController(reader: reader, popover: popover, translator: translator)
        controller.setEnabled(true)
        select(controller)
        try await waitUntil { popover.currentContent?.status == .noTranslationNeeded }
        #expect(popover.currentContent?.displayTranslation == "专有名词，无需翻译")
        #expect(popover.currentContent?.status != .failed)
        #expect(popover.currentContent?.allowsCopy == true)
        #expect(popover.currentContent?.showsOptimizeAction == true)
    }

    @Test
    func dragThatReadsNothingIsLoggedForDiagnostics() async throws {
        let reader = FakeSelectedTextReader(result: .empty)
        let popover = FakeSelectionPopover()
        let translator = StubSelectionTranslator()
        let logger = RecordingLogger()
        let controller = makeController(
            reader: reader,
            popover: popover,
            translator: translator,
            logger: logger
        )
        controller.setEnabled(true)
        dragSelect(controller)
        try await waitUntil { logger.records.contains { $0.0 == "selection_unreadable" } }
        let record = try #require(logger.records.first { $0.0 == "selection_unreadable" })
        #expect(record.1["verdict"] == "textSelection")
        #expect(record.1["clipboardAllowed"] == "true")
        #expect(popover.currentContent == nil)
        #expect(translator.texts.isEmpty)
    }

    @Test
    func skippedSelectionClearsSuppressedTextSoItCanSurfaceAgain() async throws {
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

        // A URL selection is deliberately skipped. It must clear the previous
        // suppression; otherwise selecting the original sentence again would
        // stay silently hidden forever.
        reader.setResult(.snapshot(snapshot("https://example.com/path")))
        select(controller)
        // Mouse-down dismisses the (already dismissed) popover; the settle then
        // runs the .skip branch and dismisses once more. Wait for that second
        // dismissal instead of a fixed sleep so the reader result is not swapped
        // before the URL settle actually reads it.
        let dismissesAfterSelect = popover.dismissCount
        try await waitUntil { popover.dismissCount > dismissesAfterSelect }
        #expect(popover.currentContent == nil)

        reader.setResult(.snapshot(snapshot("Hello world")))
        select(controller)
        try await waitUntil { popover.currentContent?.status == .translated }
        #expect(popover.currentContent?.original == "Hello world")
    }

    @Test
    func staleSelectionReadResultCannotPopOverANewerGesture() async throws {
        let reader = GatedSelectedTextReader()
        let popover = FakeSelectionPopover()
        let translator = StubSelectionTranslator()
        translator.result = "你好"
        let controller = SelectionTranslateController(
            reader: reader,
            popover: popover,
            monitor: NullSelectionPointerMonitor(),
            permissions: FakePermissionController(snapshot: .allGranted),
            logger: RecordingLogger(),
            translator: { translator },
            ownBundleIdentifiers: ["com.maodashu.global-translator"],
            frontmostBundleIdentifier: { "com.apple.TextEdit" },
            settleDelay: .milliseconds(5),
            unavailableDismissDelay: .milliseconds(30)
        )
        controller.setEnabled(true)
        dragSelect(controller)
        try await waitUntil { reader.readCount == 1 }
        // A newer gesture invalidates the first read's settle token while its
        // AX read is still in flight.
        dragSelect(controller)
        try await waitUntil { reader.readCount == 2 }
        reader.release(.snapshot(snapshot("First")))
        try await Task.sleep(for: .milliseconds(20))
        #expect(popover.currentContent == nil)
        reader.release(.snapshot(snapshot("Second")))
        try await waitUntil { popover.currentContent?.original == "Second" }
        #expect(popover.currentContent?.status == .translated)
    }

    private func makeClockController(
        reader: FakeSelectedTextReader,
        popover: FakeSelectionPopover,
        translator: StubSelectionTranslator,
        logger: RecordingLogger = RecordingLogger(),
        clock: @escaping () -> TimeInterval
    ) -> SelectionTranslateController {
        SelectionTranslateController(
            reader: reader,
            popover: popover,
            monitor: NullSelectionPointerMonitor(),
            permissions: FakePermissionController(snapshot: .allGranted),
            logger: logger,
            translator: { translator },
            ownBundleIdentifiers: ["com.maodashu.global-translator"],
            frontmostBundleIdentifier: { "com.apple.TextEdit" },
            settleDelay: .milliseconds(5),
            unavailableDismissDelay: .milliseconds(30),
            now: clock
        )
    }

    private func waitUntil(_ condition: @escaping () -> Bool, timeout: TimeInterval = 1) async throws {
        let deadline = Date().addingTimeInterval(timeout)
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
    func videoTranslateDefaultsOffAndTogglePersists() async throws {
        let store = RecordingConfigurationStore()
        let controller = ApplicationController(
            paths: try RuntimePaths(validatingRoot: temporaryRoot()),
            components: makeComponents(store: store)
        )
        try await controller.start()
        await waitForStartupHealthCheck(controller)
        #expect(!controller.configuration.videoTranslateEnabled)
        #expect(!controller.viewModel.isVideoTranslateEnabled)
        #expect(controller.videoASR?.snapshot().running == false)
        controller.setVideoTranslate(true)
        try await controller.persistence.flush()
        #expect(controller.configuration.videoTranslateEnabled)
        #expect(controller.viewModel.isVideoTranslateEnabled)
        #expect(await store.saved.last?.videoTranslateEnabled == true)
        #expect(controller.videoASR?.snapshot().running == false)
        #expect(controller.videoASR?.snapshot().enabled == true)
        controller.setVideoTranslate(false)
        try await controller.persistence.flush()
        #expect(!controller.configuration.videoTranslateEnabled)
        #expect(await store.saved.last?.videoTranslateEnabled == false)
        await controller.stop()
    }

    @Test
    func promptOptimizeModePersistsLikeOtherSettings() async throws {
        let store = RecordingConfigurationStore()
        let popover = FakeSelectionPopover()
        let controller = ApplicationController(
            paths: try RuntimePaths(validatingRoot: temporaryRoot()),
            components: makeComponents(store: store, selectionPopover: popover)
        )
        try await controller.start()
        await waitForStartupHealthCheck(controller)
        #expect(controller.configuration.promptOptimizeMode == .communicationPolish)
        #expect(controller.viewModel.promptOptimizeMode == .communicationPolish)
        controller.setPromptOptimizeMode(.taskInstruction)
        try await controller.persistence.flush()
        #expect(controller.configuration.promptOptimizeMode == .taskInstruction)
        #expect(controller.viewModel.promptOptimizeMode == .taskInstruction)
        #expect(await store.saved.last?.promptOptimizeMode == .taskInstruction)
        popover.simulateOptimizeMode(.wordingFix)
        try await controller.persistence.flush()
        #expect(controller.configuration.promptOptimizeMode == .wordingFix)
        #expect(controller.viewModel.promptOptimizeMode == .wordingFix)
        #expect(await store.saved.last?.promptOptimizeMode == .wordingFix)
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
        #expect(try await session.translateSelection("Hello from Chrome").text == "你好 Hello from Chrome")
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
        #expect(try await session.translateSelection("Hello there").text == "你好 Hello there")
        #expect(
            try await session.translateSelection("Swift 6 + SwiftUI + ScreenCaptureKit").text
                == "你好 Swift 6 + SwiftUI + ScreenCaptureKit"
        )
        #expect(try await session.optimizePrompt("一个女孩站在雨里") == "优化 一个女孩站在雨里")
        #expect(try await session.optimizePrompt("Swift 6 + SwiftUI + ScreenCaptureKit") == "优化 Swift 6 + SwiftUI + ScreenCaptureKit")
        await controller.stop()
    }

    @Test
    func selectionStructuredFailureFallsBackToPlainCompletion() async throws {
        let coordinator = RecoveringSelectionCoordinator()
        await coordinator.setPlainResult("Figma（设计工具）")
        let logger = RecordingLogger()
        let store = RecordingConfigurationStore(configuration: AppConfiguration(
            autoTranslateEnabled: false, backend: .local, localModel: "test"))
        let controller = ApplicationController(
            paths: try RuntimePaths(validatingRoot: temporaryRoot()),
            components: makeComponents(store: store, coordinator: coordinator, logger: logger)
        )
        try await controller.start()
        await waitForStartupHealthCheck(controller)
        let session = try #require(controller.session)
        let outcome = try await session.translateSelection("Figma")
        #expect(outcome.text == "Figma（设计工具）")
        let calls = await coordinator.plainCalls
        #expect(calls.count == 1)
        #expect(calls.first?.user == "Figma")
        #expect(calls.first?.system.contains("proper noun") == true)
        #expect(logger.records.contains { $0.0 == "selection_plain_fallback" && $0.1["status"] == "success" })
        await controller.stop()
    }

    @Test
    func selectionPlainFallbackEchoBecomesProprietaryNameNotice() async throws {
        let coordinator = RecoveringSelectionCoordinator()
        await coordinator.setPlainResult("figma")
        let store = RecordingConfigurationStore(configuration: AppConfiguration(
            autoTranslateEnabled: false, backend: .local, localModel: "test"))
        let controller = ApplicationController(
            paths: try RuntimePaths(validatingRoot: temporaryRoot()),
            components: makeComponents(store: store, coordinator: coordinator)
        )
        try await controller.start()
        await waitForStartupHealthCheck(controller)
        let session = try #require(controller.session)
        await #expect(throws: SelectionTranslateError.noTranslationNeeded) {
            _ = try await session.translateSelection("Figma")
        }
        await controller.stop()
    }

    @Test
    func selectionNetworkFailureIsNotReplayedAsPlainCompletion() async throws {
        let coordinator = RecoveringSelectionCoordinator()
        await coordinator.setStructuredError(TranslationError.networkFailure)
        let store = RecordingConfigurationStore(configuration: AppConfiguration(
            autoTranslateEnabled: false, backend: .local, localModel: "test"))
        let controller = ApplicationController(
            paths: try RuntimePaths(validatingRoot: temporaryRoot()),
            components: makeComponents(store: store, coordinator: coordinator)
        )
        try await controller.start()
        await waitForStartupHealthCheck(controller)
        let session = try #require(controller.session)
        await #expect(throws: TranslationError.networkFailure) {
            _ = try await session.translateSelection("Hello there")
        }
        #expect(await coordinator.plainCalls.isEmpty)
        await controller.stop()
    }

    @Test
    func selectionPlainFallbackSkipsChunksLongerThanItsBudget() async throws {
        let coordinator = RecoveringSelectionCoordinator()
        let logger = RecordingLogger()
        let store = RecordingConfigurationStore(configuration: AppConfiguration(
            autoTranslateEnabled: false, backend: .local, localModel: "test"))
        let controller = ApplicationController(
            paths: try RuntimePaths(validatingRoot: temporaryRoot()),
            components: makeComponents(store: store, coordinator: coordinator, logger: logger)
        )
        try await controller.start()
        await waitForStartupHealthCheck(controller)
        let session = try #require(controller.session)
        let source = String(
            repeating: "A long paragraph that is still one selection chunk. ",
            count: 20
        )
        #expect(source.count > SelectionTranslateSupport.plainFallbackMaxCharacters)
        #expect(SelectionTranslateSupport.prepareSource(source).chunks.count == 1)
        await #expect(throws: SelectionTranslateError.emptyResult) {
            _ = try await session.translateSelection(source)
        }
        #expect(await coordinator.plainCalls.isEmpty)
        #expect(logger.records.contains {
            $0.0 == "selection_plain_fallback"
                && $0.1["status"] == "skipped"
                && $0.1["reason"] == "too_long"
        })
        await controller.stop()
    }

    @Test
    func selectionPlainFallbackFailureBecomesTranslateFailure() async throws {
        let coordinator = RecoveringSelectionCoordinator()
        await coordinator.setPlainError(TranslationError.networkFailure)
        let logger = RecordingLogger()
        let store = RecordingConfigurationStore(configuration: AppConfiguration(
            autoTranslateEnabled: false, backend: .local, localModel: "test"))
        let controller = ApplicationController(
            paths: try RuntimePaths(validatingRoot: temporaryRoot()),
            components: makeComponents(store: store, coordinator: coordinator, logger: logger)
        )
        try await controller.start()
        await waitForStartupHealthCheck(controller)
        let session = try #require(controller.session)
        await #expect(throws: SelectionTranslateError.emptyResult) {
            _ = try await session.translateSelection("Figma")
        }
        #expect(logger.records.contains {
            $0.0 == "selection_plain_fallback" && $0.1["status"] == "failed"
        })
        await controller.stop()
    }

    @Test
    func selectionPlainFallbackEchoedSentenceStaysAnHonestFailure() async throws {
        let coordinator = RecoveringSelectionCoordinator()
        await coordinator.setPlainResult("Please review the pull request")
        let store = RecordingConfigurationStore(configuration: AppConfiguration(
            autoTranslateEnabled: false, backend: .local, localModel: "test"))
        let controller = ApplicationController(
            paths: try RuntimePaths(validatingRoot: temporaryRoot()),
            components: makeComponents(store: store, coordinator: coordinator)
        )
        try await controller.start()
        await waitForStartupHealthCheck(controller)
        let session = try #require(controller.session)
        await #expect(throws: SelectionTranslateError.emptyResult) {
            _ = try await session.translateSelection("Please review the pull request")
        }
        await controller.stop()
    }

    @Test
    func echoedTrailingBrandChunkDoesNotSoftSkipTheWholeSelection() async throws {
        let coordinator = EchoingTrailingChunkCoordinator()
        let store = RecordingConfigurationStore(configuration: AppConfiguration(
            autoTranslateEnabled: false, backend: .local, localModel: "test"))
        let controller = ApplicationController(
            paths: try RuntimePaths(validatingRoot: temporaryRoot()),
            components: makeComponents(store: store, coordinator: coordinator)
        )
        try await controller.start()
        await waitForStartupHealthCheck(controller)
        let session = try #require(controller.session)
        let source = Self.longEnglish(characters: 1_800) + "\n\nFigma"
        #expect(SelectionTranslateSupport.prepareSource(source).chunks.count > 1)
        await #expect(throws: SelectionTranslateError.emptyResult) {
            _ = try await session.translateSelection(source)
        }
        await controller.stop()
    }

    @Test
    func optimizePromptSendsDistinctInstructionsPerMode() async throws {
        let coordinator = RecordingPlainCoordinator()
        let store = RecordingConfigurationStore(configuration: AppConfiguration(
            autoTranslateEnabled: false, backend: .local, localModel: "test"))
        let controller = ApplicationController(
            paths: try RuntimePaths(validatingRoot: temporaryRoot()),
            components: makeComponents(store: store, coordinator: coordinator)
        )
        try await controller.start()
        await waitForStartupHealthCheck(controller)
        let session = try #require(controller.session)
        _ = try await session.optimizePrompt("把这段写清楚", mode: .taskInstruction)
        _ = try await session.optimizePrompt("把这段写清楚", mode: .communicationPolish)
        let systems = await coordinator.systems
        let users = await coordinator.users
        #expect(systems.count == 2)
        #expect(systems[0].contains("structured task brief"))
        #expect(systems[1].contains("workplace or social communication"))
        #expect(systems[0] != systems[1])
        #expect(users[0].contains("structured task brief"))
        #expect(users[1].contains("workplace or social communication"))
        #expect(systems.allSatisfy { $0.contains("untrusted data") })
        #expect(systems.allSatisfy { $0.contains("Do not turn the text into a generative image prompt") })
        await controller.stop()
    }

    @Test
    func settingsBackendSwitchPersistsAndSelectionUsesIt() async throws {
        let store = RecordingConfigurationStore(configuration: AppConfiguration(
            backend: .local, localModel: "test", deepSeekAPIKeyConfigured: true))
        let popover = FakeSelectionPopover()
        let controller = ApplicationController(
            paths: try RuntimePaths(validatingRoot: temporaryRoot()),
            components: makeComponents(store: store, selectionPopover: popover)
        )
        try await controller.start()
        await waitForStartupHealthCheck(controller)
        #expect(controller.configuration.backend == .local)
        #expect(controller.viewModel.selectedBackend == .local)

        controller.selectBackend(.deepSeekCloud)
        try await controller.persistence.flush()
        #expect(controller.configuration.backend == .deepSeekCloud)
        #expect(controller.viewModel.selectedBackend == .deepSeekCloud)
        #expect(await store.saved.last?.backend == .deepSeekCloud)

        controller.selectBackend(.local)
        try await controller.persistence.flush()
        #expect(controller.configuration.backend == .local)
        #expect(controller.viewModel.selectedBackend == .local)
        #expect(await store.saved.last?.backend == .local)
        await controller.stop()
    }

    @Test
    func settingsSwitchToDeepSeekWithoutKeyBlocksSelectionTranslate() async throws {
        let store = RecordingConfigurationStore(configuration: AppConfiguration(
            backend: .local, localModel: "test", deepSeekAPIKeyConfigured: false))
        let reader = FakeSelectedTextReader(result: .snapshot(SelectedTextSnapshot(
            text: "Hello world",
            screenFrame: CGRect(x: 40, y: 80, width: 60, height: 14),
            source: .accessibility,
            bundleIdentifier: "com.apple.TextEdit"
        )))
        let popover = FakeSelectionPopover()
        let controller = ApplicationController(
            paths: try RuntimePaths(validatingRoot: temporaryRoot()),
            components: makeComponents(
                store: store,
                coordinator: TranslatingCoordinator(),
                selectedTextReader: reader,
                selectionPopover: popover
            )
        )
        try await controller.start()
        await waitForStartupHealthCheck(controller)
        let selection = try #require(controller.selectionTranslate)
        selection.handlePointer(.down, location: CGPoint(x: 50, y: 90))
        selection.handlePointer(.up, location: CGPoint(x: 50, y: 90))
        let translatedDeadline = Date().addingTimeInterval(1)
        while popover.currentContent?.status != .translated, Date() < translatedDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(popover.currentContent?.status == .translated)

        controller.selectBackend(.deepSeekCloud)
        try await controller.persistence.flush()
        #expect(controller.configuration.backend == .deepSeekCloud)
        #expect(controller.viewModel.selectedBackend == .deepSeekCloud)
        #expect(controller.viewModel.keyConfigured == false)
        popover.simulateTranslate()
        #expect(popover.currentContent?.displayTranslation == SelectionTranslateSupport.missingDeepSeekKeyCopy)
        #expect(popover.currentContent?.status == .failed)
        await controller.stop()
    }

    @Test
    func selectionTranslateAndOptimizeFollowSettingsBackend() async throws {
        let coordinator = RecordingPlainCoordinator()
        let store = RecordingConfigurationStore(configuration: AppConfiguration(
            autoTranslateEnabled: false, backend: .local, localModel: "test",
            deepSeekAPIKeyConfigured: true))
        let popover = FakeSelectionPopover()
        let controller = ApplicationController(
            paths: try RuntimePaths(validatingRoot: temporaryRoot()),
            components: makeComponents(
                store: store,
                coordinator: coordinator,
                selectionPopover: popover
            )
        )
        try await controller.start()
        await waitForStartupHealthCheck(controller)
        let session = try #require(controller.session)
        #expect(try await session.translateSelection("Hello there").text == "你好 Hello there")
        #expect(await coordinator.translateBackends == [.local])
        _ = try await session.optimizePrompt("把这段写清楚")
        #expect(await coordinator.completePlainBackends == [.local])

        controller.selectBackend(.deepSeekCloud)
        #expect(controller.configuration.backend == .deepSeekCloud)
        #expect(controller.viewModel.selectedBackend == .deepSeekCloud)
        let switched = try #require(controller.session)
        #expect(try await switched.translateSelection("Hello there").text == "你好 Hello there")
        #expect(try await switched.optimizePrompt("把这段写清楚") == "rewritten")
        #expect(await coordinator.translateBackends == [.local, .deepSeekCloud])
        #expect(await coordinator.completePlainBackends == [.local, .deepSeekCloud])
        await controller.stop()
    }

    @Test
    func longSelectionIsChunkedTranslatedAndJoinedInOrder() async throws {
        let coordinator = RecordingPlainCoordinator()
        let store = RecordingConfigurationStore(configuration: AppConfiguration(
            autoTranslateEnabled: false, backend: .local, localModel: "test"))
        let controller = ApplicationController(
            paths: try RuntimePaths(validatingRoot: temporaryRoot()),
            components: makeComponents(store: store, coordinator: coordinator)
        )
        try await controller.start()
        await waitForStartupHealthCheck(controller)
        let session = try #require(controller.session)
        let source = Self.longEnglish(characters: 4_500)
        let plan = SelectionTranslateSupport.prepareSource(source)
        #expect(plan.chunks.count >= 3)
        let outcome = try await session.translateSelection(source)
        #expect(!outcome.sourceWasTruncated)
        let expected = SelectionTranslateSupport.joinTranslatedChunks(
            plan.chunks.map { "你好 " + $0 }
        )
        #expect(outcome.text == expected)
        #expect(await coordinator.sources.count == plan.chunks.count)
        #expect(await coordinator.sources.allSatisfy { $0.count == 1 })
        #expect(await coordinator.sources.map { $0[0] } == plan.chunks)
        #expect(await coordinator.translateBackends.allSatisfy { $0 == .local })
        await controller.stop()
    }

    @Test
    func selectionOverHardCapJoinsChunksAndFlagsTruncation() async throws {
        let coordinator = RecordingPlainCoordinator()
        let store = RecordingConfigurationStore(configuration: AppConfiguration(
            autoTranslateEnabled: false, backend: .local, localModel: "test"))
        let controller = ApplicationController(
            paths: try RuntimePaths(validatingRoot: temporaryRoot()),
            components: makeComponents(store: store, coordinator: coordinator)
        )
        try await controller.start()
        await waitForStartupHealthCheck(controller)
        let session = try #require(controller.session)
        let source = Self.longEnglish(characters: SelectionTranslateSupport.selectionHardLimitCharacters + 800)
        let outcome = try await session.translateSelection(source)
        #expect(outcome.sourceWasTruncated)
        #expect(!outcome.text.contains(SelectionTranslateSupport.truncatedSourceCopy))
        #expect(outcome.text.hasPrefix("你好 "))
        #expect(await coordinator.sources.count == SelectionTranslateSupport.prepareSource(source).chunks.count)
        await controller.stop()
    }

    @Test
    func laterSelectionStillWorksAfterChunkedSelectionOnLiveCoordinator() async throws {
        let coordinator = TranslationCoordinator(
            backends: [StubBackend(kind: .local)],
            permissions: FakePermissionController(snapshot: .allGranted)
        )
        let store = RecordingConfigurationStore(configuration: AppConfiguration(
            autoTranslateEnabled: false, backend: .local, localModel: "test"))
        let controller = ApplicationController(
            paths: try RuntimePaths(validatingRoot: temporaryRoot()),
            components: makeComponents(store: store, coordinator: coordinator)
        )
        try await controller.start()
        await waitForStartupHealthCheck(controller)
        let session = try #require(controller.session)
        let long = Self.longEnglish(characters: 4_500)
        #expect(SelectionTranslateSupport.prepareSource(long).chunks.count >= 3)
        let first = try await session.translateSelection(long)
        #expect(!first.text.isEmpty)
        let second = try await session.translateSelection("Hello there")
        #expect(second.text == "ok")
        #expect(!second.sourceWasTruncated)
        await controller.stop()
    }

    private static func longEnglish(characters: Int) -> String {
        let unit = "A cinematic wide shot of a girl standing in the rain on a city street at night. "
        var text = ""
        while text.count < characters {
            text += unit
        }
        return String(text.prefix(characters))
    }
}
