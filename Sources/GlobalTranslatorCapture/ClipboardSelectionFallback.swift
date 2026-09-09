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

public protocol PasteboardSnapshotting: Sendable {
    var changeCount: Int { get }
    var stringValue: String? { get }
    func capture() -> [PasteboardItemSnapshot]
    func restore(_ items: [PasteboardItemSnapshot])
}

public protocol CopyKeystrokeIssuing: Sendable {
    func issueCopyKeystroke()
}

/// Saves the general pasteboard, posts ⌘C, reads the new string, then
/// restores the previous contents. Used only when AX selectedText is empty
/// but the selected range length is greater than zero.
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
        pasteboard.restore(backup)
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

    public func capture() -> [PasteboardItemSnapshot] {
        guard let items = NSPasteboard.general.pasteboardItems else { return [] }
        return items.map { item in
            var dataByType: [String: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    dataByType[type.rawValue] = data
                }
            }
            return PasteboardItemSnapshot(types: item.types.map(\.rawValue), dataByType: dataByType)
        }
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
