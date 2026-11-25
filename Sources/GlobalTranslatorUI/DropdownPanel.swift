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

/// Tracks the one-shot exemption that lets a cold launch survive the focus
/// bounce back to the previously frontmost app.
///
/// The exemption must belong to the launch only. A panel that the user closes
/// and reopens must never inherit it: otherwise a real app switch within the
/// window would be ignored and the panel would keep floating over other apps.
/// Every open therefore either arms (launch) or disarms (anything else), and
/// closing always disarms.
public struct LaunchFocusExemption: Equatable, Sendable {
    public private(set) var isArmed = false
    public let window: TimeInterval

    public init(window: TimeInterval = 5) {
        self.window = window
    }

    /// Arms for a cold-launch request.
    public mutating func armForLaunch() {
        isArmed = true
    }

    /// Disarms for a normal open or a dismissal.
    public mutating func disarm() {
        isArmed = false
    }

    /// Returns true when this activation is the launch focus bounce.
    ///
    /// Consulted on every foreign activation and always consumes the exemption,
    /// so a stale arm cannot survive into a later interaction.
    public mutating func consumeIfBounce(shownAt: Date?, now: Date) -> Bool {
        guard isArmed else { return false }
        isArmed = false
        guard let shownAt, now.timeIntervalSince(shownAt) < window else { return false }
        return true
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
    public var onEscape: (() -> Void)?
    public var shouldHandleEscape: (() -> Bool)?
    nonisolated(unsafe) private var eventMonitors: [Any] = []
    private var presentationGeneration: UInt64 = 0

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

    deinit {
        for monitor in eventMonitors { NSEvent.removeMonitor(monitor) }
    }

    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { false }

    public override func resignKey() {
        super.resignKey()
        onResignKey?()
    }

    public override func cancelOperation(_ sender: Any?) {
        guard shouldHandleEscape?() ?? true else { return }
        onEscape?()
    }

    /// Presents the panel anchored under `anchorTopLeft` without animating
    /// window height; uses a crisp ease-out opacity fade (respecting Reduce Motion).
    public func present(anchorTopLeft: CGPoint, size: CGSize) {
        presentationGeneration &+= 1
        let finalFrame = NSRect(
            x: anchorTopLeft.x,
            y: anchorTopLeft.y - size.height,
            width: size.width,
            height: size.height
        )
        setFrame(finalFrame, display: true)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        alphaValue = reduceMotion ? 1 : 0
        startOutsideClickMonitoring()
        makeKeyAndOrderFront(nil)
        guard !reduceMotion else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
            context.allowsImplicitAnimation = true
            animator().alphaValue = 1
        }
    }

    /// Updates panel height dynamically while keeping the top edge anchored.
    public func updateHeight(_ height: CGFloat) {
        guard isVisible, abs(frame.height - height) > 1 else { return }
        let topY = frame.maxY
        let updated = NSRect(
            x: frame.minX,
            y: topY - height,
            width: frame.width,
            height: height
        )
        setFrame(updated, display: true)
    }

    /// Dismisses with an interruptible ease-out fade, then orders the panel out
    /// only if no newer `present` superseded this dismissal.
    public func dismiss(animated: Bool) {
        guard isVisible else { return }
        presentationGeneration &+= 1
        let token = presentationGeneration
        stopOutsideClickMonitoring()
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !animated || reduceMotion {
            orderOut(nil)
            alphaValue = 1
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
            context.allowsImplicitAnimation = true
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.presentationGeneration == token else { return }
                self.orderOut(nil)
                self.alphaValue = 1
            }
        })
    }

    /// Outside clicks must always dismiss: global monitors cover other apps
    /// (where a non-key panel never resigns), the local monitor covers clicks
    /// inside our own app such as the menu bar icon itself.
    private func startOutsideClickMonitoring() {
        guard eventMonitors.isEmpty else { return }
        var monitors: [Any] = []
        if let global = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown],
            handler: { [weak self] _ in
                let location = NSEvent.mouseLocation
                guard let self else { return }
                assert(Thread.isMainThread)
                MainActor.assumeIsolated {
                    guard self.isVisible, !self.containsOwnedUI(at: location) else { return }
                    self.onOutsideClick?()
                }
            }
        ) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown],
            handler: { [weak self] event in
                let location = NSEvent.mouseLocation
                guard let self else { return event }
                assert(Thread.isMainThread)
                MainActor.assumeIsolated {
                    guard self.isVisible, !self.containsOwnedUI(at: location) else { return }
                    self.onOutsideClick?()
                }
                return event
            }
        ) {
            monitors.append(local)
        }
        if let localKey = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown,
            handler: { [weak self] event in
                guard event.keyCode == 53 else { return event }
                guard let self else { return event }
                assert(Thread.isMainThread)
                let handled = MainActor.assumeIsolated { () -> Bool in
                    guard self.isVisible, !self.hasOwnedMenuOpen() else { return false }
                    guard self.shouldHandleEscape?() ?? true else { return false }
                    self.onEscape?()
                    return true
                }
                return handled ? nil : event
            }
        ) {
            monitors.append(localKey)
        }
        eventMonitors = monitors
    }

    private func stopOutsideClickMonitoring() {
        for monitor in eventMonitors { NSEvent.removeMonitor(monitor) }
        eventMonitors = []
    }

    @MainActor
    func containsOwnedUI(at location: CGPoint, windows: [NSWindow]? = nil) -> Bool {
        if frame.contains(location) { return true }
        let list = windows ?? NSApp.windows
        return list.contains { window in
            guard window.isVisible, window !== self else { return false }
            let owned = window.level == .popUpMenu || window.parent === self
            return owned && window.frame.contains(location)
        }
    }

    @MainActor
    func hasOwnedMenuOpen(windows: [NSWindow]? = nil) -> Bool {
        let list = windows ?? NSApp.windows
        return list.contains { $0.isVisible && $0 !== self && ($0.level == .popUpMenu || $0.parent === self) }
    }

    var outsideClickMonitorCount: Int { eventMonitors.count }
}
