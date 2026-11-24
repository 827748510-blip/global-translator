import Foundation
import CoreGraphics
import Testing
@testable import GlobalTranslatorCapture

@MainActor
struct WindowReadinessTests {
    @Test
    func visualChangeRequestsRevalidationWithoutDeclaringTextInvalid() async throws {
        let callbacks = CallbackRecorder()
        let monitor = ActiveWindowMonitor(
            translatedBundleIdentifiers: ["qa.editor"],
            permissions: FakePermissionController(snapshot: .allGranted),
            callback: { callbacks.record($0) }
        )
        monitor.workspaceNotificationCenter = NotificationCenter()
        monitor.frontmostApplicationProvider = { (42, "qa.editor") }
        monitor.windowDescriptorProvider = { pid, bundleIdentifier, invalidates in
            ActiveWindowDescriptor(pid: pid, bundleIdentifier: bundleIdentifier, windowID: 17, frame: CGRect(x: 0, y: 0, width: 800, height: 600), revision: 0, invalidatesOverlay: invalidates)
        }
        monitor.start()
        monitor.handleVisualChange()
        try await waitForLookup { callbacks.values().compactMap { $0 }.count == 2 }
        #expect(callbacks.values().compactMap { $0 }.last?.invalidatesOverlay == false)
        monitor.stop()
    }

    @Test
    func screenOnlyPermissionCanDescribeTheFrontmostNormalWindow() {
        let permission = FakePermissionController(snapshot: PermissionSnapshot(accessibilityTrusted: false, screenCaptureAuthorized: true, secureInputEnabled: false, sessionLocked: false))
        let monitor = ActiveWindowMonitor(permissions: permission)
        let windows: [[String: Any]] = [
            windowInfo(pid: 77, id: 1, layer: 0),
            windowInfo(pid: 42, id: 2, layer: 10),
            windowInfo(pid: 42, id: 3, layer: 0, alpha: 0),
            windowInfo(pid: 42, id: 17, layer: 0),
            windowInfo(pid: 42, id: 18, layer: 0)
        ]
        let descriptor = monitor.windowListDescriptor(windows, pid: 42, bundleIdentifier: "qa.editor", invalidatesOverlay: true, primaryDisplayFrame: CGRect(x: 0, y: 0, width: 1440, height: 1000))
        #expect(descriptor?.windowID == 17)
        #expect(descriptor?.frame == CGRect(x: 100, y: 400, width: 600, height: 400))
    }

    @Test
    func windowListFallbackRejectsMissingPermissionAndProtectedInput() {
        let states = [
            PermissionSnapshot(accessibilityTrusted: true, screenCaptureAuthorized: false, secureInputEnabled: false, sessionLocked: false),
            PermissionSnapshot(accessibilityTrusted: false, screenCaptureAuthorized: true, secureInputEnabled: true, sessionLocked: false)
        ]
        for state in states {
            let monitor = ActiveWindowMonitor(permissions: FakePermissionController(snapshot: state))
            #expect(monitor.windowListDescriptor([windowInfo(pid: 42, id: 17, layer: 0)], pid: 42, bundleIdentifier: "qa.editor", invalidatesOverlay: true, primaryDisplayFrame: CGRect(x: 0, y: 0, width: 1440, height: 1000)) == nil)
        }
    }

    @Test
    func firstWindowLookupRecoversWithoutAnotherAppNotification() async throws {
        let probe = WindowLookupProbe(failures: 1)
        let monitor = makeMonitor(probe: probe)
        monitor.start()
        try await waitForLookup { monitor.current != nil }
        #expect(probe.reads == 2)
        #expect(monitor.current?.windowID == 17)
        #expect(monitor.current?.revision == 1)
        monitor.stop()
    }

    @Test
    func recoveredDescriptorKeepsASeparateBoundedBudgetForCaptureFailures() async throws {
        let probe = WindowLookupProbe(failures: 2)
        let monitor = makeMonitor(probe: probe)
        monitor.start()
        try await waitForLookup { monitor.current != nil }
        #expect(probe.reads == 3)
        monitor.retryCurrentWindowCapture()
        try await waitForLookup { probe.reads == 4 }
        #expect(probe.reads == 4)
        monitor.retryCurrentWindowCapture()
        try await waitForLookup { probe.reads == 5 }
        #expect(probe.reads == 5)
        monitor.retryCurrentWindowCapture()
        try await Task.sleep(for: .milliseconds(450))
        #expect(probe.reads == 5)
        monitor.stop()
    }

