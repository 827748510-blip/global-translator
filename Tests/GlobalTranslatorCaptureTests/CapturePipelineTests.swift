import CoreGraphics
import Foundation
import Testing
@testable import GlobalTranslatorCapture
import GlobalTranslatorCore

struct CapturePipelineTests {
    @Test
    func emptyWebAreaWithSidebarLabelsRequiresOCR() async throws {
        let collector = AccessibilityTextCollector(
            translatedBundleIdentifiers: ["com.example.foreign"],
            reader: FakeAccessibilityReader(root: .group(children: [
            .staticText("Bookmarks", frame: CGRect(x: 20, y: 200, width: 100, height: 30)),
            AccessibilityNode(role: .webArea, frame: CGRect(x: 200, y: 0, width: 800, height: 700), children: [
                AccessibilityNode(role: .group)
            ])
        ])))
        #expect(await collector.collectResult(from: testWindow(frame: CGRect(x: 0, y: 0, width: 1000, height: 800))) == .unavailable(.accessibilityUnavailable))
    }

    @Test
    func webContentIsSelectedInsteadOfBrowserChrome() {
        let collector = AccessibilityTextCollector(
            translatedBundleIdentifiers: ["com.example.foreign"],
            reader: FakeAccessibilityReader(root: .group(children: [
            .staticText("Bookmarks", frame: CGRect(x: 20, y: 200, width: 100, height: 30)),
            AccessibilityNode(role: .webArea, frame: CGRect(x: 200, y: 0, width: 800, height: 700), children: [
                .staticText("Read the article", frame: CGRect(x: 250, y: 400, width: 400, height: 30))
            ])
        ])))
        let regions = collector.collect(from: testWindow(frame: CGRect(x: 0, y: 0, width: 1000, height: 800)))
        #expect(regions.map(\.sourceText) == ["Read the article"])
    }

    @Test
    func hiddenContainerCannotLeakItsVisibleLookingChildren() {
        let collector = AccessibilityTextCollector(
            translatedBundleIdentifiers: ["com.example.foreign"],
            reader: FakeAccessibilityReader(root: .group(children: [
            AccessibilityNode(role: .group, children: [
                .staticText("Hidden tab content", frame: CGRect(x: 200, y: 200, width: 300, height: 30))
            ], isOffscreen: true),
            .staticText("Visible page", frame: CGRect(x: 200, y: 300, width: 300, height: 30))
        ])))
        #expect(collector.collect(from: testWindow()).map(\.sourceText) == ["Visible page"])
    }

    @Test
    func readableBodyGetsBudgetBeforeManyActionButtons() {
        let controls = (0..<30).map { index in
            AccessibilityNode.button("Action \(index)", frame: CGRect(x: 10, y: 20 + index * 20, width: 80, height: 18))
        }
        let collector = AccessibilityTextCollector(
            translatedBundleIdentifiers: ["com.example.foreign"],
            reader: FakeAccessibilityReader(root: .group(children: controls + [
            .staticText("Translate the visible article text", frame: CGRect(x: 250, y: 350, width: 500, height: 35))
        ])))
        let result = collector.collect(from: testWindow(frame: CGRect(x: 0, y: 0, width: 1000, height: 800)))
        #expect(result.first?.sourceText == "Translate the visible article text")
        #expect(result.count <= 24)
    }

    @Test(arguments: [CGFloat(0), CGFloat(1)])
    func clippedOffscreenTextDoesNotRenderAtViewportEdge(height: CGFloat) {
        let collector = AccessibilityTextCollector(
            translatedBundleIdentifiers: ["com.example.foreign"],
            reader: FakeAccessibilityReader(root: .group(children: [
            .staticText("Scrolled out of view", frame: CGRect(x: 100, y: 600, width: 300, height: height)),
            .staticText("Visible destination", frame: CGRect(x: 100, y: 200, width: 300, height: 29))
        ])))
        let regions = collector.collect(from: testWindow(frame: CGRect(x: 0, y: 0, width: 1000, height: 800)))
        #expect(regions.map(\.sourceText) == ["Visible destination"])
    }

    @Test
    func smallImageWithAVisibleLabelKeepsItsText() {
        let collector = AccessibilityTextCollector(
            translatedBundleIdentifiers: ["com.example.foreign"],
            reader: FakeAccessibilityReader(root: .group(children: [
            AccessibilityNode(role: .image, description: "Read Before Closing.txt", frame: CGRect(x: 300, y: 300, width: 120, height: 100))
        ])))
        let regions = collector.collect(from: testWindow(frame: CGRect(x: 0, y: 0, width: 1000, height: 800)))
        #expect(regions.contains { $0.sourceText == "Read Before Closing.txt" })
    }

    @Test
    func untranslatedChromeDoesNotConsumeTheDocumentRegionBudget() {
        let descriptor = testWindow(frame: CGRect(x: 0, y: 0, width: 1000, height: 800))
        let controls = (0..<30).map { index in AccessibilityNode.staticText("中文菜单", frame: CGRect(x: 10, y: 10 + index * 20, width: 80, height: 18)) }
        let collector = AccessibilityTextCollector(
            translatedBundleIdentifiers: ["com.example.foreign"],
            reader: FakeAccessibilityReader(root: .group(children: controls + [.staticText("Read Before Closing", frame: CGRect(x: 300, y: 300, width: 200, height: 30))])))
        let result = collector.collect(from: descriptor)
        #expect(result.contains { $0.sourceText == "Read Before Closing" })
        #expect(result.count <= 24)
    }

