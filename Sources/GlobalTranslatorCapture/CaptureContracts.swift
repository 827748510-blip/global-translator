@_exported import GlobalTranslatorCore
import CoreGraphics
import Foundation

public struct PermissionSnapshot: Codable, Equatable, Sendable {
    public let accessibilityTrusted: Bool
    public let screenCaptureAuthorized: Bool
    public let secureInputEnabled: Bool
    public let sessionLocked: Bool

    public init(
        accessibilityTrusted: Bool,
        screenCaptureAuthorized: Bool,
        secureInputEnabled: Bool,
        sessionLocked: Bool
    ) {
        self.accessibilityTrusted = accessibilityTrusted
        self.screenCaptureAuthorized = screenCaptureAuthorized
        self.secureInputEnabled = secureInputEnabled
        self.sessionLocked = sessionLocked
    }

    public static let allGranted = PermissionSnapshot(
        accessibilityTrusted: true,
        screenCaptureAuthorized: true,
        secureInputEnabled: false,
        sessionLocked: false
    )

    /// Window overlay / OCR capture needs at least one of these.
    /// The browser-extension bridge does not: it receives DOM text.
    public var hasCaptureAccess: Bool {
        accessibilityTrusted || screenCaptureAuthorized
    }
}

public enum PermissionKind: String, Codable, Equatable, Sendable {
    case accessibility
    case screenCapture
}

public enum ProtectedReason: String, Codable, Equatable, Sendable {
    case secureInput
    case sessionLocked
    case protectedWindow
}

public enum CaptureError: Error, Codable, Equatable, Sendable, CustomStringConvertible {
    case permissionRequired(PermissionKind)
    case protected(ProtectedReason)
    case excludedApplication(String)
    case selfApplication
    case noActiveWindow
    case accessibilityUnavailable
    case captureFailed
    case ocrFailed
    case unsupported
    case invalidWindow
    case cancelled

    public var description: String {
        switch self {
        case .permissionRequired(let kind):
            return "permission required: \(kind.rawValue)"
        case .protected(let reason):
            return "capture protected: \(reason.rawValue)"
        case .excludedApplication(let bundleIdentifier):
            return "excluded application: \(bundleIdentifier)"
        case .selfApplication:
            return "self application is excluded"
        case .noActiveWindow:
            return "no active window"
        case .accessibilityUnavailable:
            return "accessibility data unavailable"
        case .captureFailed:
            return "screen capture failed"
        case .ocrFailed:
            return "vision OCR failed"
        case .unsupported:
            return "capture unsupported"
        case .invalidWindow:
            return "invalid active window"
        case .cancelled:
            return "capture cancelled"
        }
    }
}

public struct ActiveWindowDescriptor: Codable, Equatable, Sendable {
    public let pid: Int32
    public let bundleIdentifier: String
    public let windowID: CGWindowID?
    public let frame: CGRect
    public let revision: UInt64
    public let invalidatesOverlay: Bool

    public var processID: Int32 { pid }
    public var bundleID: String { bundleIdentifier }

    public init(
        pid: Int32,
        bundleIdentifier: String,
        windowID: CGWindowID? = nil,
        frame: CGRect,
        revision: UInt64,
        invalidatesOverlay: Bool = true
    ) {
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
        self.windowID = windowID
        self.frame = frame
        self.revision = revision
        self.invalidatesOverlay = invalidatesOverlay
    }

    private enum CodingKeys: String, CodingKey { case pid, bundleIdentifier, windowID, frame, revision, invalidatesOverlay }
    private enum FrameKeys: String, CodingKey { case x, y, width, height }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pid = try container.decode(Int32.self, forKey: .pid)
        bundleIdentifier = try container.decode(String.self, forKey: .bundleIdentifier)
        windowID = try container.decodeIfPresent(CGWindowID.self, forKey: .windowID)
        let frame = try container.nestedContainer(keyedBy: FrameKeys.self, forKey: .frame)
        self.frame = CGRect(
            x: try frame.decode(CGFloat.self, forKey: .x),
            y: try frame.decode(CGFloat.self, forKey: .y),
            width: try frame.decode(CGFloat.self, forKey: .width),
            height: try frame.decode(CGFloat.self, forKey: .height)
        )
        revision = try container.decode(UInt64.self, forKey: .revision)
        invalidatesOverlay = try container.decodeIfPresent(Bool.self, forKey: .invalidatesOverlay) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pid, forKey: .pid)
        try container.encode(invalidatesOverlay, forKey: .invalidatesOverlay)
        try container.encode(bundleIdentifier, forKey: .bundleIdentifier)
        try container.encodeIfPresent(windowID, forKey: .windowID)
        var frame = container.nestedContainer(keyedBy: FrameKeys.self, forKey: .frame)
        try frame.encode(self.frame.origin.x, forKey: .x)
        try frame.encode(self.frame.origin.y, forKey: .y)
        try frame.encode(self.frame.size.width, forKey: .width)
        try frame.encode(self.frame.size.height, forKey: .height)
        try container.encode(revision, forKey: .revision)
    }
}

public enum CaptureSource: String, Codable, Equatable, Sendable {
    case accessibility
    case visionOCR
    /// Text already extracted from a page (extension bridge or CDP in-page).
    /// No screen or Accessibility capture is involved, so secure-input and
    /// session-lock gates that protect window capture do not apply.
    case pageText
}

public struct ImageFingerprint: Hashable, Codable, Sendable {
    public let value: UInt64

    public init(value: UInt64) {
        self.value = value
    }

    public init(image: CGImage) {
        self = CGImageUtilities.fingerprint(image)
    }
}

public struct CapturedWindow: @unchecked Sendable {
    public let descriptor: ActiveWindowDescriptor
    public let regions: [TextRegion]
    public let source: CaptureSource
    public let fingerprint: ImageFingerprint?
    public let capturedImage: CGImage?

    public var textRegions: [TextRegion] { regions }

    public init(
        descriptor: ActiveWindowDescriptor,
        regions: [TextRegion],
        source: CaptureSource,
        fingerprint: ImageFingerprint? = nil,
        capturedImage: CGImage? = nil
    ) {
        self.descriptor = descriptor
        self.regions = regions
        self.source = source
        self.fingerprint = fingerprint
        self.capturedImage = capturedImage
    }
}

public struct CaptureSnapshot: @unchecked Sendable {
    public let window: CapturedWindow
    public let ocrSkipped: Bool
    public let sourceLanguage: TranslationSourceLanguage?

    public init(window: CapturedWindow, ocrSkipped: Bool = false, sourceLanguage: TranslationSourceLanguage? = nil) {
        self.window = window
        self.ocrSkipped = ocrSkipped
        self.sourceLanguage = sourceLanguage
    }

    public var descriptor: ActiveWindowDescriptor { window.descriptor }
    public var regions: [TextRegion] { window.regions }
    public var source: CaptureSource { window.source }
    public var capturedImage: CGImage? { window.capturedImage }
    public var capturedWindow: CapturedWindow { window }
    public var windows: [CapturedWindow] { [window] }
    public var textRegions: [TextRegion] { regions }
}
