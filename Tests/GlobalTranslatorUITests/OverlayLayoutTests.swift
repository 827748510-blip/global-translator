import Foundation
import AppKit
import Testing
@testable import GlobalTranslatorUI
import GlobalTranslatorCore
import GlobalTranslatorEngine

private func makeRegion(
    frame: CGRect,
    text: String = "source",
    revision: UInt64 = 1
) -> TextRegion {
    TextRegion(
        id: UUID(),
        sourceText: text,
        screenFrame: frame,
        confidence: 1,
        source: .accessibility,
        windowRevision: revision
    )
}

struct OverlayLayoutTests {
    private let primaryVisible = CGRect(x: 0, y: 0, width: 1440, height: 875)

    @Test
    func placesTranslationAboveOriginalWhenRoomExists() {
        let original = CGRect(x: 100, y: 300, width: 200, height: 20)
        let content = CGSize(width: 260, height: 40)
        let frame = OverlayLayout.placementFrame(
            originalFrame: original,
            contentSize: content,
            screenVisibleFrame: primaryVisible
        )
        #expect(frame.minY > original.maxY)
        #expect(frame.minX == 100)
        #expect(frame.size == content)
    }

    @Test
    func fallsBackBelowOriginalWhenTopIsOutOfRoom() {
        let original = CGRect(x: 100, y: 840, width: 200, height: 20)
        let content = CGSize(width: 260, height: 40)
        let frame = OverlayLayout.placementFrame(
            originalFrame: original,
            contentSize: content,
            screenVisibleFrame: primaryVisible
        )
        #expect(frame.maxY <= original.minY)
        #expect(frame.minY >= primaryVisible.minY)
    }

    @Test
    func clampsHorizontallyToRightEdge() {
        let original = CGRect(x: 1400, y: 300, width: 200, height: 20)
        let content = CGSize(width: 260, height: 40)
        let frame = OverlayLayout.placementFrame(
            originalFrame: original,
            contentSize: content,
            screenVisibleFrame: primaryVisible
        )
        #expect(frame.maxX <= primaryVisible.maxX)
        #expect(frame.maxX == primaryVisible.maxX)
    }

    @Test
    func clampsIntoNegativeCoordinateSecondaryScreen() {
        let secondaryVisible = CGRect(x: -1920, y: 0, width: 1920, height: 1055)
        let original = CGRect(x: -1935, y: 400, width: 100, height: 20)
        let content = CGSize(width: 260, height: 40)
        let frame = OverlayLayout.placementFrame(
            originalFrame: original,
            contentSize: content,
            screenVisibleFrame: secondaryVisible
        )
        #expect(frame.minX >= secondaryVisible.minX)
        #expect(frame.minX == secondaryVisible.minX)
        #expect(frame.maxX <= secondaryVisible.maxX)
        #expect(frame.minY > original.maxY)
        #expect(frame.maxY <= secondaryVisible.maxY)
    }

    @Test
    func clampsVerticallyWhenNeitherAboveNorBelowFits() {
        let visible = CGRect(x: 0, y: 0, width: 800, height: 100)
        let original = CGRect(x: 10, y: 40, width: 200, height: 20)
        let content = CGSize(width: 260, height: 90)
        let frame = OverlayLayout.placementFrame(
            originalFrame: original,
            contentSize: content,
            screenVisibleFrame: visible
        )
        #expect(frame.minY >= visible.minY)
        #expect(frame.maxY <= visible.maxY)
    }

    @Test
    func estimatedTextSizeCapsWidthAndLineCountForLongCJK() {
        let longText = String(repeating: "这是一段很长的中文翻译文本，", count: 30)
        let size = OverlayLayout.estimatedTextSize(
            for: longText,
            maxWidth: GTOverlayMetrics.maxTextWidth,
            maxLines: GTOverlayMetrics.maxLines
        )
        #expect(size.width <= GTOverlayMetrics.maxTextWidth)
        let lineHeight = OverlayLayout.estimatedLineHeight
        #expect(size.height <= lineHeight * CGFloat(GTOverlayMetrics.maxLines) + 0.5)
        #expect(size.height > lineHeight * 1.5)
    }

    @Test
    func estimatedTextSizeFitsShortTextOnOneLine() {
        let size = OverlayLayout.estimatedTextSize(
            for: "你好",
            maxWidth: GTOverlayMetrics.maxTextWidth,
            maxLines: GTOverlayMetrics.maxLines
        )
        #expect(size.width < GTOverlayMetrics.maxTextWidth)
        #expect(size.height <= OverlayLayout.estimatedLineHeight + 0.5)
    }
}

@MainActor
struct OverlayPanelControllerTests {
    private let visibleFrames = [CGRect(x: 0, y: 0, width: 1440, height: 875)]

