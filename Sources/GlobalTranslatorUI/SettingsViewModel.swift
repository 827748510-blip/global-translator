import Foundation
import Observation
import GlobalTranslatorCore
import GlobalTranslatorCapture

/// Top-level navigation tabs inside the menu-bar settings popover.
public enum SettingsTab: String, CaseIterable, Equatable, Hashable, Sendable, Identifiable {
    case translation
    case backend
    case advanced

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .translation:
            return "翻译"
        case .backend:
            return "后端"
        case .advanced:
            return "高级"
        }
    }
}

/// View model for the settings popover. Presentation only — all backend,
/// keychain, and permission work is delegated to the injected `SettingsActions`.
///
/// Security invariant: `keyDraft` starts empty and is never populated from a
/// stored key. It is cleared only after a successful save.
@MainActor
@Observable
public final class SettingsViewModel {
    // MARK: - Integration-pushed state

    /// Current runtime status shown in the status item and popover header.
    public var status: MenuBarStatus = .off {
        didSet {
            guard oldValue != status else { return }
            onStatusChange?(status)
        }
    }
    public var isAutomaticTranslationEnabled = false
    public var isSelectionTranslateEnabled = true
    public var isVideoTranslateEnabled = false
    public var promptOptimizeMode: PromptOptimizeMode = .communicationPolish
    public var autoCopyScreenshotTranslation = false
    public var saveScreenshotImage = false
    public var copyScreenshotImage = false
    public var screenshotSaveDirectory = AppConfiguration.defaultScreenshotSaveDirectory
    public var screenshotTranslateHotkey = KeyboardShortcutSpec.screenshotTranslateDefault
    public var isRecordingScreenshotHotkey = false
    public var screenshotHotkeyConflictMessage: String?
    public var selectedBackend: BackendKind = .deepSeekCloud
    public var keyConfigured = false
    public var localBaseURL = ""
    public var localModel = ""
    public var deepSeekModel = AppConfiguration.defaultDeepSeekModel
    public var availableModels: [String] = []
    public var permissionSnapshot = PermissionSnapshot(
        accessibilityTrusted: false,
        screenCaptureAuthorized: false,
        secureInputEnabled: false,
        sessionLocked: false
    )
    public var translatedApplications: [TranslatedApplication] = []
    public var healthMessage: String?

    /// Whether the currently selected backend has been validated (healthy
    /// connection test, or a successful key save for cloud). Reset whenever
    /// the backend selection or local configuration changes.
    public var backendReady = false

    // MARK: - Navigation & feedback state

    public var selectedTab: SettingsTab = .translation
    public var actionFeedbackMessage: String?

    // MARK: - User-editable state

    /// Never prefilled; cleared on successful save only.
    public var keyDraft = ""
    /// When a key is marked configured, the SecureField stays hidden until
    /// the user explicitly chooses 替换密钥. Switching backends must not open it
    /// and must not read Keychain to decide.
    public var isReplacingKey = false
    public var keyOperation: KeyOperationState = .idle
    public var connectionTest: ConnectionTestState = .idle

    // MARK: - Confirmation state

    public var isDeleteKeyConfirmationPresented = false
    public var isClearCacheConfirmationPresented = false

    /// 窗口覆盖层与扩展桥的目标语言固定为简体中文；划词/截图方向按内容判定。
    public let targetLanguageDisplayName = "简体中文"

    @ObservationIgnored
    public var onStatusChange: ((MenuBarStatus) -> Void)?

    @ObservationIgnored
    private let actions: SettingsActions
    @ObservationIgnored
    private var lastValidatedLocalBaseURL: String?
    @ObservationIgnored
    private var lastValidatedLocalModels: Set<String> = []
    @ObservationIgnored
    private var actionFeedbackGeneration: UInt64 = 0
    @ObservationIgnored
    private var actionFeedbackTask: Task<Void, Never>?

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

    /// Empty key field is only for first-time setup or an explicit replace.
    /// `keyConfigured` is a persisted non-secret flag — never populated by
    /// reading Keychain just to render this form.
    public var showsKeyEntry: Bool {
        !keyConfigured || isReplacingKey
    }

