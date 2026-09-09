import Foundation
import GlobalTranslatorCore
import GlobalTranslatorCapture
import GlobalTranslatorEngine

/// UI-facing runtime status for the menu bar and popover header.
/// State is always carried by text (`accessibilityLabel` / `statusText`);
/// the SF Symbol is reinforcement only.
public enum MenuBarStatus: String, CaseIterable, Equatable, Sendable {
    case off
    case listening
    case translating
    case missingPermission
    case error

    public init(engineState: EngineState) {
        switch engineState {
        case .off:
            self = .off
        case .listening:
            self = .listening
        case .translating:
            self = .translating
        case .missingPermission:
            self = .missingPermission
        case .backendError, .circuitOpen:
            self = .error
        }
    }

    /// SF Symbol name rendered as a template image in the status item.
    public var symbolName: String {
        switch self {
        case .off:
            return "pause.circle"
        case .listening:
            return "character.bubble"
        case .translating:
            return "ellipsis.bubble"
        case .missingPermission, .error:
            return "exclamationmark.triangle"
        }
    }

    /// Short state line for the status item accessibility label and popover header.
    public var accessibilityLabel: String {
        switch self {
        case .off:
            return "自动翻译已关闭"
        case .listening:
            return "正在监听活动窗口"
        case .translating:
            return "翻译中"
        case .missingPermission:
            return "缺少系统权限"
        case .error:
            return "翻译服务出错"
        }
    }

    /// Longer tooltip/help text for the status item.
    public var helpText: String {
        switch self {
        case .off:
            return "Global Translator 已暂停，点击打开设置"
        case .listening:
            return "Global Translator 正在监听活动窗口的文本"
        case .translating:
            return "Global Translator 正在翻译屏幕内容"
        case .missingPermission:
            return "Global Translator 需要辅助功能或屏幕录制权限，点击打开设置"
        case .error:
            return "Global Translator 翻译服务出错，点击查看详情"
        }
    }
}

/// Result of a user-triggered key operation (save/delete).
public enum KeyOperationState: Equatable, Sendable {
    case idle
    case inProgress
    case failure(String)
}

/// Result of a user-triggered connection test.
public enum ConnectionTestState: Equatable, Sendable {
    case idle
    case testing
    case healthy(String)
    case failed(String)
}

/// Errors surfaced in the UI must be safe to render verbatim. Conformers
/// provide fixed, user-facing Chinese text; anything that does not conform is
/// replaced by a generic message so internal details (URLs, credentials,
/// backend payloads) can never reach the screen.
public protocol UISafeError {
    var uiSafeDescription: String { get }
}

/// Fixed UI-facing copy shared across the settings surface.
public enum UIFeedback {
    /// Shown for any error that is not explicitly UI-safe.
    public static let genericErrorMessage = "操作失败，请稍后重试。"
}

extension TranslationError: UISafeError {
    /// Fixed Chinese text per known error; associated payloads are never
    /// interpolated because they may contain internal detail.
    public var uiSafeDescription: String {
        switch self {
        case .invalidRequest:
            return "请求无效，请检查配置"
        case .missingCredential:
            return "缺少凭证，请先配置 API Key"
        case .unauthorized, .forbidden:
            return "凭证被拒绝，请检查 API Key"
        case .rateLimited:
            return "请求过于频繁，请稍后重试"
        case .serverFailure:
            return "服务端出错，请稍后重试"
        case .timeout:
            return "请求超时，请检查网络后重试"
        case .networkFailure:
            return "网络连接失败，请检查网络"
        case .redirectRejected:
            return "请求被重定向拦截，请检查服务地址"
        case .modelUnavailable:
            return "所需模型不可用，请更换模型"
        case .invalidConfiguration:
            return "配置无效，请检查后端设置"
        case .invalidResponse:
            return "服务返回异常，请稍后重试"
        }
    }
}

extension BackendHealthStatus {
    /// Fixed Chinese text for non-healthy statuses; raw backend messages are
    /// only shown for healthy results.
    public var uiSafeFailureMessage: String {
        switch self {
        case .healthy:
            return ""
        case .unavailable:
            return "服务暂不可用，请稍后重试"
        case .invalidCredentials:
            return "凭证无效，请检查 API Key 后重试"
        case .modelUnavailable:
            return "所需模型不可用，请更换模型或检查服务"
        case .invalidConfiguration:
            return "配置无效，请检查后端设置"
        }
    }
}

/// One application explicitly allowed for translation.
public struct TranslatedApplication: Identifiable, Equatable, Sendable {
    public let bundleIdentifier: String
    public let displayName: String

    public var id: String { bundleIdentifier }

    public init(bundleIdentifier: String, displayName: String) {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
    }
}

/// Actions the settings surface delegates to the integration layer.
/// Implementations live outside this target; the UI contains no backend logic.
@MainActor
public protocol SettingsActions: AnyObject {
    func setAutomaticTranslation(_ enabled: Bool)
    func setSelectionTranslate(_ enabled: Bool)
    func setVideoTranslate(_ enabled: Bool)
    func setPromptOptimizeMode(_ mode: PromptOptimizeMode)
    func selectBackend(_ kind: BackendKind)
    /// Persists the draft API key. The UI never logs or stores it; the draft is
    /// cleared by the view model only after this call succeeds.
    func saveAPIKey(_ draft: String) async throws
    func deleteAPIKey() async throws
    func testConnection() async throws -> BackendHealth
    func setVisionFallback(_ enabled: Bool)
    func setLocalConfiguration(baseURL: String, model: String)
    func setDeepSeekModel(_ model: String)
    func requestPermission(_ kind: PermissionKind)
    func refreshPermissions()
    func openSystemSettings(_ kind: PermissionKind)
    /// Adds the currently active application to the translation allow list.
    func addCurrentAppTranslation()
    /// Opens a native application picker and adds every selected app to the
    /// translation allow list. Only listed applications are ever translated.
    func chooseTranslatedApplications()
    func removeTranslationApplication(bundleIdentifier: String)
    func clearCache() async throws
    func openLogs()
    func quit()
}
