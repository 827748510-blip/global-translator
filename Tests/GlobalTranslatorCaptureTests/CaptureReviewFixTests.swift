import CoreGraphics
import Foundation
import Testing
@testable import GlobalTranslatorCapture

struct CaptureReviewFixTests {
    @Test
    func quartzFramesUsePrimaryDisplayReferenceForEveryArrangement() {
        let primary = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let cases: [(CGRect, CGRect)] = [
            (CGRect(x: 100, y: 100, width: 300, height: 100), CGRect(x: 100, y: 700, width: 300, height: 100)),
            (CGRect(x: -1_800, y: 100, width: 300, height: 100), CGRect(x: -1_800, y: 700, width: 300, height: 100)),
            (CGRect(x: 100, y: -100, width: 300, height: 100), CGRect(x: 100, y: 900, width: 300, height: 100)),
            (CGRect(x: 100, y: 950, width: 300, height: 100), CGRect(x: 100, y: -150, width: 300, height: 100))
        ]

        for (quartzFrame, expected) in cases {
            #expect(CoordinateConverter.quartzTopLeftFrameToAppKitGlobal(
                quartzFrame,
                primaryDisplayFrame: primary
            ) == expected)
        }
    }

    @Test
    func accessibilityCollectorConvertsQuartzNodeFramesBeforeIntersection() {
        let primary = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let descriptor = ActiveWindowDescriptor(
            pid: 123,
            bundleIdentifier: "foreign",
            frame: CGRect(x: -1_800, y: 600, width: 500, height: 300),
            revision: 1
        )
        let node = AccessibilityNode.staticText(
            "left",
            frame: CGRect(x: -1_800, y: 100, width: 300, height: 100),
            coordinateSpace: .quartzTopLeft
        )
        let collector = AccessibilityTextCollector(
            reader: FakeAccessibilityReader(root: .group(children: [node])),
            primaryDisplayFrame: primary
        )

        let regions = collector.collect(from: descriptor)

        #expect(regions.count == 1)
        #expect(regions[0].screenFrame == CGRect(x: -1_800, y: 700, width: 300, height: 100))
    }

    @Test
    func screenCaptureMatcherComparesQuartzCandidateInAppKitSpace() {
        let primary = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let descriptor = ActiveWindowDescriptor(
            pid: 7,
            bundleIdentifier: "foreign",
            frame: CGRect(x: 100, y: 200, width: 800, height: 600),
            revision: 1
        )

        #expect(ScreenCaptureKitWindowCapturer.matches(
            candidateProcessID: 7,
            candidateWindowID: 88,
            candidateFrame: CGRect(x: 100, y: 100, width: 800, height: 600),
            descriptor: descriptor,
            primaryDisplayFrame: primary
        ))
    }

    @Test
    func capturedImageLivesOnlyInMemoryAndAXSnapshotsHaveNoImage() async throws {
        let image = try #require(makeTestImage())
        let descriptor = ActiveWindowDescriptor(
            pid: 123,
            bundleIdentifier: "foreign",
            frame: CGRect(x: 0, y: 0, width: 100, height: 100),
            revision: 1
        )
        let pipeline = CapturePipeline(
            permissions: FakePermissionController(snapshot: .allGranted),
            accessibility: FakeAccessibilityCollector(result: .empty),
            screenshot: CountingScreenshotProvider(image: image),
            ocr: FakeOCRService(regions: [
                VisionTextObservation(text: "text", boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.2), confidence: 0.2)
            ])
        )

        let ocrSnapshot = try await pipeline.capture(descriptor)

        #expect(ocrSnapshot.capturedImage === image)
        #expect(ocrSnapshot.window.capturedImage === image)
        #expect(pipeline.prepareCloudCrops(snapshot: ocrSnapshot).count == 1)

        let axSnapshot = CaptureSnapshot(window: CapturedWindow(
            descriptor: descriptor,
            regions: [],
            source: .accessibility
        ))
        #expect(axSnapshot.capturedImage == nil)
        #expect(pipeline.prepareCloudCrops(snapshot: axSnapshot).isEmpty)
    }

    @Test
    func excludedSwitchClearsCurrentOverlayImmediately() async {
        let recorder = CallbackRecorder()
        let monitor = await MainActor.run {
            ActiveWindowMonitor(
                ownBundleIdentifier: "com.example.self",
                excludedBundleIdentifiers: ["com.example.excluded"],
                callback: { descriptor in recorder.record(descriptor) }
            )
        }
        let descriptor = ActiveWindowDescriptor(
            pid: 123,
            bundleIdentifier: "foreign",
            frame: CGRect(x: 0, y: 0, width: 100, height: 100),
            revision: 0
        )

        await MainActor.run {
            monitor.ingestForTesting(descriptor, atUptimeNanoseconds: 1_000_000_000)
            monitor.handleApplicationSwitchForTesting(bundleIdentifier: "com.example.excluded")
        }

        #expect(await MainActor.run { monitor.current } == nil)
        #expect(recorder.values().last! == nil)
    }

    @Test
    func screenCaptureOutputSizeUsesUniformScale() {
        #expect(ScreenCaptureKitWindowCapturer.outputSize(
            for: CGSize(width: 4_000, height: 1_000),
            maximumDimension: 2_048
        ) == CGSize(width: 2_048, height: 512))
        #expect(ScreenCaptureKitWindowCapturer.outputSize(
            for: CGSize(width: 800, height: 600),
            maximumDimension: 2_048
        ) == CGSize(width: 800, height: 600))
    }

    @Test
    func fingerprintStoreEvictsOldWindowKeysAtBound() {
        let store = InMemoryFingerprintStore(maximumEntries: 2)
        store.remember(ImageFingerprint(value: 1), for: FingerprintKey(pid: 1, windowID: 1))
        store.remember(ImageFingerprint(value: 2), for: FingerprintKey(pid: 1, windowID: 2))
        store.remember(ImageFingerprint(value: 3), for: FingerprintKey(pid: 1, windowID: 3))

        #expect(store.count == 2)
        #expect(!store.isUnchanged(ImageFingerprint(value: 1), for: FingerprintKey(pid: 1, windowID: 1)))
        #expect(store.isUnchanged(ImageFingerprint(value: 3), for: FingerprintKey(pid: 1, windowID: 3)))
    }
}
