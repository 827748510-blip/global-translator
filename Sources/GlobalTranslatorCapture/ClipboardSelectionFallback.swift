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
    func capture() -> PasteboardCapture
    func restore(_ items: [PasteboardItemSnapshot])
}

public protocol CopyKeystrokeIssuing: Sendable {
    func issueCopyKeystroke()
}

/// Serializes steal-and-restore windows. Two overlapping reads (fast
/// consecutive drags) must not let the second call snapshot the first call's
/// temporary selection text as the "user clipboard".
private final class ClipboardBorrowGate: @unchecked Sendable {
    private struct State {
        var busy = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func acquire() async {
        let takenImmediately: Bool = state.withLock { current in
            if current.busy { return false }
            current.busy = true
            return true
        }
        guard !takenImmediately else { return }
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

    func release() {
        let next: CheckedContinuation<Void, Never>? = state.withLock { current in
            guard !current.waiters.isEmpty else {
                current.busy = false
                return nil
            }
            return current.waiters.removeFirst()
        }
        next?.resume()
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
    /// Must **ignore cancellation**. Once ⌘C is posted, the target app writes
    /// the pasteboard later; if the wait aborts early, the restore runs first
    /// and the late copy overwrites it, leaving the user's clipboard holding
    /// the selected text. Cancellation only decides the return value.
    private let wait: @Sendable () async -> Void
    private let gate = ClipboardBorrowGate()

    public init(
        pasteboard: any PasteboardSnapshotting = SystemPasteboardAccess(),
        keystroke: any CopyKeystrokeIssuing = HIDCopyKeystrokeIssuer(),
        wait: @escaping @Sendable () async -> Void = {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + .milliseconds(Self.waitIntervalMilliseconds)
                ) {
                    continuation.resume()
                }
            }
        }
    ) {
        self.pasteboard = pasteboard
        self.keystroke = keystroke
        self.wait = wait
    }

    public func copySelectedTextRestoringClipboard() async -> String? {
        guard !Task.isCancelled else { return nil }
        await gate.acquire()
        guard !Task.isCancelled else {
            gate.release()
            return nil
        }
        let result = await borrowAndRestore()
        gate.release()
        return result
    }

    private func borrowAndRestore() async -> String? {
        let backup = pasteboard.capture()
        guard backup != .incomplete else { return nil }
        let before = pasteboard.changeCount
        keystroke.issueCopyKeystroke()
        var changed = pasteboard.changeCount != before
        if !changed {
            for _ in 0..<Self.maximumWaitAttempts {
                await wait()
                if pasteboard.changeCount != before {
                    changed = true
                    break
                }
            }
        }
        let copied = pasteboard.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
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
        guard changed, let copied, !copied.isEmpty else { return nil }
        return copied
    }
}

public struct SystemPasteboardAccess: PasteboardSnapshotting, @unchecked Sendable {
    public init() {}

    public var changeCount: Int { NSPasteboard.general.changeCount }

    public var stringValue: String? {
        NSPasteboard.general.string(forType: .string)
    }

    public func capture() -> PasteboardCapture {
        guard let items = NSPasteboard.general.pasteboardItems else { return .empty }
        if items.isEmpty { return .empty }
        var snapshots: [PasteboardItemSnapshot] = []
        snapshots.reserveCapacity(items.count)
        for item in items {
            var dataByType: [String: Data] = [:]
            for type in item.types {
                guard let data = item.data(forType: type) else {
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
