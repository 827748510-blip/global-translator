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
    func panelAnchorHangsBelowIconAndFallsBackWithoutUsableGeometry() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = CGSize(width: 380, height: 600)

        // Normal icon: top edge follows the icon's bottom edge.
        let withIcon = DropdownLayout.panelAnchor(
            iconFrame: CGRect(x: 1200, y: 876, width: 24, height: 24),
            panelSize: size,
            visibleFrame: screen,
            screenFrame: screen
        )
        #expect(withIcon.y == 876)
        #expect(withIcon.x == 1022)

        // ControlCenter hosts the item with no window at all.
        let withoutWindow = DropdownLayout.panelAnchor(
            iconFrame: nil,
            panelSize: size,
            visibleFrame: screen,
            screenFrame: screen
        )
        #expect(withoutWindow.y == 892)
        #expect(withoutWindow.x == 1052)

        // The item exists but reports a zero-size frame, which previously
        // anchored the panel off-screen.
        let zeroSize = DropdownLayout.panelAnchor(
            iconFrame: CGRect(x: 900, y: 0, width: 0, height: 0),
            panelSize: size,
            visibleFrame: screen,
            screenFrame: screen
        )
        #expect(zeroSize == withoutWindow)

        // An icon frame on another display must not be used.
        let offScreenIcon = DropdownLayout.panelAnchor(
            iconFrame: CGRect(x: 5000, y: 5000, width: 24, height: 24),
            panelSize: size,
            visibleFrame: screen,
            screenFrame: screen
        )
        #expect(offScreenIcon == withoutWindow)
    }

    @Test
    func panelAnchorTreatsAMenuBarIconAsUsable() {
        // A real status item lives entirely inside the strip that visibleFrame
        // excludes: it only touches the visible frame's top edge. Ownership
        // must be decided against the screen frame instead.
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let menuBar: CGFloat = 24
        let visible = CGRect(x: 0, y: 0, width: 1920, height: screen.height - menuBar)
        let icon = CGRect(x: 1500, y: 1056, width: 24, height: 24)
        let size = CGSize(width: 360, height: 600)

        let anchor = DropdownLayout.panelAnchor(
            iconFrame: icon,
            panelSize: size,
            visibleFrame: visible,
            screenFrame: screen
        )
        // Centered under the icon, not parked in the fallback corner.
        let expectedX = icon.midX - size.width / 2
        let fallbackX = visible.maxX - DropdownLayout.screenMargin - size.width
        #expect(anchor.x == expectedX)
        #expect(anchor.x != fallbackX)
        // Top edge still clamped under the menu bar.
        #expect(anchor.y == visible.maxY - DropdownLayout.screenMargin)
    }

    @Test
    func panelAnchorRejectsAHostedFrameParkedAtTheScreenOrigin() {
        // ControlCenter can report a non-empty frame that is not the icon at
        // all — observed in the wild as (0, 0, 44, 24), which passed the old
        // intersection check and anchored the panel to the bottom-left corner.
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let visible = CGRect(x: 0, y: 0, width: 1920, height: 1056)
        let size = CGSize(width: 360, height: 600)
        let anchor = DropdownLayout.panelAnchor(
            iconFrame: CGRect(x: 0, y: 0, width: 44, height: 24),
            panelSize: size,
            visibleFrame: visible,
            screenFrame: screen
        )
        let fallbackX = visible.maxX - DropdownLayout.screenMargin - size.width
        #expect(anchor.x == fallbackX)
        #expect(anchor.y == visible.maxY - DropdownLayout.screenMargin)
    }

    @Test
    func launchExemptionBelongsToTheLaunchOnly() {
        let shownAt = Date(timeIntervalSince1970: 2_000)

        // Armed by a cold launch: the first foreign activation is the bounce.
        var launched = LaunchFocusExemption()
        launched.armForLaunch()
        let firstBounce = launched.consumeIfBounce(shownAt: shownAt, now: shownAt.addingTimeInterval(1))
        #expect(firstBounce)
        // Consumed on consultation, so a second switch is a real decision.
        let secondSwitch = launched.consumeIfBounce(shownAt: shownAt, now: shownAt.addingTimeInterval(1.5))
        #expect(!secondSwitch)

        // A panel the user closed and reopened must not inherit the exemption,
        // otherwise switching apps within the window leaves it floating.
        var reopened = LaunchFocusExemption()
        reopened.armForLaunch()
        reopened.disarm()
        let afterReopen = reopened.consumeIfBounce(shownAt: shownAt, now: shownAt.addingTimeInterval(1))
        #expect(!afterReopen)
        #expect(!reopened.isArmed)

        // Past the window it is not a bounce, and the arm is still consumed.
        var expired = LaunchFocusExemption()
        expired.armForLaunch()
        let afterExpiry = expired.consumeIfBounce(shownAt: shownAt, now: shownAt.addingTimeInterval(9))
        #expect(!afterExpiry)
        #expect(!expired.isArmed)

        // A missing show time cannot justify an exemption.
        var unknown = LaunchFocusExemption()
        unknown.armForLaunch()
        let withoutShownAt = unknown.consumeIfBounce(shownAt: nil, now: shownAt)
        #expect(!withoutShownAt)
    }

    @Test
    func focusPolicyIgnoresLaunchChurnButDismissesDeliberateSwitching() {
        let shownAt = Date(timeIntervalSince1970: 1_000)
        // Cold launch: another app takes focus back right after the panel shows.
        #expect(!DropdownFocusPolicy.shouldDismiss(
            shownAt: shownAt,
            now: shownAt.addingTimeInterval(0.3),
            isOwnApplication: false
        ))
        // Our own app activating never dismisses.
        #expect(!DropdownFocusPolicy.shouldDismiss(
            shownAt: shownAt,
            now: shownAt.addingTimeInterval(5),
            isOwnApplication: true
        ))
        // Cmd-Tab after the grace period is a user decision.
        #expect(DropdownFocusPolicy.shouldDismiss(
            shownAt: shownAt,
            now: shownAt.addingTimeInterval(DropdownFocusPolicy.settleWindow + 0.1),
            isOwnApplication: false
        ))
        // Unknown show time behaves conservatively.
        #expect(DropdownFocusPolicy.shouldDismiss(shownAt: nil, now: shownAt, isOwnApplication: false))
    }

    @Test
    func panelAnchorKeepsTallPanelInsideShortScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 700)
        let size = CGSize(width: 380, height: 640)
        let anchor = DropdownLayout.panelAnchor(
            iconFrame: CGRect(x: 1880, y: 676, width: 24, height: 24),
            panelSize: size,
            visibleFrame: screen,
            screenFrame: screen
        )
        // Top edge pins to the icon when it still fits; the panel never leaves
        // the visible frame even when it is nearly as tall as the screen.
        #expect(anchor.y == 676)
        #expect(anchor.y - size.height >= screen.minY)
    }

    @Test @MainActor
    func presentPutsTheAnchorOnTheTopEdge() {
        let panel = DropdownPanel(content: NSViewController())
        panel.present(anchorTopLeft: CGPoint(x: 100, y: 800), size: CGSize(width: 380, height: 240))
        // The frame's bottom edge is the anchor minus the panel height, so the
        // top edge lands on the anchor instead of the bottom edge doing so.
        #expect(panel.frame.minY == 560)
        panel.dismiss(animated: false)
        panel.orderOut(nil)
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

    @Test @MainActor
    func dropdownPanelHandlesEscapeUpdateHeightAndModalPickerProtection() {
        let panel = DropdownPanel(content: NSViewController())
        var escaped = 0
        panel.onEscape = { escaped += 1 }
        panel.present(anchorTopLeft: CGPoint(x: 100, y: 800), size: CGSize(width: 360, height: 300))
        #expect(panel.frame.maxY == 800)

        panel.updateHeight(420)
        #expect(panel.frame.maxY == 800)
        #expect(panel.frame.height == 420)

        panel.shouldHandleEscape = { false }
        panel.cancelOperation(nil)
        #expect(escaped == 0)

        panel.shouldHandleEscape = { true }
        panel.cancelOperation(nil)
        #expect(escaped == 1)

        panel.dismiss(animated: false)
        panel.orderOut(nil)
    }

    @Test @MainActor
    func statusItemDismissCancelsActiveHotkeyRecording() {
        let viewModel = SettingsViewModel(actions: StatusItemTestActions())
        let controller = StatusItemController(viewModel: viewModel)
        viewModel.beginRecordingScreenshotHotkey()
        #expect(viewModel.isRecordingScreenshotHotkey)
        controller.stop()
        #expect(!viewModel.isRecordingScreenshotHotkey)
    }
}
