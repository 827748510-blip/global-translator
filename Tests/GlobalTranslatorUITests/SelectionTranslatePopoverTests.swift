import Foundation
import AppKit
import Testing
@testable import GlobalTranslatorUI
import GlobalTranslatorCore

@MainActor
struct SelectionTranslatePopoverTests {
    @Test
    func panelAcceptsClicksAndIsNonactivating() {
        let panel = SelectionTranslatePanel(contentRect: CGRect(x: 0, y: 0, width: 280, height: 80))
        #expect(!panel.ignoresMouseEvents)
        #expect(panel.styleMask.contains(.borderless))
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
        #expect(panel.hasShadow)
        #expect(panel.level == .floating)
    }

    @Test
    func showWiresContentThenDismissClears() {
        let visible = [CGRect(x: 0, y: 0, width: 1440, height: 875)]
        var copied: [String] = []
        let controller = SelectionTranslatePanelController(
            visibleFramesProvider: { visible },
            pasteboardWriter: { copied.append($0) }
        )
        let content = SelectionPopoverContent.translated(
            original: "Hello world",
            translation: "你好，世界",
            screenFrame: CGRect(x: 100, y: 300, width: 120, height: 18)
        )
        controller.show(content)
        #expect(controller.currentContent == content)
        #expect(controller.panelFrame != nil)
        #expect(controller.currentContent?.copyText == "你好，世界")
        controller.copyCurrentTranslation()
        #expect(copied == ["你好，世界"])
        #expect(controller.copyFeedback == .copied)
        let size = SelectionTranslatePanelController.contentSize(for: content)
        #expect(size.width == GTSelectionMetrics.width)
        #expect(size.height >= 44)
        controller.dismiss()
        #expect(controller.currentContent == nil)
        #expect(controller.panelFrame == nil)
        #expect(copied == ["你好，世界"])
        #expect(controller.copyFeedback == .idle)
    }

