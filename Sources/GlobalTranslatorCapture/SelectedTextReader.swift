import AppKit
import CoreGraphics
import Foundation

public enum SelectedTextSource: String, Equatable, Sendable {
    case accessibility
    case clipboardFallback
}

public struct FrontmostApplicationInfo: Equatable, Sendable {
    public let pid: Int32
    public let bundleIdentifier: String

    public init(pid: Int32, bundleIdentifier: String) {
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
    }
}

public struct SelectedTextSnapshot: Equatable, Sendable {
    public let text: String
    public let screenFrame: CGRect
    public let source: SelectedTextSource
    public let bundleIdentifier: String

    public init(
        text: String,
        screenFrame: CGRect,
        source: SelectedTextSource,
        bundleIdentifier: String
    ) {
        self.text = text
        self.screenFrame = screenFrame
        self.source = source
        self.bundleIdentifier = bundleIdentifier
    }
}

public enum SelectedTextReadResult: Equatable, Sendable {
    case snapshot(SelectedTextSnapshot)
    case empty
    case unavailable
}

public protocol SelectedTextReading: Sendable {
    func readSelection(mouseLocation: CGPoint) -> SelectedTextReadResult
}

public struct NullSelectedTextReader: SelectedTextReading {
    public init() {}
    public func readSelection(mouseLocation: CGPoint) -> SelectedTextReadResult { .empty }
}

public protocol ClipboardSelectionFallingBack: Sendable {
    func copySelectedTextRestoringClipboard() -> String?
}

/// Reads AX `selectedText` / selected range on the focused element.
/// Clipboard copy is only used when AX reports a non-empty range but no
/// string, and only if the pasteboard can be fully snapshotted first.
public struct AXSelectedTextReader: SelectedTextReading, @unchecked Sendable {
    public let attributeReader: any AXAttributeReading
    public let clipboard: (any ClipboardSelectionFallingBack)?
    private let frontmostApplication: () -> FrontmostApplicationInfo?
    private let primaryDisplayFrame: () -> CGRect?

    public init(
        attributeReader: any AXAttributeReading = SystemAXAttributeReader(),
        clipboard: (any ClipboardSelectionFallingBack)? = RestoringClipboardSelectionFallback(),
        frontmostApplication: @escaping () -> FrontmostApplicationInfo? = {
            AXSelectedTextReader.systemFrontmostApplication()
        },
        primaryDisplayFrame: @escaping () -> CGRect? = {
            NSScreen.screens.first?.frame
        }
    ) {
        self.attributeReader = attributeReader
        self.clipboard = clipboard
        self.frontmostApplication = frontmostApplication
        self.primaryDisplayFrame = primaryDisplayFrame
    }

    public func readSelection(mouseLocation: CGPoint) -> SelectedTextReadResult {
        guard let app = frontmostApplication() else { return .unavailable }
        let focused = attributeReader.focusedElement(for: app.pid)
        let window = attributeReader.focusedWindow(for: app.pid)
        guard focused != nil || window != nil else { return .unavailable }

        if let focused, isSecure(focused) { return .empty }

        let candidates = [focused, window].compactMap { $0 }
        for element in candidates {
            if isSecure(element) { continue }
            if let snapshot = snapshot(from: element, app: app, mouseLocation: mouseLocation) {
                return .snapshot(snapshot)
            }
        }
        return .empty
    }

    private func snapshot(
        from element: AXElement,
        app: FrontmostApplicationInfo,
        mouseLocation: CGPoint
    ) -> SelectedTextSnapshot? {
        let range = attributeReader.selectedTextRange(of: element)
        var text = attributeReader.selectedText(of: element)
        var source = SelectedTextSource.accessibility
        let trimmedAX = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmedAX.isEmpty, let range, range.length > 0, let clipboard {
            if let copied = clipboard.copySelectedTextRestoringClipboard() {
                text = copied
                source = .clipboardFallback
            }
        }
        let resolved = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !resolved.isEmpty else { return nil }

        let axBounds: CGRect?
        if let range, range.length > 0 {
            axBounds = attributeReader.boundsForRange(of: element, location: range.location, length: range.length)
                ?? attributeReader.frame(of: element)
        } else {
            axBounds = attributeReader.frame(of: element)
        }
        let screenFrame = convertedFrame(axBounds) ?? SelectionTranslateSupport.fallbackFrame(at: mouseLocation)
        return SelectedTextSnapshot(
            text: SelectionTranslateSupport.cappedSource(resolved),
            screenFrame: screenFrame,
            source: source,
            bundleIdentifier: app.bundleIdentifier
        )
    }

    private func convertedFrame(_ quartz: CGRect?) -> CGRect? {
        guard let quartz, quartz.width >= 0, quartz.height >= 0 else { return nil }
        guard quartz.width > 0 || quartz.height > 0 else { return nil }
        guard let primary = primaryDisplayFrame() else { return nil }
        return CoordinateConverter.quartzTopLeftFrameToAppKitGlobal(quartz, primaryDisplayFrame: primary)
    }

    private func isSecure(_ element: AXElement) -> Bool {
        attributeReader.role(of: element) == "AXTextField"
            && attributeReader.subrole(of: element) == "AXSecureTextField"
    }

    public static func systemFrontmostApplication() -> FrontmostApplicationInfo? {
        guard let application = NSWorkspace.shared.frontmostApplication else { return nil }
        return FrontmostApplicationInfo(
            pid: application.processIdentifier,
            bundleIdentifier: application.bundleIdentifier ?? ""
        )
    }
}
