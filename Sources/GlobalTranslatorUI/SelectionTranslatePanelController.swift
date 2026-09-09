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
    var onTranslate: (() -> Void)? { get set }
    var onOptimize: (() -> Void)? { get set }
    var onOptimizeModeChange: ((PromptOptimizeMode) -> Void)? { get set }
    var optimizeMode: PromptOptimizeMode { get set }
    var copyFeedback: SelectionCopyFeedback { get }
    func show(_ content: SelectionPopoverContent)
    func dismiss()
}

@MainActor
public final class NullSelectionPopover: SelectionPopoverControlling {
    public private(set) var currentContent: SelectionPopoverContent?
    public var panelFrame: CGRect? { nil }
    public var onUserDismiss: (() -> Void)?
    public var onTranslate: (() -> Void)?
    public var onOptimize: (() -> Void)?
    public var onOptimizeModeChange: ((PromptOptimizeMode) -> Void)?
    public var optimizeMode: PromptOptimizeMode = .generativePrompt
    public var copyFeedback: SelectionCopyFeedback { .idle }
    public init() {}
    public func show(_ content: SelectionPopoverContent) { currentContent = content }
    public func dismiss() { currentContent = nil }
}

@MainActor
public final class SelectionTranslatePanelController: SelectionPopoverControlling {
    public private(set) var currentContent: SelectionPopoverContent?
    public var onCopy: ((String) -> Void)?
    public var onUserDismiss: (() -> Void)?
    public var onTranslate: (() -> Void)?
    public var onOptimize: (() -> Void)?
    public var onOptimizeModeChange: ((PromptOptimizeMode) -> Void)?
    public var optimizeMode: PromptOptimizeMode = .generativePrompt {
        didSet {
            guard oldValue != optimizeMode, currentContent != nil else { return }
            presentCurrent(resize: true)
        }
    }
    public private(set) var copyFeedback: SelectionCopyFeedback = .idle

    private var panel: SelectionTranslatePanel?
    private let visibleFramesProvider: () -> [CGRect]
    private let pasteboardWriter: (String) throws -> Void
    private let copyFeedbackDelay: Duration
    private var copyFeedbackTask: Task<Void, Never>?

    public var panelFrame: CGRect? { panel?.isVisible == true ? panel?.frame : nil }

    public init(
        visibleFramesProvider: @escaping () -> [CGRect] = { NSScreen.screens.map(\.visibleFrame) },
        pasteboardWriter: @escaping (String) throws -> Void = { text in
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            guard pasteboard.setString(text, forType: .string) else {
                throw SelectionCopyError.writeFailed
            }
        },
        copyFeedbackDelay: Duration = .milliseconds(SelectionTranslateSupport.copyFeedbackMilliseconds)
    ) {
        self.visibleFramesProvider = visibleFramesProvider
        self.pasteboardWriter = pasteboardWriter
        self.copyFeedbackDelay = copyFeedbackDelay
    }

    public func show(_ content: SelectionPopoverContent) {
        copyFeedbackTask?.cancel()
        copyFeedback = .idle
        currentContent = content
        presentCurrent(resize: true)
    }

    private func presentCurrent(resize: Bool) {
        guard let content = currentContent else { return }
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
        let hosting = NSHostingView(rootView: SelectionTranslatePopoverView(
            content: content,
            optimizeMode: optimizeMode,
            copyFeedback: copyFeedback,
            onCopy: { [weak self] in self?.copyCurrentTranslation() },
            onTranslate: { [weak self] in self?.onTranslate?() },
            onOptimize: { [weak self] in self?.onOptimize?() },
            onOptimizeModeChange: { [weak self] mode in
                self?.optimizeMode = mode
                self?.onOptimizeModeChange?(mode)
            }
        ))
        if let panel {
            panel.contentView = hosting
            if resize {
                panel.setFrame(frame, display: true)
            }
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
        copyFeedbackTask?.cancel()
        copyFeedbackTask = nil
        copyFeedback = .idle
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
    /// (or the original when the status is 已是中文 / 无需翻译).
    public func copyCurrentTranslation() {
        guard let current = currentContent, current.allowsCopy else { return }
        let text = current.copyText
        do {
            try pasteboardWriter(text)
            onCopy?(text)
            applyCopyFeedback(.copied)
        } catch {
            applyCopyFeedback(.failed)
        }
    }

    private func applyCopyFeedback(_ feedback: SelectionCopyFeedback) {
        copyFeedbackTask?.cancel()
        copyFeedback = feedback
        presentCurrent(resize: true)
        copyFeedbackTask = Task { @MainActor [weak self] in
            guard let delay = self?.copyFeedbackDelay else { return }
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.copyFeedback = .idle
            if self.currentContent != nil {
                self.presentCurrent(resize: true)
            }
        }
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
        if content.showsOptimizeAction {
            height += GTSpacing.xSmall + GTSelectionMetrics.modePickerHeight
        }
        if content.showsActionButtons {
            height += GTSpacing.xSmall + 28
        }
        return CGSize(width: GTSelectionMetrics.width, height: max(height, 44))
    }
}
