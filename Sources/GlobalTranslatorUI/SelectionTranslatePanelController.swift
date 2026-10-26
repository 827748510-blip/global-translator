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
        // NSEvent monitors run on the main thread. Never capture `event` inside
        // assumeIsolated, and never hop a `work` closure across DispatchQueue.main.sync.
        let outside: (NSEvent) -> Void = { [weak self] _ in
            let location = NSEvent.mouseLocation
            guard let self else { return }
            assert(Thread.isMainThread)
            let panel = self
            _ = MainActor.assumeIsolated {
                guard panel.isVisible else { return false }
                if panel.containsOwnedUI(at: location) { return false }
                panel.onOutsideClick?()
                return true
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
                let location = NSEvent.mouseLocation
                guard let self else { return event }
                assert(Thread.isMainThread)
                let panel = self
                _ = MainActor.assumeIsolated {
                    guard panel.isVisible else { return false }
                    if panel.containsOwnedUI(at: location) { return false }
                    panel.onOutsideClick?()
                    return true
                }
                return event
            }
        ) {
            monitors.append(local)
        }
        if let escapeGlobal = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            let isEscape = event.keyCode == 53
            guard isEscape else { return }
            guard let self else { return }
            assert(Thread.isMainThread)
            let panel = self
            _ = MainActor.assumeIsolated {
                guard panel.isVisible else { return false }
                if panel.hasOwnedMenuOpen() { return false }
                panel.onEscape?()
                return true
            }
        }) {
            monitors.append(escapeGlobal)
        }
        if let escapeLocal = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            let isEscape = event.keyCode == 53
            guard isEscape else { return event }
            guard let self else { return event }
            assert(Thread.isMainThread)
            let panel = self
            let consume = MainActor.assumeIsolated {
                guard panel.isVisible else { return false }
                if panel.hasOwnedMenuOpen() { return false }
                panel.onEscape?()
                return true
            }
            return consume ? nil : event
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

    @MainActor
    func containsOwnedUI(at location: CGPoint, windows: [NSWindow]? = nil) -> Bool {
        SelectionPopoverHitTesting.containsInteraction(
            panelFrame: frame,
            location: location,
            auxiliaryFrames: SelectionPopoverHitTesting.auxiliaryFrames(
                from: windows ?? NSApp.windows,
                excluding: self
            )
        )
    }

    @MainActor
    func hasOwnedMenuOpen(windows: [NSWindow]? = nil) -> Bool {
        let windows = windows ?? NSApp.windows
        return windows.contains { $0.isVisible && $0 !== self && $0.level == .popUpMenu }
    }
}

/// Picker menus render in a pop-up window outside the floating panel frame.
/// Clicks there must not count as "outside" dismissal.
public enum SelectionPopoverHitTesting {
    public static func containsInteraction(
        panelFrame: CGRect,
        location: CGPoint,
        auxiliaryFrames: [CGRect]
    ) -> Bool {
        if panelFrame.contains(location) { return true }
        return auxiliaryFrames.contains { $0.contains(location) }
    }

    @MainActor
    public static func auxiliaryFrames(from windows: [NSWindow], excluding panel: NSWindow) -> [CGRect] {
        windows.compactMap { window in
            guard window.isVisible, window !== panel else { return nil }
            let owned = window.level == .popUpMenu || window.parent === panel
            return owned ? window.frame : nil
        }
    }
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
    func containsInteraction(at location: CGPoint) -> Bool
}

@MainActor
public extension SelectionPopoverControlling {
    func containsInteraction(at location: CGPoint) -> Bool {
        panelFrame?.contains(location) == true
    }
}

