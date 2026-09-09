import CoreGraphics
import Foundation
import Testing
@testable import GlobalTranslatorCapture
import GlobalTranslatorCore

struct SelectedTextReaderTests {
    @Test
    func focusedElementSelectedTextIsPreferred() {
        let ax = FakeSelectionAXReader(selectedText: "Hello from TextEdit", range: (0, 19),
                                       bounds: CGRect(x: 10, y: 20, width: 80, height: 16))
        let clipboard = RecordingClipboardFallback(text: "should-not-use")
        let reader = AXSelectedTextReader(
            attributeReader: ax,
            clipboard: clipboard,
            frontmostApplication: { FrontmostApplicationInfo(pid: 42, bundleIdentifier: "com.apple.TextEdit") },
            primaryDisplayFrame: { CGRect(x: 0, y: 0, width: 1440, height: 900) }
        )
        let result = reader.readSelection(
            mouseLocation: CGPoint(x: 40, y: 40),
            allowClipboardFallback: true
        )
        guard case .snapshot(let snapshot) = result else {
            Issue.record("expected snapshot")
            return
        }
        #expect(snapshot.text == "Hello from TextEdit")
        #expect(snapshot.source == .accessibility)
        #expect(snapshot.bundleIdentifier == "com.apple.TextEdit")
        #expect(clipboard.callCount == 0)
        #expect(snapshot.screenFrame.width == 80)
    }

    @Test
    func emptySelectionIsEmptyNotUnavailable() {
        let ax = FakeSelectionAXReader(selectedText: "", range: (0, 0), bounds: nil)
        let clipboard = RecordingClipboardFallback(text: "clip")
        let reader = AXSelectedTextReader(
            attributeReader: ax,
            clipboard: clipboard,
            frontmostApplication: { FrontmostApplicationInfo(pid: 7, bundleIdentifier: "com.apple.Notes") },
            primaryDisplayFrame: { CGRect(x: 0, y: 0, width: 800, height: 600) }
        )
        #expect(reader.readSelection(mouseLocation: .zero) == .empty)
        #expect(clipboard.callCount == 0)
    }

    @Test
    func dragWithEmptyAXUsesClipboardFallback() {
        let ax = FakeSelectionAXReader(selectedText: "", range: (0, 0), bounds: nil)
        let clipboard = RecordingClipboardFallback(text: "Feishu selected text")
        let reader = AXSelectedTextReader(
            attributeReader: ax,
            clipboard: clipboard,
            frontmostApplication: { FrontmostApplicationInfo(pid: 21, bundleIdentifier: "com.electron.lark") },
            primaryDisplayFrame: { CGRect(x: 0, y: 0, width: 800, height: 600) }
        )
        guard case .snapshot(let snapshot) = reader.readSelection(
            mouseLocation: CGPoint(x: 40, y: 80),
            allowClipboardFallback: true
        ) else {
            Issue.record("expected clipboard snapshot after drag")
            return
        }
        #expect(snapshot.text == "Feishu selected text")
        #expect(snapshot.source == .clipboardFallback)
        #expect(snapshot.bundleIdentifier == "com.electron.lark")
        #expect(clipboard.callCount == 1)
    }

    @Test
    func clickWithoutDragAndEmptyAXDoesNotUseClipboard() {
        let ax = FakeSelectionAXReader(selectedText: "", range: (0, 0), bounds: nil)
        let clipboard = RecordingClipboardFallback(text: "should-not-copy")
        let reader = AXSelectedTextReader(
            attributeReader: ax,
            clipboard: clipboard,
            frontmostApplication: { FrontmostApplicationInfo(pid: 21, bundleIdentifier: "com.electron.lark") },
            primaryDisplayFrame: { CGRect(x: 0, y: 0, width: 800, height: 600) }
        )
        #expect(reader.readSelection(mouseLocation: .zero, allowClipboardFallback: false) == .empty)
        #expect(clipboard.callCount == 0)
    }

    @Test
    func dragWithEmptyAXAndEmptyClipboardIsUnavailable() {
        let ax = FakeSelectionAXReader(selectedText: "", range: (0, 0), bounds: nil)
        let clipboard = RecordingClipboardFallback(text: nil)
        let reader = AXSelectedTextReader(
            attributeReader: ax,
            clipboard: clipboard,
            frontmostApplication: { FrontmostApplicationInfo(pid: 21, bundleIdentifier: "com.electron.lark") },
            primaryDisplayFrame: { CGRect(x: 0, y: 0, width: 800, height: 600) }
        )
        #expect(reader.readSelection(mouseLocation: .zero, allowClipboardFallback: true) == .unavailable)
        #expect(clipboard.callCount == 1)
    }

