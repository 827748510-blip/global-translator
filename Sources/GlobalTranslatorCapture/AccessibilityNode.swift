import CoreGraphics
import Foundation

public enum AccessibilityRole: String, Codable, Equatable, Sendable {
    case staticText
    case button
    case textField
    case group
    case other
}

public enum AccessibilityCoordinateSpace: String, Codable, Equatable, Sendable {
    case appKitGlobal
    case quartzTopLeft
}

public struct AccessibilityNode: Codable, Equatable, Sendable {
    public let role: AccessibilityRole
    public let value: String?
    public let title: String?
    public let description: String?
    public let frame: CGRect?
    public let children: [AccessibilityNode]
    public let isSecure: Bool
    public let isOffscreen: Bool
    public let bundleIdentifier: String?
    public let coordinateSpace: AccessibilityCoordinateSpace

    public init(
        role: AccessibilityRole,
        value: String? = nil,
        title: String? = nil,
        description: String? = nil,
        frame: CGRect? = nil,
        children: [AccessibilityNode] = [],
        isSecure: Bool = false,
        isOffscreen: Bool = false,
        bundleIdentifier: String? = nil,
        coordinateSpace: AccessibilityCoordinateSpace = .appKitGlobal
    ) {
        self.role = role
        self.value = value
        self.title = title
        self.description = description
        self.frame = frame
        self.children = children
        self.isSecure = isSecure
        self.isOffscreen = isOffscreen
        self.bundleIdentifier = bundleIdentifier
        self.coordinateSpace = coordinateSpace
    }

    public static func staticText(
        _ text: String,
        frame: CGRect,
        isSecure: Bool = false,
        coordinateSpace: AccessibilityCoordinateSpace = .appKitGlobal
    ) -> AccessibilityNode {
        AccessibilityNode(role: .staticText, value: text, frame: frame, isSecure: isSecure, coordinateSpace: coordinateSpace)
    }

    public static func button(
        _ text: String,
        frame: CGRect,
        coordinateSpace: AccessibilityCoordinateSpace = .appKitGlobal
    ) -> AccessibilityNode {
        AccessibilityNode(role: .button, value: text, frame: frame, coordinateSpace: coordinateSpace)
    }

    public static func textField(
        _ text: String,
        frame: CGRect,
        isSecure: Bool = false,
        coordinateSpace: AccessibilityCoordinateSpace = .appKitGlobal
    ) -> AccessibilityNode {
        AccessibilityNode(role: .textField, value: text, frame: frame, isSecure: isSecure, coordinateSpace: coordinateSpace)
    }

    public static func group(
        children: [AccessibilityNode],
        coordinateSpace: AccessibilityCoordinateSpace = .appKitGlobal
    ) -> AccessibilityNode {
        AccessibilityNode(role: .group, children: children, coordinateSpace: coordinateSpace)
    }
}

public protocol AccessibilityNodeReading: Sendable {
    func readRoot(for descriptor: ActiveWindowDescriptor) throws -> AccessibilityNode?
}

public enum AccessibilityCollectionResult: Sendable, Equatable {
    case regions([TextRegion])
    case empty
    case unavailable(CaptureError)

    public var regions: [TextRegion] {
        if case .regions(let values) = self { return values }
        return []
    }
}

public protocol AccessibilityCollecting: Sendable {
    func collectResult(from descriptor: ActiveWindowDescriptor) async -> AccessibilityCollectionResult
}
