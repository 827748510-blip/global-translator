import CoreGraphics
import Foundation
import Testing
@testable import GlobalTranslatorCapture

struct CaptureReadinessTests {
    @Test(arguments: [true, false])
    func protectionActivatedDuringAXReadRejectsCapturedText(secureInput: Bool) async throws {
        let state = ReadinessPermissionState()
        let screenshot = CountingScreenshotProvider(image: makeTestImage())
        let pipeline = CapturePipeline(
            translatedBundleIdentifiers: ["qa.capture"],
            permissions: SystemPermissionController(snapshotProvider: { state.snapshot }),
            accessibility: ReadinessAccessibilityCollector {
                state.protect(secureInput: secureInput)
                return .regions([Self.region(text: "Private test text")])
            },
            screenshot: screenshot,
            ocr: FakeOCRService(regions: [])
        )

        await #expect(throws: CaptureError.protected(secureInput ? .secureInput : .sessionLocked)) {
            _ = try await pipeline.capture(Self.window)
        }
        #expect(screenshot.callCount == 0)
    }

    @Test(arguments: [true, false])
    func protectionActivatedDuringOCRRejectsAndDoesNotCacheImage(secureInput: Bool) async throws {
        let state = ReadinessPermissionState()
        let fingerprints = InMemoryFingerprintStore()
        let pipeline = CapturePipeline(
            translatedBundleIdentifiers: ["qa.capture"],
            permissions: SystemPermissionController(snapshotProvider: { state.snapshot }),
            accessibility: FakeAccessibilityCollector(result: .empty),
            screenshot: CountingScreenshotProvider(image: makeTestImage()),
            ocr: ReadinessOCRService { state.protect(secureInput: secureInput) },
            fingerprintStore: fingerprints
        )

        await #expect(throws: CaptureError.protected(secureInput ? .secureInput : .sessionLocked)) {
            _ = try await pipeline.capture(Self.window)
        }
        let image = try #require(makeTestImage())
        #expect(!fingerprints.isUnchanged(CGImageUtilities.fingerprint(image), for: FingerprintKey(pid: Self.window.pid, windowID: Self.window.windowID)))
    }

    @Test
    func oversizedAXValueFallsBackToVisibleOCRInsteadOfEmptyTranslation() async throws {
        let screenshot = CountingScreenshotProvider(image: makeTestImage())
        let pipeline = CapturePipeline(
            translatedBundleIdentifiers: ["qa.capture"],
            permissions: FakePermissionController(snapshot: .allGranted),
            accessibility: FakeAccessibilityCollector(result: .regions([Self.region(text: String(repeating: "English paragraph. ", count: 300))])),
            screenshot: screenshot,
            ocr: FakeOCRService(regions: [VisionTextObservation(text: "Visible paragraph", boundingBox: CGRect(x: 0.1, y: 0.2, width: 0.8, height: 0.1), confidence: 0.9)])
        )
        let result = try await pipeline.capture(Self.window)
        #expect(result.source == .visionOCR)
        #expect(result.regions.map(\.sourceText) == ["Visible paragraph"])
        #expect(screenshot.callCount == 1)
    }

    @Test
    func oversizedAXValueWithoutScreenshotPermissionReportsRequiredPermission() async {
        let screenshot = CountingScreenshotProvider(image: nil)
        let pipeline = CapturePipeline(
            translatedBundleIdentifiers: ["qa.capture"],
            permissions: FakePermissionController(snapshot: PermissionSnapshot(accessibilityTrusted: true, screenCaptureAuthorized: false, secureInputEnabled: false, sessionLocked: false)),
            accessibility: FakeAccessibilityCollector(result: .regions([Self.region(text: String(repeating: "English paragraph. ", count: 300))])),
            screenshot: screenshot,
            ocr: FakeOCRService(regions: [])
        )
        await #expect(throws: CaptureError.permissionRequired(.screenCapture)) {
            _ = try await pipeline.capture(Self.window)
        }
        #expect(screenshot.callCount == 0)
    }

    private static let window = ActiveWindowDescriptor(pid: 42, bundleIdentifier: "qa.capture", windowID: 17, frame: CGRect(x: 0, y: 0, width: 800, height: 600), revision: 1)
    private static func region(text: String) -> TextRegion {
        TextRegion(id: UUID(), sourceText: text, screenFrame: CGRect(x: 30, y: 30, width: 600, height: 200), confidence: 1, source: .accessibility, windowRevision: 1)
    }
}

private final class ReadinessPermissionState: @unchecked Sendable {
    private let lock = NSLock()
    private var value = PermissionSnapshot.allGranted
    var snapshot: PermissionSnapshot { lock.withLock { value } }
    func protect(secureInput: Bool) {
        lock.withLock {
            value = PermissionSnapshot(accessibilityTrusted: true, screenCaptureAuthorized: true, secureInputEnabled: secureInput, sessionLocked: !secureInput)
        }
    }
}

private struct ReadinessAccessibilityCollector: AccessibilityCollecting {
    let result: @Sendable () -> AccessibilityCollectionResult
    func collectResult(from descriptor: ActiveWindowDescriptor) async -> AccessibilityCollectionResult { result() }
}

private struct ReadinessOCRService: VisionOCRProviding {
    let onRecognize: @Sendable () -> Void
    func recognize(image: CGImage, window: ActiveWindowDescriptor, revision: UInt64) async throws -> [VisionTextObservation] {
        onRecognize()
        return [VisionTextObservation(text: "Private test text", boundingBox: CGRect(x: 0.1, y: 0.2, width: 0.8, height: 0.1), confidence: 0.9)]
    }
}
