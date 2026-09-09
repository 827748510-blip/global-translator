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
        let size = SelectionTranslatePanelController.contentSize(for: content)
        #expect(size.width == GTSelectionMetrics.width)
        #expect(size.height >= 44)
        controller.dismiss()
        #expect(controller.currentContent == nil)
        #expect(controller.panelFrame == nil)
        #expect(copied == ["你好，世界"])
    }

    @Test
    func contentSizeIncludesCopyButtonOnlyWhenAllowed() {
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
        #expect(translatedSize.height >= loadingSize.height)
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
        let textWidth = GTSelectionMetrics.width - GTOverlayMetrics.horizontalPadding * 2
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
        let expectedMin = GTOverlayMetrics.verticalPadding * 2
            + originalHeight
            + GTSpacing.xSmall
            + body.height
            + GTSpacing.xSmall
            + 28
        #expect(size.height >= expectedMin - 0.5)
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
}
