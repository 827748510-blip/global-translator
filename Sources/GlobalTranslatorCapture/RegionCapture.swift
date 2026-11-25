import AppKit
import CoreGraphics
import Foundation
import os
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
    func prewarm() async
    func capture(rect: CGRect) async throws -> CGImage
}

public extension RegionScreenCapturing {
    func prewarm() async {}
}

public struct NullRegionCapturer: RegionScreenCapturing {
    public init() {}
    public func capture(rect: CGRect) async throws -> CGImage {
        throw CaptureError.captureFailed
    }
}

@available(macOS 14.0, *)
public final class ScreenCaptureKitRegionCapturer: RegionScreenCapturing, @unchecked Sendable {
    private struct SendableDisplay: @unchecked Sendable {
        let value: SCDisplay
    }

    private struct DisplayCacheState: Sendable {
        var displaysByID: [CGDirectDisplayID: SendableDisplay] = [:]
        var refreshedAt: TimeInterval = -.infinity
    }

    private static let displayCacheTTLSeconds: TimeInterval = 5.0

    public let maximumDimension: Int
    private let permissions: any PermissionControlling
    private let displayCacheLock = OSAllocatedUnfairLock(initialState: DisplayCacheState())

    public init(
        maximumDimension: Int = 4_096,
        permissions: any PermissionControlling = SystemPermissionController()
    ) {
        self.maximumDimension = min(max(maximumDimension, 1), 8_192)
        self.permissions = permissions
    }

    public func prewarm() async {
        guard permissions.snapshot.screenCaptureAuthorized else { return }
        let hasFreshCache = displayCacheLock.withLock { state in
            !state.displaysByID.isEmpty
                && ProcessInfo.processInfo.systemUptime - state.refreshedAt <= Self.displayCacheTTLSeconds
        }
        if hasFreshCache { return }
        do {
            _ = try await refreshDisplayMap()
        } catch {
            // Best-effort warmup during user drag; capture() surfaces any real errors.
            _ = error
        }
    }

    public func capture(rect: CGRect) async throws -> CGImage {
        try permissions.snapshot.validateCapture(source: .visionOCR)
        guard ScreenshotTranslateSupport.isUsableRegion(rect) else {
            throw CaptureError.invalidWindow
        }
        guard let screen = owningScreen(for: rect) else {
            throw CaptureError.captureFailed
        }
        let displayID = Self.displayID(of: screen)
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
        let targetSize = ScreenCaptureKitWindowCapturer.outputSize(
            for: CGSize(width: outputWidth, height: outputHeight),
            maximumDimension: maximumDimension
        )

        let cached = cachedDisplay(for: displayID)
        let usedCache = cached != nil
        let displayBox: SendableDisplay
        if let cached {
            displayBox = cached
        } else if let refreshed = try await refreshDisplayMap()[displayID] {
            displayBox = refreshed
        } else {
            throw CaptureError.captureFailed
        }

        let image: CGImage
        do {
            image = try await captureFromDisplay(displayBox.value, sourceRect: sourceRect, targetSize: targetSize)
        } catch is CancellationError {
            throw CancellationError()
        } catch CaptureError.protected(let reason) {
            throw CaptureError.protected(reason)
        } catch {
            guard usedCache else { throw error }
            invalidateDisplayCache()
            guard let refreshed = try await refreshDisplayMap()[displayID] else {
                throw CaptureError.captureFailed
            }
            image = try await captureFromDisplay(refreshed.value, sourceRect: sourceRect, targetSize: targetSize)
        }
        try permissions.snapshot.validateCapture(source: .visionOCR)
        return RegionCaptureFallback.croppedIfFullDisplay(
            image,
            selection: rect,
            screenFrame: screen.frame,
            scale: scale
        )
    }

    private func captureFromDisplay(
        _ display: SCDisplay,
        sourceRect: CGRect,
        targetSize: CGSize
    ) async throws -> CGImage {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = sourceRect
        configuration.width = Int(targetSize.width)
        configuration.height = Int(targetSize.height)
        configuration.showsCursor = false
        configuration.capturesAudio = false
        try permissions.snapshot.validateCapture(source: .visionOCR)
        return try await captureImage(filter: filter, configuration: configuration)
    }

    private func cachedDisplay(for displayID: CGDirectDisplayID) -> SendableDisplay? {
        let now = ProcessInfo.processInfo.systemUptime
        return displayCacheLock.withLock { state in
            guard !state.displaysByID.isEmpty,
                  now - state.refreshedAt <= Self.displayCacheTTLSeconds else {
                return nil
            }
            return state.displaysByID[displayID]
        }
    }

    private func invalidateDisplayCache() {
        displayCacheLock.withLock { state in
            state = DisplayCacheState()
        }
    }

    private func refreshDisplayMap() async throws -> [CGDirectDisplayID: SendableDisplay] {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        } catch {
            throw CaptureError.captureFailed
        }
        var map: [CGDirectDisplayID: SendableDisplay] = [:]
        map.reserveCapacity(content.displays.count)
        for display in content.displays {
            map[display.displayID] = SendableDisplay(value: display)
        }
        let frozenMap = map
        let now = ProcessInfo.processInfo.systemUptime
        displayCacheLock.withLock { state in
            state = DisplayCacheState(displaysByID: frozenMap, refreshedAt: now)
        }
        return frozenMap
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
