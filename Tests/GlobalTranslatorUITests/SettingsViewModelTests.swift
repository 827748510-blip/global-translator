import Foundation
import Testing
@testable import GlobalTranslatorUI
import GlobalTranslatorCore
import GlobalTranslatorCapture

@MainActor
private final class SpyActions: SettingsActions {
    struct StubError: Error, Equatable, LocalizedError, UISafeError {
        let message: String
        var errorDescription: String? { message }
        var uiSafeDescription: String { message }
    }

    var automaticValues: [Bool] = []
    var selectionTranslateValues: [Bool] = []
    var videoTranslateValues: [Bool] = []
    var promptOptimizeModes: [PromptOptimizeMode] = []
    var autoCopyScreenshotValues: [Bool] = []
    var saveScreenshotImageValues: [Bool] = []
    var copyScreenshotImageValues: [Bool] = []
    var chooseScreenshotSaveDirectoryCount = 0
    var screenshotHotkeys: [KeyboardShortcutSpec] = []
    var beginHotkeyRecordingCount = 0
    var cancelHotkeyRecordingCount = 0
    var selectedBackends: [BackendKind] = []
    var savedKeyDrafts: [String] = []
    var deleteKeyCallCount = 0
    var visionValues: [Bool] = []
    var localConfigurations: [(baseURL: String, model: String)] = []
    var deepSeekModels: [String] = []
    var testConnectionCallCount = 0
    var permissionRequests: [PermissionKind] = []
    var openedSystemSettings: [PermissionKind] = []
    var addExclusionCallCount = 0
    var removedExclusions: [String] = []
    var clearCacheCallCount = 0
    var openLogsCallCount = 0
    var openDeepSeekStatsCallCount = 0
    var quitCallCount = 0

    var saveKeyError: Error?
    var deleteKeyError: Error?
    var testConnectionError: Error?
    var clearCacheError: Error?
    var health = BackendHealth(status: .healthy, message: "连接正常", availableModels: ["deepseek-flash"])

    func setAutomaticTranslation(_ enabled: Bool) {
        automaticValues.append(enabled)
    }

    func setSelectionTranslate(_ enabled: Bool) {
        selectionTranslateValues.append(enabled)
    }

    func setVideoTranslate(_ enabled: Bool) {
        videoTranslateValues.append(enabled)
    }

    func setPromptOptimizeMode(_ mode: PromptOptimizeMode) {
        promptOptimizeModes.append(mode)
    }

    func setAutoCopyScreenshotTranslation(_ enabled: Bool) {
        autoCopyScreenshotValues.append(enabled)
    }

    func setSaveScreenshotImage(_ enabled: Bool) {
        saveScreenshotImageValues.append(enabled)
    }

    func setCopyScreenshotImage(_ enabled: Bool) {
        copyScreenshotImageValues.append(enabled)
    }

    func chooseScreenshotSaveDirectory() {
        chooseScreenshotSaveDirectoryCount += 1
    }

    func setScreenshotTranslateHotkey(_ spec: KeyboardShortcutSpec) {
        screenshotHotkeys.append(spec)
    }

    func beginScreenshotHotkeyRecording() {
        beginHotkeyRecordingCount += 1
    }

    func cancelScreenshotHotkeyRecording() {
        cancelHotkeyRecordingCount += 1
    }

    func selectBackend(_ kind: BackendKind) {
        selectedBackends.append(kind)
    }

    func saveAPIKey(_ draft: String) async throws {
        if let saveKeyError { throw saveKeyError }
        savedKeyDrafts.append(draft)
    }

    func deleteAPIKey() async throws {
        if let deleteKeyError { throw deleteKeyError }
        deleteKeyCallCount += 1
    }

    func testConnection() async throws -> BackendHealth {
        if let testConnectionError { throw testConnectionError }
        testConnectionCallCount += 1
        return health
    }

    func setVisionFallback(_ enabled: Bool) {
        visionValues.append(enabled)
    }

    func setLocalConfiguration(baseURL: String, model: String) {
        localConfigurations.append((baseURL, model))
    }

    func setDeepSeekModel(_ model: String) {
        deepSeekModels.append(model)
    }

