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
        let finalFrame = NSRect(origin: anchorTopLeft, size: size)
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
