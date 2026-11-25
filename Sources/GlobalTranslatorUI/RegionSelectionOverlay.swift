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
    private let dimLayer = CAShapeLayer()
    private let outerBorderLayer = CAShapeLayer()
    private let innerBorderLayer = CAShapeLayer()
    private let badgeBackgroundLayer = CALayer()
    private let badgeTextLayer = CATextLayer()
    private var lastRenderedSelectionInLocal: CGRect?
    private var lastRenderedBounds: CGRect = .zero

    var selectionRectInScreen: CGRect = .zero {
        didSet {
            guard oldValue != selectionRectInScreen else { return }
            updateLayers()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        guard let rootLayer = layer else { return }

        dimLayer.fillRule = .evenOdd
        dimLayer.fillColor = NSColor.black.withAlphaComponent(0.4).cgColor
        rootLayer.addSublayer(dimLayer)

        outerBorderLayer.fillColor = nil
        outerBorderLayer.lineWidth = 1
        outerBorderLayer.strokeColor = NSColor.black.withAlphaComponent(0.65).cgColor
        rootLayer.addSublayer(outerBorderLayer)

        innerBorderLayer.fillColor = nil
        innerBorderLayer.lineWidth = 1
        innerBorderLayer.strokeColor = NSColor.white.cgColor
        rootLayer.addSublayer(innerBorderLayer)

        badgeBackgroundLayer.cornerRadius = 4
        badgeBackgroundLayer.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        badgeBackgroundLayer.isHidden = true

        badgeTextLayer.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        badgeTextLayer.fontSize = 11
        badgeTextLayer.foregroundColor = NSColor.white.cgColor
        badgeTextLayer.alignmentMode = .center
        badgeTextLayer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        badgeBackgroundLayer.addSublayer(badgeTextLayer)
        rootLayer.addSublayer(badgeBackgroundLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        badgeTextLayer.contentsScale = scale
        updateLayers()
    }

    override func layout() {
        super.layout()
        updateLayers()
    }

    private func updateLayers() {
        let local: CGRect
        if let window, selectionRectInScreen.width > 0, selectionRectInScreen.height > 0 {
            local = window.convertFromScreen(selectionRectInScreen)
        } else {
            local = .zero
        }
        guard lastRenderedSelectionInLocal != local || lastRenderedBounds != bounds else { return }
        lastRenderedSelectionInLocal = local
        lastRenderedBounds = bounds

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        dimLayer.frame = bounds
        let dimPath = CGMutablePath()
        dimPath.addRect(bounds)
        if local.width > 0, local.height > 0 {
            dimPath.addRect(local)
            dimLayer.path = dimPath

            outerBorderLayer.frame = bounds
            outerBorderLayer.path = CGPath(rect: local.insetBy(dx: -0.5, dy: -0.5), transform: nil)
            outerBorderLayer.isHidden = false

            innerBorderLayer.frame = bounds
            innerBorderLayer.path = CGPath(rect: local, transform: nil)
            innerBorderLayer.isHidden = false

            updateSizeBadge(for: local)
        } else {
            dimLayer.path = dimPath
            outerBorderLayer.isHidden = true
            outerBorderLayer.path = nil
            innerBorderLayer.isHidden = true
            innerBorderLayer.path = nil
            badgeBackgroundLayer.isHidden = true
        }
    }

    private func updateSizeBadge(for local: CGRect) {
        let width = Int(local.width.rounded())
        let height = Int(local.height.rounded())
        guard width > 0, height > 0 else {
            badgeBackgroundLayer.isHidden = true
            return
        }
        let text = "\(width) × \(height)"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        ]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let padX: CGFloat = 6
        let padY: CGFloat = 3
        let badgeSize = CGSize(width: ceil(textSize.width) + padX * 2, height: ceil(textSize.height) + padY * 2)
        let preferredY = local.minY - badgeSize.height - 6
        let badgeY = preferredY >= bounds.minY + 4 ? preferredY : min(local.maxY + 6, bounds.maxY - badgeSize.height - 4)
        let badgeX = min(max(local.minX, bounds.minX + 4), max(bounds.minX + 4, bounds.maxX - badgeSize.width - 4))
        badgeBackgroundLayer.frame = CGRect(origin: CGPoint(x: badgeX, y: badgeY), size: badgeSize)
        badgeTextLayer.frame = CGRect(x: padX, y: padY, width: ceil(textSize.width), height: ceil(textSize.height))
        badgeTextLayer.string = text
        badgeBackgroundLayer.isHidden = false
    }
}

@MainActor
public final class RegionSelectionOverlayController: RegionSelectionPresenting {
    private var panels: [RegionSelectionPanel] = []
    private var canvases: [RegionSelectionCanvas] = []
    private var hintViews: [NSView] = []
    private var cachedScreenFrames: [CGRect] = []
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
        let screenFrames = screens.map(\.frame)
        let mouseLocation = NSEvent.mouseLocation
        if screenFrames == cachedScreenFrames, panels.count == screens.count, !panels.isEmpty {
            var keyPanel: RegionSelectionPanel?
            for (index, panel) in panels.enumerated() {
                canvases[index].selectionRectInScreen = .zero
                hintViews[index].isHidden = false
                if screenFrames[index].contains(mouseLocation), keyPanel == nil {
                    keyPanel = panel
                    panel.makeKeyAndOrderFront(nil)
                } else {
                    panel.orderFrontRegardless()
                }
            }
            if keyPanel == nil, let first = panels.first {
                first.makeKeyAndOrderFront(nil)
            }
        } else {
            for panel in panels { panel.orderOut(nil) }
            var newPanels: [RegionSelectionPanel] = []
            var newCanvases: [RegionSelectionCanvas] = []
            var newHintViews: [NSView] = []
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
                newPanels.append(panel)
                newCanvases.append(canvas)
                newHintViews.append(hosting)
            }
            if keyPanel == nil, let first = newPanels.first {
                first.makeKeyAndOrderFront(nil)
            }
            self.panels = newPanels
            self.canvases = newCanvases
            self.hintViews = newHintViews
            self.cachedScreenFrames = screenFrames
        }
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
            return nil
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
        for hint in hintViews where hint.isHidden != hideHints {
            hint.isHidden = hideHints
        }
        for (index, canvas) in canvases.enumerated() {
            let screenFrame = panels[index].frame
            if screenFrame.intersects(rect) || canvas.selectionRectInScreen != .zero {
                canvas.selectionRectInScreen = rect
            }
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
        for canvas in canvases {
            canvas.selectionRectInScreen = .zero
        }
        for hint in hintViews {
            hint.isHidden = false
        }
        for panel in panels {
            panel.orderOut(nil)
        }
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