    @Test
    func temporarilyMissingAXWindowRecoversWithAXPermissionAlone() async throws {
        let probe = WindowLookupProbe(failures: 1)
        let permissions = FakePermissionController(snapshot: PermissionSnapshot(accessibilityTrusted: true, screenCaptureAuthorized: false, secureInputEnabled: false, sessionLocked: false))
        let monitor = makeMonitor(probe: probe, permissions: permissions)
        monitor.start()
        try await waitForLookup { monitor.current != nil }
        #expect(probe.reads == 2)
        #expect(monitor.current?.windowID == 17)
        monitor.stop()
    }

    @Test
    func missingWindowRetriesAreBounded() async throws {
        let probe = WindowLookupProbe(failures: .max)
        let monitor = makeMonitor(probe: probe)
        monitor.start()
        try await waitForLookup { probe.reads == 3 }
        #expect(probe.reads == 3)
        try await Task.sleep(for: .milliseconds(450))
        #expect(probe.reads == 3)
        #expect(monitor.current == nil)
        monitor.stop()
    }

    @Test(arguments: ["stop", "excluded", "noApplication", "protected"])
    func retryCannotReadAfterStopExclusionOrProtection(condition: String) async throws {
        let probe = WindowLookupProbe(failures: .max)
        let monitor = makeMonitor(probe: probe)
        monitor.start()
        #expect(probe.reads == 1)
        switch condition {
        case "stop": monitor.stop()
        case "excluded": probe.bundleIdentifier = "qa.excluded"
        case "noApplication": probe.hasApplication = false
        default: probe.isProtected = true
        }
        try await Task.sleep(for: .milliseconds(850))
        #expect(probe.reads == 1)
        monitor.stop()
    }

    private func makeMonitor(probe: WindowLookupProbe, permissions: (any PermissionControlling)? = nil) -> ActiveWindowMonitor {
        let monitor = ActiveWindowMonitor(
            translatedBundleIdentifiers: ["qa.editor"],
            permissions: permissions ?? probe.permissions
        )
        // Isolate from the real workspace center: a stray app activation while
        // the test sleeps resets the retry budget and adds an extra lookup.
        monitor.workspaceNotificationCenter = NotificationCenter()
        monitor.frontmostApplicationProvider = {
            probe.hasApplication ? (42, probe.bundleIdentifier) : nil
        }
        monitor.windowDescriptorProvider = { pid, bundleIdentifier, invalidates in
            probe.reads += 1
            guard probe.reads > probe.failures else { return nil }
            return ActiveWindowDescriptor(pid: pid, bundleIdentifier: bundleIdentifier, windowID: 17, frame: CGRect(x: 0, y: 0, width: 800, height: 600), revision: 0, invalidatesOverlay: invalidates)
        }
        return monitor
    }

    private func waitForLookup(_ condition: () -> Bool) async throws {
        for _ in 0..<120 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
    }

    private func windowInfo(pid: Int, id: Int, layer: Int, alpha: Double = 1) -> [String: Any] {
        [kCGWindowOwnerPID as String: pid, kCGWindowNumber as String: id, kCGWindowLayer as String: layer,
         kCGWindowAlpha as String: alpha, kCGWindowBounds as String: CGRect(x: 100, y: 200, width: 600, height: 400).dictionaryRepresentation]
    }
}

@MainActor
private final class WindowLookupProbe {
    let failures: Int
    var reads = 0
    var bundleIdentifier = "qa.editor"
    var hasApplication = true
    private let permissionState = WindowPermissionState()
    var isProtected: Bool {
        get { permissionState.snapshot.secureInputEnabled }
        set { permissionState.setProtected(newValue) }
    }
    var permissions: any PermissionControlling {
        let state = permissionState
        return SystemPermissionController(snapshotProvider: { state.snapshot })
    }
    init(failures: Int) { self.failures = failures }
}

private final class WindowPermissionState: @unchecked Sendable {
    private let lock = NSLock()
    private var value = PermissionSnapshot.allGranted
    var snapshot: PermissionSnapshot { lock.withLock { value } }
    func setProtected(_ protected: Bool) {
        lock.withLock { value = PermissionSnapshot(accessibilityTrusted: true, screenCaptureAuthorized: true, secureInputEnabled: protected, sessionLocked: false) }
    }
}
