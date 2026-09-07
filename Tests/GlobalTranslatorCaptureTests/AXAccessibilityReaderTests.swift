import CoreGraphics
import Foundation
import Testing
@testable import GlobalTranslatorCapture

struct AXAccessibilityReaderTests {
    @Test
    func incompleteTreeDoesNotReturnOnlyTheFirstControls() throws {
        let reader = AXAccessibilityNodeReader(
            attributeReader: RecordingAXAttributeReader(role: "AXGroup", subrole: nil),
            maxNodes: 2,
            clock: { 0 }
        )
        let descriptor = ActiveWindowDescriptor(pid: 123, bundleIdentifier: "qa.browser",
            frame: CGRect(x: 0, y: 0, width: 800, height: 600), revision: 1)
        #expect(try reader.readRoot(for: descriptor) == nil)
    }

    @Test
    func secureTextFieldIsDetectedBeforeSensitiveAttributesOrChildren() throws {
        let reader = RecordingAXAttributeReader()
        let materializer = AXAccessibilityNodeReader(
            attributeReader: reader,
            maxNodes: 16,
            traversalTimeout: 1
        )
        let descriptor = ActiveWindowDescriptor(
            pid: 123,
            bundleIdentifier: "foreign",
            frame: CGRect(x: 0, y: 0, width: 400, height: 300),
            revision: 1
        )

        let node = try #require(try materializer.readRoot(for: descriptor))

        #expect(node.isSecure)
        #expect(reader.valueCalls == 0)
        #expect(reader.titleCalls == 0)
        #expect(reader.descriptionCalls == 0)
        #expect(reader.childrenCalls == 0)
    }

    @Test
    func materializationStopsWhenOverallTraversalDeadlineExpires() throws {
        let clock = SequenceClock(values: [0, 0, 100_000_000, 200_000_000])
        let reader = AXAccessibilityNodeReader(
            attributeReader: RecordingAXAttributeReader(role: "AXGroup", subrole: nil),
            maxNodes: 128,
            traversalTimeout: 0.2,
            clock: { clock.next() }
        )
        let descriptor = ActiveWindowDescriptor(
            pid: 123,
            bundleIdentifier: "foreign",
            frame: CGRect(x: 0, y: 0, width: 400, height: 300),
            revision: 1
        )

        let node = try reader.readRoot(for: descriptor)

        #expect(node == nil)
    }
}

final class RecordingAXAttributeReader: AXAttributeReading, @unchecked Sendable {
    private let root = AXElement(identifier: 1)
    private let secureFrame = CGRect(x: 20, y: 30, width: 200, height: 40)
    private let roleValue: String
    private let subroleValue: String?
    private(set) var valueCalls = 0
    private(set) var titleCalls = 0
    private(set) var descriptionCalls = 0
    private(set) var childrenCalls = 0

    init(role: String = "AXTextField", subrole: String? = "AXSecureTextField") {
        roleValue = role
        subroleValue = subrole
    }

    func focusedWindow(for pid: Int32) -> AXElement? { root }

    func role(of element: AXElement) -> String? { roleValue }

    func subrole(of element: AXElement) -> String? { subroleValue }

    func value(of element: AXElement) -> String? {
        valueCalls += 1
        return "secret"
    }

    func title(of element: AXElement) -> String? {
        titleCalls += 1
        return "secret"
    }

    func description(of element: AXElement) -> String? {
        descriptionCalls += 1
        return "secret"
    }

    func frame(of element: AXElement) -> CGRect? { secureFrame }

    func isHidden(_ element: AXElement) -> Bool { false }

    func children(of element: AXElement) -> [AXElement] {
        childrenCalls += 1
        return [AXElement(identifier: 2)]
    }
}

final class SequenceClock: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UInt64]

    init(values: [UInt64]) {
        self.values = values
    }

    func next() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return values.isEmpty ? 200_000_000 : values.removeFirst()
    }
}
