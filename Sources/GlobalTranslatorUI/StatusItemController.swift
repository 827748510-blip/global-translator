import AppKit
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
/// (`fullScreenAuxiliary`), never activates the app, uses a single-layer
/// Liquid Glass shell (or solid fallback under Reduce Transparency), and
/// animates cleanly with `Esc` support.
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
    private var dropdownShownAt: Date?
    private var currentMaxHeight: CGFloat = GTPopoverMetrics.defaultMaxHeight
    private var modalPickerDepth = 0
    private var workspaceObservers: [NSObjectProtocol] = []
    private var appObservers: [NSObjectProtocol] = []
    /// Owns the cold-launch focus exemption. Reopening or closing the panel
    /// disarms it, so a stale exemption cannot swallow a later app switch.
    private var launchExemption = LaunchFocusExemption()

    private(set) var isStopped = false

    var statusItemAutosaveName: String? { statusItem.autosaveName }
    var requestsStatusItemVisibility: Bool { statusItem.isVisible }
    var isDropdownShown: Bool { dropdownPanel.isVisible }
    public var isDropdownVisible: Bool { dropdownPanel.isVisible }
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
        viewModel.onStatusChange = { [weak self] status in
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
        viewModel.onStatusChange = nil
        viewModel.cancelRecordingScreenshotHotkey()
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObservers = []
        for observer in appObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        appObservers = []
        dropdownPanel.onResignKey = nil
        dropdownPanel.onOutsideClick = nil
        dropdownPanel.onEscape = nil
        dropdownPanel.shouldHandleEscape = nil
        dropdownPanel.dismiss(animated: false)
        dropdownContent.rootView = AnyView(EmptyView())
        statusItem.button?.target = nil
        statusItem.button?.action = nil
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    /// Opens the dropdown anchored below the icon; used by every external
    /// entry point (menu bar click, dock, CLI, activation requests).
    public func showSettings() {
        showSettings(fromLaunch: false)
    }

    /// - Parameter fromLaunch: marks a cold-launch request. The first foreign
    ///   app activation afterwards is the launch focus bounce, not a user
    ///   decision, so it is ignored once. Any other open explicitly disarms the
    ///   exemption: a panel the user closed and reopened must not inherit it.
    public func showSettings(fromLaunch: Bool) {
        guard !isStopped else { return }
        if isDropdownShown {
            dropdownPanel.makeKeyAndOrderFront(nil)
            return
        }
        if fromLaunch {
            launchExemption.armForLaunch()
        } else {
            launchExemption.disarm()
        }
        showDropdown()
    }

    public func beginModalPicker() {
        modalPickerDepth += 1
    }

    public func endModalPicker(restoreFocus: Bool) {
        modalPickerDepth = max(0, modalPickerDepth - 1)
        if restoreFocus, modalPickerDepth == 0, dropdownPanel.isVisible {
            dropdownPanel.makeKeyAndOrderFront(nil)
        }
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
        let (anchor, size, maxHeight) = resolvedLayout(for: button)
        currentMaxHeight = maxHeight
        let root = makeDropdownRoot(maxHeight: maxHeight)
        dropdownContent.rootView = AnyView(root)
        dropdownContent.view.layoutSubtreeIfNeeded()
        let fitting = dropdownContent.view.fittingSize
        let resolvedSize = NSSize(width: GTPopoverMetrics.width, height: max(240, min(fitting.height, maxHeight)))

        let buttonWindow = button.window
        let screen = buttonWindow?.screen ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let screenFrame = screen?.frame ?? visibleFrame
        let buttonFrame = buttonWindow.map { $0.convertToScreen(button.frame) }
        let resolvedAnchor = DropdownLayout.panelAnchor(
            iconFrame: buttonFrame,
            panelSize: resolvedSize,
            visibleFrame: visibleFrame,
            screenFrame: screenFrame
        )
        _ = anchor
        _ = size
        button.setAccessibilityExpanded(true)
        dropdownPanel.present(anchorTopLeft: resolvedAnchor, size: resolvedSize)
        dropdownShownAt = Date()
    }

    private func resolvedLayout(for button: NSStatusBarButton) -> (anchor: CGPoint, size: NSSize, maxHeight: CGFloat) {
        let buttonWindow = button.window
        let screen = buttonWindow?.screen ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let availableHeight = visibleFrame.height
        let maxHeight = min(GTPopoverMetrics.defaultMaxHeight, max(240, availableHeight - 80))
        let size = NSSize(width: GTPopoverMetrics.width, height: maxHeight)
        let buttonFrame = buttonWindow.map { $0.convertToScreen(button.frame) }
        let screenFrame = screen?.frame ?? visibleFrame
        let anchor = DropdownLayout.panelAnchor(
            iconFrame: buttonFrame,
            panelSize: size,
            visibleFrame: visibleFrame,
            screenFrame: screenFrame
        )
        return (anchor, size, maxHeight)
    }

    private func dismissDropdown(animated: Bool) {
        viewModel.cancelRecordingScreenshotHotkey()
        buttonAccessibilityExpanded(false)
        dropdownPanel.dismiss(animated: animated)
    }

    private func buttonAccessibilityExpanded(_ expanded: Bool) {
        statusItem.button?.setAccessibilityExpanded(expanded)
    }

    private func makeDropdownRoot(maxHeight: CGFloat) -> some View {
        SettingsPopoverView(
            viewModel: viewModel,
            maxHeight: maxHeight,
            onPreferredHeightChange: { [weak self] preferredHeight in
                guard let self, self.dropdownPanel.isVisible else { return }
                let clamped = max(240, min(preferredHeight, self.currentMaxHeight))
                self.dropdownPanel.updateHeight(clamped)
            }
        )
        .frame(width: GTPopoverMetrics.width)
        .modifier(GTSettingsPanelChrome(cornerRadius: GTRadius.card))
    }

    @objc
    private func openSettings(_ sender: AnyObject?) {
        toggleDropdown(sender)
    }

    private func configureDropdownPanel() {
        dropdownPanel.onOutsideClick = { [weak self] in
            guard let self, self.modalPickerDepth == 0 else { return }
            self.dismissForOutsideInteraction()
        }
        dropdownPanel.shouldHandleEscape = { [weak self] in
            !(self?.viewModel.isRecordingScreenshotHotkey ?? false)
        }
        dropdownPanel.onEscape = { [weak self] in
            self?.dismissForOutsideInteraction()
        }
        // A non-activating panel resigns key whenever the app deactivates,
        // which is normal and must not close it: on a cold launch the
        // previously frontmost app often takes focus back a moment later. Only
        // a key loss while the app is still frontmost means the user moved on.
        dropdownPanel.onResignKey = { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, self.modalPickerDepth == 0 else { return }
                guard self.dropdownPanel.isVisible, !self.dropdownPanel.isKeyWindow else { return }
                guard NSApplication.shared.isActive else { return }
                self.dismissForOutsideInteraction()
            }
        }
        configureWorkspaceFocusObservers()
        configureScreenParameterObserver()
    }

    private func configureScreenParameterObserver() {
        let observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.repositionDropdownIfVisible()
            }
        }
        appObservers.append(observer)
    }

    private func repositionDropdownIfVisible() {
        guard !isStopped, dropdownPanel.isVisible, let button = statusItem.button else { return }
        let buttonWindow = button.window
        let screen = buttonWindow?.screen ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        currentMaxHeight = min(GTPopoverMetrics.defaultMaxHeight, max(240, visibleFrame.height - 80))
        let clampedHeight = max(240, min(dropdownPanel.frame.height, currentMaxHeight))
        let size = NSSize(width: GTPopoverMetrics.width, height: clampedHeight)
        let buttonFrame = buttonWindow.map { $0.convertToScreen(button.frame) }
        let screenFrame = screen?.frame ?? visibleFrame
        let anchor = DropdownLayout.panelAnchor(
            iconFrame: buttonFrame,
            panelSize: size,
            visibleFrame: visibleFrame,
            screenFrame: screenFrame
        )
        dropdownPanel.setFrame(
            NSRect(x: anchor.x, y: anchor.y - size.height, width: size.width, height: size.height),
            display: true
        )
    }

    /// Cmd-Tab and space switching never produce a mouse-down, so the outside
    /// click monitors cannot see them. Watch app activation and space changes
    /// directly, while letting launch-time focus churn settle first.
    private func configureWorkspaceFocusObservers() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, self.dropdownPanel.isVisible, self.modalPickerDepth == 0 else { return }
            let activated = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let isOwn = activated?.bundleIdentifier == Bundle.main.bundleIdentifier
            guard !isOwn else { return }
            // A cold launch hands focus back to the previously frontmost app
            // once; that bounce is not the user leaving. The exemption is
            // consumed on the first consultation and expires after a few
            // seconds, so it cannot mask a real switch later.
            if self.launchExemption.consumeIfBounce(
                shownAt: self.dropdownShownAt,
                now: Date()
            ) {
                return
            }
            guard DropdownFocusPolicy.shouldDismiss(
                shownAt: self.dropdownShownAt,
                now: Date(),
                isOwnApplication: false
            ) else { return }
            self.dismissForOutsideInteraction()
        })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Switching spaces cannot be launch noise; the panel is allowed to
            // follow spaces, but leaving one is a deliberate move away.
            guard let self, self.dropdownPanel.isVisible else { return }
            self.dismissForOutsideInteraction()
        })
    }

    private func dismissForOutsideInteraction() {
        guard !isStopped, dropdownPanel.isVisible else { return }
        // Closing ends whatever the launch exemption was protecting: the next
        // open is a deliberate user action and must be dismissible at once.
        launchExemption.disarm()
        lastDismissDate = Date()
        viewModel.cancelRecordingScreenshotHotkey()
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