    func requestPermission(_ kind: PermissionKind) {
        permissionRequests.append(kind)
    }
    var permissionRefreshCount = 0
    func refreshPermissions() { permissionRefreshCount += 1 }

    func openSystemSettings(_ kind: PermissionKind) {
        openedSystemSettings.append(kind)
    }

    var chooseApplicationsCallCount = 0
    func chooseTranslatedApplications() { chooseApplicationsCallCount += 1 }

    func addCurrentAppTranslation() {
        addExclusionCallCount += 1
    }

    func removeTranslationApplication(bundleIdentifier: String) {
        removedExclusions.append(bundleIdentifier)
    }

    func clearCache() async throws {
        if let clearCacheError { throw clearCacheError }
        clearCacheCallCount += 1
    }

    func openLogs() {
        openLogsCallCount += 1
    }

    func openDeepSeekStats() {
        openDeepSeekStatsCallCount += 1
    }

    func quit() {
        quitCallCount += 1
    }
}

@MainActor
struct SettingsViewModelTests {
    private func makeViewModel(
        keyConfigured: Bool = false,
        backend: BackendKind = .deepSeekCloud
    ) -> (SettingsViewModel, SpyActions) {
        let actions = SpyActions()
        let viewModel = SettingsViewModel(actions: actions)
        viewModel.keyConfigured = keyConfigured
        viewModel.selectedBackend = backend
        return (viewModel, actions)
    }

    @Test
    func keyDraftStartsEmptyAndIsNeverPrefilledFromStoredKey() {
        let (viewModel, _) = makeViewModel(keyConfigured: true)
        #expect(viewModel.keyDraft == "")
        #expect(viewModel.keyConfigured)
        // Reloading configuration state must not rehydrate the draft.
        viewModel.keyConfigured = true
        #expect(viewModel.keyDraft == "")
    }

    @Test
    func saveKeyForwardsTrimmedDraftAndClearsDraftOnSuccess() async {
        let (viewModel, actions) = makeViewModel()
        viewModel.keyDraft = "  sk-test-secret  "
        #expect(viewModel.canSaveKey)
        await viewModel.saveKey()
        #expect(actions.savedKeyDrafts == ["sk-test-secret"])
        #expect(viewModel.keyDraft == "")
        #expect(viewModel.keyConfigured)
        #expect(viewModel.keyOperation == .idle)
    }

    @Test
    func saveKeyFailureKeepsDraftAndSurfacesError() async {
        let (viewModel, actions) = makeViewModel()
        viewModel.keyDraft = "sk-bad"
        actions.saveKeyError = SpyActions.StubError(message: "存储失败")
        await viewModel.saveKey()
        #expect(actions.savedKeyDrafts.isEmpty)
        #expect(viewModel.keyDraft == "sk-bad")
        #expect(!viewModel.keyConfigured)
        #expect(viewModel.keyOperation == .failure("存储失败"))
    }

    @Test
    func saveKeyIsDisabledForEmptyOrWhitespaceDraftAndWhileInProgress() {
        let (viewModel, _) = makeViewModel()
        viewModel.keyDraft = ""
        #expect(!viewModel.canSaveKey)
        viewModel.keyDraft = "   "
        #expect(!viewModel.canSaveKey)
        viewModel.keyDraft = "sk-live"
        viewModel.keyOperation = .inProgress
        #expect(!viewModel.canSaveKey)
    }

    @Test
    func deleteKeyRequiresConfirmationAndForwardsOnlyAfterConfirm() async {
        let (viewModel, actions) = makeViewModel(keyConfigured: true)
        viewModel.requestDeleteKey()
        #expect(viewModel.isDeleteKeyConfirmationPresented)
        #expect(actions.deleteKeyCallCount == 0)
        await viewModel.confirmDeleteKey()
        #expect(actions.deleteKeyCallCount == 1)
        #expect(!viewModel.isDeleteKeyConfirmationPresented)
        #expect(!viewModel.keyConfigured)
        #expect(viewModel.keyDraft == "")
    }

