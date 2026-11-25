import CoreGraphics
import Foundation

public final class CapturePipeline: @unchecked Sendable {
    public let permissions: any PermissionControlling
    public let accessibility: any AccessibilityCollecting
    public let screenshot: any ScreenCaptureProviding
    public let ocr: any VisionOCRProviding
    public let fingerprintStore: InMemoryFingerprintStore
    public let translatedBundleIdentifiers: Set<String>
    public let ownBundleIdentifier: String?
    public let maximumPreviousSnapshots: Int

    private let cropPreparer: CloudCropPreparer
    private let lock = NSLock()
    private var previousSnapshots: [FingerprintKey: CaptureSnapshot] = [:]
    private var previousOrder: [FingerprintKey] = []
    private var axCooldownUntil: [FingerprintKey: TimeInterval] = [:]
    private let axFailureCooldownSeconds: TimeInterval = 8.0

    public convenience init(
        ownBundleIdentifier: String? = Bundle.main.bundleIdentifier,
        translatedBundleIdentifiers: Set<String> = [],
        maximumPreviousSnapshots: Int = 128
    ) {
        self.init(
            translatedBundleIdentifiers: translatedBundleIdentifiers,
            permissions: SystemPermissionController(),
            accessibility: AccessibilityTextCollector(translatedBundleIdentifiers: translatedBundleIdentifiers),
            screenshot: ScreenCaptureKitWindowCapturer(),
            ocr: VisionOCRService(),
            ownBundleIdentifier: ownBundleIdentifier,
            maximumPreviousSnapshots: maximumPreviousSnapshots
        )
    }

    public init(
        translatedBundleIdentifiers: Set<String>,
        permissions: any PermissionControlling,
        accessibility: any AccessibilityCollecting,
        screenshot: any ScreenCaptureProviding,
        ocr: any VisionOCRProviding,
        fingerprintStore: InMemoryFingerprintStore = InMemoryFingerprintStore(),
        ownBundleIdentifier: String? = Bundle.main.bundleIdentifier,
        maximumPreviousSnapshots: Int = 128
    ) {
        self.permissions = permissions
        self.accessibility = accessibility
        self.screenshot = screenshot
        self.ocr = ocr
        self.fingerprintStore = fingerprintStore
        self.ownBundleIdentifier = ownBundleIdentifier
        self.translatedBundleIdentifiers = translatedBundleIdentifiers
        self.maximumPreviousSnapshots = min(max(maximumPreviousSnapshots, 0), 128)
        cropPreparer = CloudCropPreparer()
    }

