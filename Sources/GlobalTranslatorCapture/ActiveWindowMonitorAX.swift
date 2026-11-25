import ApplicationServices
import AppKit
import CoreGraphics
import Foundation
import os

struct UncheckedCFBox<Value>: @unchecked Sendable {
    let value: Value
}

final class AXObserverRegistration: @unchecked Sendable {
    private struct State: @unchecked Sendable {
        weak var monitor: ActiveWindowMonitor?
        var observer: UncheckedCFBox<AXObserver>?
        var application: UncheckedCFBox<AXUIElement>?
        var window: UncheckedCFBox<AXUIElement>?
        var invalidated = false
    }

    private struct Teardown: Sendable {
        let observer: UncheckedCFBox<AXObserver>?
        let application: UncheckedCFBox<AXUIElement>?
        let window: UncheckedCFBox<AXUIElement>?
    }

    private let state: OSAllocatedUnfairLock<State>
    private let notifications: [UncheckedCFBox<CFString>]

    init(monitor: ActiveWindowMonitor, observer: AXObserver, application: AXUIElement, notifications: [CFString]) {
        self.notifications = notifications.map(UncheckedCFBox.init)
        self.state = OSAllocatedUnfairLock(initialState: State(
            monitor: monitor,
            observer: UncheckedCFBox(value: observer),
            application: UncheckedCFBox(value: application),
            window: nil,
            invalidated: false
        ))
    }

    func activeMonitor() -> ActiveWindowMonitor? {
        state.withLock { current in
            current.invalidated ? nil : current.monitor
        }
    }

    func updateWindow(_ window: AXUIElement?) {
        let wrapped = window.map(UncheckedCFBox.init)
        let stale = state.withLock { current -> Teardown? in
            guard !current.invalidated else { return nil }
            let previous = current.window
            current.window = wrapped
            return Teardown(observer: current.observer, application: nil, window: previous)
        }
        if let previous = stale?.window?.value, let observer = stale?.observer?.value {
            for notification in notifications {
                AXObserverRemoveNotification(observer, previous, notification.value)
            }
        }
    }

