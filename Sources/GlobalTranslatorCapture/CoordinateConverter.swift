import CoreGraphics
import Foundation

public enum CoordinateConverter {
    /// `TextRegion.screenFrame` uses AppKit global lower-left coordinates.
    public static func quartzTopLeftFrameToAppKitGlobal(
        _ frame: CGRect,
        primaryDisplayFrame: CGRect
    ) -> CGRect {
        CGRect(
            x: primaryDisplayFrame.minX + frame.minX,
            y: primaryDisplayFrame.minY + primaryDisplayFrame.height - frame.maxY,
            width: frame.width,
            height: frame.height
        )
    }

    public static func axTopLeftFrameToAppKitGlobal(_ frame: CGRect, desktopFrame: CGRect) -> CGRect {
        quartzTopLeftFrameToAppKitGlobal(frame, primaryDisplayFrame: desktopFrame)
    }

    public static func visionBoundingBoxToAppKitGlobal(
        _ normalizedBoundingBox: CGRect,
        windowFrame: CGRect,
        imageSize: CGSize
    ) -> CGRect {
        visionBoundingBoxToScreenFrame(normalizedBoundingBox, windowFrame: windowFrame, imageSize: imageSize)
    }

    public static func visionBoundingBoxToScreenFrame(
        _ normalizedBoundingBox: CGRect,
        windowFrame: CGRect,
        imageSize: CGSize
    ) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let normalized = normalizedBoundingBox.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !normalized.isNull, !normalized.isEmpty else { return .zero }
        let pixelRect = CGRect(
            x: normalized.minX * imageSize.width,
            y: normalized.minY * imageSize.height,
            width: normalized.width * imageSize.width,
            height: normalized.height * imageSize.height
        )
        return CGRect(
            x: windowFrame.minX + pixelRect.minX / imageSize.width * windowFrame.width,
            y: windowFrame.minY + pixelRect.minY / imageSize.height * windowFrame.height,
            width: pixelRect.width / imageSize.width * windowFrame.width,
            height: pixelRect.height / imageSize.height * windowFrame.height
        )
    }

    public static func screenFrameToImageRect(
        _ screenFrame: CGRect,
        windowFrame: CGRect,
        imageSize: CGSize
    ) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, windowFrame.width > 0, windowFrame.height > 0 else {
            return .zero
        }
        let intersection = screenFrame.intersection(windowFrame)
        guard !intersection.isNull, !intersection.isEmpty else { return .zero }
        return CGRect(
            x: (intersection.minX - windowFrame.minX) / windowFrame.width * imageSize.width,
            y: (intersection.minY - windowFrame.minY) / windowFrame.height * imageSize.height,
            width: intersection.width / windowFrame.width * imageSize.width,
            height: intersection.height / windowFrame.height * imageSize.height
        )
    }

    public static func lowerLeftToTopLeft(_ rect: CGRect, imageHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: imageHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}
