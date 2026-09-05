import CoreGraphics
import Foundation
import Testing
@testable import GlobalTranslatorCapture
import GlobalTranslatorCore

struct CapturePipelineTests {
    @Test
    func permissionSnapshotIsCodableAndPrivacyURLsAreExposedWithoutOpening() throws {
        let snapshot = PermissionSnapshot(
            accessibilityTrusted: true,
            screenCaptureAuthorized: false,
            secureInputEnabled: false,
            sessionLocked: true
        )
        let roundTrip = try JSONDecoder().decode(
            PermissionSnapshot.self,
            from: JSONEncoder().encode(snapshot)
        )
        #expect(roundTrip == snapshot)
        let controller = SystemPermissionController(snapshotProvider: { snapshot })
        #expect(controller.privacyURLs.contains { $0.absoluteString.hasPrefix("x-apple.systempreferences:") })
    }

    @Test
    func accessibilityTextIsPreferredAndDoesNotCallScreenshot() async throws {
        let descriptor = testWindow()
        let screenshot = CountingScreenshotProvider(image: nil)
        let collector = FakeAccessibilityCollector(result: .regions([
            TextRegion(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                sourceText: "Hello",
                screenFrame: CGRect(x: 10, y: 20, width: 60, height: 18),
                confidence: 1,
                source: .accessibility,
                windowRevision: descriptor.revision
            )
        ]))
        let pipeline = CapturePipeline(
            permissions: FakePermissionController(snapshot: .allGranted),
            accessibility: collector,
            screenshot: screenshot,
            ocr: FakeOCRService(regions: [])
        )

        let result = try await pipeline.capture(descriptor)

        #expect(result.source == .accessibility)
        #expect(result.regions.map(\.sourceText) == ["Hello"])
        #expect(screenshot.callCount == 0)
    }

    @Test
    func emptyAccessibilityFallsBackToOneScreenshotAndOCR() async throws {
        let descriptor = testWindow()
        let image = try #require(makeImage(width: 80, height: 40))
        let screenshot = CountingScreenshotProvider(image: image)
        let ocr = FakeOCRService(regions: [
            VisionTextObservation(text: "OCR", boundingBox: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.2), confidence: 0.9)
        ])
        let pipeline = CapturePipeline(
            permissions: FakePermissionController(snapshot: .allGranted),
            accessibility: FakeAccessibilityCollector(result: .empty),
            screenshot: screenshot,
            ocr: ocr
        )

        let result = try await pipeline.capture(descriptor)