    @Test
    func cancelDeleteKeyKeepsConfiguration() async {
        let (viewModel, actions) = makeViewModel(keyConfigured: true)
        viewModel.requestDeleteKey()
        viewModel.cancelDeleteKey()
        #expect(!viewModel.isDeleteKeyConfirmationPresented)
        #expect(actions.deleteKeyCallCount == 0)
        #expect(viewModel.keyConfigured)
    }

    @Test
    func enablingVisionFallbackRequiresConsentDescribingUpload() async {
        let (viewModel, actions) = makeViewModel()
        viewModel.setVisionFallbackEnabled(true)
        #expect(viewModel.isVisionConsentPresented)
        #expect(!viewModel.visionFallbackEnabled)
        #expect(actions.visionValues.isEmpty)
        viewModel.confirmVisionConsent()
        #expect(viewModel.visionFallbackEnabled)
        #expect(!viewModel.isVisionConsentPresented)
        #expect(actions.visionValues == [true])
    }

    @Test
    func decliningVisionConsentLeavesFallbackDisabled() {
        let (viewModel, actions) = makeViewModel()
        viewModel.setVisionFallbackEnabled(true)
        viewModel.cancelVisionConsent()
        #expect(!viewModel.visionFallbackEnabled)
        #expect(!viewModel.isVisionConsentPresented)
        #expect(actions.visionValues.isEmpty)
    }

    @Test
    func disablingVisionFallbackAppliesImmediatelyWithoutConsent() {
        let (viewModel, actions) = makeViewModel()
        viewModel.visionFallbackEnabled = true
        viewModel.setVisionFallbackEnabled(false)
        #expect(!viewModel.visionFallbackEnabled)
        #expect(!viewModel.isVisionConsentPresented)
        #expect(actions.visionValues == [false])
    }

    @Test
    func visionConsentTextMentionsLocalCroppedScreenshotUploadToDeepSeek() {
        let viewModel = SettingsViewModel(actions: SpyActions())
        let text = viewModel.visionConsentText
        #expect(text.contains("截图"))
        #expect(text.contains("DeepSeek"))
    }

    @Test
    func automaticToggleForwardsWhenGatePassesAndOffAlwaysWorks() {
        let (viewModel, actions) = makeViewModel(keyConfigured: true)
        viewModel.permissionSnapshot = PermissionSnapshot(
            accessibilityTrusted: false,
            screenCaptureAuthorized: true,
            secureInputEnabled: false,
            sessionLocked: false
        )
        viewModel.backendReady = true
        #expect(viewModel.canEnableAutomaticTranslation)
        viewModel.setAutomaticTranslation(true)
        #expect(viewModel.isAutomaticTranslationEnabled)
        // OFF must remain possible even when the gate no longer passes.
        viewModel.backendReady = false
        viewModel.permissionSnapshot = PermissionSnapshot(
            accessibilityTrusted: false,
            screenCaptureAuthorized: false,
            secureInputEnabled: false,
            sessionLocked: false
        )
        #expect(!viewModel.canEnableAutomaticTranslation)
        viewModel.setAutomaticTranslation(false)
        #expect(!viewModel.isAutomaticTranslationEnabled)
        #expect(actions.automaticValues == [true, false])
    }

    @Test
    func selectionTranslateToggleForwardsAndDefaultsOn() {
        let (viewModel, actions) = makeViewModel()
        #expect(viewModel.isSelectionTranslateEnabled)
        viewModel.setSelectionTranslate(false)
        #expect(!viewModel.isSelectionTranslateEnabled)
        #expect(actions.selectionTranslateValues == [false])
        viewModel.setSelectionTranslate(true)
        #expect(viewModel.isSelectionTranslateEnabled)
        #expect(actions.selectionTranslateValues == [false, true])
        viewModel.setSelectionTranslate(true)
        #expect(actions.selectionTranslateValues == [false, true])
    }

