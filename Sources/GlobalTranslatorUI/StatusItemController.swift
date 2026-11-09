import AppKit
import Combine
import SwiftUI

/// Decision for one menu bar icon click.
public enum DropdownToggleAction: Equatable {
    case show
    case close
    /// The click itself just dismissed the dropdown; keep it closed so the
    /// icon acts as a toggle instead of flickering open again.
    case stayClosed
}

public enum DropdownToggleLogic {
    /// A dismissal younger than the suppression window was caused by the very
    /// click now being handled (an outside click closes the panel just before
    /// the button action runs).
    static let dismissalSuppressionWindow: TimeInterval = 0.2

    public static func toggleAction(isShown: Bool, secondsSinceDismiss: TimeInterval?) -> DropdownToggleAction {
        if isShown { return .close }
        if let secondsSinceDismiss, secondsSinceDismiss < dismissalSuppressionWindow { return .stayClosed }
        return .show
    }
}

/// Owns the menu bar item and presents the matching dropdown panel anchored
/// directly below the status item icon. The panel is fullscreen-capable
/// (`fullScreenAuxiliary`), never activates the app, uses a solid panel
/// background that follows system light/dark, and animates its expand/collapse.
@MainActor
public final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let viewModel: SettingsViewModel
    private let dropdownContent: NSHostingController<AnyView>
    private lazy var dropdownPanel = DropdownPanel(content: dropdownContent)
    /// When the panel was dismissed by this very click (outside click closes
    /// it just before the button action runs), reopening must be suppressed
    /// so the icon behaves as a toggle instead of flickering.
    private var lastDismissDate: Date?
    private var statusCancellable: AnyCancellable?

    private(set) var isStopped = false

    var statusItemAutosaveName: String? { statusItem.autosaveName }
    var requestsStatusItemVisibility: Bool { statusItem.isVisible }
    var isDropdownShown: Bool { dropdownPanel.isVisible }
    var dropdownIsFullscreenCapable: Bool {
        dropdownPanel.collectionBehavior.contains(.fullScreenAuxiliary)
            && dropdownPanel.collectionBehavior.contains(.canJoinAllSpaces)
    }

    public init(viewModel: SettingsViewModel) {
        self.viewModel = viewModel
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.dropdownContent = NSHostingController(rootView: AnyView(EmptyView()))
        super.init()
        statusItem.autosaveName = "com.maodashu.global-translator.status"
        statusItem.isVisible = true
        configureDropdownPanel()
        configureStatusItem()
        statusCancellable = viewModel.$status
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                self?.applyStatus(status)
            }
    }

    /// Updates symbol, template rendering, and textual accessibility state.
    public func applyStatus(_ status: MenuBarStatus) {
        guard !isStopped else { return }
        guard let button = statusItem.button else { return }
        let image = NSImage(
            systemSymbolName: status.symbolName,
            accessibilityDescription: status.accessibilityLabel
        )
        image?.isTemplate = true
        button.image = image
        button.title = ""
        button.contentTintColor = nil
        button.toolTip = status.helpText
        button.setAccessibilityLabel(status.accessibilityLabel)
        button.setAccessibilityHelp(status.helpText)
    }

    public func stop() {
        guard !isStopped else { return }
        isStopped = true
        statusCancellable?.cancel()
        statusCancellable = nil
        dropdownPanel.onResignKey = nil
        dropdownPanel.onOutsideClick = nil
        dropdownPanel.dismiss(animated: false)
        dropdownContent.rootView = AnyView(EmptyView())
        statusItem.button?.target = nil
        statusItem.button?.action = nil
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    /// Opens the dropdown anchored below the icon; used by every external
    /// entry point (menu bar click, dock, CLI, activation requests).
    public func showSettings() {
        guard !isStopped, !isDropdownShown else { return }
        showDropdown()
    }

    /// Clicking the icon toggles the dropdown: show when closed, close when
    /// open, and stay closed when the click itself just dismissed it.
    @objc
    func toggleDropdown(_ sender: AnyObject?) {
        guard !isStopped else { return }
        let secondsSinceDismiss = lastDismissDate.map { Date().timeIntervalSince($0) }
        switch DropdownToggleLogic.toggleAction(isShown: isDropdownShown, secondsSinceDismiss: secondsSinceDismiss) {
        case .show:
            showDropdown()
        case .close:
            dismissDropdown(animated: true)
        case .stayClosed:
            break
        }
    }

    private func showDropdown() {
        guard !isStopped, !isDropdownShown, let button = statusItem.button else { return }
        let buttonWindow = button.window
        let screen = buttonWindow?.screen ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let availableHeight = visibleFrame.height
        let maxHeight = min(GTPopoverMetrics.defaultMaxHeight, max(240, availableHeight - 80))
        let root = makeDropdownRoot(maxHeight: maxHeight)
        dropdownContent.rootView = AnyView(root)
        dropdownContent.view.layoutSubtreeIfNeeded()
        let fitting = dropdownContent.view.fittingSize
        let size = NSSize(width: GTPopoverMetrics.width, height: max(240, min(fitting.height, maxHeight)))

        // A ControlCenter-hosted item may have no window or a zero-size frame;
        // DropdownLayout falls back to the screen corner instead of bailing out.
        let buttonFrame = buttonWindow.map { $0.convertToScreen(button.frame) }
        let anchor = DropdownLayout.panelAnchor(
            iconFrame: buttonFrame,
            panelSize: size,
            visibleFrame: visibleFrame
        )
        button.setAccessibilityExpanded(true)
        dropdownPanel.present(anchorTopLeft: anchor, size: size)
    }

    private func dismissDropdown(animated: Bool) {
        buttonAccessibilityExpanded(false)
        dropdownPanel.dismiss(animated: animated)
    }

    private func buttonAccessibilityExpanded(_ expanded: Bool) {
        statusItem.button?.setAccessibilityExpanded(expanded)
    }

    private func makeDropdownRoot(maxHeight: CGFloat) -> some View {
        SettingsPopoverView(viewModel: viewModel, maxHeight: maxHeight)
            .frame(width: GTPopoverMetrics.width)
            .modifier(GTSettingsPanelChrome(cornerRadius: GTRadius.card))
    }

    @objc
    private func openSettings(_ sender: AnyObject?) {
        toggleDropdown(sender)
    }

    private func configureDropdownPanel() {
        dropdownPanel.onOutsideClick = { [weak self] in
            self?.dismissForOutsideInteraction()
        }
        // A non-activating panel resigns key whenever the app deactivates,
        // which is normal and must not close it: on a cold launch the
        // previously frontmost app often takes focus back a moment later. Only
        // a key loss while the app is still frontmost means the user moved on.
        dropdownPanel.onResignKey = { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, self.dropdownPanel.isVisible, !self.dropdownPanel.isKeyWindow else { return }
                guard NSApplication.shared.isActive else { return }
                self.dismissForOutsideInteraction()
            }
        }
    }

    private func dismissForOutsideInteraction() {
        guard !isStopped, dropdownPanel.isVisible else { return }
        lastDismissDate = Date()
        buttonAccessibilityExpanded(false)
        dropdownPanel.dismiss(animated: true)
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.action = #selector(openSettings(_:))
        button.target = self
        applyStatus(viewModel.status)
    }

}
