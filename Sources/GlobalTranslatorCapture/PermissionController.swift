import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation

public protocol PermissionControlling: Sendable {
    var snapshot: PermissionSnapshot { get }
    var privacyURLs: [URL] { get }
    func requestAccessibilityPermission() -> Bool
    func requestScreenCapturePermission() -> Bool
}

public final class SystemPermissionController: PermissionControlling, @unchecked Sendable {
    private let snapshotProvider: @Sendable () -> PermissionSnapshot

    public let privacyURLs: [URL]

    public init(snapshotProvider: (@Sendable () -> PermissionSnapshot)? = nil) {
        self.snapshotProvider = snapshotProvider ?? Self.readSnapshot
        privacyURLs = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ].compactMap(URL.init(string:))
    }

    public var snapshot: PermissionSnapshot { snapshotProvider() }

    public func requestAccessibilityPermission() -> Bool {
        return AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    public func requestScreenCapturePermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    private static func readSnapshot() -> PermissionSnapshot {
        PermissionSnapshot(
            accessibilityTrusted: AXIsProcessTrusted(),
            screenCaptureAuthorized: CGPreflightScreenCaptureAccess(),
            secureInputEnabled: IsSecureEventInputEnabled(),
            sessionLocked: isSessionLocked()
        )
    }

    private static func isSessionLocked() -> Bool {
        guard let dictionary = CGSessionCopyCurrentDictionary() as NSDictionary? else {
            return false
        }
        return dictionary["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
}
