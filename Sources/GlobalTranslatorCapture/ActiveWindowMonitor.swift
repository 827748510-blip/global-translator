import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

public typealias ActiveWindowCallback = @MainActor @Sendable (ActiveWindowDescriptor?) -> Void

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
    var imageNotificationLabels: [UInt: String] = [:]
    private var workspaceToken: NSObjectProtocol?
    private var throttleTask: Task<Void, Never>?
    private let intervalNanoseconds: UInt64 = 250_000_000
    private var visualUpdatesEnabled = false
    private var captureRetryCount = 0
    private var descriptorRetryCount = 0
    private var captureRetryTask: Task<Void, Never>?
    private var visualTask: Task<Void, Never>?
    private lazy var visualUpdates = WindowVisualUpdates { [weak self] in self?.handleVisualChange() }
    let permissions: any PermissionControlling
    var frontmostApplicationProvider: () -> (pid: Int32, bundleIdentifier: String)? = {
        guard let app = NSWorkspace.shared.frontmostApplication, let bundleIdentifier = app.bundleIdentifier else { return nil }
        return (app.processIdentifier, bundleIdentifier)
    }
    lazy var windowDescriptorProvider: (Int32, String, Bool) -> ActiveWindowDescriptor? = { [weak self] pid, bundleIdentifier, invalidates in
        if self?.permissions.snapshot.accessibilityTrusted == true {
            self?.installAXObserver(for: pid)
        } else {
            self?.removeAXObserver()
        }
        return self?.descriptor(for: pid, bundleIdentifier: bundleIdentifier, invalidatesOverlay: invalidates)
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
        workspaceToken = workspaceNotificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshFromWorkspace() }
        }
        refreshFromWorkspace()
    }

    public func stop() {
        running = false
        captureRetryTask?.cancel()
        captureRetryTask = nil
        setVisualUpdatesEnabled(false)
        throttleTask?.cancel()
        throttleTask = nil
        if let token = workspaceToken {
            workspaceNotificationCenter.removeObserver(token)
            workspaceToken = nil
        }
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

    func refreshFromWorkspace(isCaptureRetry: Bool = false, invalidatesOverlay: Bool = true) {
        guard running else { return }
        if !isCaptureRetry {
            captureRetryCount = 0
            descriptorRetryCount = 0
            captureRetryTask?.cancel()
            captureRetryTask = nil
        }
        guard let application = frontmostApplicationProvider() else {
            clearCurrent()
            return
        }
        let bundleIdentifier = application.bundleIdentifier
        guard isTranslatable(bundleIdentifier), application.pid != getpid() else {
            removeAXObserver()
            clearCurrent()
            return
        }
        let descriptor = windowDescriptorProvider(application.pid, bundleIdentifier, invalidatesOverlay)
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
