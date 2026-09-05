import CoreGraphics
import Foundation
@testable import GlobalTranslatorCapture

final class FakePermissionController: PermissionControlling, @unchecked Sendable {
    let snapshot: PermissionSnapshot

    init(snapshot: PermissionSnapshot) {
        self.snapshot = snapshot
    }

    var privacyURLs: [URL] { [] }

    func requestAccessibilityPermission() -> Bool { false }
    func requestScreenCapturePermission() -> Bool { false }
}

final class FakeAccessibilityCollector: AccessibilityCollecting, @unchecked Sendable {
    let result: AccessibilityCollectionResult

    init(result: AccessibilityCollectionResult) {
        self.result = result
    }

    func collectResult(from descriptor: ActiveWindowDescriptor) async -> AccessibilityCollectionResult {
        result
    }
}

final class FakeAccessibilityReader: AccessibilityNodeReading, @unchecked Sendable {
    let value: AccessibilityNode

    init(root: AccessibilityNode) {
        value = root
    }

    func readRoot(for descriptor: ActiveWindowDescriptor) throws -> AccessibilityNode? {
        value
    }
}

final class CountingScreenshotProvider: ScreenCaptureProviding, @unchecked Sendable {
    let image: CGImage?
    private(set) var callCount = 0

    init(image: CGImage?) {
        self.image = image
    }

    func capture(window: ActiveWindowDescriptor) async throws -> CGImage {
        callCount += 1
        guard let image else { throw CaptureError.captureFailed }
        return image
    }
}

final class FakeOCRService: VisionOCRProviding, @unchecked Sendable {
    let values: [VisionTextObservation]
    private(set) var callCount = 0

    init(regions: [VisionTextObservation]) {
        values = regions
    }

    func recognize(
        image: CGImage,
        window: ActiveWindowDescriptor,
        revision: UInt64
    ) async throws -> [VisionTextObservation] {
        callCount += 1
        return values
    }
}

final class CallbackRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [ActiveWindowDescriptor?] = []

    func record(_ descriptor: ActiveWindowDescriptor?) {
        lock.lock()
        entries.append(descriptor)
        lock.unlock()
    }

    func values() -> [ActiveWindowDescriptor?] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }
}

func makeTestImage(width: Int = 64, height: Int = 32) -> CGImage? {
    let colorSpace = CGColorSpaceCreateDeviceGray()
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.none.rawValue
    ) else { return nil }
    context.setFillColor(gray: 0.7, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()
}
