import ApplicationServices
import CoreGraphics
import Foundation

public final class AXElement: @unchecked Sendable, Hashable {
    public let identifier: Int
    fileprivate let rawValue: AXUIElement?

    public init(identifier: Int) {
        self.identifier = identifier
        rawValue = nil
    }

    fileprivate init(rawValue: AXUIElement) {
        identifier = ObjectIdentifier(rawValue as AnyObject).hashValue
        self.rawValue = rawValue
    }

    public static func == (lhs: AXElement, rhs: AXElement) -> Bool {
        lhs.identifier == rhs.identifier
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(identifier)
    }
}
public protocol AXAttributeReading: Sendable {
    func focusedWindow(for pid: Int32) -> AXElement?
    func focusedElement(for pid: Int32) -> AXElement?
    func role(of element: AXElement) -> String?
    func subrole(of element: AXElement) -> String?
    func value(of element: AXElement) -> String?
    func title(of element: AXElement) -> String?
    func description(of element: AXElement) -> String?
    func selectedText(of element: AXElement) -> String?
    func selectedTextRange(of element: AXElement) -> (location: Int, length: Int)?
    func boundsForRange(of element: AXElement, location: Int, length: Int) -> CGRect?
    func frame(of element: AXElement) -> CGRect?
    func isHidden(_ element: AXElement) -> Bool
    func children(of element: AXElement) -> [AXElement]
}

public extension AXAttributeReading {
    func focusedElement(for pid: Int32) -> AXElement? { nil }
    func selectedText(of element: AXElement) -> String? { nil }
    func selectedTextRange(of element: AXElement) -> (location: Int, length: Int)? { nil }
    func boundsForRange(of element: AXElement, location: Int, length: Int) -> CGRect? { nil }
}

public final class SystemAXAttributeReader: AXAttributeReading, @unchecked Sendable {
    public let messagingTimeout: Float

    public init(messagingTimeout: TimeInterval = 0.2) {
        self.messagingTimeout = Float(min(max(messagingTimeout, 0.01), 0.2))
    }

    public func focusedWindow(for pid: Int32) -> AXElement? {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, messagingTimeout)
        guard let element = copyElement(application, kAXFocusedWindowAttribute as CFString) else { return nil }
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return AXElement(rawValue: element)
    }

    public func focusedElement(for pid: Int32) -> AXElement? {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, messagingTimeout)
        guard let element = copyElement(application, kAXFocusedUIElementAttribute as CFString) else { return nil }
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return AXElement(rawValue: element)
    }

    public func role(of element: AXElement) -> String? {
        stringValue(of: element, attribute: kAXRoleAttribute as CFString)
    }

    public func subrole(of element: AXElement) -> String? {
        stringValue(of: element, attribute: kAXSubroleAttribute as CFString)
    }

    public func value(of element: AXElement) -> String? {
        stringValue(of: element, attribute: kAXValueAttribute as CFString)
    }

    public func title(of element: AXElement) -> String? {
        stringValue(of: element, attribute: kAXTitleAttribute as CFString)
    }

    public func description(of element: AXElement) -> String? {
        stringValue(of: element, attribute: kAXDescriptionAttribute as CFString)
    }

    public func selectedText(of element: AXElement) -> String? {
        stringValue(of: element, attribute: kAXSelectedTextAttribute as CFString)
    }

    public func selectedTextRange(of element: AXElement) -> (location: Int, length: Int)? {
        guard let raw = element.rawValue,
              let value = copyAXValue(raw, kAXSelectedTextRangeAttribute as CFString) else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value, .cfRange, &range) else { return nil }
        return (range.location, range.length)
    }

    public func boundsForRange(of element: AXElement, location: Int, length: Int) -> CGRect? {
        guard let raw = element.rawValue else { return nil }
        var range = CFRange(location: location, length: length)
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return nil }
        var value: CFTypeRef?
        let status = AXUIElementCopyParameterizedAttributeValue(
            raw,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeValue,
            &value
        )
        guard status == .success, let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        var rect = CGRect.zero
        guard AXValueGetValue(axValue, .cgRect, &rect) else { return nil }
        return rect
    }

    public func frame(of element: AXElement) -> CGRect? {
        guard let raw = element.rawValue,
              let position = copyAXValue(raw, kAXPositionAttribute as CFString),
              let size = copyAXValue(raw, kAXSizeAttribute as CFString) else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &point), AXValueGetValue(size, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    public func isHidden(_ element: AXElement) -> Bool {
        guard let raw = element.rawValue else { return false }
        return (copyValue(raw, kAXHiddenAttribute as CFString) as? Bool) ?? false
    }

    public func children(of element: AXElement) -> [AXElement] {
        guard let raw = element.rawValue,
              let values = copyValue(raw, kAXChildrenAttribute as CFString),
              let children = values as? [AXUIElement] else { return [] }
        return children.map(AXElement.init(rawValue:))
    }

    private func stringValue(of element: AXElement, attribute: CFString) -> String? {
        guard let raw = element.rawValue else { return nil }
        if let value = copyValue(raw, attribute) as? String { return value }
        if let value = copyValue(raw, attribute) as? NSString { return String(value) }
        return nil
    }

    private func copyValue(_ element: AXUIElement, _ attribute: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute, &value) == .success ? value : nil
    }

    private func copyElement(_ element: AXUIElement, _ attribute: CFString) -> AXUIElement? {
        guard let value = copyValue(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func copyAXValue(_ element: AXUIElement, _ attribute: CFString) -> AXValue? {
        guard let value = copyValue(element, attribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXValue.self)
    }
}
