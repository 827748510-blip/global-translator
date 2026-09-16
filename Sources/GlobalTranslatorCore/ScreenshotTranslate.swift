import CoreGraphics
import Foundation

public enum ScreenshotBackendReadiness: Equatable, Sendable {
    case ready
    case missingCloudKey
    case localNotReady
}

public enum ScreenshotTranslateError: Error, Equatable, Sendable {
    case missingScreenCapture
    case emptyRegion
    case captureFailed
    case ocrFailed
    case ocrEmpty
    case notTranslatable
    case translatorUnavailable
    case emptyResult
    case cancelled
}

public enum ScreenshotTranslateSupport {
    public static let emptyRegionCopy = "未选中有效区域"
    public static let ocrFailedCopy = "未能识别文字"
    public static let ocrEmptyCopy = "未识别到文字"
    public static let notTranslatableCopy = "未识别到可翻译文字"
    public static let captureFailedCopy = "截图失败"
    public static let missingScreenCaptureCopy = "截图翻译需要屏幕录制权限，请到设置授权"
    public static let localBackendNotReadyCopy = "本地后端未就绪，请先启动 Ollama 并测试连接"
    public static let missingDeepSeekKeyCopy = SelectionTranslateSupport.missingDeepSeekKeyCopy
    public static let translatorUnavailableCopy = "翻译服务未就绪"
    public static let overlayHintCopy = "拖选要翻译的区域，Esc 取消"
    public static let minRegionSize: CGFloat = 8
    public static let recognitionLanguages = ["zh-Hans", "en-US"]
    public static let hotkeyID: UInt32 = 1

    public static func isUsableRegion(_ rect: CGRect) -> Bool {
        rect.width >= minRegionSize && rect.height >= minRegionSize
    }

    public static func message(for error: ScreenshotTranslateError) -> String {
        switch error {
        case .missingScreenCapture:
            return missingScreenCaptureCopy
        case .emptyRegion:
            return emptyRegionCopy
        case .captureFailed:
            return captureFailedCopy
        case .ocrFailed:
            return ocrFailedCopy
        case .ocrEmpty:
            return ocrEmptyCopy
        case .notTranslatable:
            return notTranslatableCopy
        case .translatorUnavailable:
            return translatorUnavailableCopy
        case .emptyResult:
            return SelectionTranslateErrorMessage.failed
        case .cancelled:
            return ""
        }
    }
}

public enum SelectionTranslateErrorMessage {
    public static let failed = "翻译失败"
}

/// Geometry-only drag session for the region overlay. Screen points are
/// AppKit global (origin lower-left). Never records pixel contents.
public struct ScreenshotRegionDrag: Equatable, Sendable {
    public private(set) var isDragging = false
    public private(set) var origin: CGPoint?
    public private(set) var current: CGPoint?

    public init() {}

    public var screenRect: CGRect {
        guard let origin, let current else { return .zero }
        return CGRect(
            x: min(origin.x, current.x),
            y: min(origin.y, current.y),
            width: abs(current.x - origin.x),
            height: abs(current.y - origin.y)
        )
    }

    public mutating func begin(at point: CGPoint) {
        isDragging = true
        origin = point
        current = point
    }

    public mutating func move(to point: CGPoint) {
        guard isDragging else { return }
        current = point
    }

    public mutating func finish() -> CGRect? {
        let rect = screenRect
        reset()
        return ScreenshotTranslateSupport.isUsableRegion(rect) ? rect : nil
    }

    public mutating func cancel() {
        reset()
    }

    private mutating func reset() {
        isDragging = false
        origin = nil
        current = nil
    }
}

public enum RegionCaptureGeometry {
    /// Display-local Quartz `sourceRect` (origin top-left of the display).
    public static func displayLocalSourceRect(selection: CGRect, screenFrame: CGRect) -> CGRect {
        let intersection = selection.intersection(screenFrame)
        guard !intersection.isNull, !intersection.isEmpty else { return .zero }
        return CGRect(
            x: intersection.minX - screenFrame.minX,
            y: screenFrame.maxY - intersection.maxY,
            width: intersection.width,
            height: intersection.height
        )
    }

    /// Crop in lower-left image pixels (matches `CGImageUtilities.crop`).
    public static func imageCropRect(
        selection: CGRect,
        screenFrame: CGRect,
        imageSize: CGSize
    ) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              screenFrame.width > 0, screenFrame.height > 0 else { return .zero }
        let intersection = selection.intersection(screenFrame)
        guard !intersection.isNull, !intersection.isEmpty else { return .zero }
        return CGRect(
            x: (intersection.minX - screenFrame.minX) / screenFrame.width * imageSize.width,
            y: (intersection.minY - screenFrame.minY) / screenFrame.height * imageSize.height,
            width: intersection.width / screenFrame.width * imageSize.width,
            height: intersection.height / screenFrame.height * imageSize.height
        )
    }

    public static func clamp(_ rect: CGRect, to screen: CGRect) -> CGRect {
        rect.intersection(screen)
    }

    public static func owningScreenFrame(for point: CGPoint, in frames: [CGRect]) -> CGRect? {
        if let containing = frames.first(where: { $0.contains(point) }) {
            return containing
        }
        return frames.max(by: { $0.intersection(CGRect(origin: point, size: CGSize(width: 1, height: 1))).width
            < $1.intersection(CGRect(origin: point, size: CGSize(width: 1, height: 1))).width })
    }
}
