import Foundation
import Combine
import GlobalTranslatorCore
import GlobalTranslatorCapture

/// View model for the settings popover. Presentation only — all backend,
/// keychain, and permission work is delegated to the injected `SettingsActions`.
///
/// Security invariant: `keyDraft` starts empty and is never populated from a
/// stored key. It is cleared only after a successful save.
@MainActor
public final class SettingsViewModel: ObservableObject {
    // MARK: - Integration-pushed state

    /// Current runtime status shown in the status item and popover header.
    @Published public var status: MenuBarStatus = .off
    @Published public var isAutomaticTranslationEnabled = false
    @Published public var selectedBackend: BackendKind = .deepSeekCloud
    @Published public var visionFallbackEnabled = false
    @Published public var keyConfigured = false
    @Published public var localBaseURL = ""
    @Published public var localModel = ""
    @Published public var availableModels: [String] = []
    @Published public var permissionSnapshot = PermissionSnapshot(
        accessibilityTrusted: false,
        screenCaptureAuthorized: false,
        secureInputEnabled: false,
        sessionLocked: false
    )
    @Published public var translatedApplications: [TranslatedApplication] = []
    @Published public var healthMessage: String?

    /// Whether the currently selected backend has been validated (healthy
    /// connection test, or a successful key save for cloud). Reset whenever
    /// the backend selection or local configuration changes.
    @Published public var backendReady = false

    // MARK: - User-editable state

    /// Never prefilled; cleared on successful save only.
    @Published public var keyDraft = ""
    @Published public var keyOperation: KeyOperationState = .idle
    @Published public var connectionTest: ConnectionTestState = .idle

    // MARK: - Confirmation state

    @Published public var isDeleteKeyConfirmationPresented = false
    @Published public var isVisionConsentPresented = false
    @Published public var isClearCacheConfirmationPresented = false

    /// Target language is fixed by product design.
    public let targetLanguageDisplayName = "简体中文"

    /// Consent copy shown before the vision fallback can be enabled.
    public var visionConsentText: String {
        "开启视觉兜底后，当辅助功能无法读取文本时，Global Translator 会将当前窗口的局部截图上传到 DeepSeek 进行识别翻译。截图仅用于本次翻译，不会在本地保存。仅在信任该后端时开启。"
    }

    private let actions: SettingsActions

    public init(actions: SettingsActions) {
        self.actions = actions
    }

    // MARK: - Derived state

