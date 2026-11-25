import CoreGraphics
import Foundation

/// Joins Vision observations into reading-order text for screenshot translate.
/// Overlay OCR still uses `VisionOCRService` (24-region budget, TextFilter).
public enum ScreenshotOCRAssembler {
    /// Normalized Vision Y distance treated as the same line.
    public static let lineTolerance: CGFloat = 0.02

    public static func joinedText(from observations: [VisionTextObservation]) -> String {
        let lines = groupedLines(readingOrder(observations))
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func readingOrder(_ observations: [VisionTextObservation]) -> [VisionTextObservation] {
        guard observations.count > 1 else { return observations }
        let items = observations.map { (observation: $0, box: $0.boundingBox.standardized) }
        let byVertical = items.sorted { lhs, rhs in
            if lhs.box.midY != rhs.box.midY {
                return lhs.box.midY > rhs.box.midY
            }
            return lhs.box.minX < rhs.box.minX
        }

        var ordered: [VisionTextObservation] = []
        ordered.reserveCapacity(items.count)
        var currentLine: [(observation: VisionTextObservation, box: CGRect)] = []
        var anchorY: CGFloat = 0

        for item in byVertical {
            if currentLine.isEmpty {
                currentLine.append(item)
                anchorY = item.box.midY
            } else if abs(anchorY - item.box.midY) <= lineTolerance {
                currentLine.append(item)
            } else {
                appendSortedLine(&currentLine, into: &ordered)
                currentLine.append(item)
                anchorY = item.box.midY
            }
        }
        if !currentLine.isEmpty {
            appendSortedLine(&currentLine, into: &ordered)
        }
        return ordered
    }

    private static func appendSortedLine(
        _ line: inout [(observation: VisionTextObservation, box: CGRect)],
        into ordered: inout [VisionTextObservation]
    ) {
        if line.count > 1 {
            line.sort { lhs, rhs in
                if lhs.box.minX != rhs.box.minX {
                    return lhs.box.minX < rhs.box.minX
                }
                return lhs.box.midY > rhs.box.midY
            }
        }
        for item in line {
            ordered.append(item.observation)
        }
        line.removeAll(keepingCapacity: true)
    }

    public static func groupedLines(_ observations: [VisionTextObservation]) -> [String] {
        var lines: [String] = []
        var current: [String] = []
        var currentY: CGFloat?
        for observation in observations {
            let text = observation.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let y = observation.boundingBox.standardized.midY
            if let lastY = currentY, abs(lastY - y) > lineTolerance {
                let line = current.joined(separator: " ")
                if !line.isEmpty { lines.append(line) }
                current = [text]
                currentY = y
            } else {
                current.append(text)
                if currentY == nil { currentY = y }
            }
        }
        let last = current.joined(separator: " ")
        if !last.isEmpty { lines.append(last) }
        return lines
    }
}

public protocol RegionTextRecognizing: Sendable {
    func recognizeJoinedText(image: CGImage) async throws -> String
}

public struct NullRegionOCR: RegionTextRecognizing {
    public init() {}
    public func recognizeJoinedText(image: CGImage) async throws -> String { "" }
}

public final class RegionVisionOCRService: RegionTextRecognizing, @unchecked Sendable {
    public let recognizer: any VisionTextRecognizing
    public let lowConfidenceThreshold: Float

    public init(
        recognizer: any VisionTextRecognizing = VisionFrameworkRecognizer(
            recognitionLanguages: ScreenshotTranslateSupport.recognitionLanguages
        ),
        lowConfidenceThreshold: Float = 0.65
    ) {
        self.recognizer = recognizer
        self.lowConfidenceThreshold = min(max(lowConfidenceThreshold, 0), 1)
    }

    public func recognizeJoinedText(image: CGImage) async throws -> String {
        let ocrImage = CGImageUtilities.downsample(image, maximumDimension: 1_600) ?? image
        let observations = try await recognizer.recognize(image: ocrImage, level: .accurate)
        return ScreenshotOCRAssembler.joinedText(from: observations)
    }
}
