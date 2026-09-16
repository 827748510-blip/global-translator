import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

enum RegionCaptureFallback {
    /// Crops only when ScreenCaptureKit returned a full-display buffer for a
    /// smaller `sourceRect`. Pixel vs point sizes must not be mixed (Retina).
    static func croppedIfFullDisplay(
        _ image: CGImage,
        selection: CGRect,
        screenFrame: CGRect,
        scale: CGFloat
    ) -> CGImage {
        let imageSize = CGSize(width: image.width, height: image.height)
        guard RegionCaptureGeometry.looksLikeFullDisplayBuffer(
            imageSize: imageSize,
            selection: selection,
            screenFrame: screenFrame,
            scale: scale
        ) else { return image }
        let crop = RegionCaptureGeometry.imageCropRect(
            selection: selection,
            screenFrame: screenFrame,
            imageSize: imageSize
        )
        return CGImageUtilities.crop(image, rectInLowerLeftPixels: crop) ?? image
    }
}

public protocol RegionScreenCapturing: Sendable {
    func capture(rect: CGRect) async throws -> CGImage
}

public struct NullRegionCapturer: RegionScreenCapturing {
    public init() {}
    public func capture(rect: CGRect) async throws -> CGImage {
        throw CaptureError.captureFailed
    }
}

@available(macOS 14.0, *)
public final class ScreenCaptureKitRegionCapturer: RegionScreenCapturing, @unchecked Sendable {
    public let maximumDimension: Int

    public init(maximumDimension: Int = 4_096) {
        self.maximumDimension = min(max(maximumDimension, 1), 8_192)
    }

    public func capture(rect: CGRect) async throws -> CGImage {
        guard ScreenshotTranslateSupport.isUsableRegion(rect) else {
            throw CaptureError.invalidWindow
        }
        guard let screen = owningScreen(for: rect) else {
            throw CaptureError.captureFailed
        }
        let displayID = Self.displayID(of: screen)
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw CaptureError.captureFailed
        }
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.captureFailed
        }
        let sourceRect = RegionCaptureGeometry.displayLocalSourceRect(
            selection: rect,
            screenFrame: screen.frame
        )
        guard ScreenshotTranslateSupport.isUsableRegion(sourceRect) else {
            throw CaptureError.invalidWindow
        }
        let scale = max(screen.backingScaleFactor, 1)
        let outputWidth = max(1, Int((sourceRect.width * scale).rounded()))
        let outputHeight = max(1, Int((sourceRect.height * scale).rounded()))
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = sourceRect
        configuration.width = min(outputWidth, maximumDimension)
        configuration.height = min(outputHeight, maximumDimension)
        configuration.showsCursor = false
        configuration.capturesAudio = false
        let image = try await captureImage(filter: filter, configuration: configuration)
        return RegionCaptureFallback.croppedIfFullDisplay(
            image,
            selection: rect,
            screenFrame: screen.frame,
            scale: scale
        )
    }

    public static func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? CGDirectDisplayID) ?? 0
    }

    private func owningScreen(for rect: CGRect) -> NSScreen? {
        let screens = NSScreen.screens
        if let containing = screens.first(where: { $0.frame.contains(CGPoint(x: rect.midX, y: rect.midY)) }) {
            return containing
        }
        return screens.max(by: { lhs, rhs in
            lhs.frame.intersection(rect).width * lhs.frame.intersection(rect).height
                < rhs.frame.intersection(rect).width * rhs.frame.intersection(rect).height
        })
    }

    private func captureImage(
        filter: SCContentFilter,
        configuration: SCStreamConfiguration
    ) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, _ in
                if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: CaptureError.captureFailed)
                }
            }
        }
    }
}
