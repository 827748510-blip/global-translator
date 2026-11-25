import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import os

public protocol PermissionControlling: Sendable {
    var snapshot: PermissionSnapshot { get }
    var privacyURLs: [URL] { get }
    func requestAccessibilityPermission() -> Bool
    func requestScreenCapturePermission() -> Bool
}

public final class SystemPermissionController: PermissionControlling, @unchecked Sendable {
    private struct CacheState: Sendable {
        var accessibilityTrusted = false
        var screenCaptureAuthorized = false
        var permissionCheckedAt: TimeInterval = -.infinity
        var sessionLocked = false
        var lockCheckedAt: TimeInterval = -.infinity
    }

    private let snapshotProvider: (@Sendable () -> PermissionSnapshot)?
    private let cache = OSAllocatedUnfairLock(initialState: CacheState())
    private let ttl: TimeInterval = 1.0
    private var observerTokens: [NSObjectProtocol] = []

    public let privacyURLs: [URL]

    public init(snapshotProvider: (@Sendable () -> PermissionSnapshot)? = nil) {
        self.snapshotProvider = snapshotProvider
        privacyURLs = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ].compactMap(URL.init(string:))

        if snapshotProvider == nil {
            let workspaceCenter = NSWorkspace.shared.notificationCenter
            let appCenter = NotificationCenter.default
            let distributedCenter = DistributedNotificationCenter.default()

            observerTokens.append(appCenter.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.invalidatePermissionCache()
            })
            observerTokens.append(distributedCenter.addObserver(
                forName: NSNotification.Name("com.apple.screenIsLocked"),
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.setSessionLocked(true)
            })
            observerTokens.append(distributedCenter.addObserver(
                forName: NSNotification.Name("com.apple.screenIsUnlocked"),
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.setSessionLocked(false)
            })
            observerTokens.append(workspaceCenter.addObserver(
                forName: NSWorkspace.sessionDidResignActiveNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.setSessionLocked(true)
            })
            observerTokens.append(workspaceCenter.addObserver(
                forName: NSWorkspace.sessionDidBecomeActiveNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.setSessionLocked(false)
            })
        }
    }

    deinit {
        let appCenter = NotificationCenter.default
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let distributedCenter = DistributedNotificationCenter.default()
        for token in observerTokens {
            appCenter.removeObserver(token)
            workspaceCenter.removeObserver(token)
            distributedCenter.removeObserver(token)
        }
    }

    public var snapshot: PermissionSnapshot {
        if let snapshotProvider {
            return snapshotProvider()
        }
        let now = ProcessInfo.processInfo.systemUptime
        let cached = cache.withLock { state -> (ax: Bool?, sc: Bool?, locked: Bool?) in
            let permValid = (now - state.permissionCheckedAt) < ttl
            let lockValid = (now - state.lockCheckedAt) < ttl
            return (
                permValid ? state.accessibilityTrusted : nil,
                permValid ? state.screenCaptureAuthorized : nil,
                lockValid ? state.sessionLocked : nil
            )
        }
        let ax = cached.ax ?? AXIsProcessTrusted()
        let sc = cached.sc ?? CGPreflightScreenCaptureAccess()
        let locked = cached.locked ?? Self.isSessionLocked()
        if cached.ax == nil || cached.sc == nil || cached.locked == nil {
            cache.withLock { state in
                if cached.ax == nil || cached.sc == nil {
                    state.accessibilityTrusted = ax
                    state.screenCaptureAuthorized = sc
                    state.permissionCheckedAt = now
                }
                if cached.locked == nil {
                    state.sessionLocked = locked
                    state.lockCheckedAt = now
                }
            }
        }
        // Always check secure input live with zero caching.
        return PermissionSnapshot(
            accessibilityTrusted: ax,
            screenCaptureAuthorized: sc,
            secureInputEnabled: IsSecureEventInputEnabled(),
            sessionLocked: locked
        )
    }

    public func requestAccessibilityPermission() -> Bool {
        let granted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        invalidatePermissionCache()
        return granted
    }

    public func requestScreenCapturePermission() -> Bool {
        let granted = CGRequestScreenCaptureAccess()
        invalidatePermissionCache()
        return granted
    }

    private func invalidatePermissionCache() {
        cache.withLock { state in
            state.permissionCheckedAt = -.infinity
        }
    }

    private func setSessionLocked(_ locked: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        cache.withLock { state in
            state.sessionLocked = locked
            state.lockCheckedAt = now
        }
    }

    private static func isSessionLocked() -> Bool {
        guard let dictionary = CGSessionCopyCurrentDictionary() as NSDictionary? else {
            return false
        }
        return dictionary["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
}