    @Test
    func videoTranslateToggleDefaultsOffAndForwards() {
        let (viewModel, actions) = makeViewModel()
        #expect(!viewModel.isVideoTranslateEnabled)
        viewModel.setVideoTranslate(true)
        #expect(viewModel.isVideoTranslateEnabled)
        #expect(actions.videoTranslateValues == [true])
        viewModel.setVideoTranslate(false)
        #expect(!viewModel.isVideoTranslateEnabled)
        #expect(actions.videoTranslateValues == [true, false])
        viewModel.setVideoTranslate(false)
        #expect(actions.videoTranslateValues == [true, false])
    }

    @Test
    func screenshotAutoCopyDefaultsOffAndForwards() {
        let (viewModel, actions) = makeViewModel()
        #expect(!viewModel.autoCopyScreenshotTranslation)
        #expect(viewModel.screenshotTranslateHotkey == .screenshotTranslateDefault)
        viewModel.setAutoCopyScreenshotTranslation(true)
        #expect(viewModel.autoCopyScreenshotTranslation)
        #expect(actions.autoCopyScreenshotValues == [true])
        viewModel.setAutoCopyScreenshotTranslation(true)
        #expect(actions.autoCopyScreenshotValues == [true])
        viewModel.setAutoCopyScreenshotTranslation(false)
        #expect(!viewModel.autoCopyScreenshotTranslation)
        #expect(actions.autoCopyScreenshotValues == [true, false])
    }

    @Test
    func screenshotSaveAndCopyTogglesForwardAndDefaultDirectory() {
        let (viewModel, actions) = makeViewModel()
        #expect(!viewModel.saveScreenshotImage)
        #expect(!viewModel.copyScreenshotImage)
        #expect(!viewModel.screenshotSaveDirectory.isEmpty)
        viewModel.setSaveScreenshotImage(true)
        #expect(viewModel.saveScreenshotImage)
        #expect(actions.saveScreenshotImageValues == [true])
        viewModel.setCopyScreenshotImage(true)
        #expect(viewModel.copyScreenshotImage)
        #expect(actions.copyScreenshotImageValues == [true])
        viewModel.chooseScreenshotSaveDirectory()
        #expect(actions.chooseScreenshotSaveDirectoryCount == 1)
    }

    @Test
    func screenshotHotkeyRecordingAndConflictSurface() {
        let (viewModel, actions) = makeViewModel()
        viewModel.beginRecordingScreenshotHotkey()
        #expect(viewModel.isRecordingScreenshotHotkey)
        #expect(actions.beginHotkeyRecordingCount == 1)
        viewModel.cancelRecordingScreenshotHotkey()
        #expect(!viewModel.isRecordingScreenshotHotkey)
        #expect(actions.cancelHotkeyRecordingCount == 1)
        let conflicting = KeyboardShortcutSpec(
            keyCode: KeyboardShortcutSpec.KeyCode.four,
            shift: true,
            command: true
        )
        viewModel.setScreenshotTranslateHotkey(conflicting)
        #expect(viewModel.screenshotTranslateHotkey == conflicting)
        #expect(viewModel.screenshotHotkeyConflictMessage == KeyboardShortcutSupport.systemScreenshotConflictCopy)
        #expect(actions.screenshotHotkeys == [conflicting])
        #expect(!viewModel.isRecordingScreenshotHotkey)
    }

    @Test
    func promptOptimizeModeDefaultsToCommunicationPolishAndForwards() {
        let (viewModel, actions) = makeViewModel()
        #expect(viewModel.promptOptimizeMode == .communicationPolish)
        viewModel.setPromptOptimizeMode(.taskInstruction)
        #expect(viewModel.promptOptimizeMode == .taskInstruction)
        #expect(actions.promptOptimizeModes == [.taskInstruction])
        viewModel.setPromptOptimizeMode(.taskInstruction)
        #expect(actions.promptOptimizeModes == [.taskInstruction])
        viewModel.setPromptOptimizeMode(.wordingFix)
        #expect(viewModel.promptOptimizeMode == .wordingFix)
        #expect(actions.promptOptimizeModes == [.taskInstruction, .wordingFix])
    }