        #expect(result.source == .visionOCR)
        #expect(result.regions.count == 1)
        #expect(screenshot.callCount == 1)
        #expect(ocr.callCount == 1)
    }

    @Test
    func screenshotIsBlockedWhenPermissionIsMissing() async {
        let screenshot = CountingScreenshotProvider(image: nil)
        let pipeline = CapturePipeline(
            permissions: FakePermissionController(snapshot: PermissionSnapshot(
                accessibilityTrusted: true,
                screenCaptureAuthorized: false,
                secureInputEnabled: false,
                sessionLocked: false
            )),
            accessibility: FakeAccessibilityCollector(result: .empty),
            screenshot: screenshot,
            ocr: FakeOCRService(regions: [])
        )

        do {
            _ = try await pipeline.capture(testWindow())
            Issue.record("missing screen capture permission should be typed")
        } catch let error as CaptureError {
            #expect(error == .permissionRequired(.screenCapture))
            #expect(screenshot.callCount == 0)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test
    func secureInputAndLockedSessionAreFailClosed() async {
        for snapshot in [
            PermissionSnapshot(accessibilityTrusted: true, screenCaptureAuthorized: true, secureInputEnabled: true, sessionLocked: false),
            PermissionSnapshot(accessibilityTrusted: true, screenCaptureAuthorized: true, secureInputEnabled: false, sessionLocked: true)
        ] {
            let pipeline = CapturePipeline(
                permissions: FakePermissionController(snapshot: snapshot),
                accessibility: FakeAccessibilityCollector(result: .empty),
                screenshot: CountingScreenshotProvider(image: nil),
                ocr: FakeOCRService(regions: [])
            )
            do {
                _ = try await pipeline.capture(testWindow())
                Issue.record("protected session should be rejected")
            } catch let error as CaptureError {
                #expect(error == (snapshot.secureInputEnabled ? .protected(.secureInput) : .protected(.sessionLocked)))
            } catch {
                Issue.record("unexpected error: \(error)")
            }
        }
    }

    @Test
    func selfAndExcludedApplicationsAreRejectedBeforeAccessibilityOrScreenshot() async {
        let collector = FakeAccessibilityCollector(result: .empty)
        let screenshot = CountingScreenshotProvider(image: nil)
        let pipeline = CapturePipeline(
            permissions: FakePermissionController(snapshot: .allGranted),
            accessibility: collector,
            screenshot: screenshot,
            ocr: FakeOCRService(regions: []),
            ownBundleIdentifier: "com.example.self",
            excludedBundleIdentifiers: ["com.example.excluded"]
        )

        for bundleIdentifier in ["com.example.self", "com.example.excluded"] {
            let descriptor = ActiveWindowDescriptor(
                pid: 123,
                bundleIdentifier: bundleIdentifier,
                frame: CGRect(x: 0, y: 0, width: 100, height: 100),
                revision: 1
            )
            do {
                _ = try await pipeline.capture(descriptor)
                Issue.record("excluded application should fail closed")
            } catch let error as CaptureError {
                #expect(error == (bundleIdentifier == "com.example.self" ? .selfApplication : .excludedApplication(bundleIdentifier)))
            } catch {
                Issue.record("unexpected error: \(error)")
            }
        }
        #expect(screenshot.callCount == 0)
    }

    @Test
    func collectorCapsRegionsAndRemovesDuplicateAndOffscreenNodes() {
        let descriptor = testWindow(frame: CGRect(x: -1_920, y: -80, width: 1_920, height: 1_080))
        let duplicate = AccessibilityNode.staticText(
            "same",
            frame: CGRect(x: -1_800, y: 100, width: 100, height: 24)
        )
        let root = AccessibilityNode.group(
            children: [duplicate, duplicate] + (0..<30).map { index in
                AccessibilityNode.staticText(
                    "item-\(index)",
                    frame: CGRect(x: -1_800 + CGFloat(index * 20), y: 100, width: 100, height: 24)
                )
            } + [AccessibilityNode.staticText("off", frame: CGRect(x: 0, y: 0, width: 12, height: 12))]
        )
        let collector = AccessibilityTextCollector(reader: FakeAccessibilityReader(root: root))

        let regions = collector.collect(from: descriptor)

        #expect(regions.count == 24)
        #expect(Set(regions.map(\.sourceText)).count == regions.count)
        #expect(regions.allSatisfy { descriptor.frame.intersects($0.screenFrame) })
    }

    @Test
    func visionCoordinatesPreserveNegativeSecondaryDisplayAndLowerLeftOrigin() {
        let window = CGRect(x: -1_440, y: -300, width: 1_200, height: 800)
        let normalized = CGRect(x: 0.25, y: 0.125, width: 0.5, height: 0.25)

        let screen = CoordinateConverter.visionBoundingBoxToScreenFrame(
            normalized,
            windowFrame: window,
            imageSize: CGSize(width: 2_400, height: 1_600)
        )

        #expect(screen == CGRect(x: -1_140, y: -200, width: 600, height: 200))
    }

    @Test
    func unchangedFingerprintSkipsOCR() async throws {
        let image = try #require(makeImage(width: 64, height: 32))
        let screenshot = CountingScreenshotProvider(image: image)
        let ocr = FakeOCRService(regions: [
            VisionTextObservation(text: "one", boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), confidence: 0.9)
        ])
        let pipeline = CapturePipeline(
            permissions: FakePermissionController(snapshot: .allGranted),
            accessibility: FakeAccessibilityCollector(result: .empty),
            screenshot: screenshot,
            ocr: ocr
        )

        _ = try await pipeline.capture(testWindow(revision: 1))
        let second = try await pipeline.capture(testWindow(revision: 2))

        #expect(ocr.callCount == 1)
        #expect(second.ocrSkipped)
    }

    @Test
    func cancellationAfterAccessibilityAwaitPreventsOCRWork() async {
        let screenshot = BlockingScreenshotProvider()
        let ocr = FakeOCRService(regions: [])
        let pipeline = CapturePipeline(
            permissions: FakePermissionController(snapshot: .allGranted),
            accessibility: FakeAccessibilityCollector(result: .empty),
            screenshot: screenshot,
            ocr: ocr
        )
        let task = Task { try await pipeline.capture(testWindow()) }
        await Task.yield()
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("cancelled capture should not complete")
        } catch is CancellationError {
            #expect(screenshot.callCount <= 1)
            #expect(ocr.callCount == 0)
        } catch {
            Issue.record("unexpected cancellation error")
        }
    }

    @Test
    func cloudCropsAreAtMostEightAndNeverPersisted() throws {
        let image = try #require(makeImage(width: 2_048, height: 1_024))
        let regions = (0..<12).map { index in
            TextRegion(
                id: UUID(),
                sourceText: "low-\(index)",
                screenFrame: CGRect(x: CGFloat(index * 20), y: 20, width: 300, height: 80),
                confidence: 0.2,
                source: .visionOCR,
                windowRevision: 1
            )
        }
        let crops = CloudCropPreparer().prepare(
            image: image,
            regions: regions,
            windowFrame: CGRect(x: 0, y: 0, width: 2_048, height: 1_024)
        )

        #expect(crops.count == 8)
        #expect(crops.allSatisfy { max($0.image.width, $0.image.height) <= 1_024 })
    }

    @Test
    func activeWindowMonitorCoalescesBurstsAndIncrementsRevision() async {
        let recorder = CallbackRecorder()
        let monitor = await MainActor.run {
            ActiveWindowMonitor(
                ownBundleIdentifier: "com.example.self",
                excludedBundleIdentifiers: ["com.example.excluded"],
                callback: { descriptor in recorder.record(descriptor) }
            )
        }
        let first = testWindow(revision: 0)
        let second = ActiveWindowDescriptor(
            pid: first.pid,
            bundleIdentifier: first.bundleIdentifier,
            windowID: first.windowID,
            frame: first.frame.offsetBy(dx: 2, dy: 0),
            revision: 0
        )

        await MainActor.run {
            monitor.ingestForTesting(first, atUptimeNanoseconds: 1_000_000_000)
            monitor.ingestForTesting(second, atUptimeNanoseconds: 1_100_000_000)
            monitor.flushForTesting(atUptimeNanoseconds: 1_300_000_000)
        }

        let descriptors = recorder.values()
        #expect(descriptors.count == 2)
        #expect(descriptors[0]?.revision == 1)
        #expect(descriptors[1]?.revision == 2)
    }

    private func testWindow(
        frame: CGRect = CGRect(x: 100, y: 100, width: 800, height: 600),
        revision: UInt64 = 1
    ) -> ActiveWindowDescriptor {
        ActiveWindowDescriptor(
            pid: 123,
            bundleIdentifier: "com.example.foreign",
            windowID: 42,
            frame: frame,
            revision: revision
        )
    }

    private func makeImage(width: Int, height: Int) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return nil
        }
        context.setFillColor(gray: 0.7, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

private final class BlockingScreenshotProvider: ScreenCaptureProviding, @unchecked Sendable {
    private(set) var callCount = 0

    func capture(window: ActiveWindowDescriptor) async throws -> CGImage {
        callCount += 1
        try await Task.sleep(nanoseconds: .max)
        throw CaptureError.captureFailed
    }
}
