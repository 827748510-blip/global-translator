import AppKit
import SwiftUI

/// Horizontal placement for the menu bar dropdown: centered under the icon,
/// clamped inside the screen's visible frame so it never hangs off any
/// display, including screens with negative coordinates.
public enum DropdownLayout {
    static let screenMargin: CGFloat = 8

    public static func panelOriginX(iconMidX: CGFloat, panelWidth: CGFloat, visibleFrame: CGRect) -> CGFloat {
        let width = min(panelWidth, visibleFrame.width)
        let preferred = iconMidX - width / 2
        let lowest = visibleFrame.minX + screenMargin
        let highest = visibleFrame.maxX - width - screenMargin
        return min(max(preferred, lowest), max(highest, lowest))
    }

    /// Top-left anchor for the dropdown panel.
    ///
    /// The status item can be hosted by ControlCenter with a zero-size or
    /// meaningless frame: macOS still reports the item as visible, but the icon
    /// has no pixels and its geometry is either empty or parked at the screen
    /// origin. Anchoring to such a frame placed the panel off-screen or in a
    /// random corner, so callers without a usable icon frame fall back to the
    /// top-right corner of the visible frame instead of giving up.
    ///
    /// Ownership is decided against `screenFrame`, not `visibleFrame`: a real
    /// menu bar icon sits entirely in the strip that `visibleFrame` excludes
    /// (it only touches its top edge), so testing against the visible frame
    /// reported every normal icon as unusable and pushed the panel to the
    /// fallback corner. Placement is still clamped to `visibleFrame`.
    public static func panelAnchor(
        iconFrame: CGRect?,
        panelSize: CGSize,
        visibleFrame: CGRect,
        screenFrame: CGRect
    ) -> CGPoint {
        // Menu bar height varies (24 pt classic, ~38 pt with a notch); 60 pt
        // covers both without reaching any legitimate content area.
        let menuBarBand: CGFloat = 60
        let usableIcon = iconFrame.flatMap { frame -> CGRect? in
            guard frame.width > 0, frame.height > 0, frame.intersects(screenFrame) else { return nil }
            guard frame.maxY >= screenFrame.maxY - menuBarBand else { return nil }
            return frame
        }
        let panelWidth = min(panelSize.width, visibleFrame.width)
        let iconMidX = usableIcon?.midX ?? (visibleFrame.maxX - screenMargin - panelWidth / 2)
        let x = panelOriginX(iconMidX: iconMidX, panelWidth: panelSize.width, visibleFrame: visibleFrame)

        // Pin the top edge under the icon, or just under the menu bar when the
        // icon geometry is unavailable; never let the panel leave the screen.
        let preferredTop = usableIcon.map { min($0.minY, visibleFrame.maxY) }
            ?? (visibleFrame.maxY - screenMargin)
        let top = min(
            max(preferredTop, visibleFrame.minY + screenMargin + panelSize.height),
            visibleFrame.maxY - screenMargin
        )
        return CGPoint(x: x, y: top)
    }
}

/// Decides whether an activation of another app should fold the dropdown away.
///
/// A cold launch shows the panel before activation settles: the previously
/// frontmost app often takes focus back a moment later, and closing on that
/// would hide the panel the launch asked for. Keyboard app switching later is
/// a deliberate user action and must dismiss it.
public enum DropdownFocusPolicy {
    /// Grace period after the panel appears during which focus churn is
    /// treated as launch noise rather than a user decision.
    public static let settleWindow: TimeInterval = 1.2

    public static func shouldDismiss(
        shownAt: Date?,
        now: Date,
        isOwnApplication: Bool
    ) -> Bool {
        if isOwnApplication { return false }
        guard let shownAt else { return true }
        return now.timeIntervalSince(shownAt) >= settleWindow
    }
}

/// Borderless dropdown panel that can appear above fullscreen apps.
/// `canJoinAllSpaces + fullScreenAuxiliary` puts it on the fullscreen space;
/// `nonactivatingPanel` keeps the frontmost app focused. The panel may become
/// key so text fields inside settings accept typing, without activating.
/// Appearance follows the system so light panels stay solid white and dark
/// mode uses the system window background.
public final class DropdownPanel: NSPanel {
    public var onResignKey: (() -> Void)?
    public var onOutsideClick: (() -> Void)?
    private var eventMonitors: [Any] = []

    public init(content: NSViewController) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: GTPopoverMetrics.width, height: 240),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        contentViewController = content
        // Inherit the system appearance (light / dark). Do not pin `.aqua` —
        // that forced a grey-tinted light panel and blocked Dark Mode.
        appearance = nil
        // The rounded card is drawn by the SwiftUI content; the window
        // itself is transparent so the corners are visible.
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        isMovable = false
    }

    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { false }

    public override func resignKey() {
        super.resignKey()
        onResignKey?()
    }

    /// Presents the panel with a quick fade; keeps the top edge pinned so the
    /// dropdown visually grows out from under the menu bar icon.
    public func present(anchorTopLeft: CGPoint, size: CGSize) {
        // Window frames are bottom-left based while the anchor names the top
        // edge; without this conversion the panel asked for a frame whose
        // bottom sat at the menu bar and only stayed on screen because AppKit
        // silently constrained it.
        let finalFrame = NSRect(
            x: anchorTopLeft.x,
            y: anchorTopLeft.y - size.height,
            width: size.width,
            height: size.height
        )
        let startFrame = NSRect(
            x: finalFrame.minX, y: finalFrame.minY,
            width: finalFrame.width, height: min(finalFrame.height, 8)
        )
        setFrame(startFrame, display: false)
        alphaValue = 0
        startOutsideClickMonitoring()
        makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            animator().setFrame(finalFrame, display: true)
            animator().alphaValue = 1
        }
    }

    /// Dismisses with a quick fade, then orders the panel out.
    public func dismiss(animated: Bool) {
        guard isVisible else { return }
        stopOutsideClickMonitoring()
        if !animated {
            orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            context.allowsImplicitAnimation = true
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                self?.orderOut(nil)
                self?.alphaValue = 1
            }
        })
    }

    /// Outside clicks must always dismiss: global monitors cover other apps
    /// (where a non-key panel never resigns), the local monitor covers clicks
    /// inside our own app such as the menu bar icon itself.
    private func startOutsideClickMonitoring() {
        guard eventMonitors.isEmpty else { return }
        let outside: (NSEvent) -> Void = { [weak self] _ in
            guard let self, self.isVisible, let onOutsideClick = self.onOutsideClick else { return }
            if !self.frame.contains(NSEvent.mouseLocation) {
                onOutsideClick()
            }
        }
        var monitors: [Any] = []
        if let global = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: outside
        ) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown],
            handler: { [weak self] event in
                guard let self, self.isVisible, !self.frame.contains(NSEvent.mouseLocation) else { return event }
                self.onOutsideClick?()
                return event
            }
        ) {
            monitors.append(local)
        }
        eventMonitors = monitors
    }

    private func stopOutsideClickMonitoring() {
        for monitor in eventMonitors { NSEvent.removeMonitor(monitor) }
        eventMonitors = []
    }

    var outsideClickMonitorCount: Int { eventMonitors.count }
}
