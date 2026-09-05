import CoreGraphics
import Foundation
import AppKit

public final class AccessibilityTextCollector: AccessibilityCollecting, @unchecked Sendable {
    public let reader: any AccessibilityNodeReading
    public let maxNodes: Int
    public let maxRegions: Int
    public let timeout: TimeInterval
    public let primaryDisplayFrame: CGRect?
    private let excludedBundleIdentifiers: Set<String>

    public convenience init(
        maxNodes: Int = 256,
        maxRegions: Int = 24,
        timeout: TimeInterval = 0.2,
        excludedBundleIdentifiers: Set<String> = [],
        primaryDisplayFrame: CGRect? = nil
    ) {
        self.init(
            reader: AXAccessibilityNodeReader(maxNodes: maxNodes),
            maxNodes: maxNodes,
            maxRegions: maxRegions,
            timeout: timeout,
            excludedBundleIdentifiers: excludedBundleIdentifiers,
            primaryDisplayFrame: primaryDisplayFrame
        )
    }

    public init(
        reader: any AccessibilityNodeReading,
        maxNodes: Int = 256,
        maxRegions: Int = 24,
        timeout: TimeInterval = 0.2,
        excludedBundleIdentifiers: Set<String> = [],
        primaryDisplayFrame: CGRect? = nil
    ) {
        self.reader = reader
        self.maxNodes = min(max(maxNodes, 0), 2_048)
        self.maxRegions = min(max(maxRegions, 0), 24)
        self.timeout = min(max(timeout, 0.01), 0.2)
        self.primaryDisplayFrame = primaryDisplayFrame
        self.excludedBundleIdentifiers = excludedBundleIdentifiers
    }

    public func collectResult(from descriptor: ActiveWindowDescriptor) async -> AccessibilityCollectionResult {
        do {
            let regions = try collectThrowing(from: descriptor)
            return regions.isEmpty ? .empty : .regions(regions)
        } catch let error as CaptureError {
            return .unavailable(error)
        } catch {
            return .unavailable(.accessibilityUnavailable)
        }
    }

    public func collect(from descriptor: ActiveWindowDescriptor) -> [TextRegion] {
        (try? collectThrowing(from: descriptor)) ?? []
    }

    private func collectThrowing(from descriptor: ActiveWindowDescriptor) throws -> [TextRegion] {
        guard descriptor.frame.width > 0, descriptor.frame.height > 0 else {
            throw CaptureError.invalidWindow
        }
        guard let root = try reader.readRoot(for: descriptor) else { return [] }
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeout * 1_000_000_000)
        var pending = [root]
        var regions: [TextRegion] = []
        var seen = Set<String>()
        var visited = 0
        while !pending.isEmpty, visited < maxNodes, regions.count < maxRegions {
            if DispatchTime.now().uptimeNanoseconds >= deadline { break }
            let node = pending.removeLast()
            visited += 1
            pending.append(contentsOf: node.children.reversed())
            guard let frame = nodeFrame(node), shouldInclude(node, frame: frame, descriptor: descriptor) else { continue }
            let text = normalizedText(for: node)
            guard !text.isEmpty else { continue }
            let key = dedupeKey(text: text, frame: frame)
            guard seen.insert(key).inserted else { continue }
            regions.append(TextRegion(
                id: UUID(),
                sourceText: text,
                screenFrame: frame,
                confidence: 1,
                source: .accessibility,
                windowRevision: descriptor.revision
            ))
        }
        return regions
    }

    private func shouldInclude(_ node: AccessibilityNode, frame: CGRect, descriptor: ActiveWindowDescriptor) -> Bool {
        guard !node.isSecure, !node.isOffscreen,
              node.bundleIdentifier.map({ !excludedBundleIdentifiers.contains($0) }) ?? true,
              frame.width > 0, frame.height > 0,
              descriptor.frame.intersects(frame) else { return false }
        let windowArea = descriptor.frame.width * descriptor.frame.height
        let nodeArea = frame.width * frame.height
        guard windowArea > 0, nodeArea < windowArea * 0.92 else { return false }
        return node.role == .staticText || node.role == .button || node.role == .textField ||
            (node.role == .other && node.description != nil)
    }

    private func nodeFrame(_ node: AccessibilityNode) -> CGRect? {
        guard let frame = node.frame else { return nil }
        switch node.coordinateSpace {
        case .appKitGlobal:
            return frame
        case .quartzTopLeft:
            guard let primaryDisplayFrame = primaryDisplayFrame ?? NSScreen.screens.first?.frame else { return nil }
            return CoordinateConverter.quartzTopLeftFrameToAppKitGlobal(
                frame,
                primaryDisplayFrame: primaryDisplayFrame
            )
        }
    }

    private func normalizedText(for node: AccessibilityNode) -> String {
        let candidate: String?
        switch node.role {
        case .staticText, .button, .textField:
            candidate = node.value ?? node.title ?? node.description
        case .other:
            candidate = node.description ?? node.value ?? node.title
        case .group:
            candidate = nil
        }
        return candidate?.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") ?? ""
    }

    private func dedupeKey(text: String, frame: CGRect) -> String {
        let values = [frame.minX, frame.minY, frame.width, frame.height].map { String(format: "%.2f", Double($0)) }
        return text + "|" + values.joined(separator: ",")
    }
}
