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
    func regionOCRUsesSingleAccuratePass() async throws {
        let recognizer = RecordingVisionRecognizer(
            fast: [
                VisionTextObservation(
                    text: "Fast text",
                    boundingBox: CGRect(x: 0.1, y: 0.5, width: 0.4, height: 0.1),
                    confidence: 0.99
                )
            ],
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
        #expect(await recognizer.levels() == [.accurate])
    }

    @Test
    func regionOCRKeepsChineseAndEnglish() async throws {
        let recognizer = RecordingVisionRecognizer(
            fast: [],
            accurate: [
                VisionTextObservation(
                    text: "Hello 世界",
                    boundingBox: CGRect(x: 0.1, y: 0.5, width: 0.5, height: 0.1),
                    confidence: 0.92
                )
            ]
        )
        let service = RegionVisionOCRService(recognizer: recognizer)
        let text = try await service.recognizeJoinedText(image: try #require(makeTestImage()))
        #expect(text == "Hello 世界")
        #expect(await recognizer.levels() == [.accurate])
    }

    @Test
    func regionOCRDownsamplesOversizedScreenshotTo1600() async throws {
        let capturingRecognizer = ImageSizeCapturingRecognizer()
        let service = RegionVisionOCRService(recognizer: capturingRecognizer)
        let oversized = try #require(makeTestImage(width: 3_200, height: 1_600))
        _ = try await service.recognizeJoinedText(image: oversized)
        let seen = try #require(await capturingRecognizer.lastSize)
        #expect(seen.width == 1_600)
        #expect(seen.height == 800)
    }

    @Test
    func readingOrderIsStrictWeakOrderAcrossDenseLines() {
        let items = (0..<30).map { idx in
            let row = idx / 5
            let col = idx % 5
            return VisionTextObservation(
                text: "r\(row)c\(col)",
                boundingBox: CGRect(
                    x: 0.1 + Double(4 - col) * 0.15,
                    y: 0.8 - Double(row) * 0.1 - Double(col % 2) * 0.005,
                    width: 0.1,
                    height: 0.03
                ),
                confidence: 0.95
            )
        }
        let ordered = ScreenshotOCRAssembler.readingOrder(items)
        #expect(ordered.count == 30)
        #expect(ordered.prefix(5).map(\.text) == ["r0c4", "r0c3", "r0c2", "r0c1", "r0c0"])
    }
}

private actor ImageSizeCapturingRecognizer: VisionTextRecognizing {
    private(set) var lastSize: CGSize?

    func recognize(image: CGImage, level _: OCRRecognitionLevel) async throws -> [VisionTextObservation] {
        lastSize = CGSize(width: image.width, height: image.height)
        return []
    }
}
