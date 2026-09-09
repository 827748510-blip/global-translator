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
        #expect(translatedSize.height > loadingSize.height)
    }
}
