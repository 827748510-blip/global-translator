import AppKit
import CoreGraphics
import Foundation
import os

public struct PasteboardItemSnapshot: Equatable, Sendable {
    public let types: [String]
    public let dataByType: [String: Data]

    public init(types: [String], dataByType: [String: Data]) {
        self.types = types
        self.dataByType = dataByType
    }
}

/// A pasteboard backup is only safe to steal-and-restore when every declared
/// type already has bytes. Promised files and lazy providers yield nil data.
public enum PasteboardCapture: Equatable, Sendable {
    case empty
    case complete([PasteboardItemSnapshot])
    case incomplete
}

public protocol PasteboardSnapshotting: Sendable {
    var changeCount: Int { get }
    var stringValue: String? { get }
    var hasSensitiveContent: Bool { get }
    func capture() -> PasteboardCapture
    func restore(_ items: [PasteboardItemSnapshot])
}

public extension PasteboardSnapshotting {
    var hasSensitiveContent: Bool { false }
}

public protocol CopyKeystrokeIssuing: Sendable {
    func issueCopyKeystroke()
}

/// Coordinates exclusive access to `NSPasteboard.general` across selection
/// steal-and-restore windows, screenshot copy/auto-copy, and popover Copy.
public final class ClipboardBorrowCoordinator: @unchecked Sendable {
    public static let shared = ClipboardBorrowCoordinator()

    private struct State {
        var busy = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    public var isBorrowing: Bool {
        state.withLock { $0.busy }
    }

    public func tryAcquire() -> Bool {
        state.withLock { current in
            if current.busy { return false }
            current.busy = true
            return true
        }
    }

    public func acquire() async {
        guard !tryAcquire() else { return }
        await withCheckedContinuation { continuation in
            let resumedImmediately: Bool = state.withLock { current in
                if current.busy {
                    current.waiters.append(continuation)
                    return false
                }
                current.busy = true
                return true
            }
            if resumedImmediately { continuation.resume() }
        }
    }

    public func release() {
        let next: CheckedContinuation<Void, Never>? = state.withLock { current in
            guard !current.waiters.isEmpty else {
                current.busy = false
                return nil
            }
            return current.waiters.removeFirst()
        }
        next?.resume()
    }

    @MainActor
    public func withMainActorExclusiveAccess<T>(_ operation: @MainActor () async throws -> T) async rethrows -> T {
        if !tryAcquire() {
            await acquire()
        }
        defer { release() }
        return try await operation()
    }
}

/// Saves the general pasteboard, posts ⌘C, reads the new string, then
/// restores the previous contents. Used when AX selectedText is empty after
/// a real drag, or when AX reports a non-empty range but no string.
///
/// MainActor because every AppKit call here (`NSPasteboard`, `NSEvent`
/// coordinates) is AppKit-facing. The wait is async, so the main thread is
/// free while a slow Electron page services ⌘C.
@MainActor
public struct RestoringClipboardSelectionFallback: ClipboardSelectionFallingBack, @unchecked Sendable {
    /// How long to wait for the target app to service ⌘C. The keystroke is
    /// delivered asynchronously and the app handles it on its main thread;
    /// 50 ms used to be the whole budget and Electron / webview pages under
    /// load regularly missed it, which looked like 「划词没反应」. The await does
    /// not block the main thread, so a larger ceiling is safe.
    public nonisolated static let maximumWaitAttempts = 40
    public nonisolated static let waitIntervalMilliseconds = 5

    private let pasteboard: any PasteboardSnapshotting
    private let keystroke: any CopyKeystrokeIssuing
    private let permissions: any PermissionControlling
    private let coordinator: ClipboardBorrowCoordinator
    private let frontmostPIDProvider: @MainActor @Sendable () -> Int32?
    /// Must **ignore cancellation**. Once ⌘C is posted, the target app writes
    /// the pasteboard later; if the wait aborts early, the restore runs first
    /// and the late copy overwrites it, leaving the user's clipboard holding
    /// the selected text. Cancellation only decides the return value.
    private let wait: (@Sendable () async -> Void)?

    public init(
        pasteboard: any PasteboardSnapshotting = SystemPasteboardAccess(),
        keystroke: any CopyKeystrokeIssuing = HIDCopyKeystrokeIssuer(),
        permissions: any PermissionControlling = SystemPermissionController(),
        coordinator: ClipboardBorrowCoordinator = .shared,
        frontmostPIDProvider: @escaping @MainActor @Sendable () -> Int32? = {
            NSWorkspace.shared.frontmostApplication?.processIdentifier
        },
        wait: (@Sendable () async -> Void)? = nil
    ) {
        self.pasteboard = pasteboard
        self.keystroke = keystroke
        self.permissions = permissions
        self.coordinator = coordinator
        self.frontmostPIDProvider = frontmostPIDProvider
        self.wait = wait
    }

    public func copySelectedTextRestoringClipboard() async -> String? {
        await copySelectedTextRestoringClipboard(expectedPID: nil)
    }

