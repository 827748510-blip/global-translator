import AppKit
import SwiftUI
import GlobalTranslatorCore

/// Borderless floating panel for 滑词翻译. Unlike overlay bubbles this
/// panel accepts clicks (Copy) and dismisses on Escape or an outside click.
public final class SelectionTranslatePanel: NSPanel {
    public var onOutsideClick: (() -> Void)?
    public var onEscape: (() -> Void)?
    private var eventMonitors: [Any] = []

    public override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask = [.borderless, .nonactivatingPanel],
        backing bufferingType: NSWindow.BackingStoreType = .buffered,
        defer flag: Bool = false
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: bufferingType,
            defer: flag
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
    }

    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { false }

    func startDismissalMonitors() {
        guard eventMonitors.isEmpty else { return }
        var monitors: [Any] = []
        let outside: (NSEvent) -> Void = { [weak self] _ in
            guard let self, self.isVisible else { return }
            if !self.frame.contains(NSEvent.mouseLocation) {
                self.onOutsideClick?()
            }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown],
            handler: outside
        ) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown],
            handler: { [weak self] event in
                guard let self, self.isVisible, !self.frame.contains(NSEvent.mouseLocation) else { return event }
                self.onOutsideClick?()
                return event
            }
        ) {
            monitors.append(local)
        }
        if let escapeGlobal = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == 53 else { return }
            self?.onEscape?()
        }) {
            monitors.append(escapeGlobal)
        }
        if let escapeLocal = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == 53 else { return event }
            self?.onEscape?()
            return nil
        }) {
            monitors.append(escapeLocal)
        }
        eventMonitors = monitors
    }

    func stopDismissalMonitors() {
        for monitor in eventMonitors { NSEvent.removeMonitor(monitor) }
        eventMonitors = []
    }

    var dismissalMonitorCount: Int { eventMonitors.count }
}

@MainActor
public protocol SelectionPopoverControlling: AnyObject {
    var currentContent: SelectionPopoverContent? { get }
    var panelFrame: CGRect? { get }
    var onUserDismiss: (() -> Void)? { get set }
    func show(_ content: SelectionPopoverContent)
    func dismiss()
}

@MainActor
public final class NullSelectionPopover: SelectionPopoverControlling {
    public private(set) var currentContent: SelectionPopoverContent?
    public var panelFrame: CGRect? { nil }
    public var onUserDismiss: (() -> Void)?
    public init() {}
    public func show(_ content: SelectionPopoverContent) { currentContent = content }
    public func dismiss() { currentContent = nil }
}

@MainActor
public final class SelectionTranslatePanelController: SelectionPopoverControlling {
    public private(set) var currentContent: SelectionPopoverContent?
    public var onCopy: ((String) -> Void)?
    public var onUserDismiss: (() -> Void)?

    private var panel: SelectionTranslatePanel?
    private let visibleFramesProvider: () -> [CGRect]
    private let pasteboardWriter: (String) -> Void

    public var panelFrame: CGRect? { panel?.isVisible == true ? panel?.frame : nil }

    public init(
        visibleFramesProvider: @escaping () -> [CGRect] = { NSScreen.screens.map(\.visibleFrame) },
        pasteboardWriter: @escaping (String) -> Void = { text in
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
    ) {
        self.visibleFramesProvider = visibleFramesProvider
        self.pasteboardWriter = pasteboardWriter
    }

    public func show(_ content: SelectionPopoverContent) {
        currentContent = content
        let visibleFrames = visibleFramesProvider()
        let origin = content.screenFrame.origin
        guard let visibleFrame = OverlayLayout.owningVisibleFrame(for: origin, in: visibleFrames) else {
            dismiss()
            return
        }
        let size = Self.contentSize(for: content)
        let frame = OverlayLayout.placementFrame(
            originalFrame: content.screenFrame,
            contentSize: size,
            screenVisibleFrame: visibleFrame
        )
        let hosting = NSHostingView(rootView: SelectionTranslatePopoverView(content: content, onCopy: { [weak self] in
            self?.copyCurrentTranslation()
        }))
        if let panel {
            panel.contentView = hosting
            panel.setFrame(frame, display: true)
            if !panel.isVisible {
                panel.startDismissalMonitors()
                panel.orderFrontRegardless()
            }
        } else {
            let panel = SelectionTranslatePanel(contentRect: frame)
            panel.onOutsideClick = { [weak self] in self?.notifyUserDismiss() }
            panel.onEscape = { [weak self] in self?.notifyUserDismiss() }
            panel.contentView = hosting
            self.panel = panel
            panel.startDismissalMonitors()
            panel.orderFrontRegardless()
        }
    }

    public func dismiss() {
        currentContent = nil
        panel?.stopDismissalMonitors()
        panel?.orderOut(nil)
    }

    /// Escape and outside click: tell the app to suppress this selection, then hide.
    public func notifyUserDismiss() {
        onUserDismiss?()
        dismiss()
    }

    /// Test seam and Copy button path: writes the displayed translation
    /// (or the original when the status is 已是中文).
    public func copyCurrentTranslation() {
        guard let current = currentContent, current.allowsCopy else { return }
        let text = current.copyText
        onCopy?(text)
        pasteboardWriter(text)
    }

    public static func contentSize(for content: SelectionPopoverContent) -> CGSize {
        let textWidth = GTSelectionMetrics.width - GTOverlayMetrics.horizontalPadding * 2
        var height = GTOverlayMetrics.verticalPadding * 2
        if !content.originalPreview.isEmpty {
            height += OverlayLayout.estimatedTextSize(
                for: content.originalPreview,
                maxWidth: textWidth,
                maxLines: GTSelectionMetrics.maxOriginalLines,
                font: NSFont.preferredFont(forTextStyle: .caption1)
            ).height
            height += GTSpacing.xSmall
        }
        height += OverlayLayout.estimatedTextSize(
            for: content.displayTranslation,
            maxWidth: textWidth,
            maxLines: GTSelectionMetrics.maxTranslationLines,
            font: NSFont.preferredFont(forTextStyle: .body)
        ).height
        if content.allowsCopy {
            height += GTSpacing.xSmall + 28
        }
        return CGSize(width: GTSelectionMetrics.width, height: max(height, 44))
    }
}
