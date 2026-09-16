import AppKit
import Foundation
import Testing
@testable import GlobalTranslatorUI
import GlobalTranslatorCore

@MainActor
struct RegionSelectionOverlayTests {
    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 1) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(condition())
    }

    @Test
    func regionPanelIsNonactivatingAndCapturesMouseWithoutBecomingKey() {
        let panel = RegionSelectionPanel(contentRect: CGRect(x: 0, y: 0, width: 200, height: 200))
        #expect(!panel.ignoresMouseEvents)
        #expect(panel.styleMask.contains(.borderless))
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(!panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
        #expect(panel.level == .screenSaver)
        #expect(NullRegionSelector().isSelecting == false)
    }

    @Test
    func completedTinyDragReturnsUnusableRectNotCancel() async throws {
        let overlay = RegionSelectionOverlayController(screensProvider: { [] })
        let selection = Task { @MainActor in
            await overlay.selectRegion()
        }
        defer { overlay.cancel() }
        try await waitUntil { overlay.isSelecting }
        overlay.handlePointerForTesting(.down, at: CGPoint(x: 10, y: 10))
        overlay.handlePointerForTesting(.dragged, at: CGPoint(x: 12, y: 11))
        overlay.handlePointerForTesting(.up, at: CGPoint(x: 12, y: 11))
        let outcome = await selection.value
        #expect(outcome == .completed(CGRect(x: 10, y: 10, width: 2, height: 1)))
        #expect(!ScreenshotTranslateSupport.isUsableRegion(CGRect(x: 10, y: 10, width: 2, height: 1)))
        #expect(!overlay.isSelecting)
    }

    @Test
    func explicitCancelReturnsCancelled() async throws {
        let overlay = RegionSelectionOverlayController(screensProvider: { [] })
        let selection = Task { @MainActor in
            await overlay.selectRegion()
        }
        defer { overlay.cancel() }
        try await waitUntil { overlay.isSelecting }
        overlay.cancel()
        let outcome = await selection.value
        #expect(outcome == .cancelled)
        #expect(!overlay.isSelecting)
    }
}