@MainActor
public final class NullSelectionPopover: SelectionPopoverControlling {
    public private(set) var currentContent: SelectionPopoverContent?
    public var panelFrame: CGRect? { nil }
    public var onUserDismiss: (() -> Void)?
    public var onTranslate: (() -> Void)?
    public var onOptimize: (() -> Void)?
    public var onOptimizeModeChange: ((PromptOptimizeMode) -> Void)?
    public var optimizeMode: PromptOptimizeMode = .communicationPolish
    public var copyFeedback: SelectionCopyFeedback { .idle }
    public init() {}
    public func show(_ content: SelectionPopoverContent) { currentContent = content }
    public func dismiss() { currentContent = nil }
}

/// Resolved geometry for one popover presentation. `resultHeight` is the
/// visible viewport for the result; it equals the measured full height when
/// nothing needs to scroll.
struct SelectionPopoverSizing: Equatable {
    let contentSize: CGSize
    let resultHeight: CGFloat
    let isResultScrollable: Bool
}

@MainActor
public final class SelectionTranslatePanelController: SelectionPopoverControlling {
    public private(set) var currentContent: SelectionPopoverContent?
    public var onCopy: ((String) -> Void)?
    public var onUserDismiss: (() -> Void)?
    public var onTranslate: (() -> Void)?
    public var onOptimize: (() -> Void)?
    public var onOptimizeModeChange: ((PromptOptimizeMode) -> Void)?
    public var optimizeMode: PromptOptimizeMode {
        get { chrome.optimizeMode }
        set { chrome.optimizeMode = newValue }
    }
    public var copyFeedback: SelectionCopyFeedback { chrome.copyFeedback }

    private let chrome = SelectionPopoverChrome()
    private var panel: SelectionTranslatePanel?
    private let visibleFramesProvider: () -> [CGRect]
    private let pasteboardWriter: (String) throws -> Void
    private let copyFeedbackDelay: Duration
    private var copyFeedbackTask: Task<Void, Never>?
    private var copyFeedbackGeneration: UInt64 = 0

    public var panelFrame: CGRect? { panel?.isVisible == true ? panel?.frame : nil }

    public func containsInteraction(at location: CGPoint) -> Bool {
        guard let panel, panel.isVisible else { return false }
        return panel.containsOwnedUI(at: location)
    }