    @Test
    func toolbarOnlyAccessibilityDoesNotHideMissingDocumentText() async throws {
        let descriptor = testWindow(frame: CGRect(x: 0, y: 0, width: 1000, height: 800))
        let collector = AccessibilityTextCollector(
            translatedBundleIdentifiers: ["com.example.foreign"],
            reader: FakeAccessibilityReader(root: .group(children: [
            .button("Share", frame: CGRect(x: 20, y: 750, width: 60, height: 25)),
            .staticText("Document title", frame: CGRect(x: 300, y: 750, width: 250, height: 25))
        ])))
        #expect(await collector.collectResult(from: descriptor) == .unavailable(.accessibilityUnavailable))
    }

    @Test(arguments: ["image", "page", "group"])
    func largeImageWithOnlyToolbarTextRequiresOCR(rawRole: String) async throws {
        let imageRole = try #require(AccessibilityRole(rawValue: rawRole))
        let descriptor = testWindow(frame: CGRect(x: 0, y: 0, width: 1000, height: 800))
        let collector = AccessibilityTextCollector(
            translatedBundleIdentifiers: ["com.example.foreign"],
            reader: FakeAccessibilityReader(root: .group(children: [
            .button("Share", frame: CGRect(x: 10, y: 750, width: 60, height: 30)),
            AccessibilityNode(role: imageRole, frame: CGRect(x: 20, y: 20, width: 960, height: 700))
        ])))
        let screenshot = CountingScreenshotProvider(image: makeTestImage())
        let pipeline = CapturePipeline(
            translatedBundleIdentifiers: ["com.example.foreign"],
            permissions: FakePermissionController(snapshot: .allGranted),
            accessibility: collector,
            screenshot: screenshot,
            ocr: FakeOCRService(regions: [VisionTextObservation(text: "Image body", boundingBox: CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.1), confidence: 0.9)])
        )
        let snapshot = try await pipeline.capture(descriptor)
        #expect(snapshot.source == .visionOCR)
        #expect(snapshot.regions.map(\.sourceText) == ["Image body"])
        #expect(screenshot.callCount == 1)
    }

    @Test
    func smallImageIconDoesNotForceScreenshot() async throws {
        let imageRole = try #require(AccessibilityRole(rawValue: "image"))
        let descriptor = testWindow(frame: CGRect(x: 0, y: 0, width: 1000, height: 800))
        let collector = AccessibilityTextCollector(
            translatedBundleIdentifiers: ["com.example.foreign"],
            reader: FakeAccessibilityReader(root: .group(children: [
            .staticText("Readable body", frame: CGRect(x: 100, y: 400, width: 400, height: 30)),
            AccessibilityNode(role: imageRole, frame: CGRect(x: 20, y: 20, width: 32, height: 32))
        ])))
        #expect(await collector.collectResult(from: descriptor).regions.map(\.sourceText) == ["Readable body"])
    }

    @Test
    func largeImageWithAccessibleLiveTextKeepsAXPath() async throws {
        let descriptor = testWindow(frame: CGRect(x: 0, y: 0, width: 1000, height: 800))
        let collector = AccessibilityTextCollector(
            translatedBundleIdentifiers: ["com.example.foreign"],
            reader: FakeAccessibilityReader(root: .group(children: [
            AccessibilityNode(role: .image, frame: CGRect(x: 20, y: 20, width: 960, height: 700), children: [
                .staticText("Live Text body", frame: CGRect(x: 100, y: 400, width: 400, height: 30))
            ])
        ])))
        #expect(await collector.collectResult(from: descriptor).regions.map(\.sourceText) == ["Live Text body"])
    }

    @Test
    func imageLiveTextOutsideItsImageRequiresOCR() async {
        let descriptor = testWindow(frame: CGRect(x: 0, y: 0, width: 1000, height: 800))
        let collector = AccessibilityTextCollector(
            translatedBundleIdentifiers: ["com.example.foreign"],
            reader: FakeAccessibilityReader(root: .group(children: [
            AccessibilityNode(role: .image, frame: CGRect(x: 20, y: 20, width: 960, height: 700), children: [
                .staticText("First line", frame: CGRect(x: 100, y: 400, width: 400, height: 30)),
                .textField("Mispositioned line", frame: CGRect(x: 100, y: 900, width: 400, height: 30))
            ])
        ])))
        #expect(await collector.collectResult(from: descriptor) == .unavailable(.accessibilityUnavailable))
    }

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
            translatedBundleIdentifiers: ["com.example.foreign"],
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
            translatedBundleIdentifiers: ["com.example.foreign"],
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
            translatedBundleIdentifiers: ["com.example.foreign"],
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
            translatedBundleIdentifiers: ["com.example.foreign"],
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
    func selfAndUnselectedApplicationsAreRejectedBeforeAccessibilityOrScreenshot() async {
        let collector = FakeAccessibilityCollector(result: .empty)
        let screenshot = CountingScreenshotProvider(image: nil)
        let pipeline = CapturePipeline(
            translatedBundleIdentifiers: ["com.example.foreign"],
            permissions: FakePermissionController(snapshot: .allGranted),
            accessibility: collector,
            screenshot: screenshot,
            ocr: FakeOCRService(regions: []),
            ownBundleIdentifier: "com.example.self"
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
                Issue.record("unselected application should fail closed")
            } catch let error as CaptureError {
                #expect(error == (bundleIdentifier == "com.example.self" ? .selfApplication : .excludedApplication(bundleIdentifier)))
            } catch {
                Issue.record("unexpected error: \(error)")
            }
        }
        #expect(screenshot.callCount == 0)
    }

    @Test
    func emptyAllowListRejectsEveryForeignApplication() async {
        let collector = FakeAccessibilityCollector(result: .empty)
        let screenshot = CountingScreenshotProvider(image: nil)
        let pipeline = CapturePipeline(
            translatedBundleIdentifiers: [],
            permissions: FakePermissionController(snapshot: .allGranted),
            accessibility: collector,
            screenshot: screenshot,
            ocr: FakeOCRService(regions: [])
        )
        do {
            _ = try await pipeline.capture(testWindow())
            Issue.record("empty allow list must translate nothing")
        } catch let error as CaptureError {
            #expect(error == .excludedApplication("com.example.foreign"))
        } catch {
            Issue.record("unexpected error: \(error)")
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
        let collector = AccessibilityTextCollector(
            translatedBundleIdentifiers: ["com.example.foreign"],
            reader: FakeAccessibilityReader(root: root))

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
            translatedBundleIdentifiers: ["com.example.foreign"],
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
    func cachedSnapshotReleasesPreviousImageAndBacksOffRepeatedAXUnavailable() async throws {
        weak var weakFirstImage: CGImage?
        let descriptor = testWindow(revision: 1)
        let axCollector = CountingUnavailableAXCollector()
        let secondImage = try #require(makeImage(width: 64, height: 32))
        let screenshot = SequencedImageScreenshotProvider(images: [
            try #require(makeImage(width: 64, height: 32)),
            secondImage
        ])
        weakFirstImage = screenshot.peekFirstImage()
        let pipeline = CapturePipeline(
            translatedBundleIdentifiers: ["com.example.foreign"],
            permissions: FakePermissionController(snapshot: .allGranted),
            accessibility: axCollector,
            screenshot: screenshot,
            ocr: FakeOCRService(regions: [
                VisionTextObservation(text: "cached", boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), confidence: 0.9)
            ])
        )
        _ = try await pipeline.capture(descriptor)
        screenshot.dropFirstReference()
        let second = try await pipeline.capture(testWindow(revision: 2))
        #expect(second.ocrSkipped)
        #expect(axCollector.calls == 1)
        #expect(weakFirstImage == nil || second.capturedImage === secondImage)
    }

    @Test
    func visualSampleHistoryObserveSwappingTriggersOnThreeDifferences() {
        var history = VisualSampleHistory()
        var first = [UInt16](repeating: 1, count: 16)
        var second = [UInt16](repeating: 1, count: 16)
        second[0] = 2
        second[1] = 2
        let firstChanged = history.observeSwapping(&first)
        let secondChanged = history.observeSwapping(&second)
        #expect(!firstChanged)
        #expect(!secondChanged)
        var third = [UInt16](repeating: 1, count: 16)
        third[0] = 3
        third[1] = 3
        third[2] = 3
        let thirdChanged = history.observeSwapping(&third)
        #expect(thirdChanged)
    }

    @Test
    func cancellationAfterAccessibilityAwaitPreventsOCRWork() async {
        let screenshot = BlockingScreenshotProvider()
        let ocr = FakeOCRService(regions: [])
        let pipeline = CapturePipeline(
            translatedBundleIdentifiers: ["com.example.foreign"],
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
                translatedBundleIdentifiers: ["com.example.foreign"],
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

private final class CountingUnavailableAXCollector: AccessibilityCollecting, @unchecked Sendable {
    private(set) var calls = 0
    func collectResult(from descriptor: ActiveWindowDescriptor) async -> AccessibilityCollectionResult {
        calls += 1
        return .unavailable(.accessibilityUnavailable)
    }
}

private final class SequencedImageScreenshotProvider: ScreenCaptureProviding, @unchecked Sendable {
    private var images: [CGImage?]
    private var index = 0

    init(images: [CGImage]) {
        self.images = images.map { Optional($0) }
    }

    func peekFirstImage() -> CGImage? { images.first ?? nil }
    func dropFirstReference() {
        if !images.isEmpty { images[0] = nil }
    }

    func capture(window: ActiveWindowDescriptor) async throws -> CGImage {
        let current = images[min(index, images.count - 1)]
        index += 1
        guard let current else { throw CaptureError.captureFailed }
        return current
    }
}
