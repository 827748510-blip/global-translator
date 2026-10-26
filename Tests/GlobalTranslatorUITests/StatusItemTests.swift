import AppKit
import Foundation
import SwiftUI
import Testing
@testable import GlobalTranslatorUI
import GlobalTranslatorEngine
import GlobalTranslatorCapture

@MainActor
private final class StatusItemTestActions: SettingsActions {
    func setAutomaticTranslation(_ enabled: Bool) {}
    func setSelectionTranslate(_ enabled: Bool) {}
    func setVideoTranslate(_ enabled: Bool) {}
    func setPromptOptimizeMode(_ mode: PromptOptimizeMode) {}
    func setAutoCopyScreenshotTranslation(_ enabled: Bool) {}
    func setSaveScreenshotImage(_ enabled: Bool) {}
    func setCopyScreenshotImage(_ enabled: Bool) {}
    func chooseScreenshotSaveDirectory() {}
    func setScreenshotTranslateHotkey(_ spec: KeyboardShortcutSpec) {}
    func beginScreenshotHotkeyRecording() {}
    func cancelScreenshotHotkeyRecording() {}
    func selectBackend(_ kind: BackendKind) {}
    func saveAPIKey(_ draft: String) async throws {}
    func deleteAPIKey() async throws {}
    func testConnection() async throws -> BackendHealth {
        BackendHealth(status: .healthy, message: "ok")
    }
    func setVisionFallback(_ enabled: Bool) {}
    func setLocalConfiguration(baseURL: String, model: String) {}
    func setDeepSeekModel(_ model: String) {}
    func requestPermission(_ kind: PermissionKind) {}
    func refreshPermissions() {}
    func openSystemSettings(_ kind: PermissionKind) {}
    func addCurrentAppTranslation() {}
    func chooseTranslatedApplications() {}
    func removeTranslationApplication(bundleIdentifier: String) {}
    func clearCache() async throws {}
    func openLogs() {}
    func openDeepSeekStats() {}
    func quit() {}
}

struct StatusItemTests {
    @Test @MainActor
    func stoppingControllerIsIdempotentAndReleasesStatusItem() {
        let viewModel = SettingsViewModel(actions: StatusItemTestActions())
        let controller = StatusItemController(viewModel: viewModel)

        #expect(!controller.isStopped)
        controller.stop()
        controller.stop()

        #expect(controller.isStopped)
    }

    @Test @MainActor
    func statusItemUsesStableAutosaveIdentityAndRequestsVisibility() {
        let viewModel = SettingsViewModel(actions: StatusItemTestActions())
        let controller = StatusItemController(viewModel: viewModel)

        #expect(controller.statusItemAutosaveName == "com.maodashu.global-translator.status")
        #expect(controller.requestsStatusItemVisibility)

        controller.stop()
    }

    @Test @MainActor
    func dropdownPanelCanAppearOverFullscreenSpaces() {
        let viewModel = SettingsViewModel(actions: StatusItemTestActions())
        let controller = StatusItemController(viewModel: viewModel)

        // The dropdown must join fullscreen spaces so it opens even when the
        // frontmost browser is fullscreen.
        #expect(controller.dropdownIsFullscreenCapable)

        controller.stop()
    }

    @Test @MainActor
    func dropdownPanelIsWhiteNonActivatingAndKeyCapable() {
        let panel = DropdownPanel(content: NSViewController())

        #expect(panel.styleMask.contains(.borderless))
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
        #expect(panel.level == .floating)
        // Rounded corners are drawn by the content; the window is transparent.
        #expect(!panel.isOpaque)
        #expect(panel.backgroundColor == .clear)
        #expect(panel.appearance == nil)

        panel.orderOut(nil)
    }

    @Test @MainActor
    func panelRegistersOutsideClickMonitorsWhileVisible() {
        let panel = DropdownPanel(content: NSViewController())

        #expect(panel.outsideClickMonitorCount == 0)
        panel.present(anchorTopLeft: CGPoint(x: 100, y: 300), size: CGSize(width: 380, height: 240))
        #expect(panel.outsideClickMonitorCount >= 1)

        panel.dismiss(animated: false)
        #expect(panel.outsideClickMonitorCount == 0)
        panel.orderOut(nil)
    }

