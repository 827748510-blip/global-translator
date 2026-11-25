import CoreGraphics
import Foundation
import AppKit
import ScreenCaptureKit

public protocol ScreenCaptureProviding: Sendable {
    func capture(window: ActiveWindowDescriptor) async throws -> CGImage
}

@available(macOS 14.0, *)
public final class ScreenCaptureKitWindowCapturer: ScreenCaptureProviding, @unchecked Sendable {
    public let maximumDimension: Int

    public init(maximumDimension: Int = 2_048) {
        self.maximumDimension = min(max(maximumDimension, 1), 2_048)
    }

    public static func outputSize(for size: CGSize, maximumDimension: Int) -> CGSize {
        guard size.width > 0, size.height > 0 else { return .zero }
        let maximum = CGFloat(max(maximumDimension, 1))
        let scale = min(1, maximum / max(size.width, size.height))
        return CGSize(
            width: max(1, (size.width * scale).rounded()),
            height: max(1, (size.height * scale).rounded())
        )
    }

    public static func matches(
        candidateProcessID: Int32,
        candidateWindowID: CGWindowID?,
        candidateFrame: CGRect,
        descriptor: ActiveWindowDescriptor,
        primaryDisplayFrame: CGRect
    ) -> Bool {
        guard candidateProcessID == descriptor.pid else { return false }
        if let expectedWindowID = descriptor.windowID {
            guard candidateWindowID == expectedWindowID else { return false }
        }
        let appKitFrame = CoordinateConverter.quartzTopLeftFrameToAppKitGlobal(
            candidateFrame,
            primaryDisplayFrame: primaryDisplayFrame
        )
        let delta = abs(appKitFrame.minX - descriptor.frame.minX) +
            abs(appKitFrame.minY - descriptor.frame.minY) +
            abs(appKitFrame.width - descriptor.frame.width) +
            abs(appKitFrame.height - descriptor.frame.height)
        return delta < 4
    }

    public func capture(window: ActiveWindowDescriptor) async throws -> CGImage {
        guard window.frame.width > 0, window.frame.height > 0 else {
            throw CaptureError.invalidWindow
        }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw CaptureError.captureFailed
        }
        guard let candidate = content.windows.first(where: { matches($0, descriptor: window) }) else {
            throw CaptureError.unsupported
        }
        let filter = SCContentFilter(desktopIndependentWindow: candidate)
        let configuration = SCStreamConfiguration()
        let output = Self.outputSize(
            for: CGSize(width: window.frame.width, height: window.frame.height),
            maximumDimension: maximumDimension
        )
        configuration.width = Int(output.width)
        configuration.height = Int(output.height)
        configuration.showsCursor = false
        let image = try await captureImage(filter: filter, configuration: configuration)
        return CGImageUtilities.downsample(image, maximumDimension: maximumDimension) ?? image
    }

    private func matches(_ candidate: SCWindow, descriptor: ActiveWindowDescriptor) -> Bool {
        guard let primaryDisplayFrame = NSScreen.screens.first?.frame else { return false }
        return Self.matches(
            candidateProcessID: Int32(candidate.owningApplication?.processID ?? -1),
            candidateWindowID: candidate.windowID,
            candidateFrame: candidate.frame,
            descriptor: descriptor,
            primaryDisplayFrame: primaryDisplayFrame
        )
    }

    private func captureImage(
        filter: SCContentFilter,
        configuration: SCStreamConfiguration
    ) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
                if let image {
                    continuation.resume(returning: image)
                } else if error != nil {
                    continuation.resume(throwing: CaptureError.captureFailed)
                } else {
                    continuation.resume(throwing: CaptureError.captureFailed)
                }
            }
        }
    }
}
