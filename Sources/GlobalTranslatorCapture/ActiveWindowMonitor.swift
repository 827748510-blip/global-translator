import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import os

public typealias ActiveWindowCallback = @MainActor @Sendable (ActiveWindowDescriptor?) -> Void

private struct WorkspaceObserverBox: @unchecked Sendable {
    let center: NotificationCenter
    let token: NSObjectProtocol
}

final class ActiveWindowCleanup: @unchecked Sendable {
    private struct State: Sendable {
        var workspace: WorkspaceObserverBox?
        var axRegistration: AXObserverRegistration?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func setWorkspaceObserver(center: NotificationCenter, token: NSObjectProtocol) {
        let next = WorkspaceObserverBox(center: center, token: token)
        let old = state.withLock { current -> WorkspaceObserverBox? in
            let prev = current.workspace
            current.workspace = next
            return prev
        }
        if let old {
            old.center.removeObserver(old.token)
        }
    }

    func removeWorkspaceObserver() {
        let old = state.withLock { current -> WorkspaceObserverBox? in
            let prev = current.workspace
            current.workspace = nil
            return prev
        }
        if let old {
            old.center.removeObserver(old.token)
        }
    }

    func setAXRegistration(_ registration: AXObserverRegistration?) {
        let old = state.withLock { current -> AXObserverRegistration? in
            let prev = current.axRegistration
            current.axRegistration = registration
            return prev
        }
        old?.invalidate()
    }

    deinit {
        removeWorkspaceObserver()
        setAXRegistration(nil)
    }
}

@MainActor
public final class ActiveWindowMonitor {
    public let ownBundleIdentifier: String?
    public let translatedBundleIdentifiers: Set<String>
    public let callback: ActiveWindowCallback
    public private(set) var current: ActiveWindowDescriptor?

    private var running = false
    private var revision: UInt64 = 0
    private var lastEmission: UInt64?
    private var pending: ActiveWindowDescriptor?
    var observer: AXObserver?
    var observedApplication: AXUIElement?
    var observedWindow: AXUIElement?
    var observedPID: pid_t?
    var axRegistration: AXObserverRegistration? {
        didSet { cleanup.setAXRegistration(axRegistration) }
    }
    var imageNotificationLabels: [UInt: String] = [:]
    private var workspaceToken: NSObjectProtocol?
    private let cleanup = ActiveWindowCleanup()
    private var throttleTask: Task<Void, Never>?
    private var axCoalesceTask: Task<Void, Never>?
    private var axCoalesceInvalidates = false
    private let intervalNanoseconds: UInt64 = 250_000_000
    private let axLookupQueue = DispatchQueue(label: "GlobalTranslator.axWindowLookup", qos: .userInitiated)
    private var asyncLookupGeneration: UInt64 = 0
    private var visualUpdatesEnabled = false
    private var captureRetryCount = 0
    private var descriptorRetryCount = 0
    private var captureRetryTask: Task<Void, Never>?
    private var visualTask: Task<Void, Never>?
    private lazy var visualUpdates = WindowVisualUpdates(permissions: permissions) { [weak self] in self?.handleVisualChange() }
    let permissions: any PermissionControlling
    var frontmostApplicationProvider: () -> (pid: Int32, bundleIdentifier: String)? = {
        guard let app = NSWorkspace.shared.frontmostApplication, let bundleIdentifier = app.bundleIdentifier else { return nil }
        return (app.processIdentifier, bundleIdentifier)
    }
    private var usesCustomDescriptorProvider = false
    lazy var windowDescriptorProvider: (Int32, String, Bool) -> ActiveWindowDescriptor? = { [weak self] pid, bundleIdentifier, invalidates in
        if self?.permissions.snapshot.accessibilityTrusted == true {
            self?.installAXObserver(for: pid)
        } else {
            self?.removeAXObserver()
        }
        return self?.descriptor(for: pid, bundleIdentifier: bundleIdentifier, invalidatesOverlay: invalidates)
    } {
        didSet { usesCustomDescriptorProvider = true }
    }
    /// Injectable so tests do not subscribe to the real workspace center: an
    /// unrelated app activation mid-test resets the retry budget and performs
    /// an extra lookup, which made bounded-retry tests flaky on busy machines.
    var workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter

