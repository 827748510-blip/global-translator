import Foundation

public extension PermissionSnapshot {
    func validateCapture(source: CaptureSource? = nil) throws {
        if source == .pageText { return }
        if secureInputEnabled { throw CaptureError.protected(.secureInput) }
        if sessionLocked { throw CaptureError.protected(.sessionLocked) }
        switch source {
        case .accessibility:
            guard accessibilityTrusted else { throw CaptureError.permissionRequired(.accessibility) }
        case .visionOCR:
            guard screenCaptureAuthorized else { throw CaptureError.permissionRequired(.screenCapture) }
        case .pageText:
            return
        case nil:
            guard hasCaptureAccess else {
                throw CaptureError.permissionRequired(.accessibility)
            }
        }
    }
}
