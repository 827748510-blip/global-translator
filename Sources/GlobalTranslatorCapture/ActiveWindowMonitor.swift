import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

public typealias ActiveWindowCallback = @MainActor @Sendable (ActiveWindowDescriptor?) -> Void

@MainActor
public final class ActiveWindowMonitor {
    public let ownBundleIdentifier: String?
    public let excludedBundleIdentifiers: Set<String>
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
    private var workspaceToken: NSObjectProtocol?
    private var throttleTask: Task<Void, Never>?
    private let intervalNanoseconds: UInt64 = 250_000_000

    public init(
        ownBundleIdentifier: String? = Bundle.main.bundleIdentifier,
        excludedBundleIdentifiers: Set<String> = [],
        callback: @escaping ActiveWindowCallback = { _ in }
    ) {
        self.ownBundleIdentifier = ownBundleIdentifier
        self.excludedBundleIdentifiers = excludedBundleIdentifiers
        self.callback = callback
    }

    public convenience init(
        ownBundleIdentifier: String? = Bundle.main.bundleIdentifier,
        excludedBundleIdentifiers: Set<String> = [],
        onChange: @escaping ActiveWindowCallback
    ) {
        self.init(
            ownBundleIdentifier: ownBundleIdentifier,
            excludedBundleIdentifiers: excludedBundleIdentifiers,
            callback: onChange
        )
    }

    public func start() {
        guard !running else { return }
        running = true
        workspaceToken = NSWorkspace.shared.notificationCenter.addObserver(
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
        throttleTask?.cancel()
        throttleTask = nil
        if let token = workspaceToken {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
            workspaceToken = nil
        }
        removeAXObserver()
        pending = nil
    }

    public func handleApplicationSwitchForTesting(bundleIdentifier: String) {
        if isExcluded(bundleIdentifier) {
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

    func refreshFromWorkspace() {
        guard running else { return }
        let application = NSWorkspace.shared.frontmostApplication
        guard let application, let bundleIdentifier = application.bundleIdentifier else {
            clearCurrent()
            return
        }
        guard !isExcluded(bundleIdentifier), application.processIdentifier != getpid() else {
            removeAXObserver()
            clearCurrent()
            return
        }
        installAXObserver(for: application.processIdentifier)
        let descriptor = descriptor(for: application.processIdentifier, bundleIdentifier: bundleIdentifier)
        if let descriptor {
            ingestForTesting(descriptor, atUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds)
            scheduleFlushIfNeeded()
        } else {
            clearCurrent()
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
        pending = nil
        revision &+= 1
        let emitted = ActiveWindowDescriptor(
            pid: descriptor.pid,
            bundleIdentifier: descriptor.bundleIdentifier,
            windowID: descriptor.windowID,
            frame: descriptor.frame,
            revision: revision
        )
        lastEmission = now
        current = emitted
        callback(emitted)
    }

    private func clearCurrent() {
        pending = nil
        current = nil
        callback(nil)
    }

    private func isAllowed(_ descriptor: ActiveWindowDescriptor) -> Bool {
        !isExcluded(descriptor.bundleIdentifier) && descriptor.pid != getpid()
    }

    private func isExcluded(_ bundleIdentifier: String) -> Bool {
        bundleIdentifier == ownBundleIdentifier || excludedBundleIdentifiers.contains(bundleIdentifier)
    }

}
