import ApplicationServices
import AppKit
import CoreGraphics
import Foundation

@MainActor
extension ActiveWindowMonitor {
    func installAXObserver(for pid: pid_t) {
        if observedApplication != nil, observer != nil, observedPID == pid { return }
        if observedApplication != nil { removeAXObserver() }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.2)
        var created: AXObserver?
        guard AXObserverCreate(pid, Self.axCallback, &created) == .success, let created else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for notification in axNotifications {
            AXObserverAddNotification(created, application, notification, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        observer = created
        observedApplication = application
        observedPID = pid
        if let focused = copyElement(application, kAXFocusedWindowAttribute as CFString) {
            registerWindowNotifications(focused)
        }
    }

    func removeAXObserver() {
        guard let observer else {
            observedApplication = nil
            observedWindow = nil
            observedPID = nil
            return
        }
        unregisterNotifications(for: observedWindow, observer: observer)
        unregisterNotifications(for: observedApplication, observer: observer)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        self.observer = nil
        observedApplication = nil
        observedWindow = nil
        observedPID = nil
    }

    func descriptor(for pid: pid_t, bundleIdentifier: String) -> ActiveWindowDescriptor? {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.2)
        guard let value = copyElement(application, kAXFocusedWindowAttribute as CFString),
              let accessibilityFrame = frame(of: value), accessibilityFrame.width > 0, accessibilityFrame.height > 0 else { return nil }
        let frame = primaryDisplayFrame().map {
            CoordinateConverter.quartzTopLeftFrameToAppKitGlobal(
                accessibilityFrame,
                primaryDisplayFrame: $0
            )
        } ?? accessibilityFrame
        registerWindowNotifications(value)
        let windowID = windowID(for: pid, frame: accessibilityFrame)
        return ActiveWindowDescriptor(pid: pid, bundleIdentifier: bundleIdentifier, windowID: windowID, frame: frame, revision: 0)
    }

    private func primaryDisplayFrame() -> CGRect? {
        NSScreen.screens.first?.frame
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        guard let position = copyAXValue(element, kAXPositionAttribute as CFString),
              let size = copyAXValue(element, kAXSizeAttribute as CFString) else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &point), AXValueGetValue(size, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    private func windowID(for pid: pid_t, frame: CGRect) -> CGWindowID? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return nil }
        for info in windows {
            guard (info[kCGWindowOwnerPID as String] as? Int) == Int(pid),
                  let boundsValue = info[kCGWindowBounds as String],
                  CFGetTypeID(boundsValue as CFTypeRef) == CFDictionaryGetTypeID(),
                  let windowIDValue = info[kCGWindowNumber as String] as? CGWindowID else { continue }
            let bounds = unsafeBitCast(boundsValue as CFTypeRef, to: CFDictionary.self)
            guard let candidate = CGRect(dictionaryRepresentation: bounds),
                  candidate.insetBy(dx: -2, dy: -2).contains(frame.center) else { continue }
            return windowIDValue
        }
        return nil
    }

    private func copyValue(_ element: AXUIElement, _ attribute: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute, &value) == .success ? value : nil
    }

    private func copyElement(_ element: AXUIElement, _ attribute: CFString) -> AXUIElement? {
        guard let value = copyValue(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func copyAXValue(_ element: AXUIElement, _ attribute: CFString) -> AXValue? {
        guard let value = copyValue(element, attribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXValue.self)
    }

    private func registerWindowNotifications(_ window: AXUIElement) {
        guard let observer else { return }
        if let observedWindow,
           CFEqual(observedWindow as CFTypeRef, window as CFTypeRef) { return }
        unregisterNotifications(for: observedWindow, observer: observer)
        observedWindow = window
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for notification in axNotifications {
            AXObserverAddNotification(observer, window, notification, refcon)
        }
    }

    private func unregisterNotifications(for element: AXUIElement?, observer: AXObserver) {
        guard let element else { return }
        for notification in axNotifications {
            AXObserverRemoveNotification(observer, element, notification)
        }
    }

    private var axNotifications: [CFString] {
        [
            kAXFocusedWindowChangedNotification as CFString,
            kAXValueChangedNotification as CFString,
            kAXMovedNotification as CFString,
            kAXResizedNotification as CFString,
            kAXTitleChangedNotification as CFString,
            kAXUIElementDestroyedNotification as CFString
        ]
    }

    private static let axCallback: AXObserverCallback = { _, _, _, refcon in
        guard let refcon else { return }
        let monitor = Unmanaged<ActiveWindowMonitor>.fromOpaque(refcon).takeUnretainedValue()
        Task { @MainActor [weak monitor] in monitor?.refreshFromWorkspace() }
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