    @Test
    func invalidEnableAttemptDoesNotFlipStateOrCallActions() {
        let (viewModel, actions) = makeViewModel(keyConfigured: true)
        viewModel.backendReady = true
        // Missing capture permission must not block the master switch:
        // the extension bridge does not need AX or Screen Recording.
        #expect(viewModel.canEnableAutomaticTranslation)
        viewModel.setAutomaticTranslation(true)
        #expect(viewModel.isAutomaticTranslationEnabled)
        #expect(actions.automaticValues == [true])
        viewModel.setAutomaticTranslation(false)
        #expect(!viewModel.isAutomaticTranslationEnabled)
        // Backend not ready: still refused, even with capture permission.
        viewModel.permissionSnapshot = PermissionSnapshot(
            accessibilityTrusted: true,
            screenCaptureAuthorized: false,
            secureInputEnabled: false,
            sessionLocked: false
        )
        viewModel.backendReady = false
        #expect(!viewModel.canEnableAutomaticTranslation)
        viewModel.setAutomaticTranslation(true)
        #expect(!viewModel.isAutomaticTranslationEnabled)
        #expect(actions.automaticValues == [true, false])
        #expect(viewModel.healthMessage == "云端后端未就绪，请保存密钥或测试连接")
    }

    @Test
    func disabledAutomaticTranslationExposesVisibleBlockingReason() {
        let (viewModel, _) = makeViewModel()
        viewModel.permissionSnapshot = .allGranted
        viewModel.keyConfigured = false

        #expect(viewModel.visibleAutomaticEnableBlockedReason == "请先配置 API Key")

        viewModel.isAutomaticTranslationEnabled = true
        #expect(viewModel.visibleAutomaticEnableBlockedReason == nil)
    }

    @Test
    func cloudGateRequiresConfiguredKey() {
        let (viewModel, _) = makeViewModel(keyConfigured: false)
        viewModel.permissionSnapshot = PermissionSnapshot(
            accessibilityTrusted: true,
            screenCaptureAuthorized: false,
            secureInputEnabled: false,
            sessionLocked: false
        )
        viewModel.backendReady = true
        #expect(!viewModel.canEnableAutomaticTranslation)
        viewModel.setAutomaticTranslation(true)
        #expect(viewModel.healthMessage == "请先配置 API Key")
    }

    @Test
    func localGateRequiresLoopbackURLModelAndReadiness() {
        let (viewModel, _) = makeViewModel(backend: .local)
        viewModel.permissionSnapshot = PermissionSnapshot(
            accessibilityTrusted: true,
            screenCaptureAuthorized: false,
            secureInputEnabled: false,
            sessionLocked: false
        )
        viewModel.backendReady = true
        viewModel.localBaseURL = "http://127.0.0.1:11434/v1"
        viewModel.localModel = "qwen3:8b"
        #expect(viewModel.canEnableAutomaticTranslation)
        // Non-loopback hosts are rejected even though they are valid URLs.
        viewModel.localBaseURL = "https://example.com/v1"
        #expect(!viewModel.canEnableAutomaticTranslation)
        viewModel.localBaseURL = "http://localhost:11434/v1"
        #expect(viewModel.canEnableAutomaticTranslation)
        viewModel.localModel = "  "
        #expect(!viewModel.canEnableAutomaticTranslation)
        viewModel.localModel = "qwen3:8b"
        viewModel.backendReady = false
        #expect(!viewModel.canEnableAutomaticTranslation)
    }

    @Test
    func backendSelectionForwardsAndResetsReadinessAndConnectionState() {
        let (viewModel, actions) = makeViewModel(keyConfigured: true)
        viewModel.backendReady = true
        viewModel.connectionTest = .healthy("连接正常")
        viewModel.selectBackend(.local)
        #expect(actions.selectedBackends == [.local])
        #expect(viewModel.selectedBackend == .local)
        #expect(!viewModel.backendReady)
        #expect(viewModel.connectionTest == .idle)
        #expect(viewModel.keyConfigured)
        #expect(!viewModel.showsKeyEntry)
    }

    @Test
    func committingLocalConfigurationResetsReadiness() {
        let (viewModel, actions) = makeViewModel(backend: .local)
        viewModel.backendReady = true
        viewModel.localBaseURL = "http://127.0.0.1:11434/v1"
        viewModel.localModel = "qwen3:8b"
        viewModel.commitLocalConfiguration()
        #expect(actions.localConfigurations.count == 1)
        #expect(!viewModel.backendReady)
    }

