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
    func readSelection(mouseLocation: CGPoint, allowClipboardFallback: Bool) -> SelectedTextReadResult
}

public extension SelectedTextReading {
    func readSelection(mouseLocation: CGPoint) -> SelectedTextReadResult {
        readSelection(mouseLocation: mouseLocation, allowClipboardFallback: false)
    }
}

public struct NullSelectedTextReader: SelectedTextReading {
    public init() {}
    public func readSelection(mouseLocation _: CGPoint, allowClipboardFallback _: Bool) -> SelectedTextReadResult {
        .empty
    }
}

public protocol ClipboardSelectionFallingBack: Sendable {
    func copySelectedTextRestoringClipboard() -> String?
}

/// Reads AX `selectedText` / selected range on the focused element.
///
/// Clipboard ⌘C is used when the pasteboard can be fully snapshotted and:
/// - AX reports a non-empty range but no string (legacy path), or
/// - the caller allows it after a real mouse-drag selection (Electron / Feishu
///   often expose empty `selectedText` and a zero range).
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

    public func readSelection(mouseLocation: CGPoint, allowClipboardFallback: Bool) -> SelectedTextReadResult {
        guard let app = frontmostApplication() else { return .unavailable }
        let focused = attributeReader.focusedElement(for: app.pid)
        let window = attributeReader.focusedWindow(for: app.pid)

        if let focused, isSecure(focused) { return .empty }

        let candidates = [focused, window].compactMap { $0 }
        for element in candidates {
            if isSecure(element) { continue }
            if let snapshot = accessibilitySnapshot(from: element, app: app, mouseLocation: mouseLocation) {
                return .snapshot(snapshot)
            }
        }

        let hasPositiveRange = candidates.contains { element in
            (attributeReader.selectedTextRange(of: element)?.length ?? 0) > 0
        }
        if (allowClipboardFallback || hasPositiveRange),
           let copied = clipboard?.copySelectedTextRestoringClipboard() {
            let resolved = copied.trimmingCharacters(in: .whitespacesAndNewlines)
            if !resolved.isEmpty {
                let anchor = candidates.first { element in
                    (attributeReader.selectedTextRange(of: element)?.length ?? 0) > 0
                } ?? candidates.first
                return .snapshot(clipboardSnapshot(
                    text: resolved,
                    from: anchor,
                    app: app,
                    mouseLocation: mouseLocation
                ))
            }
        }

        if candidates.isEmpty || allowClipboardFallback {
            return .unavailable
        }
        return .empty
    }

    private func accessibilitySnapshot(
        from element: AXElement,
        app: FrontmostApplicationInfo,
        mouseLocation: CGPoint
    ) -> SelectedTextSnapshot? {
        let resolved = attributeReader.selectedText(of: element)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !resolved.isEmpty else { return nil }
        return SelectedTextSnapshot(
            text: SelectionTranslateSupport.cappedSource(resolved),
            screenFrame: resolvedFrame(of: element, mouseLocation: mouseLocation),
            source: .accessibility,
            bundleIdentifier: app.bundleIdentifier
        )
    }

    private func clipboardSnapshot(
        text: String,
        from element: AXElement?,
        app: FrontmostApplicationInfo,
        mouseLocation: CGPoint
    ) -> SelectedTextSnapshot {
        SelectedTextSnapshot(
            text: SelectionTranslateSupport.cappedSource(text),
            screenFrame: clipboardAnchorFrame(of: element, mouseLocation: mouseLocation),
            source: .clipboardFallback,
            bundleIdentifier: app.bundleIdentifier
        )
    }

    /// Feishu / Electron often expose a zero range on a large webview. Using that
    /// element's full AX frame would pin the popover to a window edge. Anchor to
    /// the mouse unless AX has a real selected-range rect.
    private func clipboardAnchorFrame(of element: AXElement?, mouseLocation: CGPoint) -> CGRect {
        if let element,
           let range = attributeReader.selectedTextRange(of: element),
           range.length > 0,
           let bounds = attributeReader.boundsForRange(
            of: element,
            location: range.location,
            length: range.length
           ),
           let converted = convertedFrame(bounds) {
            return converted
        }
        return SelectionTranslateSupport.fallbackFrame(at: mouseLocation)
    }

    private func resolvedFrame(of element: AXElement, mouseLocation: CGPoint) -> CGRect {
        let range = attributeReader.selectedTextRange(of: element)
        let axBounds: CGRect?
        if let range, range.length > 0 {
            axBounds = attributeReader.boundsForRange(of: element, location: range.location, length: range.length)
                ?? attributeReader.frame(of: element)
        } else {
            axBounds = attributeReader.frame(of: element)
        }
        return convertedFrame(axBounds) ?? SelectionTranslateSupport.fallbackFrame(at: mouseLocation)
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
