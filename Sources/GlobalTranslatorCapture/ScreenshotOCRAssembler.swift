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
        observations.sorted { left, right in
            let leftBox = left.boundingBox.standardized
            let rightBox = right.boundingBox.standardized
            if abs(leftBox.midY - rightBox.midY) > lineTolerance {
                return leftBox.midY > rightBox.midY
            }
            return leftBox.minX < rightBox.minX
        }
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
        let fast = try await recognizer.recognize(image: image, level: .fast)
        let selected: [VisionTextObservation]
        if fast.isEmpty || fast.contains(where: { $0.confidence < lowConfidenceThreshold }) {
            selected = try await recognizer.recognize(image: image, level: .accurate)
        } else {
            selected = fast
        }
        return ScreenshotOCRAssembler.joinedText(from: selected)
    }
}
