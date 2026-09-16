import CoreGraphics
import Foundation
import NaturalLanguage
import Vision

public enum OCRRecognitionLevel: String, Codable, Equatable, Sendable {
    case fast
    case accurate
}

public struct VisionTextObservation: Codable, Equatable, Sendable {
    public let text: String
    public let boundingBox: CGRect
    public let confidence: Float

    public init(text: String, boundingBox: CGRect, confidence: Float) {
        self.text = text
        self.boundingBox = boundingBox
        self.confidence = confidence
    }
}

public protocol VisionTextRecognizing: Sendable {
    func recognize(image: CGImage, level: OCRRecognitionLevel) async throws -> [VisionTextObservation]
}

public protocol VisionOCRProviding: Sendable {
    func recognize(
        image: CGImage,
        window: ActiveWindowDescriptor,
        revision: UInt64
    ) async throws -> [VisionTextObservation]
}

public final class VisionOCRService: VisionOCRProviding, @unchecked Sendable {
    public let recognizer: any VisionTextRecognizing
    public let maxRegions: Int
    public let lowConfidenceThreshold: Float

    public init(
        recognizer: any VisionTextRecognizing = VisionFrameworkRecognizer(),
        maxRegions: Int = 24,
        lowConfidenceThreshold: Float = 0.65
    ) {
        self.recognizer = recognizer
        self.maxRegions = min(max(maxRegions, 0), 24)
        self.lowConfidenceThreshold = min(max(lowConfidenceThreshold, 0), 1)
    }

    public func recognize(
        image: CGImage,
        window: ActiveWindowDescriptor,
        revision: UInt64
    ) async throws -> [VisionTextObservation] {
        let fast = try await recognizer.recognize(image: image, level: .fast)
        let selected: [VisionTextObservation]
        if fast.isEmpty || fast.contains(where: { $0.confidence < lowConfidenceThreshold }) {
            selected = try await recognizer.recognize(image: image, level: .accurate)
        } else {
            selected = fast
        }
        _ = Self.detectLanguage(in: selected.map(\.text).joined(separator: " "))
        return normalized(selected)
    }

    public static func detectLanguage(in text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage?.rawValue
    }

    private func normalized(_ observations: [VisionTextObservation]) -> [VisionTextObservation] {
        var seen = Set<String>()
        let normalized = observations.compactMap { observation -> VisionTextObservation? in
            let text = observation.text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            let box = observation.boundingBox.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            guard !text.isEmpty, !box.isNull, !box.isEmpty, observation.confidence >= 0,
                  seen.insert(text + "|\(box.minX)|\(box.minY)|\(box.width)|\(box.height)").inserted else { return nil }
            return VisionTextObservation(text: text, boundingBox: box, confidence: min(max(observation.confidence, 0), 1))
        }
        var eligible: [VisionTextObservation] = []
        var other: [VisionTextObservation] = []
        for observation in normalized {
            if TextFilter.shouldTranslate(observation.text) {
                eligible.append(observation)
            } else {
                other.append(observation)
            }
        }
        return Array((eligible + other).prefix(maxRegions))
    }
}

@available(macOS 14.0, *)
public final class VisionFrameworkRecognizer: VisionTextRecognizing, @unchecked Sendable {
    public let recognitionLanguages: [String]

    public init(recognitionLanguages: [String] = []) {
        self.recognitionLanguages = recognitionLanguages
    }

    public func recognize(image: CGImage, level: OCRRecognitionLevel) async throws -> [VisionTextObservation] {
        try Task.checkCancellation()
        var output: [VisionTextObservation] = []
        let request = VNRecognizeTextRequest { request, _ in
            guard let observations = request.results as? [VNRecognizedTextObservation] else { return }
            output = observations.compactMap { observation in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                return VisionTextObservation(
                    text: candidate.string,
                    boundingBox: observation.boundingBox,
                    confidence: candidate.confidence
                )
            }
        }
        request.recognitionLevel = level == .fast ? .fast : .accurate
        request.usesLanguageCorrection = true
        if recognitionLanguages.isEmpty {
            request.automaticallyDetectsLanguage = true
        } else {
            request.recognitionLanguages = recognitionLanguages
            request.automaticallyDetectsLanguage = true
        }
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        return output
    }
}
