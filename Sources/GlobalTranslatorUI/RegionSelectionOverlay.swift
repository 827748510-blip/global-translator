import AppKit
import SwiftUI
import GlobalTranslatorCore

@MainActor
public protocol RegionSelectionPresenting: AnyObject {
    var isSelecting: Bool { get }
    func selectRegion() async -> RegionSelectionOutcome
    func cancel()
}

@MainActor
public final class NullRegionSelector: RegionSelectionPresenting {
    public var isSelecting: Bool { false }
    public init() {}
    public func selectRegion() async -> RegionSelectionOutcome { .cancelled }
    public func cancel() {}
}

/// Full-screen dimmed overlay for dragging a screenshot region.
/// Uses `.nonactivatingPanel` so the user's frontmost app stays active, while
/// allowing key status so `Esc` (`cancelOperation`) works even without
/// Accessibility permission.
public final class RegionSelectionPanel: NSPanel {
    public var onEscape: (() -> Void)?

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
        hasShadow = false
        ignoresMouseEvents = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
    }

    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { false }

    public override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}

final class RegionSelectionCanvas: NSView {
    var selectionRectInScreen: CGRect = .zero {
        didSet {
            guard oldValue != selectionRectInScreen else { return }
            guard let window else {
                needsDisplay = true
                return
            }
            let oldLocal = oldValue.isEmpty ? .zero : window.convertFromScreen(oldValue)
            let newLocal = selectionRectInScreen.isEmpty ? .zero : window.convertFromScreen(selectionRectInScreen)
            let dirty: CGRect
            if oldLocal.isEmpty {
                dirty = newLocal
            } else if newLocal.isEmpty {
                dirty = oldLocal
            } else {
                dirty = oldLocal.union(newLocal)
            }
            if dirty.isEmpty {
                needsDisplay = true
            } else {
                setNeedsDisplay(dirty.insetBy(dx: -80, dy: -36))
            }
        }
    }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let dim = NSBezierPath(rect: bounds)
        if let window, selectionRectInScreen.width > 0, selectionRectInScreen.height > 0 {
            let local = window.convertFromScreen(selectionRectInScreen)
            dim.append(NSBezierPath(rect: local))
            dim.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.4).setFill()
            dim.fill()

            // Outer dark halo + inner white border ensures high contrast on both
            // bright white pages and dark video frames.
            let outer = NSBezierPath(rect: local.insetBy(dx: -0.5, dy: -0.5))
            outer.lineWidth = 1
            NSColor.black.withAlphaComponent(0.65).setStroke()
            outer.stroke()

            let inner = NSBezierPath(rect: local)
            inner.lineWidth = 1
            NSColor.white.setStroke()
            inner.stroke()

            drawSizeBadge(for: local)
        } else {
            NSColor.black.withAlphaComponent(0.4).setFill()
            dim.fill()
        }
    }

    private func drawSizeBadge(for local: CGRect) {
        let width = Int(local.width.rounded())
        let height = Int(local.height.rounded())
        guard width > 0, height > 0 else { return }
        let label = "\(width) × \(height)" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let textSize = label.size(withAttributes: attributes)
        let padX: CGFloat = 6
        let padY: CGFloat = 3
        let badgeSize = CGSize(width: ceil(textSize.width) + padX * 2, height: ceil(textSize.height) + padY * 2)
        let preferredY = local.minY - badgeSize.height - 6
        let badgeY = preferredY >= bounds.minY + 4 ? preferredY : min(local.maxY + 6, bounds.maxY - badgeSize.height - 4)
        let badgeX = min(max(local.minX, bounds.minX + 4), max(bounds.minX + 4, bounds.maxX - badgeSize.width - 4))
        let badgeRect = CGRect(origin: CGPoint(x: badgeX, y: badgeY), size: badgeSize)
        let pill = NSBezierPath(roundedRect: badgeRect, xRadius: 4, yRadius: 4)
        NSColor.black.withAlphaComponent(0.72).setFill()
        pill.fill()
        label.draw(at: CGPoint(x: badgeRect.minX + padX, y: badgeRect.minY + padY), withAttributes: attributes)
    }
}

