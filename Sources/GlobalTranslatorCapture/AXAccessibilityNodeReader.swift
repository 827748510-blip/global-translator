import CoreGraphics
import Foundation

public final class AXAccessibilityNodeReader: AccessibilityNodeReading, @unchecked Sendable {
    public let attributeReader: any AXAttributeReading
    public let messagingTimeout: Float
    public let maxNodes: Int
    public let traversalTimeout: TimeInterval
    private let clock: @Sendable () -> UInt64

    public init(
        attributeReader: any AXAttributeReading = SystemAXAttributeReader(),
        messagingTimeout: TimeInterval = 0.2,
        maxNodes: Int = 2_048,
        traversalTimeout: TimeInterval = 0.2,
        clock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) {
        self.attributeReader = attributeReader
        self.messagingTimeout = Float(min(max(messagingTimeout, 0.01), 0.2))
        self.maxNodes = min(max(maxNodes, 0), 2_048)
        self.traversalTimeout = min(max(traversalTimeout, 0.01), 0.2)
        self.clock = clock
    }

    public func readRoot(for descriptor: ActiveWindowDescriptor) throws -> AccessibilityNode? {
        let deadline = clock() + UInt64(traversalTimeout * 1_000_000_000)
        guard clock() < deadline, let focusedWindow = attributeReader.focusedWindow(for: descriptor.pid) else { return nil }
        var budget = maxNodes
        let root = materialize(focusedWindow, budget: &budget, deadline: deadline)
        guard budget > 0, clock() < deadline else { return nil }
        return root
    }

    private func materialize(
        _ element: AXElement,
        budget: inout Int,
        deadline: UInt64
    ) -> AccessibilityNode? {
        guard budget > 0, clock() < deadline else { return nil }
        budget -= 1
        let attrs = attributeReader.batchAttributes(of: element)
        let secure = attrs.role == "AXTextField" && attrs.subrole == "AXSecureTextField"
        if secure {
            return AccessibilityNode(
                role: .textField,
                frame: attrs.frame,
                isSecure: true,
                coordinateSpace: .quartzTopLeft
            )
        }
        if attrs.isHidden {
            return AccessibilityNode(
                role: mapRole(attrs.role),
                frame: attrs.frame,
                children: [],
                isSecure: false,
                isOffscreen: true,
                coordinateSpace: .quartzTopLeft
            )
        }
        guard clock() < deadline else { return nil }
        let children = attributeReader.children(of: element).compactMap {
            materialize($0, budget: &budget, deadline: deadline)
        }
        return AccessibilityNode(
            role: mapRole(attrs.role),
            value: attrs.value,
            title: attrs.title,
            description: attrs.description,
            frame: attrs.frame,
            children: children,
            isSecure: false,
            isOffscreen: false,
            coordinateSpace: .quartzTopLeft
        )
    }

    private func mapRole(_ rawRole: String?) -> AccessibilityRole {
        switch rawRole {
        case "AXStaticText": return .staticText
        case "AXButton": return .button
        case "AXTextField", "AXTextArea", "AXComboBox": return .textField
        case "AXImage": return .image
        case "AXPage": return .page
        case "AXWebArea": return .webArea
        case "AXGroup", "AXWindow", "AXSplitGroup", "AXScrollArea", "AXLayoutArea": return .group
        default: return .other
        }
    }
}
