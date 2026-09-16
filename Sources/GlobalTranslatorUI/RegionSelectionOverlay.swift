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
/// Uses `.nonactivatingPanel` so the user's frontmost app stays active.
public final class RegionSelectionPanel: NSPanel {
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

    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }
}

final class RegionSelectionCanvas: NSView {
    var selectionRectInScreen: CGRect = .zero {
        didSet { needsDisplay = true }
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
            NSColor.white.setStroke()
            let border = NSBezierPath(rect: local)
            border.lineWidth = 2
            border.stroke()
        } else {
            NSColor.black.withAlphaComponent(0.4).setFill()
            dim.fill()
        }
    }
}

@MainActor
public final class RegionSelectionOverlayController: RegionSelectionPresenting {
    private var panels: [RegionSelectionPanel] = []
    private var canvases: [RegionSelectionCanvas] = []
    private var eventMonitors: [Any] = []
    private var drag = ScreenshotRegionDrag()
    private var activeScreenFrame: CGRect?
    private var continuation: CheckedContinuation<RegionSelectionOutcome, Never>?
    private var didPushCursor = false
    private let screensProvider: () -> [NSScreen]

    public init(screensProvider: @escaping () -> [NSScreen] = { NSScreen.screens }) {
        self.screensProvider = screensProvider
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

    private func showOverlay() {
        drag.cancel()
        activeScreenFrame = nil
        let screens = screensProvider()
        var panels: [RegionSelectionPanel] = []
        var canvases: [RegionSelectionCanvas] = []
        for screen in screens {
            let panel = RegionSelectionPanel(contentRect: screen.frame)
            let canvas = RegionSelectionCanvas(frame: CGRect(origin: .zero, size: screen.frame.size))
            canvas.autoresizingMask = [.width, .height]
            let hosting = NSHostingView(rootView: RegionSelectionHintView())
            hosting.translatesAutoresizingMaskIntoConstraints = false
            canvas.addSubview(hosting)
            NSLayoutConstraint.activate([
                hosting.centerXAnchor.constraint(equalTo: canvas.centerXAnchor),
                hosting.topAnchor.constraint(equalTo: canvas.topAnchor, constant: 48)
            ])
            panel.contentView = canvas
            panel.orderFrontRegardless()
            panels.append(panel)
            canvases.append(canvas)
        }
        self.panels = panels
        self.canvases = canvases
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

    private func updateCanvases() {
        let rect = drag.isDragging ? drag.screenRect : .zero
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
    var body: some View {
        Text(ScreenshotTranslateSupport.overlayHintCopy)
            .font(GTType.body)
            .foregroundStyle(Color.white)
            .padding(.horizontal, GTSpacing.medium)
            .padding(.vertical, GTSpacing.xSmall)
            .background(Color.black.opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: GTRadius.row, style: .continuous))
            .accessibilityLabel(ScreenshotTranslateSupport.overlayHintCopy)
    }
}
