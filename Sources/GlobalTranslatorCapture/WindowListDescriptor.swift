import AppKit
import CoreGraphics
import Foundation

@MainActor
extension ActiveWindowMonitor {
    func screenCaptureDescriptor(for pid: Int32, bundleIdentifier: String, invalidatesOverlay: Bool) -> ActiveWindowDescriptor? {
        do { try permissions.snapshot.validateCapture(source: .visionOCR) } catch { return nil }
        guard let primaryFrame = NSScreen.screens.first?.frame,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        return windowListDescriptor(windows, pid: pid, bundleIdentifier: bundleIdentifier, invalidatesOverlay: invalidatesOverlay, primaryDisplayFrame: primaryFrame)
    }

    func windowListDescriptor(
        _ windows: [[String: Any]],
        pid: Int32,
        bundleIdentifier: String,
        invalidatesOverlay: Bool,
        primaryDisplayFrame: CGRect
    ) -> ActiveWindowDescriptor? {
        do { try permissions.snapshot.validateCapture(source: .visionOCR) } catch { return nil }
        for info in windows {
            guard info[kCGWindowOwnerPID as String] as? Int == Int(pid),
                  info[kCGWindowLayer as String] as? Int == 0,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let windowID = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds), frame.width > 0, frame.height > 0 else { continue }
            return ActiveWindowDescriptor(
                pid: pid, bundleIdentifier: bundleIdentifier, windowID: windowID,
                frame: CoordinateConverter.quartzTopLeftFrameToAppKitGlobal(frame, primaryDisplayFrame: primaryDisplayFrame),
                revision: 0, invalidatesOverlay: invalidatesOverlay
            )
        }
        return nil
    }
}