@MainActor
public final class RegionSelectionOverlayController: RegionSelectionPresenting {
    private var panels: [RegionSelectionPanel] = []
    private var canvases: [RegionSelectionCanvas] = []
    private var hintViews: [NSView] = []
    nonisolated(unsafe) private var eventMonitors: [Any] = []
    private var drag = ScreenshotRegionDrag()
    private var activeScreenFrame: CGRect?
    private var continuation: CheckedContinuation<RegionSelectionOutcome, Never>?
    private var didPushCursor = false
    private let screensProvider: () -> [NSScreen]

    public init(screensProvider: @escaping () -> [NSScreen] = { NSScreen.screens }) {
        self.screensProvider = screensProvider
    }

    deinit {
        for monitor in eventMonitors { NSEvent.removeMonitor(monitor) }
    }

    public func selectRegion() async -> RegionSelectionOutcome {
        cancel()
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            showOverlay()
        }
    }

    public func cancel() {
        finish(.cancelled)
    }

    public var isSelecting: Bool { continuation != nil }

    /// Test seam: same geometry as mouse monitors.
    public func handlePointerForTesting(_ phase: SelectionPointerPhase, at location: CGPoint) {
        handlePointer(phase, at: location)
    }

    /// Test seam: clamped screen selection rect currently drawn on canvases.
    public var displayedSelectionRectForTesting: CGRect {
        canvases.first?.selectionRectInScreen ?? clampedPreviewRect()
    }

    private func showOverlay() {
        drag.cancel()
        activeScreenFrame = nil
        let screens = screensProvider()
        let mouseLocation = NSEvent.mouseLocation
        var panels: [RegionSelectionPanel] = []
        var canvases: [RegionSelectionCanvas] = []
        var hintViews: [NSView] = []
        var keyPanel: RegionSelectionPanel?
        for screen in screens {
            let panel = RegionSelectionPanel(contentRect: screen.frame)
            panel.onEscape = { [weak self] in self?.finish(.cancelled) }
            let canvas = RegionSelectionCanvas(frame: CGRect(origin: .zero, size: screen.frame.size))
            canvas.autoresizingMask = [.width, .height]
            let hosting = NSHostingView(rootView: RegionSelectionHintView(onCancel: { [weak self] in
                self?.finish(.cancelled)
            }))
            hosting.translatesAutoresizingMaskIntoConstraints = false
            canvas.addSubview(hosting)
            let notchInset = max(CGFloat(0), screen.frame.maxY - screen.visibleFrame.maxY)
            let topOffset = max(CGFloat(16), notchInset + 16)
            NSLayoutConstraint.activate([
                hosting.centerXAnchor.constraint(equalTo: canvas.centerXAnchor),
                hosting.topAnchor.constraint(equalTo: canvas.topAnchor, constant: topOffset)
            ])
            panel.contentView = canvas
            if screen.frame.contains(mouseLocation), keyPanel == nil {
                keyPanel = panel
                panel.makeKeyAndOrderFront(nil)
            } else {
                panel.orderFrontRegardless()
            }
            panels.append(panel)
            canvases.append(canvas)
            hintViews.append(hosting)
        }
        if keyPanel == nil, let first = panels.first {
            first.makeKeyAndOrderFront(nil)
        }
        self.panels = panels
        self.canvases = canvases
        self.hintViews = hintViews
        NSCursor.crosshair.push()
        didPushCursor = true
        startMonitors()
    }

    private func startMonitors() {
        stopMonitors()
        var monitors: [Any] = []
        let mouseMask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mouseMask, handler: { [weak self] event in
            let phase = Self.phase(event.type)
            let location = NSEvent.mouseLocation
            guard let self else { return }
            assert(Thread.isMainThread)
            MainActor.assumeIsolated {
                self.handlePointer(phase, at: location)
            }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mouseMask, handler: { [weak self] event in
            let phase = Self.phase(event.type)
            let location = NSEvent.mouseLocation
            guard let self else { return event }
            assert(Thread.isMainThread)
            MainActor.assumeIsolated {
                self.handlePointer(phase, at: location)
            }
            return event
        }) {
            monitors.append(local)
        }
        if let rightGlobal = NSEvent.addGlobalMonitorForEvents(matching: .rightMouseDown, handler: { [weak self] _ in
            guard let self else { return }
            assert(Thread.isMainThread)
            MainActor.assumeIsolated { self.finish(.cancelled) }
        }) {
            monitors.append(rightGlobal)
        }
        if let rightLocal = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown, handler: { [weak self] event in
            guard let self else { return event }
            assert(Thread.isMainThread)
            MainActor.assumeIsolated { self.finish(.cancelled) }
            return nil
        }) {
            monitors.append(rightLocal)
        }
        if let escapeGlobal = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == KeyboardShortcutSpec.KeyCode.escape else { return }
            guard let self else { return }
            assert(Thread.isMainThread)
            MainActor.assumeIsolated {
                self.finish(.cancelled)
            }
        }) {
            monitors.append(escapeGlobal)
        }
        if let escapeLocal = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == KeyboardShortcutSpec.KeyCode.escape else { return event }
            guard let self else { return event }
            assert(Thread.isMainThread)
            MainActor.assumeIsolated {
                self.finish(.cancelled)
            }
            return nil
        }) {
            monitors.append(escapeLocal)
        }
        eventMonitors = monitors
    }

    private func handlePointer(_ phase: SelectionPointerPhase, at location: CGPoint) {
        guard continuation != nil else { return }
        switch phase {
        case .down:
            let screens = screensProvider().map(\.frame)
            activeScreenFrame = RegionCaptureGeometry.owningScreenFrame(for: location, in: screens)
            drag.begin(at: location)
            updateCanvases()
        case .dragged:
            drag.move(to: location)
            updateCanvases()
        case .up:
            guard let outcome = drag.completePointerUp(clampedTo: activeScreenFrame) else { return }
            finish(outcome)
        }
    }

    private func clampedPreviewRect() -> CGRect {
        guard drag.isDragging else { return .zero }
        let raw = drag.screenRect
        guard let activeScreenFrame else { return raw }
        return raw.intersection(activeScreenFrame)
    }

    private func updateCanvases() {
        let rect = clampedPreviewRect()
        let hideHints = drag.isDragging
        for hint in hintViews {
            hint.isHidden = hideHints
        }
        for canvas in canvases {
            canvas.selectionRectInScreen = rect
        }
    }

    private func finish(_ outcome: RegionSelectionOutcome) {
        guard continuation != nil else {
            hideOverlay()
            return
        }
        let pending = continuation
        continuation = nil
        hideOverlay()
        pending?.resume(returning: outcome)
    }

    private func hideOverlay() {
        stopMonitors()
        drag.cancel()
        activeScreenFrame = nil
        for panel in panels {
            panel.orderOut(nil)
        }
        panels = []
        canvases = []
        hintViews = []
        if didPushCursor {
            NSCursor.pop()
            didPushCursor = false
        }
    }

    private func stopMonitors() {
        for monitor in eventMonitors { NSEvent.removeMonitor(monitor) }
        eventMonitors = []
    }

    private static func phase(_ type: NSEvent.EventType) -> SelectionPointerPhase {
        switch type {
        case .leftMouseDown:
            return .down
        case .leftMouseDragged:
            return .dragged
        default:
            return .up
        }
    }
}

private struct RegionSelectionHintView: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var onCancel: () -> Void

    var body: some View {
        HStack(spacing: GTSpacing.small) {
            Text(ScreenshotTranslateSupport.overlayHintCopy)
                .font(GTType.body)
                .foregroundStyle(Color.white)
            Button("取消", action: onCancel)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(Color.white)
                .accessibilityLabel("取消截图翻译")
                .accessibilityHint("按下 Esc 或点击取消退出截图区域选择")
        }
        .padding(.horizontal, GTSpacing.medium)
        .padding(.vertical, GTSpacing.xSmall)
        .background(Color.black.opacity(reduceTransparency ? 0.92 : 0.72))
        .clipShape(RoundedRectangle(cornerRadius: GTRadius.row, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: GTRadius.row, style: .continuous)
                .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
    }
}