    public init(
        ownBundleIdentifier: String? = Bundle.main.bundleIdentifier,
        translatedBundleIdentifiers: Set<String> = [],
        permissions: any PermissionControlling = SystemPermissionController(),
        callback: @escaping ActiveWindowCallback = { _ in }
    ) {
        self.ownBundleIdentifier = ownBundleIdentifier
        self.translatedBundleIdentifiers = translatedBundleIdentifiers
        self.permissions = permissions
        self.callback = callback
    }

    public convenience init(
        ownBundleIdentifier: String? = Bundle.main.bundleIdentifier,
        translatedBundleIdentifiers: Set<String> = [],
        onChange: @escaping ActiveWindowCallback
    ) {
        self.init(
            ownBundleIdentifier: ownBundleIdentifier,
            translatedBundleIdentifiers: translatedBundleIdentifiers,
            callback: onChange
        )
    }

    public func start() {
        guard !running else { return }
        running = true
        let token = workspaceNotificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshFromWorkspace() }
        }
        workspaceToken = token
        cleanup.setWorkspaceObserver(center: workspaceNotificationCenter, token: token)
        refreshFromWorkspace()
    }

    public func stop() {
        running = false
        asyncLookupGeneration &+= 1
        axCoalesceTask?.cancel()
        axCoalesceTask = nil
        axCoalesceInvalidates = false
        captureRetryTask?.cancel()
        captureRetryTask = nil
        setVisualUpdatesEnabled(false)
        throttleTask?.cancel()
        throttleTask = nil
        if let token = workspaceToken {
            workspaceNotificationCenter.removeObserver(token)
            workspaceToken = nil
        }
        cleanup.removeWorkspaceObserver()
        removeAXObserver()
        pending = nil
    }

    public func setVisualUpdatesEnabled(_ enabled: Bool) {
        visualUpdatesEnabled = enabled
        guard enabled, running, let current else {
            visualTask?.cancel()
            visualTask = nil
            visualUpdates.stop()
            return
        }
        visualTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            await self.visualUpdates.watch(current)
        }
    }

    public func retryCurrentWindowCapture() {
        scheduleWindowRetry(forMissingDescriptor: false)
    }

    func handleVisualChange() {
        refreshFromWorkspace(invalidatesOverlay: false)
    }

    private func scheduleWindowRetry(forMissingDescriptor: Bool) {
        guard running, captureRetryTask == nil else { return }
        do { try permissions.snapshot.validateCapture() } catch { return }
        if forMissingDescriptor {
            guard descriptorRetryCount < 2 else { return }
            descriptorRetryCount += 1
        } else {
            guard captureRetryCount < 2 else { return }
            captureRetryCount += 1
        }
        captureRetryTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            guard let self, self.running else { return }
            self.captureRetryTask = nil
            do { try self.permissions.snapshot.validateCapture() } catch { return }
            self.refreshFromWorkspace(isCaptureRetry: true)
        }
    }

    public func handleApplicationSwitchForTesting(bundleIdentifier: String) {
        if !isTranslatable(bundleIdentifier) {
            removeAXObserver()
            clearCurrent()
        }
    }

    public func ingestForTesting(_ descriptor: ActiveWindowDescriptor, atUptimeNanoseconds now: UInt64) {
        guard isAllowed(descriptor) else { return }
        pending = descriptor
        guard let lastEmission else {
            emitPending(atUptimeNanoseconds: now)
            return
        }
        if now >= lastEmission + intervalNanoseconds {
            emitPending(atUptimeNanoseconds: now)
        }
    }

    public func flushForTesting(atUptimeNanoseconds now: UInt64) {
        guard pending != nil else { return }
        guard lastEmission.map({ now >= $0 + intervalNanoseconds }) ?? true else { return }
        emitPending(atUptimeNanoseconds: now)
    }

    func scheduleAXRefresh(invalidatesOverlay: Bool) {
        guard running else { return }
        if invalidatesOverlay {
            axCoalesceInvalidates = true
        }
        guard axCoalesceTask == nil else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let delay: UInt64
        if let lastEmission, now < lastEmission + intervalNanoseconds {
            delay = lastEmission + intervalNanoseconds - now
        } else {
            delay = 25_000_000
        }
        axCoalesceTask = Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            guard let self, self.running else { return }
            let invalidates = self.axCoalesceInvalidates
            self.axCoalesceInvalidates = false
            self.axCoalesceTask = nil
            self.refreshFromWorkspace(invalidatesOverlay: invalidates)
        }
    }

    func refreshFromWorkspace(isCaptureRetry: Bool = false, invalidatesOverlay: Bool = true) {
        guard running else { return }
        if !isCaptureRetry {
            captureRetryCount = 0
            descriptorRetryCount = 0
            captureRetryTask?.cancel()
            captureRetryTask = nil
        }
        guard let application = frontmostApplicationProvider() else {
            asyncLookupGeneration &+= 1
            clearCurrent()
            return
        }
        let bundleIdentifier = application.bundleIdentifier
        guard isTranslatable(bundleIdentifier), application.pid != getpid() else {
            asyncLookupGeneration &+= 1
            removeAXObserver()
            clearCurrent()
            return
        }
        if usesCustomDescriptorProvider {
            let descriptor = windowDescriptorProvider(application.pid, bundleIdentifier, invalidatesOverlay)
            handleResolvedDescriptor(descriptor)
            return
        }

        let permissionsSnapshot = permissions.snapshot
        if permissionsSnapshot.accessibilityTrusted {
            installAXObserver(for: application.pid)
        } else {
            removeAXObserver()
        }
        let primaryDisplayFrame = NSScreen.screens.first?.frame
        asyncLookupGeneration &+= 1
        let generation = asyncLookupGeneration
        let pid = application.pid
        axLookupQueue.async { [weak self] in
            guard let self else { return }
            let result = self.resolveDescriptorOffMain(
                pid: pid,
                bundleIdentifier: bundleIdentifier,
                invalidatesOverlay: invalidatesOverlay,
                accessibilityTrusted: permissionsSnapshot.accessibilityTrusted,
                primaryDisplayFrame: primaryDisplayFrame
            )
            Task { @MainActor [weak self] in
                guard let self, self.running, self.asyncLookupGeneration == generation else { return }
                if let focusedWindow = result.focusedWindow?.value {
                    self.registerWindowNotifications(focusedWindow)
                }
                self.handleResolvedDescriptor(result.descriptor)
            }
        }
    }

    private func handleResolvedDescriptor(_ descriptor: ActiveWindowDescriptor?) {
        if let descriptor {
            descriptorRetryCount = 0
            ingestForTesting(descriptor, atUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds)
            scheduleFlushIfNeeded()
        } else {
            clearCurrent()
            scheduleWindowRetry(forMissingDescriptor: true)
        }
    }

    private func scheduleFlushIfNeeded() {
        guard pending != nil, throttleTask == nil, let lastEmission else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let delay = now >= lastEmission + intervalNanoseconds ? 0 : lastEmission + intervalNanoseconds - now
        throttleTask = Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            guard let self, self.running else { return }
            self.flushForTesting(atUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds)
            self.throttleTask = nil
        }
    }

    private func emitPending(atUptimeNanoseconds now: UInt64) {
        guard let descriptor = pending else { return }
        if current?.pid != descriptor.pid || current?.windowID != descriptor.windowID {
            setVisualUpdatesEnabled(false)
        }
        pending = nil
        revision &+= 1
        let emitted = ActiveWindowDescriptor(
            pid: descriptor.pid,
            bundleIdentifier: descriptor.bundleIdentifier,
            windowID: descriptor.windowID,
            frame: descriptor.frame,
            revision: revision,
            invalidatesOverlay: descriptor.invalidatesOverlay
        )
        lastEmission = now
        current = emitted
        if visualUpdatesEnabled { setVisualUpdatesEnabled(true) }
        callback(emitted)
    }

    private func clearCurrent() {
        setVisualUpdatesEnabled(false)
        pending = nil
        current = nil
        callback(nil)
    }

    private func isAllowed(_ descriptor: ActiveWindowDescriptor) -> Bool {
        isTranslatable(descriptor.bundleIdentifier) && descriptor.pid != getpid()
    }

    /// Only explicitly selected applications may be watched and captured; an
    /// empty allow list translates nothing. The tool itself never qualifies.
    private func isTranslatable(_ bundleIdentifier: String) -> Bool {
        bundleIdentifier != ownBundleIdentifier
            && bundleIdentifier != "com.maodashu.global-translator"
            && translatedBundleIdentifiers.contains(bundleIdentifier)
    }

}
