import AppKit
import Combine
import SwiftUI

/// Owns the NSStatusItem and its transient settings NSPopover.
/// Accessory-friendly: no Dock icon or app activation is assumed anywhere.
@MainActor
public final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let hostingController: NSHostingController<SettingsPopoverView>
    private let viewModel: SettingsViewModel
    private var statusCancellable: AnyCancellable?

    private(set) var isStopped = false

    public var isPopoverShown: Bool {
        popover.isShown
    }

    var statusItemAutosaveName: String? { statusItem.autosaveName }
    var requestsStatusItemVisibility: Bool { statusItem.isVisible }

    public init(viewModel: SettingsViewModel) {
        self.viewModel = viewModel
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.popover = NSPopover()
        self.hostingController = NSHostingController(
            rootView: SettingsPopoverView(viewModel: viewModel)
        )
        super.init()
        statusItem.autosaveName = "com.maodashu.global-translator.status"
        statusItem.isVisible = true
        configureStatusItem()
        configurePopover()
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
        popover.performClose(nil)
        statusItem.button?.target = nil
        statusItem.button?.action = nil
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    @objc
    private func togglePopover(_ sender: AnyObject?) {
        guard !isStopped else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else if let button = statusItem.button {
            updatePopoverContentSize()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.action = #selector(togglePopover(_:))
        button.target = self
        applyStatus(viewModel.status)
    }

    private func configurePopover() {
        popover.behavior = .transient // clicking outside closes
        popover.animates = true
        popover.contentViewController = hostingController
        popover.contentSize = NSSize(
            width: GTPopoverMetrics.width,
            height: GTPopoverMetrics.defaultMaxHeight
        )
    }

    /// Sizes the popover to its content, capped by the usable screen height so
    /// the inner ScrollView handles overflow instead of clipping.
    private func updatePopoverContentSize() {
        let fitting = hostingController.sizeThatFits(
            in: CGSize(width: GTPopoverMetrics.width, height: .greatestFiniteMagnitude)
        )
        let screenCap = statusItem.button?.window?.screen?.visibleFrame.height
            ?? NSScreen.main?.visibleFrame.height
            ?? GTPopoverMetrics.defaultMaxHeight
        let heightCap = max(240, screenCap - GTSpacing.xLarge * 2)
        popover.contentSize = NSSize(
            width: GTPopoverMetrics.width,
            height: min(ceil(fitting.height), heightCap)
        )
    }
}
