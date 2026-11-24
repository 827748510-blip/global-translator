import CoreGraphics
import Foundation
import AppKit

public final class AccessibilityTextCollector: AccessibilityCollecting, @unchecked Sendable {
    public let reader: any AccessibilityNodeReading
    public let maxNodes: Int
    public let maxRegions: Int
    public let timeout: TimeInterval
    public let primaryDisplayFrame: CGRect?
    private let translatedBundleIdentifiers: Set<String>

    public convenience init(
        translatedBundleIdentifiers: Set<String> = [],
        maxNodes: Int = 256,
        maxRegions: Int = 24,
        timeout: TimeInterval = 0.2,
        primaryDisplayFrame: CGRect? = nil
    ) {
        self.init(
            translatedBundleIdentifiers: translatedBundleIdentifiers,
            reader: AXAccessibilityNodeReader(maxNodes: maxNodes),
            maxNodes: maxNodes,
            maxRegions: maxRegions,
            timeout: timeout,
            primaryDisplayFrame: primaryDisplayFrame
        )
    }

    public init(
        translatedBundleIdentifiers: Set<String>,
        reader: any AccessibilityNodeReading,
        maxNodes: Int = 256,
        maxRegions: Int = 24,
        timeout: TimeInterval = 0.2,
        primaryDisplayFrame: CGRect? = nil
    ) {
        self.reader = reader
        self.maxNodes = min(max(maxNodes, 0), 2_048)
        self.maxRegions = min(max(maxRegions, 0), 24)
        self.timeout = min(max(timeout, 0.01), 0.2)
        self.primaryDisplayFrame = primaryDisplayFrame
        self.translatedBundleIdentifiers = translatedBundleIdentifiers
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
        // Window-level authorization happens before any AX tree is read.
        guard translatedBundleIdentifiers.contains(descriptor.bundleIdentifier) else {
            throw CaptureError.excludedApplication(descriptor.bundleIdentifier)
        }
        guard let root = try reader.readRoot(for: descriptor) else { return [] }
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeout * 1_000_000_000)
        var pending: [(node: AccessibilityNode, inWebArea: Bool)] = [(root, false)]
        var regions: [TextRegion] = []
        var bodyRegions: [TextRegion] = []
        var webRegions: [TextRegion] = []
        var hasWebArea = false
        var untranslatedRegions: [TextRegion] = []
        var largeImageFrames: [CGRect] = []
        var readableTextFrames: [CGRect] = []
        var seen = Set<String>()
        var visited = 0
        while !pending.isEmpty, visited < maxNodes {
            if DispatchTime.now().uptimeNanoseconds >= deadline { break }
            let entry = pending.removeLast()
            let node = entry.node
            visited += 1
            guard !node.isSecure, !node.isOffscreen,
                  node.bundleIdentifier.map({ translatedBundleIdentifiers.contains($0) }) ?? true else { continue }
            let inWebArea = entry.inWebArea || node.role == .webArea
            if node.role == .webArea, let frame = nodeFrame(node), descriptor.frame.intersects(frame) {
                hasWebArea = true
            }
            pending.append(contentsOf: node.children.reversed().map { ($0, inWebArea) })
            if node.role == .image || node.role == .page || (node.role == .group && node.children.isEmpty), let frame = nodeFrame(node) {
                let visibleImage = frame.intersection(descriptor.frame)
                if !visibleImage.isNull, visibleImage.width * visibleImage.height >= descriptor.frame.width * descriptor.frame.height * 0.25 {
                    if hasInvalidImageTextCoordinates(node, imageFrame: frame, deadline: deadline) {
                        throw CaptureError.accessibilityUnavailable
                    }
                    largeImageFrames.append(visibleImage)
                }
            }
            guard let frame = nodeFrame(node), shouldInclude(node, frame: frame, descriptor: descriptor) else { continue }
            let text = normalizedText(for: node)
            guard !text.isEmpty else { continue }
            if node.role == .staticText || node.role == .textField { readableTextFrames.append(frame) }
            let key = dedupeKey(text: text, frame: frame)
            guard seen.insert(key).inserted else { continue }
            let region = TextRegion(
                id: UUID(),
                sourceText: text,
                screenFrame: frame,
                confidence: 1,
                source: .accessibility,
                windowRevision: descriptor.revision
            )
            if inWebArea { webRegions.append(region) }
            if TextFilter.shouldTranslate(text) {
                if node.role == .staticText || node.role == .textField {
                    bodyRegions.append(region)
                } else {
                    regions.append(region)
                }
            } else if untranslatedRegions.count < maxRegions {
                untranslatedRegions.append(region)
            }
        }
        guard pending.isEmpty else { throw CaptureError.accessibilityUnavailable }
        if largeImageFrames.contains(where: { imageFrame in
            !readableTextFrames.contains { imageFrame.contains(CGPoint(x: $0.midX, y: $0.midY)) }
        }) {
            throw CaptureError.accessibilityUnavailable
        }
        if hasWebArea {
            guard !webRegions.isEmpty else { throw CaptureError.accessibilityUnavailable }
            let eligible = webRegions.filter { TextFilter.shouldTranslate($0.sourceText) }
            let remaining = webRegions.filter { !TextFilter.shouldTranslate($0.sourceText) }
            return Array((eligible + remaining).prefix(maxRegions))
        }
        let selectedRegions = Array((bodyRegions + regions + untranslatedRegions).prefix(maxRegions))
        if descriptor.frame.height >= 300, !selectedRegions.isEmpty,
           selectedRegions.allSatisfy({ $0.screenFrame.midY >= descriptor.frame.minY + descriptor.frame.height * 0.7 }) {
            throw CaptureError.accessibilityUnavailable
        }
        return selectedRegions
    }

    private func hasInvalidImageTextCoordinates(_ image: AccessibilityNode, imageFrame: CGRect, deadline: UInt64) -> Bool {
        var pending = image.children
        var visited = 0
        while let node = pending.popLast() {
            guard visited < maxNodes, DispatchTime.now().uptimeNanoseconds < deadline else { return true }
            visited += 1
            guard !node.isSecure, !node.isOffscreen else { continue }
            pending.append(contentsOf: node.children)
            guard node.role == .staticText || node.role == .textField, !normalizedText(for: node).isEmpty else { continue }
            guard let frame = nodeFrame(node), frame.width > 0, frame.height > 0,
                  imageFrame.contains(CGPoint(x: frame.midX, y: frame.midY)) else { return true }
        }
        return false
    }

    private func shouldInclude(_ node: AccessibilityNode, frame: CGRect, descriptor: ActiveWindowDescriptor) -> Bool {
        guard !node.isSecure, !node.isOffscreen,
              node.bundleIdentifier.map({ translatedBundleIdentifiers.contains($0) }) ?? true,
              frame.width > 1, frame.height > 1,
              descriptor.frame.intersects(frame) else { return false }
        let windowArea = descriptor.frame.width * descriptor.frame.height
        let nodeArea = frame.width * frame.height
        guard windowArea > 0, nodeArea < windowArea * 0.92 else { return false }
        if node.role == .image { return nodeArea < windowArea * 0.25 }
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
        case .image:
            candidate = [node.title, node.description, node.value].compactMap { $0 }.first { !$0.isEmpty }
        case .group, .page, .webArea:
            candidate = nil
        }
        return candidate?.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") ?? ""
    }

    private func dedupeKey(text: String, frame: CGRect) -> String {
        let values = [frame.minX, frame.minY, frame.width, frame.height].map { String(format: "%.2f", Double($0)) }
        return text + "|" + values.joined(separator: ",")
    }
}