    public var canTestConnection: Bool {
        guard connectionTest != .testing else { return false }
        switch selectedBackend {
        case .deepSeekCloud:
            // Legacy installs may have a Keychain key without the config flag.
            // Allow a health check to migrate the flag; never Keychain-read
            // just to enable this button.
            return true
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

    public func setSelectionTranslate(_ enabled: Bool) {
        guard isSelectionTranslateEnabled != enabled else { return }
        isSelectionTranslateEnabled = enabled
        actions.setSelectionTranslate(enabled)
    }

    public func setVideoTranslate(_ enabled: Bool) {
        guard isVideoTranslateEnabled != enabled else { return }
        isVideoTranslateEnabled = enabled
        actions.setVideoTranslate(enabled)
    }

    public func setPromptOptimizeMode(_ mode: PromptOptimizeMode) {
        guard promptOptimizeMode != mode else { return }
        promptOptimizeMode = mode
        actions.setPromptOptimizeMode(mode)
    }

    public func setAutoCopyScreenshotTranslation(_ enabled: Bool) {
        guard autoCopyScreenshotTranslation != enabled else { return }
        autoCopyScreenshotTranslation = enabled
        actions.setAutoCopyScreenshotTranslation(enabled)
    }

    public func setSaveScreenshotImage(_ enabled: Bool) {
        guard saveScreenshotImage != enabled else { return }
        saveScreenshotImage = enabled
        actions.setSaveScreenshotImage(enabled)
    }

    public func setCopyScreenshotImage(_ enabled: Bool) {
        guard copyScreenshotImage != enabled else { return }
        copyScreenshotImage = enabled
        actions.setCopyScreenshotImage(enabled)
    }

    public func chooseScreenshotSaveDirectory() {
        actions.chooseScreenshotSaveDirectory()
    }

    public func beginRecordingScreenshotHotkey() {
        screenshotHotkeyConflictMessage = nil
        isRecordingScreenshotHotkey = true
        actions.beginScreenshotHotkeyRecording()
    }

    public func cancelRecordingScreenshotHotkey() {
        guard isRecordingScreenshotHotkey else { return }
        isRecordingScreenshotHotkey = false
        actions.cancelScreenshotHotkeyRecording()
    }

    public func setScreenshotTranslateHotkey(_ spec: KeyboardShortcutSpec) {
        screenshotTranslateHotkey = spec
        isRecordingScreenshotHotkey = false
        screenshotHotkeyConflictMessage = spec.conflictWarning
        actions.setScreenshotTranslateHotkey(spec)
    }

    public func selectBackend(_ kind: BackendKind) {
        selectedBackend = kind
        connectionTest = .idle
        backendReady = false
        lastValidatedLocalBaseURL = nil
        lastValidatedLocalModels = []
        isReplacingKey = false
        keyDraft = ""
        keyOperation = .idle
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
            isReplacingKey = false
            // A validated save is enough to consider the cloud backend ready.
            if selectedBackend == .deepSeekCloud {
                backendReady = true
            }
            keyOperation = .idle
            showActionFeedback("已保存 API Key 到钥匙串")
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
            isReplacingKey = false
            backendReady = false
            keyOperation = .idle
            showActionFeedback("已删除 API Key")
        } catch {
            keyOperation = .failure(Self.describe(error))
        }
    }

    public func cancelDeleteKey() {
        isDeleteKeyConfirmationPresented = false
    }

    public func beginReplaceKey() {
        guard keyConfigured else { return }
        isReplacingKey = true
        keyDraft = ""
        keyOperation = .idle
    }

    public func cancelReplaceKey() {
        isReplacingKey = false
        keyDraft = ""
        keyOperation = .idle
    }

    // MARK: - Connection test

    public func testConnection() async {
        guard canTestConnection else { return }
        connectionTest = .testing
        do {
            let health = try await actions.testConnection()
            let supportedModels = selectedBackend == .deepSeekCloud
                ? health.availableModels.filter(AppConfiguration.isSupportedDeepSeekModel)
                : health.availableModels
            switch health.status {
            case .healthy:
                connectionTest = .healthy(health.message)
                healthMessage = health.message
                backendReady = true
                availableModels = supportedModels
                if selectedBackend == .local {
                    lastValidatedLocalBaseURL = localBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    lastValidatedLocalModels = Set(supportedModels)
                } else {
                    lastValidatedLocalBaseURL = nil
                    lastValidatedLocalModels = []
                }
                adoptCloudModelIfNeeded(from: supportedModels)
            case .modelUnavailable:
                lastValidatedLocalBaseURL = nil
                lastValidatedLocalModels = []
                if !supportedModels.isEmpty {
                    availableModels = supportedModels
                }
                // Only the fresh `/models` payload may be adopted. An empty
                // list must not reuse a stale `availableModels` to fake healthy.
                if selectedBackend == .deepSeekCloud, !supportedModels.isEmpty {
                    let picked = AppConfiguration.preferredDeepSeekModel(
                        current: deepSeekModel,
                        available: supportedModels
                    )
                    if supportedModels.contains(picked) {
                        if picked != deepSeekModel {
                            deepSeekModel = picked
                            actions.setDeepSeekModel(picked)
                        }
                        connectionTest = .healthy("DeepSeek 后端已就绪")
                        healthMessage = "DeepSeek 后端已就绪"
                        backendReady = true
                        break
                    }
                }
                let message = health.status.uiSafeFailureMessage
                connectionTest = .failed(message)
                healthMessage = message
                backendReady = false
            case .unavailable, .invalidCredentials, .invalidConfiguration:
                lastValidatedLocalBaseURL = nil
                lastValidatedLocalModels = []
                // Only `.healthy` (and an adoptable cloud model list) counts
                // as success; failure statuses show fixed UI-safe Chinese
                // text, never the raw backend message.
                let message = health.status.uiSafeFailureMessage
                connectionTest = .failed(message)
                healthMessage = message
                backendReady = false
                if !supportedModels.isEmpty {
                    availableModels = supportedModels
                }
            }
        } catch {
            lastValidatedLocalBaseURL = nil
            lastValidatedLocalModels = []
            let message = Self.describe(error)
            connectionTest = .failed(message)
            healthMessage = message
            backendReady = false
        }
    }

    // MARK: - Local backend

    public func commitLocalConfiguration() {
        let trimmedURL = localBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else { return }
        let modelMatchesValidated = selectedBackend == .local
            && backendReady
            && trimmedURL == lastValidatedLocalBaseURL
            && !localModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && lastValidatedLocalModels.contains(localModel)
        if modelMatchesValidated {
            showActionFeedback("已切换本地模型")
        } else {
            backendReady = false
            lastValidatedLocalBaseURL = nil
            lastValidatedLocalModels = []
            showActionFeedback("已更新本地配置，请测试连接")
        }
        actions.setLocalConfiguration(baseURL: trimmedURL, model: localModel)
    }

    public func commitDeepSeekModel() {
        let trimmed = AppConfiguration.resolvedDeepSeekModel(deepSeekModel)
        guard !trimmed.isEmpty else { return }
        deepSeekModel = trimmed
        actions.setDeepSeekModel(trimmed)
    }

    private func adoptCloudModelIfNeeded(from models: [String]) {
        guard selectedBackend == .deepSeekCloud, !models.isEmpty else { return }
        let supported = models.filter(AppConfiguration.isSupportedDeepSeekModel)
        let picked = AppConfiguration.preferredDeepSeekModel(current: deepSeekModel, available: supported)
        if picked != deepSeekModel {
            deepSeekModel = picked
            actions.setDeepSeekModel(picked)
        }
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
            showActionFeedback("已清除本地翻译缓存")
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

    public func showActionFeedback(_ message: String, duration: Duration = .seconds(2)) {
        actionFeedbackGeneration &+= 1
        let generation = actionFeedbackGeneration
        actionFeedbackTask?.cancel()
        actionFeedbackMessage = message
        actionFeedbackTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: duration)
            } catch {
                return
            }
            guard let self, !Task.isCancelled, self.actionFeedbackGeneration == generation else { return }
            self.actionFeedbackMessage = nil
        }
    }

    // MARK: - Error description

    /// Only explicitly UI-safe errors render their own text; everything else
    /// collapses to a fixed generic message so no internal detail leaks.
    private static func describe(_ error: Error) -> String {
        if let safe = error as? UISafeError {
            return safe.uiSafeDescription
        }
        if let credential = error as? CredentialStoreError {
            switch credential {
            case .invalidValue:
                return "API Key 格式无效"
            case .keychainFailure:
                return "无法访问系统钥匙串，请检查钥匙串权限后重试。"
            }
        }
        return UIFeedback.genericErrorMessage
    }
}
