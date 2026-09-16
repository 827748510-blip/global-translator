import CoreGraphics
import Foundation
import Testing
@testable import GlobalTranslatorCapture

struct RegionCaptureTests {
    @Test
    func retinaHalfScreenKeepsBufferUncropped() throws {
        let screen = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        let half = CGRect(x: 0, y: 0, width: 500, height: 800)
        let image = try #require(makeTestImage(width: 1_000, height: 1_600))
        let result = RegionCaptureFallback.croppedIfFullDisplay(
            image,
            selection: half,
            screenFrame: screen,
            scale: 2
        )
        #expect(result.width == 1_000)
        #expect(result.height == 1_600)
    }

    @Test
    func retinaFullDisplayBufferIsCroppedToSelection() throws {
        let screen = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        let half = CGRect(x: 0, y: 0, width: 500, height: 800)
        let image = try #require(makeTestImage(width: 2_000, height: 1_600))
        let result = RegionCaptureFallback.croppedIfFullDisplay(
            image,
            selection: half,
            screenFrame: screen,
            scale: 2
        )
        #expect(result.width == 1_000)
        #expect(result.height == 1_600)
    }

    @Test
    func retinaFullDisplayBufferCropsOffsetSelectionInPixels() throws {
        let screen = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        let selection = CGRect(x: 100, y: 200, width: 80, height: 40)
        let image = try #require(makeTestImage(width: 2_000, height: 1_600))
        let result = RegionCaptureFallback.croppedIfFullDisplay(
            image,
            selection: selection,
            screenFrame: screen,
            scale: 2
        )
        #expect(result.width == 160)
        #expect(result.height == 80)
    }

    @Test
    func oneXFullDisplayFallbackStillCrops() throws {
        let screen = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        let half = CGRect(x: 0, y: 0, width: 500, height: 800)
        let region = try #require(makeTestImage(width: 500, height: 800))
        let kept = RegionCaptureFallback.croppedIfFullDisplay(
            region,
            selection: half,
            screenFrame: screen,
            scale: 1
        )
        #expect(kept.width == 500)
        #expect(kept.height == 800)

        let full = try #require(makeTestImage(width: 1_000, height: 800))
        let cropped = RegionCaptureFallback.croppedIfFullDisplay(
            full,
            selection: half,
            screenFrame: screen,
            scale: 1
        )
        #expect(cropped.width == 500)
        #expect(cropped.height == 800)
    }
}