    @Test
    func successfulKeySaveMarksCloudBackendReady() async {
        let (viewModel, _) = makeViewModel()
        viewModel.keyDraft = "sk-live"
        await viewModel.saveKey()
        #expect(viewModel.backendReady)
    }

    @Test
    func deleteKeyClearsReadiness() async {
        let (viewModel, _) = makeViewModel(keyConfigured: true)
        viewModel.backendReady = true
        viewModel.requestDeleteKey()
        await viewModel.confirmDeleteKey()
        #expect(!viewModel.backendReady)
    }

    @Test
    func overlayAndBridgeTargetLanguageStaysSimplifiedChinese() {
        let viewModel = SettingsViewModel(actions: SpyActions())
        #expect(viewModel.targetLanguageDisplayName == "简体中文")
    }

    @Test
    func testConnectionAllowsDeepSeekWithoutConfiguredFlagAndRequiresURLForLocal() {
        let (cloudWithoutKey, _) = makeViewModel(keyConfigured: false, backend: .deepSeekCloud)
        #expect(cloudWithoutKey.canTestConnection)
        let (cloudWithKey, _) = makeViewModel(keyConfigured: true, backend: .deepSeekCloud)
        #expect(cloudWithKey.canTestConnection)
        let (localEmpty, _) = makeViewModel(backend: .local)
        localEmpty.localBaseURL = ""
        #expect(!localEmpty.canTestConnection)
        localEmpty.localBaseURL = "http://127.0.0.1:11434/v1"
        #expect(localEmpty.canTestConnection)
    }

    @Test
    func testConnectionWithoutConfiguredFlagStillRunsHealthCheck() async {
        let (viewModel, actions) = makeViewModel(keyConfigured: false, backend: .deepSeekCloud)
        actions.health = BackendHealth(
            status: .healthy,
            message: "连接正常",
            availableModels: ["deepseek-flash"]
        )
        await viewModel.testConnection()
        #expect(actions.testConnectionCallCount == 1)
        #expect(viewModel.connectionTest == .healthy("连接正常"))
        #expect(viewModel.backendReady)
        #expect(viewModel.availableModels == ["deepseek-flash"])
    }

    @Test
    func successfulConnectionTestUpdatesModelsAndHealth() async {
        let (viewModel, actions) = makeViewModel(keyConfigured: true)
        actions.health = BackendHealth(status: .healthy, message: "连接正常", availableModels: ["deepseek-flash"])
        await viewModel.testConnection()
        #expect(actions.testConnectionCallCount == 1)
        #expect(viewModel.connectionTest == .healthy("连接正常"))
        #expect(viewModel.availableModels == ["deepseek-flash"])
        #expect(viewModel.healthMessage == "连接正常")
        #expect(viewModel.backendReady)
    }

    @Test
    func failedConnectionTestSurfacesErrorState() async {
        let (viewModel, actions) = makeViewModel(keyConfigured: true)
        actions.testConnectionError = SpyActions.StubError(message: "无法连接")
        await viewModel.testConnection()
        #expect(viewModel.connectionTest == .failed("无法连接"))
        #expect(viewModel.healthMessage == "无法连接")
        #expect(!viewModel.backendReady)
    }

    @Test
    func nonHealthyConnectionStatusesBecomeFailedWithSafeChineseText() async {
        let cases: [(BackendHealthStatus, String)] = [
            (.invalidCredentials, "凭证无效，请检查 API Key 后重试"),
            (.invalidConfiguration, "配置无效，请检查后端设置"),
            (.unavailable, "服务暂不可用，请稍后重试"),
        ]
        for (status, expected) in cases {
            let (viewModel, actions) = makeViewModel(keyConfigured: true)
            viewModel.backendReady = true
            viewModel.availableModels = ["previous"]
            // Raw backend messages may contain internal detail; they must
            // never be shown for failure statuses.
            actions.health = BackendHealth(
                status: status,
                message: "upstream 401 Authorization: sk-secret-detail",
                availableModels: ["deepseek-flash"]
            )
            await viewModel.testConnection()
            #expect(viewModel.connectionTest == .failed(expected))
            #expect(viewModel.healthMessage == expected)
            #expect(!viewModel.backendReady)
            // Failure responses still refresh the supported model list.
            #expect(viewModel.availableModels == ["deepseek-flash"])
        }
    }

