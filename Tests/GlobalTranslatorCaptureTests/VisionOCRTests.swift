import CoreGraphics
import Foundation
import Testing
@testable import GlobalTranslatorCapture

struct VisionOCRTests {
    @Test
    func translatedTextGetsBudgetBeforeChineseAndNumericNoise() async throws {
        let noise = (0..<30).map { index in
            VisionTextObservation(text: "中文菜单 \(index)", boundingBox: CGRect(x: 0.01, y: 0.01, width: 0.1, height: 0.02), confidence: 0.9)
        }
        let text = VisionTextObservation(text: "Please save your changes", boundingBox: CGRect(x: 0.2, y: 0.4, width: 0.6, height: 0.04), confidence: 0.95)
        let service = VisionOCRService(recognizer: RecordingVisionRecognizer(fast: noise + [text], accurate: []))
        let result = try await service.recognize(image: try #require(makeTestImage()), window: ActiveWindowDescriptor(pid: 42, bundleIdentifier: "qa", frame: CGRect(x: 0, y: 0, width: 800, height: 600), revision: 1), revision: 1)
        #expect(result.first?.text == text.text)
        #expect(result.count <= 24)
    }

    @Test
    func fastRecognitionAvoidsAccurateWhenConfidenceIsGood() async throws {
        let recognizer = RecordingVisionRecognizer(fast: [
            VisionTextObservation(text: "  hello  world ", boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.2), confidence: 0.9)
        ], accurate: [])
        let service = VisionOCRService(recognizer: recognizer)

        let values = try await service.recognize(
            image: try #require(makeTestImage()),
            window: ActiveWindowDescriptor(pid: 1, bundleIdentifier: "foreign", frame: CGRect(x: 0, y: 0, width: 100, height: 100), revision: 1),
            revision: 1
        )

        #expect(values.map(\.text) == ["hello world"])
        #expect(await recognizer.levels() == [.fast])
    }

    @Test
    func lowConfidenceRecognitionRunsBoundedAccurateFallbackAndCapsResults() async throws {
        let low = VisionTextObservation(text: "low", boundingBox: CGRect(x: 0, y: 0, width: 0.1, height: 0.1), confidence: 0.1)
        let values = (0..<30).map { index in
            VisionTextObservation(
                text: "value-\(index)",
                boundingBox: CGRect(x: 0.01, y: 0.01, width: 0.1, height: 0.1),
                confidence: 0.8
            )
        }
        let recognizer = RecordingVisionRecognizer(fast: [low], accurate: values)
        let service = VisionOCRService(recognizer: recognizer)

        let result = try await service.recognize(
            image: try #require(makeTestImage()),
            window: ActiveWindowDescriptor(pid: 1, bundleIdentifier: "foreign", frame: CGRect(x: 0, y: 0, width: 100, height: 100), revision: 1),
            revision: 1
        )

        #expect(result.count == 24)
        #expect(await recognizer.levels() == [.fast, .accurate])
    }

    @Test
    func anyLowConfidenceFastObservationTriggersAccurateFallback() async throws {
        let recognizer = RecordingVisionRecognizer(
            fast: [
                VisionTextObservation(text: "high", boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), confidence: 0.95),
                VisionTextObservation(text: "low", boundingBox: CGRect(x: 0.4, y: 0.1, width: 0.2, height: 0.2), confidence: 0.2)
            ],
            accurate: [
                VisionTextObservation(text: "accurate", boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), confidence: 0.9)
            ]
        )
        let service = VisionOCRService(recognizer: recognizer)

        _ = try await service.recognize(
            image: try #require(makeTestImage()),
            window: ActiveWindowDescriptor(pid: 1, bundleIdentifier: "foreign", frame: CGRect(x: 0, y: 0, width: 100, height: 100), revision: 1),
            revision: 1
        )

        #expect(await recognizer.levels() == [.fast, .accurate])
    }
}

actor RecordingVisionRecognizer: VisionTextRecognizing {
    let fast: [VisionTextObservation]
    let accurate: [VisionTextObservation]
    private var calls: [OCRRecognitionLevel] = []

    init(fast: [VisionTextObservation], accurate: [VisionTextObservation]) {
        self.fast = fast
        self.accurate = accurate
    }

    func recognize(image: CGImage, level: OCRRecognitionLevel) async throws -> [VisionTextObservation] {
        calls.append(level)
        return level == .fast ? fast : accurate
    }

    func levels() -> [OCRRecognitionLevel] { calls }
}