    @Test
    func missingFocusedElementStillUsesClipboardAfterDrag() {
        let ax = FakeSelectionAXReader(hasFocus: false)
        let clipboard = RecordingClipboardFallback(text: "copied from custom canvas")
        let reader = AXSelectedTextReader(
            attributeReader: ax,
            clipboard: clipboard,
            frontmostApplication: { FrontmostApplicationInfo(pid: 9, bundleIdentifier: "com.electron.lark") },
            primaryDisplayFrame: { CGRect(x: 0, y: 0, width: 800, height: 600) }
        )
        guard case .snapshot(let snapshot) = reader.readSelection(
            mouseLocation: CGPoint(x: 12, y: 18),
            allowClipboardFallback: true
        ) else {
            Issue.record("expected clipboard snapshot without AX focus")
            return
        }
        #expect(snapshot.text == "copied from custom canvas")
        #expect(snapshot.source == .clipboardFallback)
        #expect(clipboard.callCount == 1)
    }

    @Test
    func missingFocusedElementWithoutDragDoesNotUseClipboard() {
        let ax = FakeSelectionAXReader(hasFocus: false)
        let clipboard = RecordingClipboardFallback(text: "should-not-copy")
        let reader = AXSelectedTextReader(
            attributeReader: ax,
            clipboard: clipboard,
            frontmostApplication: { FrontmostApplicationInfo(pid: 9, bundleIdentifier: "com.apple.Safari") },
            primaryDisplayFrame: { CGRect(x: 0, y: 0, width: 800, height: 600) }
        )
        #expect(reader.readSelection(mouseLocation: .zero, allowClipboardFallback: false) == .unavailable)
        #expect(clipboard.callCount == 0)
    }

    @Test
    func clipboardFallbackRestoresPasteboardWhenRangeHasNoAXText() {
        let ax = FakeSelectionAXReader(selectedText: "", range: (2, 11), bounds: CGRect(x: 0, y: 0, width: 40, height: 12))
        let clipboard = RecordingClipboardFallback(text: "Clipboard text")
        let reader = AXSelectedTextReader(
            attributeReader: ax,
            clipboard: clipboard,
            frontmostApplication: { FrontmostApplicationInfo(pid: 11, bundleIdentifier: "com.google.Chrome") },
            primaryDisplayFrame: { CGRect(x: 0, y: 0, width: 800, height: 600) }
        )
        guard case .snapshot(let snapshot) = reader.readSelection(mouseLocation: CGPoint(x: 5, y: 5)) else {
            Issue.record("expected clipboard snapshot")
            return
        }
        #expect(snapshot.text == "Clipboard text")
        #expect(snapshot.source == .clipboardFallback)
        #expect(clipboard.callCount == 1)
    }

    @Test
    func secureFieldNeverReadsValueOrClipboard() {
        let ax = FakeSelectionAXReader(
            selectedText: "password",
            range: (0, 8),
            bounds: CGRect(x: 0, y: 0, width: 40, height: 12),
            role: "AXTextField",
            subrole: "AXSecureTextField"
        )
        let clipboard = RecordingClipboardFallback(text: "stolen")
        let reader = AXSelectedTextReader(
            attributeReader: ax,
            clipboard: clipboard,
            frontmostApplication: { FrontmostApplicationInfo(pid: 3, bundleIdentifier: "com.apple.Safari") },
            primaryDisplayFrame: { CGRect(x: 0, y: 0, width: 800, height: 600) }
        )
        #expect(reader.readSelection(mouseLocation: .zero) == .empty)
        #expect(reader.readSelection(mouseLocation: .zero, allowClipboardFallback: true) == .empty)
        #expect(clipboard.callCount == 0)
        #expect(ax.selectedTextCalls == 0)
    }
}

struct ClipboardRestoreTests {
    @Test
    func copyRestoresPreviousPasteboardAndReturnsNewString() {
        let pasteboard = FakePasteboardAccess(initial: "secret-token", initialChange: 4)
        let keystroke = FakeCopyKeystroke { pasteboard.simulateCopy("selected phrase") }
        let fallback = RestoringClipboardSelectionFallback(
            pasteboard: pasteboard,
            keystroke: keystroke,
            wait: {}
        )
        #expect(fallback.copySelectedTextRestoringClipboard() == "selected phrase")
        #expect(pasteboard.stringValue == "secret-token")
        #expect(keystroke.callCount == 1)
    }