    func invalidate() {
        let teardown = state.withLock { current -> Teardown? in
            guard !current.invalidated else { return nil }
            current.invalidated = true
            let result = Teardown(
                observer: current.observer,
                application: current.application,
                window: current.window
            )
            current.monitor = nil
            current.observer = nil
            current.application = nil
            current.window = nil
            return result
        }
        guard let observer = teardown?.observer?.value else { return }
        if let window = teardown?.window?.value {
            for notification in notifications {
                AXObserverRemoveNotification(observer, window, notification.value)
            }
        }
        if let application = teardown?.application?.value {
            for notification in notifications {
                AXObserverRemoveNotification(observer, application, notification.value)
            }
        }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    deinit {
        invalidate()
    }
}

@MainActor
extension ActiveWindowMonitor {
    func installAXObserver(for pid: pid_t) {
        if observedApplication != nil, observer != nil, observedPID == pid { return }
        if observedApplication != nil || axRegistration != nil { removeAXObserver() }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.2)
        var created: AXObserver?
        guard AXObserverCreate(pid, Self.axCallback, &created) == .success, let created else { return }
        let registration = AXObserverRegistration(
            monitor: self,
            observer: created,
            application: application,
            notifications: axNotifications
        )
        let refcon = Unmanaged.passUnretained(registration).toOpaque()
        for notification in axNotifications {
            AXObserverAddNotification(created, application, notification, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        axRegistration = registration
        observer = created
        observedApplication = application
        observedPID = pid
        if let focused = copyElement(application, kAXFocusedWindowAttribute as CFString) {
            registerWindowNotifications(focused)
        }
    }

    func removeAXObserver() {
        imageNotificationLabels.removeAll()
        if let registration = axRegistration {
            registration.invalidate()
            axRegistration = nil
        } else if let observer {
            unregisterNotifications(for: observedWindow, observer: observer)
            unregisterNotifications(for: observedApplication, observer: observer)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        self.observer = nil
        observedApplication = nil
        observedWindow = nil
        observedPID = nil
    }

    struct DescriptorLookupResult: @unchecked Sendable {
        let descriptor: ActiveWindowDescriptor?
        let focusedWindow: UncheckedCFBox<AXUIElement>?
    }

    func descriptor(for pid: pid_t, bundleIdentifier: String, invalidatesOverlay: Bool = true) -> ActiveWindowDescriptor? {
        let primary = primaryDisplayFrame()
        let trusted = permissions.snapshot.accessibilityTrusted
        let result = resolveDescriptorOffMain(
            pid: pid,
            bundleIdentifier: bundleIdentifier,
            invalidatesOverlay: invalidatesOverlay,
            accessibilityTrusted: trusted,
            primaryDisplayFrame: primary
        )
        if let focusedWindow = result.focusedWindow?.value {
            registerWindowNotifications(focusedWindow)
        }
        return result.descriptor
    }

    nonisolated func resolveDescriptorOffMain(
        pid: pid_t,
        bundleIdentifier: String,
        invalidatesOverlay: Bool,
        accessibilityTrusted: Bool,
        primaryDisplayFrame: CGRect?
    ) -> DescriptorLookupResult {
        guard accessibilityTrusted else {
            return DescriptorLookupResult(
                descriptor: screenCaptureDescriptor(
                    for: pid,
                    bundleIdentifier: bundleIdentifier,
                    invalidatesOverlay: invalidatesOverlay,
                    primaryDisplayFrame: primaryDisplayFrame
                ),
                focusedWindow: nil
            )
        }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.2)
        guard let value = Self.copyElement(application, kAXFocusedWindowAttribute as CFString) else {
            return DescriptorLookupResult(
                descriptor: screenCaptureDescriptor(
                    for: pid,
                    bundleIdentifier: bundleIdentifier,
                    invalidatesOverlay: invalidatesOverlay,
                    primaryDisplayFrame: primaryDisplayFrame
                ),
                focusedWindow: nil
            )
        }
        AXUIElementSetMessagingTimeout(value, 0.2)
        guard let accessibilityFrame = Self.frame(of: value),
              accessibilityFrame.width > 0, accessibilityFrame.height > 0 else {
            return DescriptorLookupResult(
                descriptor: screenCaptureDescriptor(
                    for: pid,
                    bundleIdentifier: bundleIdentifier,
                    invalidatesOverlay: invalidatesOverlay,
                    primaryDisplayFrame: primaryDisplayFrame
                ),
                focusedWindow: nil
            )
        }
        let frame = primaryDisplayFrame.map {
            CoordinateConverter.quartzTopLeftFrameToAppKitGlobal(
                accessibilityFrame,
                primaryDisplayFrame: $0
            )
        } ?? accessibilityFrame
        let windowID = Self.windowID(for: pid, frame: accessibilityFrame)
        let descriptor = ActiveWindowDescriptor(
            pid: pid,
            bundleIdentifier: bundleIdentifier,
            windowID: windowID,
            frame: frame,
            revision: 0,
            invalidatesOverlay: invalidatesOverlay
        )
        return DescriptorLookupResult(descriptor: descriptor, focusedWindow: UncheckedCFBox(value: value))
    }

    private func primaryDisplayFrame() -> CGRect? {
        NSScreen.screens.first?.frame
    }

    private nonisolated static func frame(of element: AXUIElement) -> CGRect? {
        guard let position = copyAXValue(element, kAXPositionAttribute as CFString),
              let size = copyAXValue(element, kAXSizeAttribute as CFString) else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &point), AXValueGetValue(size, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    private nonisolated static func windowID(for pid: pid_t, frame: CGRect) -> CGWindowID? {
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

    private nonisolated static func copyValue(_ element: AXUIElement, _ attribute: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute, &value) == .success ? value : nil
    }

    private nonisolated static func copyElement(_ element: AXUIElement, _ attribute: CFString) -> AXUIElement? {
        guard let value = copyValue(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private nonisolated static func copyAXValue(_ element: AXUIElement, _ attribute: CFString) -> AXValue? {
        guard let value = copyValue(element, attribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXValue.self)
    }

    private func copyValue(_ element: AXUIElement, _ attribute: CFString) -> CFTypeRef? {
        Self.copyValue(element, attribute)
    }

    private func copyElement(_ element: AXUIElement, _ attribute: CFString) -> AXUIElement? {
        Self.copyElement(element, attribute)
    }

    func registerWindowNotifications(_ window: AXUIElement) {
        guard let observer, let registration = axRegistration else { return }
        if let observedWindow,
           CFEqual(observedWindow as CFTypeRef, window as CFTypeRef) { return }
        registration.updateWindow(window)
        observedWindow = window
        let refcon = Unmanaged.passUnretained(registration).toOpaque()
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
            kAXFocusedUIElementChangedNotification as CFString,
            kAXValueChangedNotification as CFString,
            kAXMovedNotification as CFString,
            kAXResizedNotification as CFString,
            kAXTitleChangedNotification as CFString,
            kAXUIElementDestroyedNotification as CFString
        ]
    }

    private static let axCallback: AXObserverCallback = { _, element, notification, refcon in
        guard let refcon else { return }
        let registration = Unmanaged<AXObserverRegistration>.fromOpaque(refcon).takeUnretainedValue()
        guard let monitor = registration.activeMonitor() else { return }
        let isMetadata = notification == kAXValueChangedNotification as CFString || notification == kAXTitleChangedNotification as CFString
        let invalidates = !isMetadata
        if notification == kAXValueChangedNotification as CFString {
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
            if (role as? String) == "AXImage" {
                let source = NotificationAXElement(value: element)
                Task { @MainActor [weak monitor] in
                    guard let monitor else { return }
                    guard let owner = monitor.copyElement(source.value, kAXWindowAttribute as CFString),
                          let current = monitor.observedWindow, CFEqual(owner, current) else { return }
                    let title = monitor.copyValue(source.value, kAXTitleAttribute as CFString) as? String
                    let description = monitor.copyValue(source.value, kAXDescriptionAttribute as CFString) as? String
                    let label = [title, description].compactMap { $0 }.map { String($0.prefix(512)) }.joined(separator: "\n")
                    let key = CFHash(source.value)
                    if monitor.imageNotificationLabels[key] == label { return }
                    if monitor.imageNotificationLabels.count >= 128 { monitor.imageNotificationLabels.removeAll(keepingCapacity: true) }
                    monitor.imageNotificationLabels[key] = label
                    monitor.scheduleAXRefresh(invalidatesOverlay: false)
                }
                return
            }
        }
        Task { @MainActor [weak monitor] in
            monitor?.scheduleAXRefresh(invalidatesOverlay: invalidates)
        }
    }
}

private struct NotificationAXElement: @unchecked Sendable {
    let value: AXUIElement
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