    /// Test seam: same path as mouse-down monitors.
    public func handlePotentialOutsideClick(at location: CGPoint, auxiliaryFrames: [CGRect]? = nil) {
        guard let panel, panel.isVisible else { return }
        let extra = auxiliaryFrames ?? SelectionPopoverHitTesting.auxiliaryFrames(from: NSApp.windows, excluding: panel)
        if SelectionPopoverHitTesting.containsInteraction(
            panelFrame: panel.frame,
            location: location,
            auxiliaryFrames: extra
        ) {
            return
        }
        notifyUserDismiss()
    }

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
        resetCopyFeedback(.idle)
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
        let maxPanelHeight = max(
            GTPopoverMetrics.minRowHitHeight,
            visibleFrame.height - GTPopoverMetrics.screenMargin * 2
        )
        let sizing = Self.sizing(for: content, maxHeight: maxPanelHeight)
        let frame = OverlayLayout.placementFrame(
            originalFrame: content.screenFrame,
            contentSize: sizing.contentSize,
            screenVisibleFrame: visibleFrame
        )
        let hosting = NSHostingView(rootView: SelectionTranslatePopoverView(
            content: content,
            chrome: chrome,
            resultHeight: sizing.resultHeight,
            isResultScrollable: sizing.isResultScrollable,
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
        resetCopyFeedback(.idle)
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

    private func resetCopyFeedback(_ feedback: SelectionCopyFeedback) {
        copyFeedbackGeneration &+= 1
        copyFeedbackTask?.cancel()
        copyFeedbackTask = nil
        chrome.copyFeedback = feedback
    }

    /// Sets copy-button chrome immediately. Does not rebuild the panel — that
    /// was resetting feedback to idle via dismissal / hosting-view replacement.
    private func applyCopyFeedback(_ feedback: SelectionCopyFeedback) {
        copyFeedbackGeneration &+= 1
        let token = copyFeedbackGeneration
        copyFeedbackTask?.cancel()
        chrome.copyFeedback = feedback
        let delay = copyFeedbackDelay
        copyFeedbackTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self, !Task.isCancelled, self.copyFeedbackGeneration == token else { return }
            self.chrome.copyFeedback = .idle
        }
    }

    public static func contentSize(for content: SelectionPopoverContent) -> CGSize {
        sizing(for: content, maxHeight: .greatestFiniteMagnitude).contentSize
    }

    /// Measures the whole result, then caps only the visible result viewport to
    /// the screen. Actions and the truncated original stay outside the scroll
    /// area, so 翻译 / 拷贝 never disappear below a long explanation.
    static func sizing(
        for content: SelectionPopoverContent,
        maxHeight: CGFloat
    ) -> SelectionPopoverSizing {
        let textWidth = GTSelectionMetrics.width - GTSelectionMetrics.horizontalPadding * 2
        let resultMeasuringFont = SelectionPopoverLayout.resultMeasuringFont(for: content.status)
        let resultLineHeight = OverlayLayout.estimatedLineHeight(for: resultMeasuringFont)
        var chromeHeight = GTSelectionMetrics.verticalPadding * 2
        if !content.originalPreview.isEmpty {
            chromeHeight += OverlayLayout.estimatedTextSize(
                for: content.originalPreview,
                maxWidth: textWidth,
                maxLines: GTSelectionMetrics.maxOriginalLines,
                font: NSFont.preferredFont(forTextStyle: .caption1)
            ).height
            chromeHeight += GTSelectionMetrics.textBlockSpacing
        }
        if let savedHint = content.savedImageHint, !savedHint.isEmpty {
            chromeHeight += GTSelectionMetrics.textBlockSpacing
            chromeHeight += OverlayLayout.estimatedTextSize(
                for: savedHint,
                maxWidth: textWidth,
                maxLines: 2,
                font: NSFont.preferredFont(forTextStyle: .caption1)
            ).height
        }
        let hasActions = content.showsOptimizeAction || content.showsActionButtons
        if hasActions {
            chromeHeight += GTSelectionMetrics.sectionSpacing
            if content.showsOptimizeAction {
                chromeHeight += GTSelectionMetrics.modePickerHeight
            }
            if content.showsActionButtons {
                if content.showsOptimizeAction {
                    chromeHeight += GTSelectionMetrics.actionsSpacing
                }
                chromeHeight += GTSelectionMetrics.actionRowHeight
            }
        }

        let fullResultHeight = max(
            resultLineHeight,
            SelectionPopoverLayout.measuredWrappedHeight(
                for: content.displayTranslation,
                width: textWidth,
                font: resultMeasuringFont
            )
        )
        let desiredHeight = chromeHeight + fullResultHeight
        let finiteMaxHeight = maxHeight.isFinite ? max(maxHeight, 1) : desiredHeight
        let availableForResult = max(0, finiteMaxHeight - chromeHeight)
        if desiredHeight <= finiteMaxHeight + 0.5 {
            return SelectionPopoverSizing(
                contentSize: CGSize(
                    width: GTSelectionMetrics.width,
                    height: max(desiredHeight, GTPopoverMetrics.minRowHitHeight)
                ),
                resultHeight: fullResultHeight,
                isResultScrollable: false
            )
        }

        let resultHeight = max(min(resultLineHeight, fullResultHeight), availableForResult)
        let totalHeight = min(chromeHeight + resultHeight, finiteMaxHeight)
        let minimumHeight = min(GTPopoverMetrics.minRowHitHeight, finiteMaxHeight)
        return SelectionPopoverSizing(
            contentSize: CGSize(
                width: GTSelectionMetrics.width,
                height: max(totalHeight, minimumHeight)
            ),
            resultHeight: resultHeight,
            isResultScrollable: true
        )
    }
}
