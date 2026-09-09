import AppKit
import CoreGraphics
import Foundation

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

/// Saves the general pasteboard, posts ⌘C, reads the new string, then
/// restores the previous contents. Used when AX selectedText is empty after
/// a real drag, or when AX reports a non-empty range but no string.
public struct RestoringClipboardSelectionFallback: ClipboardSelectionFallingBack, @unchecked Sendable {
    private let pasteboard: any PasteboardSnapshotting
    private let keystroke: any CopyKeystrokeIssuing
    private let wait: @Sendable () -> Void

    public init(
        pasteboard: any PasteboardSnapshotting = SystemPasteboardAccess(),
        keystroke: any CopyKeystrokeIssuing = HIDCopyKeystrokeIssuer(),
        wait: @escaping @Sendable () -> Void = {
            Thread.sleep(forTimeInterval: 0.01)
        }
    ) {
        self.pasteboard = pasteboard
        self.keystroke = keystroke
        self.wait = wait
    }

    public func copySelectedTextRestoringClipboard() -> String? {
        let backup = pasteboard.capture()
        guard backup != .incomplete else { return nil }
        let before = pasteboard.changeCount
        keystroke.issueCopyKeystroke()
        var changed = pasteboard.changeCount != before
        if !changed {
            for _ in 0..<12 {
                wait()
                if pasteboard.changeCount != before {
                    changed = true
                    break
                }
            }
        }
        let copied = pasteboard.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
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
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
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
        pasteboard.writeObjects(objects)
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
