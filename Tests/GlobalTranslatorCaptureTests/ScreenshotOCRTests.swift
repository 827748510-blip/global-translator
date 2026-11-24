import CoreGraphics
import Foundation
import Testing
@testable import GlobalTranslatorCapture

struct ScreenshotOCRTests {
    @Test
    func assemblerJoinsTopToBottomThenLeftToRight() {
        let hello = VisionTextObservation(
            text: "Hello",
            boundingBox: CGRect(x: 0.1, y: 0.7, width: 0.2, height: 0.05),
            confidence: 0.9
        )
        let world = VisionTextObservation(
            text: "world",
            boundingBox: CGRect(x: 0.35, y: 0.7, width: 0.2, height: 0.05),
            confidence: 0.9
        )
        let next = VisionTextObservation(
            text: "Next line",
            boundingBox: CGRect(x: 0.1, y: 0.4, width: 0.4, height: 0.05),
            confidence: 0.9
        )
        let joined = ScreenshotOCRAssembler.joinedText(from: [next, world, hello])
        #expect(joined == "Hello world\nNext line")
    }

    @Test
    func assemblerSkipsEmptyObservations() {
        let empty = VisionTextObservation(text: "   ", boundingBox: CGRect(x: 0, y: 0, width: 0.1, height: 0.1), confidence: 1)
        #expect(ScreenshotOCRAssembler.joinedText(from: [empty]) == "")
    }

    @Test
    func regionOCRUsesAccurateFallbackWhenFastIsEmpty() async throws {
        let recognizer = RecordingVisionRecognizer(
            fast: [],
            accurate: [
                VisionTextObservation(
                    text: "Please save",
                    boundingBox: CGRect(x: 0.1, y: 0.5, width: 0.4, height: 0.1),
                    confidence: 0.9
                )
            ]
        )
        let service = RegionVisionOCRService(recognizer: recognizer)
        let text = try await service.recognizeJoinedText(image: try #require(makeTestImage()))
        #expect(text == "Please save")
        #expect(await recognizer.levels() == [.fast, .accurate])
    }

    @Test
    func regionOCRKeepsChineseAndEnglish() async throws {
        let recognizer = RecordingVisionRecognizer(
            fast: [
                VisionTextObservation(
                    text: "Hello 世界",
                    boundingBox: CGRect(x: 0.1, y: 0.5, width: 0.5, height: 0.1),
                    confidence: 0.92
                )
            ],
            accurate: []
        )
        let service = RegionVisionOCRService(recognizer: recognizer)
        let text = try await service.recognizeJoinedText(image: try #require(makeTestImage()))
        #expect(text == "Hello 世界")
        #expect(await recognizer.levels() == [.fast])
    }
}