    @Test
    func copyButtonShowsCopiedThenReturnsToCopy() async throws {
        var copied: [String] = []
        let controller = SelectionTranslatePanelController(
            visibleFramesProvider: { [CGRect(x: 0, y: 0, width: 1440, height: 875)] },
            pasteboardWriter: { copied.append($0) },
            copyFeedbackDelay: .milliseconds(40)
        )
        controller.show(.translated(
            original: "Hello world",
            translation: "你好，世界",
            screenFrame: CGRect(x: 100, y: 300, width: 120, height: 18)
        ))
        #expect(controller.copyFeedback == .idle)
        #expect(SelectionCopyFeedback.idle.title == "拷贝")
        controller.copyCurrentTranslation()
        #expect(copied == ["你好，世界"])
        #expect(controller.copyFeedback == .copied)
        #expect(SelectionCopyFeedback.copied.title == "已拷贝")

        let deadline = ContinuousClock.now + .seconds(2)
        while controller.copyFeedback != .idle {
            if ContinuousClock.now >= deadline {
                Issue.record("copyFeedback stayed \(controller.copyFeedback) after copyFeedbackDelay")
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(controller.copyFeedback == .idle)
        controller.dismiss()
    }

    @Test
    func copyFailureShowsFailedFeedbackOnCopyableStates() async throws {
        struct WriteFailed: Error {}
        let controller = SelectionTranslatePanelController(
            visibleFramesProvider: { [CGRect(x: 0, y: 0, width: 1440, height: 875)] },
            pasteboardWriter: { _ in throw WriteFailed() },
            copyFeedbackDelay: .milliseconds(40)
        )
        let states: [SelectionPopoverContent] = [
            .translated(original: "Hello", translation: "你好", screenFrame: .zero),
            .optimized(original: "Hello", prompt: "电影感雨景", screenFrame: .zero),
            .alreadyChinese(original: "一个女孩站在雨里", screenFrame: .zero),
            .noTranslationNeeded(original: "Swift 6 + SwiftUI + ScreenCaptureKit", screenFrame: .zero)
        ]
        for content in states {
            controller.show(content)
            #expect(content.allowsCopy)
            controller.copyCurrentTranslation()
            #expect(controller.copyFeedback == .failed)
            #expect(SelectionCopyFeedback.failed.title == "拷贝失败")
        }
        controller.dismiss()
    }

    @Test
    func contentSizeIncludesModePickerAndCopyButton() {
        let loading = SelectionPopoverContent.loading(
            original: "Hello",
            screenFrame: CGRect(x: 0, y: 0, width: 10, height: 10)
        )
        let translated = SelectionPopoverContent.translated(
            original: "Hello",
            translation: "你好",
            screenFrame: CGRect(x: 0, y: 0, width: 10, height: 10)
        )
        let loadingSize = SelectionTranslatePanelController.contentSize(for: loading)
        let translatedSize = SelectionTranslatePanelController.contentSize(for: translated)
        #expect(loading.showsOptimizeAction)
        #expect(!loading.allowsCopy)
        #expect(translated.allowsCopy)
        #expect(translated.showsOptimizeAction)
        #expect(!SelectionPopoverLayout.usesStatusResultFont(.loading))
        #expect(!SelectionPopoverLayout.usesStatusResultFont(.translated))
        #expect(translatedSize.height >= loadingSize.height)
        #expect(translatedSize.width == GTSelectionMetrics.width)
    }

    @Test
    func selectionMetricsUseDedicatedPaddingAndWidth() {
        #expect(GTSelectionMetrics.width >= 300)
        #expect(GTSelectionMetrics.width <= 320)
        #expect(GTSelectionMetrics.horizontalPadding > GTOverlayMetrics.horizontalPadding)
        #expect(GTSelectionMetrics.verticalPadding > GTOverlayMetrics.verticalPadding)
        #expect(GTSelectionMetrics.sectionSpacing > GTSpacing.xSmall)
        #expect(GTSelectionMetrics.textBlockSpacing < GTSelectionMetrics.sectionSpacing)
        #expect(GTSelectionMetrics.modePickerHeight >= 28)
        let three = GTEqualWidthMetrics.itemWidth(total: 284, count: 3, spacing: GTSpacing.xSmall)
        #expect(abs(three * 3 + GTSpacing.xSmall * 2 - 284) < 0.001)
        #expect(GTEqualWidthMetrics.itemWidth(total: 284, count: 2, spacing: GTSpacing.xSmall) == 138)
        #expect(GTEqualWidthMetrics.itemWidth(total: 100, count: 0, spacing: 8) == 0)
        #expect(GTControlMetrics.fieldHeight >= 36)
        #expect(GTControlMetrics.menuRowHeight >= 32)
        #expect(GTControlMetrics.fieldHeight > GTSelectionMetrics.modePickerHeight - 8)
    }

    @Test
    func unavailableOmitsActionsWhileStatusStatesKeepTheGroup() {
        let unavailable = SelectionPopoverContent.unavailable(screenFrame: .zero)
        let alreadyChinese = SelectionPopoverContent.alreadyChinese(
            original: "抖测已完成，本地已进行全面测试并完成安装。",
            screenFrame: .zero
        )
        let failed = SelectionPopoverContent.failed(
            original: "Hello",
            message: "翻译失败",
            screenFrame: .zero
        )
        #expect(!unavailable.showsActionButtons)
        #expect(!unavailable.showsOptimizeAction)
        #expect(alreadyChinese.showsActionButtons)
        #expect(alreadyChinese.showsOptimizeAction)
        #expect(failed.showsActionButtons)
        let unavailableSize = SelectionTranslatePanelController.contentSize(for: unavailable)
        let chineseSize = SelectionTranslatePanelController.contentSize(for: alreadyChinese)
        let failedSize = SelectionTranslatePanelController.contentSize(for: failed)
        #expect(chineseSize.height > unavailableSize.height)
        #expect(failedSize.width == GTSelectionMetrics.width)
        #expect(unavailableSize.width == GTSelectionMetrics.width)
    }

    @Test
    func statusCopyUsesLargerStatusFontThanBody() {
        let content = SelectionPopoverContent.alreadyChinese(
            original: "抖测已完成",
            screenFrame: .zero
        )
        let textWidth = GTSelectionMetrics.width - GTSelectionMetrics.horizontalPadding * 2
        let status = OverlayLayout.estimatedTextSize(
            for: content.displayTranslation,
            maxWidth: textWidth,
            maxLines: GTSelectionMetrics.maxTranslationLines,
            font: SelectionPopoverLayout.resultMeasuringFont(for: .alreadyChinese)
        )
        let body = OverlayLayout.estimatedTextSize(
            for: content.displayTranslation,
            maxWidth: textWidth,
            maxLines: GTSelectionMetrics.maxTranslationLines,
            font: NSFont.preferredFont(forTextStyle: .body)
        )
        #expect(status.height > body.height)
        #expect(SelectionPopoverLayout.usesStatusResultFont(.alreadyChinese))
        #expect(SelectionPopoverLayout.usesStatusResultFont(.noTranslationNeeded))
        #expect(SelectionPopoverLayout.usesStatusResultFont(.failed))
        #expect(SelectionPopoverLayout.usesStatusResultFont(.unavailable))
        #expect(!SelectionPopoverLayout.usesStatusResultFont(.loading))
        #expect(!SelectionPopoverLayout.usesStatusResultFont(.optimizing))
        #expect(!SelectionPopoverLayout.usesStatusResultFont(.optimized))
        let size = SelectionTranslatePanelController.contentSize(for: content)
        #expect(size.height >= GTSelectionMetrics.verticalPadding * 2 + status.height + GTSelectionMetrics.sectionSpacing)
    }

    @Test
    func optimizeButtonIsWiredOnThePanel() {
        var optimized = 0
        var translated = 0
        let controller = SelectionTranslatePanelController(
            visibleFramesProvider: { [CGRect(x: 0, y: 0, width: 1440, height: 875)] },
            pasteboardWriter: { _ in }
        )
        controller.onOptimize = { optimized += 1 }
        controller.onTranslate = { translated += 1 }
        controller.show(.alreadyChinese(
            original: "一个女孩站在雨里",
            screenFrame: CGRect(x: 40, y: 80, width: 60, height: 14)
        ))
        controller.onOptimize?()
        controller.onTranslate?()
        #expect(optimized == 1)
        #expect(translated == 1)
        let optimizedContent = SelectionPopoverContent.optimized(
            original: "一个女孩站在雨里",
            prompt: "主体：雨中女孩，电影感。",
            screenFrame: CGRect(x: 40, y: 80, width: 60, height: 14)
        )
        controller.show(optimizedContent)
        controller.copyCurrentTranslation()
    }

    @Test
    func contentSizeUsesBodyFontSoTranslationDoesNotClipCopy() {
        let text = String(repeating: "这是一段需要换行的译文内容，", count: 8)
        let textWidth = GTSelectionMetrics.width - GTSelectionMetrics.horizontalPadding * 2
        let callout = OverlayLayout.estimatedTextSize(
            for: text,
            maxWidth: textWidth,
            maxLines: GTSelectionMetrics.maxTranslationLines
        )
        let body = OverlayLayout.estimatedTextSize(
            for: text,
            maxWidth: textWidth,
            maxLines: GTSelectionMetrics.maxTranslationLines,
            font: NSFont.preferredFont(forTextStyle: .body)
        )
        #expect(body.height > callout.height)
        let content = SelectionPopoverContent.translated(
            original: "Hello",
            translation: text,
            screenFrame: .zero
        )
        let size = SelectionTranslatePanelController.contentSize(for: content)
        let originalHeight = OverlayLayout.estimatedTextSize(
            for: content.originalPreview,
            maxWidth: textWidth,
            maxLines: GTSelectionMetrics.maxOriginalLines,
            font: NSFont.preferredFont(forTextStyle: .caption1)
        ).height
        let expectedMin = GTSelectionMetrics.verticalPadding * 2
            + originalHeight
            + GTSelectionMetrics.textBlockSpacing
            + body.height
            + GTSelectionMetrics.sectionSpacing
            + GTSelectionMetrics.modePickerHeight
            + GTSelectionMetrics.actionsSpacing
            + GTSelectionMetrics.actionRowHeight
        #expect(size.height >= expectedMin - 0.5)
        #expect(size.width == GTSelectionMetrics.width)
    }

    @Test
    func outsideClickNotifiesUserDismissThenHides() {
        var dismissed = 0
        let controller = SelectionTranslatePanelController(
            visibleFramesProvider: { [CGRect(x: 0, y: 0, width: 1440, height: 875)] },
            pasteboardWriter: { _ in }
        )
        controller.onUserDismiss = { dismissed += 1 }
        controller.show(.translated(
            original: "Hello",
            translation: "你好",
            screenFrame: CGRect(x: 40, y: 80, width: 60, height: 14)
        ))
        #expect(controller.currentContent != nil)
        controller.notifyUserDismiss()
        #expect(dismissed == 1)
        #expect(controller.currentContent == nil)
    }

    @Test
    func sceneMenuFramesAreNotOutsideClicks() {
        let panelFrame = CGRect(x: 40, y: 80, width: 280, height: 90)
        let menuFrame = CGRect(x: 40, y: 10, width: 160, height: 140)
        #expect(SelectionPopoverHitTesting.containsInteraction(
            panelFrame: panelFrame,
            location: CGPoint(x: 80, y: 50),
            auxiliaryFrames: [menuFrame]
        ))
        #expect(!SelectionPopoverHitTesting.containsInteraction(
            panelFrame: panelFrame,
            location: CGPoint(x: 800, y: 600),
            auxiliaryFrames: [menuFrame]
        ))
        #expect(SelectionPopoverHitTesting.containsInteraction(
            panelFrame: panelFrame,
            location: CGPoint(x: 50, y: 100),
            auxiliaryFrames: [menuFrame]
        ))
    }

    @Test
    func popUpMenuWindowClickDoesNotDismissPopover() {
        var dismissed = 0
        let controller = SelectionTranslatePanelController(
            visibleFramesProvider: { [CGRect(x: 0, y: 0, width: 1440, height: 875)] },
            pasteboardWriter: { _ in }
        )
        controller.onUserDismiss = { dismissed += 1 }
        controller.show(.translated(
            original: "Hello",
            translation: "你好",
            screenFrame: CGRect(x: 40, y: 80, width: 60, height: 14)
        ))
        let menuFrame = CGRect(x: 200, y: 200, width: 140, height: 120)
        controller.handlePotentialOutsideClick(at: CGPoint(x: 240, y: 240), auxiliaryFrames: [menuFrame])
        #expect(dismissed == 0)
        #expect(controller.currentContent != nil)
        controller.handlePotentialOutsideClick(at: CGPoint(x: 1200, y: 800), auxiliaryFrames: [menuFrame])
        #expect(dismissed == 1)
        #expect(controller.currentContent == nil)
    }
}