    @Test
    func modelUnavailableWithoutListStaysFailed() async {
        let (viewModel, actions) = makeViewModel(keyConfigured: true)
        viewModel.availableModels = ["kept"]
        actions.health = BackendHealth(
            status: .modelUnavailable,
            message: "Required DeepSeek model is unavailable",
            availableModels: []
        )
        await viewModel.testConnection()
        #expect(viewModel.connectionTest == .failed("所需模型不可用，请更换模型或检查服务"))
        #expect(!viewModel.backendReady)
        #expect(viewModel.availableModels == ["kept"])
    }

    @Test
    func modelUnavailableWithListAdoptsPreferredDeepSeekModel() async {
        let (viewModel, actions) = makeViewModel(keyConfigured: true)
        viewModel.deepSeekModel = "missing-model"
        actions.health = BackendHealth(
            status: .modelUnavailable,
            message: "Selected DeepSeek model is unavailable",
            availableModels: ["deepseek-flash", "deepseek-v4-pro"]
        )
        await viewModel.testConnection()
        #expect(viewModel.connectionTest == .healthy("DeepSeek backend is ready"))
        #expect(viewModel.backendReady)
        #expect(viewModel.deepSeekModel == "deepseek-flash")
        #expect(actions.deepSeekModels == ["deepseek-flash"])
        #expect(viewModel.availableModels == ["deepseek-flash"])
    }

    @Test
    func configuredKeyHidesEntryUntilReplaceAndClearsDraftOnSwitch() {
        let (viewModel, _) = makeViewModel(keyConfigured: true)
        #expect(!viewModel.showsKeyEntry)
        #expect(!viewModel.isReplacingKey)
        viewModel.beginReplaceKey()
        #expect(viewModel.showsKeyEntry)
        #expect(viewModel.isReplacingKey)
        viewModel.keyDraft = "sk-should-not-stick"
        viewModel.cancelReplaceKey()
        #expect(!viewModel.showsKeyEntry)
        #expect(viewModel.keyDraft == "")
        viewModel.beginReplaceKey()
        viewModel.keyDraft = "sk-draft"
        viewModel.selectBackend(.local)
        #expect(!viewModel.isReplacingKey)
        #expect(viewModel.keyDraft == "")
        #expect(viewModel.keyConfigured)
    }

    @Test
    func commitDeepSeekModelForwardsSelection() {
        let (viewModel, actions) = makeViewModel(keyConfigured: true)
        viewModel.deepSeekModel = "deepseek-v4-pro"
        viewModel.commitDeepSeekModel()
        #expect(viewModel.deepSeekModel == "deepseek-flash")
        #expect(actions.deepSeekModels == ["deepseek-flash"])
    }

    @Test
    func nonHealthyStatusPreservesModelsWhenResponseHasNone() async {
        let (viewModel, actions) = makeViewModel(keyConfigured: true)
        viewModel.availableModels = ["kept"]
        actions.health = BackendHealth(status: .unavailable, message: "down", availableModels: [])
        await viewModel.testConnection()
        #expect(viewModel.availableModels == ["kept"])
        #expect(!viewModel.backendReady)
    }

    @Test
    func keychainFailureShowsAnActionableNonSecretMessage() async {
        let (viewModel, actions) = makeViewModel(keyConfigured: true)
        viewModel.keyDraft = "sk-new"
        actions.saveKeyError = CredentialStoreError.keychainFailure(status: -34018)
        await viewModel.saveKey()
        guard case .failure(let message) = viewModel.keyOperation else {
            Issue.record("expected keyOperation to be .failure")
            return
        }
        #expect(message == "无法访问系统钥匙串，请检查钥匙串权限后重试。")
        #expect(!message.contains("sk-"))

        actions.saveKeyError = CredentialStoreError.invalidValue
        await viewModel.saveKey()
        guard case .failure(let invalidMessage) = viewModel.keyOperation else {
            Issue.record("expected keyOperation to be .failure")
            return
        }
        #expect(invalidMessage == "API Key 格式无效")
    }