    public var canSaveKey: Bool {
        guard keyOperation != .inProgress else { return false }
        return !keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var isKeyOperationInProgress: Bool {
        keyOperation == .inProgress
    }

    public var canTestConnection: Bool {
        guard connectionTest != .testing else { return false }
        switch selectedBackend {
        case .deepSeekCloud:
            return keyConfigured
        case .local:
            return !localBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Automatic translation may be enabled when the selected backend is
    /// validated. Capture permissions are not required: the Chrome
    /// extension sends DOM text to the local bridge. Window overlay capture
    /// stays permission-gated separately. Turning OFF is never gated.
    public var canEnableAutomaticTranslation: Bool {
        automaticEnableBlockedReason == nil
    }

    public var visibleAutomaticEnableBlockedReason: String? {
        guard !isAutomaticTranslationEnabled else { return nil }
        return automaticEnableBlockedReason
    }

    /// Human-readable Chinese reason why enabling is currently blocked, or nil
    /// when enabling is allowed. Also shown after a refused enable attempt.
    public var automaticEnableBlockedReason: String? {
        switch selectedBackend {
        case .deepSeekCloud:
            guard keyConfigured else { return "请先配置 API Key" }
            guard backendReady else { return "云端后端未就绪，请保存密钥或测试连接" }
        case .local:
            guard Self.isLoopbackURL(localBaseURL) else {
                return "请填写本机回环服务地址，例如 http://127.0.0.1:11434/v1"
            }
            guard !localModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "请选择本地模型"
            }
            guard backendReady else { return "本地后端未就绪，请先测试连接" }
        }
        return nil
    }

    /// True when the string is a URL whose host is a loopback address.
    static func isLoopbackURL(_ string: String) -> Bool {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host?.lowercased() else { return false }
        return host == "localhost" || host == "::1" || host.hasPrefix("127.")
    }

    // MARK: - General

    public func setAutomaticTranslation(_ enabled: Bool) {
        if enabled {
            guard !isAutomaticTranslationEnabled else { return }
            guard canEnableAutomaticTranslation else {
                // Refused: state and integration layer stay untouched.
                healthMessage = automaticEnableBlockedReason
                return
            }
            isAutomaticTranslationEnabled = true
            actions.setAutomaticTranslation(true)
        } else {
            guard isAutomaticTranslationEnabled else { return }
            isAutomaticTranslationEnabled = false
            actions.setAutomaticTranslation(false)
        }
    }

    public func selectBackend(_ kind: BackendKind) {
        selectedBackend = kind
        connectionTest = .idle
        backendReady = false
        actions.selectBackend(kind)
    }

    // MARK: - API key

    public func saveKey() async {
        let trimmed = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSaveKey, !trimmed.isEmpty else { return }
        keyOperation = .inProgress
        do {
            try await actions.saveAPIKey(trimmed)
            keyDraft = ""
            keyConfigured = true
            // A validated save is enough to consider the cloud backend ready.
            if selectedBackend == .deepSeekCloud {
                backendReady = true
            }
            keyOperation = .idle
        } catch {
            // Draft is preserved so the user can retry; it is never logged.
            keyOperation = .failure(Self.describe(error))
        }
    }

    public func requestDeleteKey() {
        guard keyConfigured else { return }
        isDeleteKeyConfirmationPresented = true
    }

    public func confirmDeleteKey() async {
        guard keyConfigured else {
            isDeleteKeyConfirmationPresented = false
            return
        }
        isDeleteKeyConfirmationPresented = false
        keyOperation = .inProgress
        do {
            try await actions.deleteAPIKey()
            keyConfigured = false
            keyDraft = ""
            backendReady = false
            keyOperation = .idle
        } catch {
            keyOperation = .failure(Self.describe(error))
        }
    }

    public func cancelDeleteKey() {
        isDeleteKeyConfirmationPresented = false
    }

    // MARK: - Connection test

    public func testConnection() async {
        guard canTestConnection else { return }
        connectionTest = .testing
        do {
            let health = try await actions.testConnection()
            switch health.status {
            case .healthy:
                connectionTest = .healthy(health.message)
                healthMessage = health.message
                backendReady = true
                availableModels = health.availableModels
            case .unavailable, .invalidCredentials, .modelUnavailable, .invalidConfiguration:
                // Only `.healthy` counts as success; failure statuses show
                // fixed UI-safe Chinese text, never the raw backend message.
                let message = health.status.uiSafeFailureMessage
                connectionTest = .failed(message)
                healthMessage = message
                backendReady = false
                if !health.availableModels.isEmpty {
                    availableModels = health.availableModels
                }
            }
        } catch {
            let message = Self.describe(error)
            connectionTest = .failed(message)
            healthMessage = message
            backendReady = false
        }
    }

    // MARK: - Vision fallback

    /// Enabling requires explicit consent about the screenshot upload;
    /// disabling applies immediately.
    public func setVisionFallbackEnabled(_ enabled: Bool) {
        if enabled {
            guard !visionFallbackEnabled else { return }
            isVisionConsentPresented = true
        } else {
            visionFallbackEnabled = false
            isVisionConsentPresented = false
            actions.setVisionFallback(false)
        }
    }

    public func confirmVisionConsent() {
        isVisionConsentPresented = false
        visionFallbackEnabled = true
        actions.setVisionFallback(true)
    }

    public func cancelVisionConsent() {
        isVisionConsentPresented = false
    }

    // MARK: - Local backend

    public func commitLocalConfiguration() {
        let trimmedURL = localBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else { return }
        // Any local config change invalidates previous validation.
        backendReady = false
        actions.setLocalConfiguration(baseURL: trimmedURL, model: localModel)
    }

    // MARK: - Permissions

    public func refreshPermissions() {
        actions.refreshPermissions()
    }

    public func requestPermission(_ kind: PermissionKind) {
        actions.requestPermission(kind)
    }

    public func openSystemSettings(_ kind: PermissionKind) {
        actions.openSystemSettings(kind)
    }

    // MARK: - Translated applications

    public func addCurrentAppTranslation() {
        actions.addCurrentAppTranslation()
    }

    public func chooseTranslatedApplications() {
        actions.chooseTranslatedApplications()
    }

    public func removeTranslationApplication(bundleIdentifier: String) {
        translatedApplications.removeAll { $0.bundleIdentifier == bundleIdentifier }
        actions.removeTranslationApplication(bundleIdentifier: bundleIdentifier)
    }

    // MARK: - Maintenance

    public func requestClearCache() {
        isClearCacheConfirmationPresented = true
    }

    public func confirmClearCache() async {
        isClearCacheConfirmationPresented = false
        do {
            try await actions.clearCache()
        } catch {
            healthMessage = Self.describe(error)
        }
    }

    public func cancelClearCache() {
        isClearCacheConfirmationPresented = false
    }

    public func openLogs() {
        actions.openLogs()
    }

    public func quit() {
        actions.quit()
    }

    // MARK: - Error description

    /// Only explicitly UI-safe errors render their own text; everything else
    /// collapses to a fixed generic message so no internal detail leaks.
    private static func describe(_ error: Error) -> String {
        if let safe = error as? UISafeError {
            return safe.uiSafeDescription
        }
        return UIFeedback.genericErrorMessage
    }
}