    @Test
    func unchangedPasteboardReturnsNilAndStillRestores() {
        let pasteboard = FakePasteboardAccess(initial: "keep-me", initialChange: 1)
        let keystroke = FakeCopyKeystroke {}
        let fallback = RestoringClipboardSelectionFallback(
            pasteboard: pasteboard,
            keystroke: keystroke,
            wait: {}
        )
        #expect(fallback.copySelectedTextRestoringClipboard() == nil)
        #expect(pasteboard.stringValue == "keep-me")
    }

    @Test
    func incompletePasteboardSkipsCopyKeystroke() {
        let pasteboard = FakePasteboardAccess(initial: "promised-file", initialChange: 9)
        pasteboard.captureResult = .incomplete
        let keystroke = FakeCopyKeystroke { pasteboard.simulateCopy("stolen") }
        let fallback = RestoringClipboardSelectionFallback(
            pasteboard: pasteboard,
            keystroke: keystroke,
            wait: {}
        )
        #expect(fallback.copySelectedTextRestoringClipboard() == nil)
        #expect(keystroke.callCount == 0)
        #expect(pasteboard.restoreCount == 0)
        #expect(pasteboard.stringValue == "promised-file")
    }
}

final class FakeSelectionAXReader: AXAttributeReading, @unchecked Sendable {
    private let root = AXElement(identifier: 1)
    private let hasFocus: Bool
    private let selected: String?
    private let range: (location: Int, length: Int)?
    private let bounds: CGRect?
    private let roleValue: String
    private let subroleValue: String?
    private(set) var selectedTextCalls = 0

    init(
        selectedText: String? = nil,
        range: (location: Int, length: Int)? = nil,
        bounds: CGRect? = nil,
        role: String = "AXTextArea",
        subrole: String? = nil,
        hasFocus: Bool = true
    ) {
        self.selected = selectedText
        self.range = range
        self.bounds = bounds
        self.roleValue = role
        self.subroleValue = subrole
        self.hasFocus = hasFocus
    }

    func focusedWindow(for pid: Int32) -> AXElement? { hasFocus ? root : nil }
    func focusedElement(for pid: Int32) -> AXElement? { hasFocus ? root : nil }
    func role(of element: AXElement) -> String? { roleValue }
    func subrole(of element: AXElement) -> String? { subroleValue }
    func value(of element: AXElement) -> String? { nil }
    func title(of element: AXElement) -> String? { nil }
    func description(of element: AXElement) -> String? { nil }
    func selectedText(of element: AXElement) -> String? {
        selectedTextCalls += 1
        return selected
    }
    func selectedTextRange(of element: AXElement) -> (location: Int, length: Int)? { range }
    func boundsForRange(of element: AXElement, location: Int, length: Int) -> CGRect? { bounds }
    func frame(of element: AXElement) -> CGRect? { bounds }
    func isHidden(_ element: AXElement) -> Bool { false }
    func children(of element: AXElement) -> [AXElement] { [] }
}

final class RecordingClipboardFallback: ClipboardSelectionFallingBack, @unchecked Sendable {
    let text: String?
    private(set) var callCount = 0
    init(text: String?) { self.text = text }
    func copySelectedTextRestoringClipboard() -> String? {
        callCount += 1
        return text
    }
}

final class FakePasteboardAccess: PasteboardSnapshotting, @unchecked Sendable {
    private var stored: String?
    private var count: Int
    init(initial: String, initialChange: Int) {
        stored = initial
        count = initialChange
    }
    var changeCount: Int { count }
    var stringValue: String? { stored }
    var captureResult: PasteboardCapture?
    private(set) var restoreCount = 0
    func capture() -> PasteboardCapture {
        if let captureResult { return captureResult }
        guard let stored else { return .empty }
        return .complete([PasteboardItemSnapshot(
            types: ["public.utf8-plain-text"],
            dataByType: ["public.utf8-plain-text": Data(stored.utf8)]
        )])
    }
    func restore(_ items: [PasteboardItemSnapshot]) {
        restoreCount += 1
        if let data = items.first?.dataByType["public.utf8-plain-text"] {
            stored = String(data: data, encoding: .utf8)
        } else {
            stored = nil
        }
    }
    func simulateCopy(_ value: String) {
        stored = value
        count += 1
    }
}

final class FakeCopyKeystroke: CopyKeystrokeIssuing, @unchecked Sendable {
    private let body: () -> Void
    private(set) var callCount = 0
    init(_ body: @escaping () -> Void) { self.body = body }
    func issueCopyKeystroke() {
        callCount += 1
        body()
    }
}