    @Test
    func panelUsesClickThroughNonactivatingBorderlessPolicy() {
        let panel = OverlayPanel(contentRect: CGRect(x: 0, y: 0, width: 100, height: 40))
        #expect(panel.ignoresMouseEvents)
        #expect(!panel.isOpaque)
        #expect(panel.backgroundColor == .clear)
        #expect(!panel.hasShadow)
        #expect(panel.styleMask.contains(.borderless))
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(!panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
        #expect(panel.level == .floating)
        #expect(panel.level.rawValue < NSWindow.Level.statusBar.rawValue)
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(panel.collectionBehavior.contains(.ignoresCycle))
    }

    @Test
    func hoverRaisesOnlyTheTargetBubbleWithoutChangingClickThroughPolicy() {
        let controller = OverlayPanelController(visibleFramesProvider: { self.visibleFrames })
        let first = makeRegion(frame: CGRect(x: 100, y: 300, width: 200, height: 20))
        let second = makeRegion(frame: CGRect(x: 700, y: 300, width: 200, height: 20))
        controller.update(translations: [RenderedTranslation(region: first, text: "悬停译文"),
                                          RenderedTranslation(region: second, text: "另一条译文")], revision: 1)
        controller.updateHover(at: CGPoint(x: 150, y: 310))
        #expect(controller.panelLevel(for: first.id) == .screenSaver)
        #expect(controller.panelLevel(for: second.id) == .floating)
        controller.updateHover(at: CGPoint(x: 150, y: 335))
        #expect(controller.panelLevel(for: first.id) == .screenSaver)
        controller.updateHover(at: CGPoint(x: 1200, y: 700))
        #expect(controller.panelLevel(for: first.id) == .floating)
        controller.hideAll()
        controller.updateHover(at: CGPoint(x: 150, y: 310))
        #expect(controller.panelCount == 0)
    }

    @Test
    func updateCreatesPanelsAndHideAllRemovesThemImmediately() {
        let controller = OverlayPanelController(visibleFramesProvider: { self.visibleFrames })
        let region = makeRegion(frame: CGRect(x: 100, y: 300, width: 200, height: 20))
        controller.update(translations: [RenderedTranslation(region: region, text: "你好")], revision: 2)
        #expect(controller.panelCount == 1)
        #expect(controller.currentRevision == 2)
        controller.hideAll()
        #expect(controller.panelCount == 0)
    }

    @Test
    func staleRevisionsNeverUpdatePanels() {
        let controller = OverlayPanelController(visibleFramesProvider: { self.visibleFrames })
        let region = makeRegion(frame: CGRect(x: 100, y: 300, width: 200, height: 20))
        controller.update(translations: [RenderedTranslation(region: region, text: "新")], revision: 5)
        #expect(controller.panelCount == 1)
        controller.update(translations: [], revision: 4)
        #expect(controller.panelCount == 1)
        #expect(controller.currentRevision == 5)
        controller.update(translations: [], revision: 6)
        #expect(controller.panelCount == 0)
    }

    @Test
    func existingPanelUpdatesRootContentWhenSameRegionReceivesNewText() {
        let controller = OverlayPanelController(visibleFramesProvider: { self.visibleFrames })
        let region = makeRegion(frame: CGRect(x: 100, y: 300, width: 200, height: 20))
        controller.update(translations: [RenderedTranslation(region: region, text: "旧文本")], revision: 1)
        #expect(controller.panelCount == 1)
        #expect(controller.panelText(for: region.id) == "旧文本")
        controller.update(translations: [RenderedTranslation(region: region, text: "新文本")], revision: 2)
        #expect(controller.panelCount == 1)
        #expect(controller.panelText(for: region.id) == "新文本")
    }

    @Test
    func hideAllInvalidatesInFlightRevisionsButAllowsNewerCapture() {
        let controller = OverlayPanelController(visibleFramesProvider: { self.visibleFrames })
        let region = makeRegion(frame: CGRect(x: 100, y: 300, width: 200, height: 20))
        controller.update(translations: [RenderedTranslation(region: region, text: "甲")], revision: 5)
        #expect(controller.panelCount == 1)
        controller.hideAll()
        #expect(controller.panelCount == 0)
        // An in-flight update carrying the pre-hide (equal) revision is blocked.
        controller.update(translations: [RenderedTranslation(region: region, text: "甲")], revision: 5)
        #expect(controller.panelCount == 0)
        // Older revisions stay blocked too.
        controller.update(translations: [RenderedTranslation(region: region, text: "甲")], revision: 4)
        #expect(controller.panelCount == 0)
        // A genuinely newer capture is allowed again.
        controller.update(translations: [RenderedTranslation(region: region, text: "乙")], revision: 6)
        #expect(controller.panelCount == 1)
        #expect(controller.panelText(for: region.id) == "乙")
    }

    @Test
    func repeatedHidesBeforeFirstCaptureDoNotOutrunWindowRevision() {
        let controller = OverlayPanelController(visibleFramesProvider: { self.visibleFrames })
        let region = makeRegion(frame: CGRect(x: 100, y: 300, width: 200, height: 20))

        controller.hideAll()
        controller.hideAll()
        controller.update(translations: [RenderedTranslation(region: region, text: "首个结果")], revision: 1)

        #expect(controller.panelCount == 1)
        #expect(controller.currentRevision == 1)
    }

    @Test
    func regionsOffAllScreensAreSkipped() {
        let controller = OverlayPanelController(visibleFramesProvider: { self.visibleFrames })
        let offScreen = makeRegion(frame: CGRect(x: 10000, y: 10000, width: 100, height: 20))
        controller.update(translations: [RenderedTranslation(region: offScreen, text: "看不到")], revision: 1)
        #expect(controller.panelCount == 0)
    }
}