    public func copySelectedTextRestoringClipboard(expectedPID: Int32?) async -> String? {
        guard !Task.isCancelled else { return nil }
        await coordinator.acquire()
        defer { coordinator.release() }
        guard !Task.isCancelled else { return nil }
        let snap = permissions.snapshot
        guard !snap.secureInputEnabled, !snap.sessionLocked else { return nil }
        if let expectedPID, frontmostPIDProvider() != expectedPID {
            return nil
        }
        return await borrowAndRestore()
    }

    private func borrowAndRestore() async -> String? {
        let backup = pasteboard.capture()
        guard backup != .incomplete else { return nil }
        let before = pasteboard.changeCount
        keystroke.issueCopyKeystroke()
        var changed = pasteboard.changeCount != before
        if !changed {
            let maxAttempts = wait != nil ? Self.maximumWaitAttempts : 14
            for attempt in 0..<maxAttempts {
                if let wait {
                    await wait()
                } else {
                    let delayMs: Int
                    switch attempt {
                    case 0..<4: delayMs = 5
                    case 4..<8: delayMs = 10
                    default: delayMs = 20
                    }
                    await Self.sleepMilliseconds(delayMs)
                }
                if pasteboard.changeCount != before {
                    changed = true
                    break
                }
            }
        }
        let sensitive = pasteboard.hasSensitiveContent
        let copied = sensitive ? nil : pasteboard.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let stillAllowed: Bool = {
            let currentPermissions = permissions.snapshot
            return !currentPermissions.secureInputEnabled && !currentPermissions.sessionLocked
        }()
        // Restore after the target app had its full window: a cancelled settle
        // must never leave the user's clipboard holding the selection text.
        switch backup {
        case .complete(let items):
            pasteboard.restore(items)
        case .empty:
            pasteboard.restore([])
        case .incomplete:
            break
        }
        guard changed, stillAllowed, let copied, !copied.isEmpty else { return nil }
        return copied
    }

    private nonisolated static func sleepMilliseconds(_ milliseconds: Int) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(milliseconds)) {
                continuation.resume()
            }
        }
    }
}

public struct SystemPasteboardAccess: PasteboardSnapshotting, @unchecked Sendable {
    public static let defaultMaximumBackupBytes = 16 * 1024 * 1024

    public static let sensitivePasteboardTypes: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
        "org.nspasteboard.AutoGeneratedType",
        "com.agilebits.onepassword"
    ]

    public let maximumBackupBytes: Int

    public init(maximumBackupBytes: Int = defaultMaximumBackupBytes) {
        self.maximumBackupBytes = max(0, maximumBackupBytes)
    }

    public var changeCount: Int { NSPasteboard.general.changeCount }

    public var stringValue: String? {
        NSPasteboard.general.string(forType: .string)
    }

    public var hasSensitiveContent: Bool {
        guard let items = NSPasteboard.general.pasteboardItems else { return false }
        for item in items {
            for type in item.types {
                if Self.sensitivePasteboardTypes.contains(type.rawValue) {
                    return true
                }
            }
        }
        return false
    }

    public func capture() -> PasteboardCapture {
        guard let items = NSPasteboard.general.pasteboardItems else { return .empty }
        if items.isEmpty { return .empty }
        var snapshots: [PasteboardItemSnapshot] = []
        snapshots.reserveCapacity(items.count)
        var totalBytes = 0
        for item in items {
            for type in item.types where Self.sensitivePasteboardTypes.contains(type.rawValue) {
                return .incomplete
            }
            var dataByType: [String: Data] = [:]
            dataByType.reserveCapacity(item.types.count)
            for type in item.types {
                guard let data = item.data(forType: type) else {
                    return .incomplete
                }
                totalBytes += data.count
                guard totalBytes <= maximumBackupBytes else {
                    return .incomplete
                }
                dataByType[type.rawValue] = data
            }
            snapshots.append(PasteboardItemSnapshot(
                types: item.types.map(\.rawValue),
                dataByType: dataByType
            ))
        }
        return .complete(snapshots)
    }

    public func restore(_ items: [PasteboardItemSnapshot]) {
        let pasteboard = NSPasteboard.general
        guard !items.isEmpty else {
            pasteboard.clearContents()
            return
        }
        // Build the replacement items before clearing: if construction cannot
        // produce anything, clearing first would leave the user with an empty
        // pasteboard and no way back.
        let objects: [NSPasteboardItem] = items.map { snapshot in
            let item = NSPasteboardItem()
            for typeName in snapshot.types {
                let type = NSPasteboard.PasteboardType(typeName)
                if let data = snapshot.dataByType[typeName] {
                    item.setData(data, forType: type)
                }
            }
            return item
        }
        pasteboard.clearContents()
        if !pasteboard.writeObjects(objects) {
            // One retry so a transient failure does not silently drop the backup.
            pasteboard.clearContents()
            _ = pasteboard.writeObjects(objects)
        }
    }
}

public struct HIDCopyKeystrokeIssuer: CopyKeystrokeIssuing, @unchecked Sendable {
    public init() {}

    public func issueCopyKeystroke() {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyC: CGKeyCode = 0x08
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyC, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyC, keyDown: false) else {
            return
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