    @Test
    func arbitraryErrorsNeverRenderSecretLikeText() async {
        let (viewModel, actions) = makeViewModel(keyConfigured: true)
        let secretError = NSError(
            domain: "Upstream",
            code: 500,
            userInfo: [NSLocalizedDescriptionKey: "upstream 500: Authorization Bearer sk-secret-abcdef123"]
        )
        viewModel.keyDraft = "sk-new"
        actions.saveKeyError = secretError
        await viewModel.saveKey()
        guard case .failure(let keyMessage) = viewModel.keyOperation else {
            Issue.record("expected keyOperation to be .failure")
            return
        }
        #expect(keyMessage == UIFeedback.genericErrorMessage)
        #expect(!keyMessage.contains("sk-secret"))

        actions.testConnectionError = secretError
        await viewModel.testConnection()
        guard case .failed(let testMessage) = viewModel.connectionTest else {
            Issue.record("expected connectionTest to be .failed")
            return
        }
        #expect(testMessage == UIFeedback.genericErrorMessage)
        #expect(!testMessage.contains("sk-secret"))
    }

    @Test
    func localConfigurationCommitForwardsLoopbackURLAndModel() {
        let (viewModel, actions) = makeViewModel(backend: .local)
        viewModel.localBaseURL = "http://127.0.0.1:11434/v1"
        viewModel.availableModels = ["qwen3:8b"]
        viewModel.localModel = "qwen3:8b"
        viewModel.commitLocalConfiguration()
        #expect(actions.localConfigurations.count == 1)
        #expect(actions.localConfigurations.first?.baseURL == "http://127.0.0.1:11434/v1")
        #expect(actions.localConfigurations.first?.model == "qwen3:8b")
    }

    @Test
    func permissionAndSystemSettingsActionsForwardKind() {
        let (viewModel, actions) = makeViewModel()
        viewModel.requestPermission(.accessibility)
        viewModel.requestPermission(.screenCapture)
        viewModel.openSystemSettings(.screenCapture)
        viewModel.refreshPermissions()
        #expect(actions.permissionRequests == [.accessibility, .screenCapture])
        #expect(actions.openedSystemSettings == [.screenCapture])
        #expect(actions.permissionRefreshCount == 1)
    }

    @Test
    func exclusionActionsForward() {
        let (viewModel, actions) = makeViewModel()
        viewModel.addCurrentAppTranslation()
        viewModel.chooseTranslatedApplications()
        viewModel.removeTranslationApplication(bundleIdentifier: "com.example.app")
        #expect(actions.addExclusionCallCount == 1)
        #expect(actions.chooseApplicationsCallCount == 1)
        #expect(actions.removedExclusions == ["com.example.app"])
    }

    @Test
    func clearCacheRequiresConfirmation() async {
        let (viewModel, actions) = makeViewModel()
        viewModel.requestClearCache()
        #expect(viewModel.isClearCacheConfirmationPresented)
        #expect(actions.clearCacheCallCount == 0)
        await viewModel.confirmClearCache()
        #expect(actions.clearCacheCallCount == 1)
        #expect(!viewModel.isClearCacheConfirmationPresented)
    }

    @Test
    func openLogsStatsAndQuitForward() {
        let (viewModel, actions) = makeViewModel()
        viewModel.openLogs()
        viewModel.openDeepSeekStats()
        viewModel.quit()
        #expect(actions.openLogsCallCount == 1)
        #expect(actions.openDeepSeekStatsCallCount == 1)
        #expect(actions.quitCallCount == 1)
    }

    @Test
    func permissionSnapshotDefaultsToNothingGranted() {
        let viewModel = SettingsViewModel(actions: SpyActions())
        #expect(viewModel.permissionSnapshot.accessibilityTrusted == false)
        #expect(viewModel.permissionSnapshot.screenCaptureAuthorized == false)
    }
}
