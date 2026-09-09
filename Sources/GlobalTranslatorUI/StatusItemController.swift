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
    private var resignActiveObserver: NSObjectProtocol?

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
        // Fallback dismissal: if the user switches to another app through a
        // path that bypasses the mouse monitors (Mission Control, etc.), the
        // panel still folds away.
        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.dropdownPanel.isVisible else { return }
                self.lastDismissDate = Date()
                self.dropdownPanel.dismiss(animated: true)
            }
        }
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
        if let resignActiveObserver {
            NotificationCenter.default.removeObserver(resignActiveObserver)
            self.resignActiveObserver = nil
        }
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
        guard !isStopped, !isDropdownShown, let button = statusItem.button, let window = button.window else { return }
        let screen = window.screen ?? NSScreen.main
        let availableHeight = screen?.visibleFrame.height ?? 800
        let maxHeight = min(GTPopoverMetrics.defaultMaxHeight, max(240, availableHeight - 80))
        let root = makeDropdownRoot(maxHeight: maxHeight)
        dropdownContent.rootView = AnyView(root)
        dropdownContent.view.layoutSubtreeIfNeeded()
        let fitting = dropdownContent.view.fittingSize
        let size = NSSize(width: GTPopoverMetrics.width, height: max(240, min(fitting.height, maxHeight)))

        let buttonFrame = window.convertToScreen(button.frame)
        let originX = DropdownLayout.panelOriginX(
            iconMidX: buttonFrame.midX,
            panelWidth: size.width,
            visibleFrame: screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(
                x: 0, y: 0, width: 1440, height: 900
            )
        )
        // The panel hangs directly below the icon's bottom edge.
        let anchor = NSPoint(x: originX, y: buttonFrame.minY)
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
        let cornerRadius = GTRadius.card
        return SettingsPopoverView(viewModel: viewModel, maxHeight: maxHeight)
            .frame(width: GTPopoverMetrics.width)
            .background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(GTColor.panelBackground))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(GTColor.hairline, lineWidth: GTControlMetrics.fieldStrokeWidth)
            )
    }

    @objc
    private func openSettings(_ sender: AnyObject?) {
        toggleDropdown(sender)
    }

    private func configureDropdownPanel() {
        let handleOutsideDismissal = { [weak self] in
            guard let self, self.dropdownPanel.isVisible else { return }
            self.lastDismissDate = Date()
            self.buttonAccessibilityExpanded(false)
            self.dropdownPanel.dismiss(animated: true)
        }
        dropdownPanel.onResignKey = handleOutsideDismissal
        dropdownPanel.onOutsideClick = handleOutsideDismissal
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.action = #selector(openSettings(_:))
        button.target = self
        applyStatus(viewModel.status)
    }

}
