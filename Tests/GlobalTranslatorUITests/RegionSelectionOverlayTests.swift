import AppKit
import Foundation
import Testing
@testable import GlobalTranslatorUI
import GlobalTranslatorCore

struct RegionSelectionOverlayTests {
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
}
