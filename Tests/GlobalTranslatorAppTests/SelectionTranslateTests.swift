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
        frontmostBundleIdentifier: @escaping () -> String = { "com.apple.TextEdit" }
    ) -> SelectionTranslateController {
        SelectionTranslateController(
            reader: reader,
            popover: popover,
            monitor: NullSelectionPointerMonitor(),
            permissions: permission,
            logger: RecordingLogger(),
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
        try await waitUntil { popover.currentContent?.status == .alreadyChinese }
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

    @Test
    func backendSwitchForwardsAndMissingKeyBlocksTranslateAndOptimize() async throws {
        let reader = FakeSelectedTextReader(result: .snapshot(snapshot("Hello world")))
        let popover = FakeSelectionPopover()
        let translator = StubSelectionTranslator()
        translator.result = "你好，世界"
        translator.optimizeResult = "得体的英文"
        var cloudKey = true
        var switched: [BackendKind] = []
        let controller = makeController(
            reader: reader,
            popover: popover,
            translator: translator,
            isCloudKeyConfigured: { cloudKey }
        )
        controller.onBackendChange = { switched.append($0) }
        controller.setBackend(.local)
        controller.setEnabled(true)
        select(controller)
        try await waitUntil { popover.currentContent?.status == .translated }
        #expect(popover.backend == .local)
        #expect(translator.texts == ["Hello world"])

        cloudKey = false
        popover.simulateBackend(.deepSeekCloud)
        #expect(switched == [.deepSeekCloud])
        #expect(popover.backend == .deepSeekCloud)
        #expect(popover.currentContent?.status == .failed)
        #expect(popover.currentContent?.displayTranslation == SelectionTranslateSupport.missingDeepSeekKeyCopy)
        #expect(translator.texts == ["Hello world"])
        #expect(translator.optimizedTexts.isEmpty)

        popover.simulateTranslate()
        #expect(popover.currentContent?.displayTranslation == SelectionTranslateSupport.missingDeepSeekKeyCopy)
        #expect(translator.texts == ["Hello world"])

        popover.simulateOptimize()
        #expect(popover.currentContent?.displayTranslation == SelectionTranslateSupport.missingDeepSeekKeyCopy)
        #expect(translator.optimizedTexts.isEmpty)

        cloudKey = true
        popover.simulateBackend(.local)
        try await waitUntil { popover.currentContent?.status == .translated }
        #expect(switched == [.deepSeekCloud, .local])
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
        #expect(
            try await session.translateSelection("Swift 6 + SwiftUI + ScreenCaptureKit")
                == "你好 Swift 6 + SwiftUI + ScreenCaptureKit"
        )
        #expect(try await session.optimizePrompt("一个女孩站在雨里") == "优化 一个女孩站在雨里")
        #expect(try await session.optimizePrompt("Swift 6 + SwiftUI + ScreenCaptureKit") == "优化 Swift 6 + SwiftUI + ScreenCaptureKit")
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
    func selectionPopupBackendSwitchPersistsAndSyncsSettings() async throws {
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
        #expect(popover.backend == .local)

        popover.simulateBackend(.deepSeekCloud)
        try await controller.persistence.flush()
        #expect(controller.configuration.backend == .deepSeekCloud)
        #expect(controller.viewModel.selectedBackend == .deepSeekCloud)
        #expect(popover.backend == .deepSeekCloud)
        #expect(await store.saved.last?.backend == .deepSeekCloud)

        controller.selectBackend(.local)
        try await controller.persistence.flush()
        #expect(controller.configuration.backend == .local)
        #expect(controller.viewModel.selectedBackend == .local)
        #expect(popover.backend == .local)
        #expect(await store.saved.last?.backend == .local)
        await controller.stop()
    }

    @Test
    func selectionPopupSwitchToDeepSeekWithoutKeyShowsSettingsTip() async throws {
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

        popover.simulateBackend(.deepSeekCloud)
        try await controller.persistence.flush()
        #expect(controller.configuration.backend == .deepSeekCloud)
        #expect(controller.viewModel.selectedBackend == .deepSeekCloud)
        #expect(controller.viewModel.keyConfigured == false)
        #expect(popover.currentContent?.displayTranslation == SelectionTranslateSupport.missingDeepSeekKeyCopy)
        #expect(popover.currentContent?.status == .failed)
        await controller.stop()
    }

    @Test
    func selectionTranslateAndOptimizeFollowPopupBackend() async throws {
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
        #expect(try await session.translateSelection("Hello there") == "你好 Hello there")
        #expect(await coordinator.translateBackends == [.local])
        _ = try await session.optimizePrompt("把这段写清楚")
        #expect(await coordinator.completePlainBackends == [.local])

        popover.simulateBackend(.deepSeekCloud)
        #expect(controller.configuration.backend == .deepSeekCloud)
        #expect(controller.viewModel.selectedBackend == .deepSeekCloud)
        #expect(popover.backend == .deepSeekCloud)
        let switched = try #require(controller.session)
        #expect(try await switched.translateSelection("Hello there") == "你好 Hello there")
        #expect(try await switched.optimizePrompt("把这段写清楚") == "rewritten")
        #expect(await coordinator.translateBackends == [.local, .deepSeekCloud])
        #expect(await coordinator.completePlainBackends == [.local, .deepSeekCloud])
        await controller.stop()
    }
}