    @Test
    func dropdownLayoutCentersUnderIconAndClampsToScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        // Icon near the middle: panel centers under it.
        #expect(DropdownLayout.panelOriginX(iconMidX: 700, panelWidth: 380, visibleFrame: screen) == 510.0)
        // Icon at the far right: panel clamps inside the right edge.
        #expect(DropdownLayout.panelOriginX(iconMidX: 1430, panelWidth: 380, visibleFrame: screen) == 1052.0)
        // Icon at the far left: panel clamps inside the left edge.
        #expect(DropdownLayout.panelOriginX(iconMidX: 10, panelWidth: 380, visibleFrame: screen) == 8.0)
        // Negative-coordinate secondary display keeps the panel on screen.
        let secondary = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        #expect(DropdownLayout.panelOriginX(iconMidX: -1900, panelWidth: 380, visibleFrame: secondary) == -1912.0)
        #expect(DropdownLayout.panelOriginX(iconMidX: -10, panelWidth: 380, visibleFrame: secondary) == -388.0)
        // Narrower than the panel: origin pins to the left margin.
        let tiny = CGRect(x: 0, y: 0, width: 100, height: 600)
        #expect(DropdownLayout.panelOriginX(iconMidX: 50, panelWidth: 380, visibleFrame: tiny) == 8.0)
    }

    @Test
    func toggleDecisionCoversOpenCloseAndFlickerGuard() {
        // Closed with no recent dismissal: clicking opens.
        #expect(DropdownToggleLogic.toggleAction(isShown: false, secondsSinceDismiss: nil) == .show)
        // Closed but the dismissal is old: clicking opens again.
        #expect(DropdownToggleLogic.toggleAction(isShown: false, secondsSinceDismiss: 5) == .show)
        // Open: clicking closes.
        #expect(DropdownToggleLogic.toggleAction(isShown: true, secondsSinceDismiss: nil) == .close)
        // The click just dismissed the transient panel: do not reopen.
        #expect(DropdownToggleLogic.toggleAction(isShown: false, secondsSinceDismiss: 0.05) == .stayClosed)
        #expect(DropdownToggleLogic.toggleAction(isShown: false, secondsSinceDismiss: 0.19) == .stayClosed)
        // Just past the suppression window clicking opens again.
        #expect(DropdownToggleLogic.toggleAction(isShown: false, secondsSinceDismiss: 0.21) == .show)
    }

    @Test @MainActor
    func stopMarksControllerInactive() {
        let viewModel = SettingsViewModel(actions: StatusItemTestActions())
        let controller = StatusItemController(viewModel: viewModel)

        #expect(!controller.isStopped)
        controller.stop()

        // Further requests after stopping must be ignored.
        controller.toggleDropdown(nil)
        controller.showSettings()
        #expect(!controller.isDropdownShown)

        controller.stop()
        #expect(controller.isStopped)
    }

    @Test
    func everyStateMapsToExpectedSFSymbol() {
        #expect(MenuBarStatus.listening.symbolName == "character.bubble")
        #expect(MenuBarStatus.off.symbolName == "pause.circle")
        #expect(MenuBarStatus.translating.symbolName == "ellipsis.bubble")
        #expect(MenuBarStatus.missingPermission.symbolName == "exclamationmark.triangle")
        #expect(MenuBarStatus.error.symbolName == "exclamationmark.triangle")
    }

    @Test
    func everyStateHasDistinctTextualAccessibilityLabel() {
        let labels = MenuBarStatus.allCases.map(\.accessibilityLabel)
        #expect(Set(labels).count == MenuBarStatus.allCases.count)
        for status in MenuBarStatus.allCases {
            #expect(!status.accessibilityLabel.isEmpty)
            #expect(!status.helpText.isEmpty)
        }
        // Error and missing permission share a symbol but never share text:
        // state is never conveyed by symbol/color alone.
        #expect(MenuBarStatus.missingPermission.accessibilityLabel != MenuBarStatus.error.accessibilityLabel)
    }

    @Test
    func engineStateMappingCoversAllEngineStates() {
        #expect(MenuBarStatus(engineState: .off) == .off)
        #expect(MenuBarStatus(engineState: .listening) == .listening)
        #expect(MenuBarStatus(engineState: .translating) == .translating)
        #expect(MenuBarStatus(engineState: .missingPermission) == .missingPermission)
        #expect(MenuBarStatus(engineState: .backendError) == .error)
        #expect(MenuBarStatus(engineState: .circuitOpen) == .error)
    }
}
