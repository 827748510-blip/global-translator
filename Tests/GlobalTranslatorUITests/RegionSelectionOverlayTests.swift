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
    func regionPanelIsNonactivatingAndSupportsEscapeKeyWithoutBecomingMain() {
        let panel = RegionSelectionPanel(contentRect: CGRect(x: 0, y: 0, width: 200, height: 200))
        var escaped = 0
        panel.onEscape = { escaped += 1 }
        #expect(!panel.ignoresMouseEvents)
        #expect(panel.styleMask.contains(.borderless))
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
        #expect(panel.level == .screenSaver)
        panel.cancelOperation(nil)
        #expect(escaped == 1)
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

    @Test
    func crossScreenDragClampsPreviewToStartingDisplay() async throws {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return }
        let overlay = RegionSelectionOverlayController(screensProvider: { [primary] })
        let selection = Task { @MainActor in
            await overlay.selectRegion()
        }
        defer { overlay.cancel() }
        try await waitUntil { overlay.isSelecting }

        let start = CGPoint(x: primary.frame.maxX - 40, y: primary.frame.midY)
        let outside = CGPoint(x: primary.frame.maxX + 200, y: primary.frame.midY + 60)
        overlay.handlePointerForTesting(.down, at: start)
        overlay.handlePointerForTesting(.dragged, at: outside)
        let preview = overlay.displayedSelectionRectForTesting
        #expect(preview.maxX <= primary.frame.maxX + 0.01)

        overlay.handlePointerForTesting(.up, at: outside)
        let outcome = await selection.value
        guard case .completed(let finalRect) = outcome else {
            Issue.record("expected completed rect")
            return
        }
        #expect(finalRect.maxX <= primary.frame.maxX + 0.01)
    }
}