    public func capture(_ descriptor: ActiveWindowDescriptor) async throws -> CaptureSnapshot {
        try validate(descriptor)
        let permission = permissions.snapshot
        try permission.validateCapture()

        try Task.checkCancellation()
        let key = FingerprintKey(pid: descriptor.pid, windowID: descriptor.windowID)
        let now = ProcessInfo.processInfo.systemUptime
        let axInCooldown = lock.withLock { () -> Bool in
            guard let until = axCooldownUntil[key] else { return false }
            if now < until { return true }
            axCooldownUntil.removeValue(forKey: key)
            return false
        }
        let accessibilityResult: AccessibilityCollectionResult
        if !permission.accessibilityTrusted {
            accessibilityResult = .unavailable(.permissionRequired(.accessibility))
        } else if axInCooldown {
            accessibilityResult = .unavailable(.accessibilityUnavailable)
        } else {
            accessibilityResult = await accessibility.collectResult(from: descriptor)
        }
        try Task.checkCancellation()
        switch accessibilityResult {
        case .regions(let regions) where !regions.isEmpty:
            try permissions.snapshot.validateCapture(source: .accessibility)
            lock.withLock { _ = axCooldownUntil.removeValue(forKey: key) }
            if regions.contains(where: { TextFilter.shouldTranslate($0.sourceText) && $0.sourceText.count > 4_000 }) {
                break
            }
            return CaptureSnapshot(window: CapturedWindow(
                descriptor: descriptor,
                regions: Array(regions.prefix(24)),
                source: .accessibility
            ))
        case .unavailable(let error) where isTerminalAccessibilityError(error):
            throw error
        case .unavailable(.accessibilityUnavailable):
            lock.withLock {
                axCooldownUntil[key] = ProcessInfo.processInfo.systemUptime + axFailureCooldownSeconds
            }
        case .regions, .empty, .unavailable:
            break
        }

        try permissions.snapshot.validateCapture(source: .visionOCR)
        let image: CGImage
        do {
            try Task.checkCancellation()
            image = try await screenshot.capture(window: descriptor)
            try Task.checkCancellation()
            try permissions.snapshot.validateCapture(source: .visionOCR)
        } catch let error as CaptureError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CaptureError.captureFailed
        }
        let fingerprint = CGImageUtilities.fingerprint(image)
        if fingerprintStore.isUnchanged(fingerprint, for: key), let previous = previousSnapshot(for: key) {
            let window = CapturedWindow(
                descriptor: descriptor,
                regions: translatedRegions(previous.regions, from: previous.descriptor, to: descriptor),
                source: .visionOCR,
                fingerprint: fingerprint,
                capturedImage: image
            )
            return CaptureSnapshot(window: window, ocrSkipped: true)
        }
        let observations: [VisionTextObservation]
        do {
            try Task.checkCancellation()
            observations = try await ocr.recognize(image: image, window: descriptor, revision: descriptor.revision)
            try Task.checkCancellation()
            try permissions.snapshot.validateCapture(source: .visionOCR)
        } catch let error as CaptureError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CaptureError.ocrFailed
        }
        let regions = makeRegions(observations, descriptor: descriptor, image: image)
        let snapshot = CaptureSnapshot(window: CapturedWindow(
            descriptor: descriptor,
            regions: regions,
            source: .visionOCR,
            fingerprint: fingerprint,
            capturedImage: image
        ))
        fingerprintStore.remember(fingerprint, for: key)
        remember(snapshot, for: key)
        return snapshot
    }

    public func prepareCloudCrops(snapshot: CaptureSnapshot) -> [PreparedCloudCrop] {
        guard let image = snapshot.capturedImage else { return [] }
        return cropPreparer.prepare(image: image, regions: snapshot.regions, windowFrame: snapshot.descriptor.frame)
    }

    private func validate(_ descriptor: ActiveWindowDescriptor) throws {
        guard descriptor.pid > 0, !descriptor.bundleIdentifier.isEmpty,
              descriptor.frame.width > 0, descriptor.frame.height > 0 else { throw CaptureError.invalidWindow }
        if descriptor.pid == getpid() || descriptor.bundleIdentifier == ownBundleIdentifier {
            throw CaptureError.selfApplication
        }
        // Fail closed before any accessibility, screenshot, or OCR work:
        // applications outside the user-selected allow list translate nothing.
        guard translatedBundleIdentifiers.contains(descriptor.bundleIdentifier) else {
            throw CaptureError.excludedApplication(descriptor.bundleIdentifier)
        }
    }

    private func isTerminalAccessibilityError(_ error: CaptureError) -> Bool {
        switch error {
        case .protected, .selfApplication, .excludedApplication, .invalidWindow, .cancelled:
            return true
        case .permissionRequired, .accessibilityUnavailable, .captureFailed, .ocrFailed, .unsupported, .noActiveWindow:
            return false
        }
    }

    private func makeRegions(
        _ observations: [VisionTextObservation],
        descriptor: ActiveWindowDescriptor,
        image: CGImage
    ) -> [TextRegion] {
        observations.prefix(24).compactMap { observation in
            let frame = CoordinateConverter.visionBoundingBoxToScreenFrame(
                observation.boundingBox,
                windowFrame: descriptor.frame,
                imageSize: CGSize(width: image.width, height: image.height)
            )
            guard !frame.isEmpty else { return nil }
            return TextRegion(
                id: UUID(),
                sourceText: observation.text,
                screenFrame: frame,
                confidence: observation.confidence,
                source: .visionOCR,
                windowRevision: descriptor.revision
            )
        }
    }

    private func previousSnapshot(for key: FingerprintKey) -> CaptureSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard let snapshot = previousSnapshots[key] else { return nil }
        previousOrder.removeAll { $0 == key }
        previousOrder.append(key)
        return snapshot
    }

    private func remember(_ snapshot: CaptureSnapshot, for key: FingerprintKey) {
        let lightweight = CaptureSnapshot(
            window: CapturedWindow(
                descriptor: snapshot.descriptor,
                regions: snapshot.regions,
                source: snapshot.source,
                fingerprint: snapshot.window.fingerprint,
                capturedImage: nil
            ),
            ocrSkipped: snapshot.ocrSkipped,
            sourceLanguage: snapshot.sourceLanguage,
            cacheScope: snapshot.cacheScope
        )
        lock.lock()
        guard maximumPreviousSnapshots > 0 else {
            lock.unlock()
            return
        }
        previousSnapshots[key] = lightweight
        previousOrder.removeAll { $0 == key }
        previousOrder.append(key)
        while previousOrder.count > maximumPreviousSnapshots {
            let oldest = previousOrder.removeFirst()
            previousSnapshots.removeValue(forKey: oldest)
        }
        lock.unlock()
    }

    private func translatedRegions(
        _ regions: [TextRegion],
        from previous: ActiveWindowDescriptor,
        to current: ActiveWindowDescriptor
    ) -> [TextRegion] {
        let offset = CGPoint(
            x: current.frame.minX - previous.frame.minX,
            y: current.frame.minY - previous.frame.minY
        )
        return regions.map { region in
            TextRegion(
                id: region.id,
                sourceText: region.sourceText,
                screenFrame: region.screenFrame.offsetBy(dx: offset.x, dy: offset.y),
                confidence: region.confidence,
                source: region.source,
                windowRevision: current.revision
            )
        }
    }
}
