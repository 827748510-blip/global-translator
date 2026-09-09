import AppKit
import Foundation
import UniformTypeIdentifiers
import GlobalTranslatorCapture
import GlobalTranslatorCore
import GlobalTranslatorUI

public enum ApplicationActionError: Error, Equatable, Sendable, UISafeError {
    case invalidAPIKey
    case backendUnhealthy(BackendHealthStatus)
    case localEndpointInvalid
    case backendNotSelected

    public var uiSafeDescription: String {
        switch self {
        case .invalidAPIKey:
            return "API Key 无效，请检查后重试"
        case .backendUnhealthy(let status):
            return status == .healthy ? "操作失败，请稍后重试。" : status.uiSafeFailureMessage
        case .localEndpointInvalid:
            return "请使用本机回环服务地址"
        case .backendNotSelected:
            return "后端配置无效，请重新选择"
        }
    }
}

extension ApplicationController {
    public func setAutomaticTranslation(_ enabled: Bool) {
        if !enabled {
            disableAutomaticTranslation()
            return
        }
        automaticRequestToken &+= 1
        automaticEnableTask?.cancel()
        automaticEnableTask = nil
        automaticEnablePending = true
        let requestToken = automaticRequestToken
        viewModel.permissionSnapshot = components.permissionController.snapshot
        guard viewModel.canEnableAutomaticTranslation else {
            automaticEnablePending = false
            viewModel.isAutomaticTranslationEnabled = false
            session?.setBridgeActive(false)
            viewModel.healthMessage = viewModel.automaticEnableBlockedReason
            applyStatus(.off)
            return
        }
        viewModel.isAutomaticTranslationEnabled = false
        configuration.autoTranslateEnabled = false
        let expectedBackend = configuration.backend
        automaticEnableTask = Task { @MainActor [weak self] in
            guard let self,
                  self.started,
                  self.configuration.backend == expectedBackend,
                  self.automaticEnablePending,
                  self.automaticRequestToken == requestToken,
                  !Task.isCancelled else { return }
            let health = await self.components.backendFactory.healthCheck(
                kind: expectedBackend,
                configuration: self.configuration,
                credentials: self.components.credentialStore
            )
            guard self.started,
                  self.configuration.backend == expectedBackend,
                  self.automaticEnablePending,
                  self.automaticRequestToken == requestToken,
                  !Task.isCancelled else { return }
            guard health.status == .healthy else {
                self.automaticEnablePending = false
                self.automaticEnableTask = nil
                self.viewModel.isAutomaticTranslationEnabled = false
                if health.status == .unavailable {
                    // Transient failure (cold local model, sleeping backend):
                    // keep the user's saved intent and let the retry loop
                    // flip the switch on once the backend recovers — a cold
                    // start must not silently erase the preference.
                    self.configuration.autoTranslateEnabled = true
                    self.scheduleBackendRetry(healthToken: self.backendHealthToken)
                } else {
                    self.configuration.autoTranslateEnabled = false
                }
                self.session?.setBridgeActive(false)
                self.session?.stop()
                self.viewModel.healthMessage = health.status.uiSafeFailureMessage
                self.applyStatus(.error)
                self.queueSave()
                return
            }
            self.applyHealth(health)
            guard self.viewModel.canEnableAutomaticTranslation else {
                self.automaticEnablePending = false
                self.automaticEnableTask = nil
                self.viewModel.isAutomaticTranslationEnabled = false
                self.configuration.autoTranslateEnabled = false
                self.session?.setBridgeActive(false)
                self.session?.stop()
                self.applyStatus(.off)
                return
            }
            self.viewModel.isAutomaticTranslationEnabled = true
            self.automaticEnablePending = false
            self.automaticEnableTask = nil
            self.configuration.autoTranslateEnabled = true
            self.session?.setBridgeActive(true)
            self.startWindowSessionIfPermitted()
            self.queueSave()
        }
    }

    public func setSelectionTranslate(_ enabled: Bool) {
        configuration.selectionTranslateEnabled = enabled
        viewModel.isSelectionTranslateEnabled = enabled
        selectionTranslate?.setEnabled(enabled)
        queueSave()
    }

    public func setPromptOptimizeMode(_ mode: PromptOptimizeMode) {
        viewModel.promptOptimizeMode = mode
        guard configuration.promptOptimizeMode != mode else {
            selectionTranslate?.setOptimizeMode(mode)
            return
        }
        configuration.promptOptimizeMode = mode
        selectionTranslate?.setOptimizeMode(mode)
        queueSave()
    }

    public func selectBackend(_ kind: BackendKind) {
        guard configuration.backend != kind else { return }
        backendHealthToken &+= 1
        let previousSession = session
        disableAutomaticTranslation()
        configuration.backend = kind
        viewModel.selectedBackend = kind
        viewModel.isReplacingKey = false
        viewModel.keyDraft = ""
        viewModel.backendReady = false
        viewModel.connectionTest = .idle
        viewModel.availableModels = []
        viewModel.keyConfigured = configuration.deepSeekAPIKeyConfigured
        selectionTranslate?.setBackend(kind)
        Task { await previousSession?.clearCache() }
        rebuildSession()
        queueSave()
        // Wire overlay / bridge / 滑词 immediately so translate can run
        // without waiting on a health check. DeepSeek must not `read()`
        // Keychain here; `makeBackend` only holds the store.
        if let backend = try? components.backendFactory.makeBackend(
            kind: kind,
            configuration: configuration,
            credentials: components.credentialStore
        ) {
            applySessionBackends(overlay: backend, configuration: configuration)
        }
        if kind != .deepSeekCloud {
            scheduleBackendRefresh()
        }
    }

    public func saveAPIKey(_ draft: String) async throws {
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 4_096 else {
            throw ApplicationActionError.invalidAPIKey
        }
        guard configuration.backend == .deepSeekCloud else {
            throw ApplicationActionError.backendNotSelected
        }
        let validator = InMemoryCredentialStore(value: value)
        let health = await components.backendFactory.healthCheck(
            kind: .deepSeekCloud,
            configuration: configuration,
            credentials: validator
        )
        guard health.status == .healthy
            || (health.status == .modelUnavailable && !health.availableModels.isEmpty) else {
            throw ApplicationActionError.backendUnhealthy(health.status)
        }
        try components.credentialStore.save(apiKey: value)
        persistDeepSeekAPIKeyConfigured(true)
        viewModel.isReplacingKey = false
        viewModel.keyDraft = ""
        viewModel.availableModels = health.availableModels
        if !health.availableModels.isEmpty {
            let picked = AppConfiguration.preferredDeepSeekModel(
                current: configuration.deepSeekModel,
                available: health.availableModels
            )
            configuration.deepSeekModel = picked
            viewModel.deepSeekModel = picked
        }
        viewModel.backendReady = health.status == .healthy
            || viewModel.availableModels.contains(
                AppConfiguration.resolvedDeepSeekModel(configuration.deepSeekModel)
            )
        if health.status == .healthy {
            viewModel.healthMessage = health.message
        } else if viewModel.backendReady {
            viewModel.healthMessage = "DeepSeek backend is ready"
        } else {
            viewModel.healthMessage = health.status.uiSafeFailureMessage
        }
        if let backend = try? components.backendFactory.makeBackend(
            kind: configuration.backend,
            configuration: configuration,
            credentials: components.credentialStore
        ) {
            applySessionBackends(overlay: backend, configuration: configuration)
        }
        queueSave()
    }

    public func deleteAPIKey() async throws {
        try components.credentialStore.delete()
        persistDeepSeekAPIKeyConfigured(false)
        viewModel.isReplacingKey = false
        viewModel.keyDraft = ""
        viewModel.backendReady = false
        viewModel.availableModels = []
        viewModel.isAutomaticTranslationEnabled = false
        configuration.autoTranslateEnabled = false
        session?.setBridgeActive(false)
        session?.stop()
        await session?.clearCache()
        queueSave()
        applyStatus(.off)
    }

    public func testConnection() async throws -> BackendHealth {
        let health = await components.backendFactory.healthCheck(
            kind: configuration.backend,
            configuration: configuration,
            credentials: components.credentialStore
        )
        applyHealth(health)
        rewireDeepSeekSessionIfAdoptedModelDiffers(from: health)
        return health
    }

    /// After a successful DeepSeek health, `applyHealth` may adopt a different
    /// model id. Rewire backends to that id without leaving overlay stopped.
    func rewireDeepSeekSessionIfAdoptedModelDiffers(from health: BackendHealth) {
        guard configuration.backend == .deepSeekCloud else { return }
        let healthOK = health.status == .healthy
            || (health.status == .modelUnavailable && !health.availableModels.isEmpty)
        guard healthOK else { return }
        let adopted = AppConfiguration.resolvedDeepSeekModel(configuration.deepSeekModel)
        guard session?.configuredModel != adopted else { return }
        rewireDeepSeekBackendsPreservingCapture()
    }

    public func setVisionFallback(_ enabled: Bool) {
        configuration.visionFallbackEnabled = enabled
        viewModel.visionFallbackEnabled = enabled
        let previousSession = session
        disableAutomaticTranslation()
        Task { await previousSession?.clearCache() }
        rebuildSession()
        queueSave()
        if configuration.backend == .deepSeekCloud {
            applyDeepSeekSessionBackendsWithoutHealthCheck()
        } else {
            scheduleBackendRefresh()
        }
    }

    public func setLocalConfiguration(baseURL: String, model: String) {
        guard let url = URL(string: baseURL) else {
            viewModel.healthMessage = ApplicationActionError.localEndpointInvalid.uiSafeDescription
            return
        }
        do {
            configuration.localBaseURL = try EndpointValidator.validateLocalBaseURL(url)
        } catch {
            viewModel.healthMessage = ApplicationActionError.localEndpointInvalid.uiSafeDescription
            return
        }
        configuration.localModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        backendHealthToken &+= 1
        viewModel.localBaseURL = configuration.localBaseURL.absoluteString
        viewModel.localModel = configuration.localModel
        viewModel.backendReady = false
        let previousSession = session
        disableAutomaticTranslation()
        Task { await previousSession?.clearCache() }
        rebuildSession()
        queueSave()
        scheduleBackendRefresh()
    }

    public func setDeepSeekModel(_ model: String) {
        let trimmed = AppConfiguration.resolvedDeepSeekModel(model)
        guard trimmed.utf8.count <= 256 else { return }
        let modelChanged = configuration.deepSeekModel != trimmed
        configuration.deepSeekModel = trimmed
        viewModel.deepSeekModel = trimmed
        if !viewModel.availableModels.isEmpty, !viewModel.availableModels.contains(trimmed) {
            viewModel.backendReady = false
        }
        guard modelChanged else { return }
        backendHealthToken &+= 1
        let previousSession = session
        Task { await previousSession?.clearCache() }
        rebuildSession()
        queueSave()
        if configuration.backend == .deepSeekCloud {
            applyDeepSeekSessionBackendsWithoutHealthCheck()
        } else {
            scheduleBackendRefresh()
        }
    }

    public func refreshPermissions() {
        guard started else { return }
        let previous = viewModel.permissionSnapshot
        let snapshot = components.permissionController.snapshot
        viewModel.permissionSnapshot = snapshot
        let grantsChanged = previous.accessibilityTrusted != snapshot.accessibilityTrusted
            || previous.screenCaptureAuthorized != snapshot.screenCaptureAuthorized
        guard !configurationLoadFailed else { return }
        guard snapshot.hasCaptureAccess else {
            // Overlay capture cannot run. The extension bridge may keep
            // serving page text only while the master switch is on *and*
            // the backend is still ready — do not revive the switch after a
            // failed health check or while enable is in flight.
            if configuration.autoTranslateEnabled || viewModel.isAutomaticTranslationEnabled || automaticEnablePending {
                session?.stop()
            }
            if configuration.autoTranslateEnabled, viewModel.canEnableAutomaticTranslation {
                session?.setBridgeActive(true)
                viewModel.isAutomaticTranslationEnabled = true
                applyStatus(.missingPermission)
            } else if !automaticEnablePending {
                viewModel.isAutomaticTranslationEnabled = false
                session?.setBridgeActive(false)
                if !configuration.autoTranslateEnabled {
                    applyStatus(.off)
                }
            }
            return
        }
        if grantsChanged, viewModel.backendReady {
            viewModel.healthMessage = "权限状态已更新"
            if viewModel.isAutomaticTranslationEnabled {
                session?.stop()
                session?.start()
            }
        }
        if configuration.autoTranslateEnabled,
           !viewModel.isAutomaticTranslationEnabled,
           !automaticEnablePending,
           viewModel.canEnableAutomaticTranslation {
            maybeStartPersistedSession()
        }
    }

    public func requestPermission(_ kind: PermissionKind) {
        switch kind {
        case .accessibility:
            _ = components.permissionController.requestAccessibilityPermission()
        case .screenCapture:
            _ = components.permissionController.requestScreenCapturePermission()
        }
        refreshPermissions()
        schedulePermissionRefresh(kind)
    }

    private func schedulePermissionRefresh(_ kind: PermissionKind) {
        permissionRefreshToken &+= 1
        permissionRefreshTask?.cancel()
        let refreshToken = permissionRefreshToken
        permissionRefreshTask = Task { @MainActor [weak self] in
            let delays: [UInt64] = [250_000_000, 1_000_000_000, 3_000_000_000, 6_000_000_000]
            for delay in delays {
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    return
                }
                guard let self,
                      self.started,
                      self.permissionRefreshToken == refreshToken,
                      !Task.isCancelled else { return }
                self.refreshPermissions()
                let snapshot = self.viewModel.permissionSnapshot
                let granted = kind == .accessibility
                    ? snapshot.accessibilityTrusted
                    : snapshot.screenCaptureAuthorized
                if granted { break }
            }
            guard let self, self.permissionRefreshToken == refreshToken else { return }
            self.permissionRefreshTask = nil
        }
    }

    public func openSystemSettings(_ kind: PermissionKind) {
        let index: Int
        switch kind {
        case .accessibility: index = 0
        case .screenCapture: index = 1
        }
        let urls = components.permissionController.privacyURLs
        guard urls.indices.contains(index) else { return }
        NSWorkspace.shared.open(urls[index])
        schedulePermissionRefresh(kind)
    }

    public func addCurrentAppTranslation() {
        guard let application = NSWorkspace.shared.frontmostApplication,
              let bundleID = application.bundleIdentifier,
              application.processIdentifier != getpid(),
              bundleID != Bundle.main.bundleIdentifier else { return }
        addApplications([TranslatedApplication(bundleIdentifier: bundleID, displayName: application.localizedName ?? bundleID)])
    }

    public func chooseTranslatedApplications() {
        guard started, applicationPicker == nil else { return }
        let panel = NSOpenPanel()
        panel.title = "选择要翻译的应用"
        panel.message = "只有所选应用会被采集并翻译；未选择时不翻译任何应用。可按住 Command 多选。"
        panel.prompt = "翻译所选应用"
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        applicationPicker = panel
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self, panel] response in
            guard let self else { return }
            self.applicationPicker = nil
            guard self.started, response == .OK else { return }
            let applications = panel.urls.compactMap { url -> TranslatedApplication? in
                guard url.pathExtension.lowercased() == "app", let bundle = Bundle(url: url),
                      let id = bundle.bundleIdentifier else { return nil }
                return TranslatedApplication(bundleIdentifier: id,
                    displayName: FileManager.default.displayName(atPath: url.path))
            }
            self.addApplications(applications)
        }
        if let window = NSApplication.shared.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    func addApplications(_ applications: [TranslatedApplication]) {
        guard started else { return }
        var identifiers = Set(configuration.translatedBundleIDs)
        let additions = applications.filter {
            Self.isSafeBundleIdentifier($0.bundleIdentifier)
                && $0.bundleIdentifier != Bundle.main.bundleIdentifier
                && $0.bundleIdentifier != "com.maodashu.global-translator"
                && identifiers.insert($0.bundleIdentifier).inserted
        }
        guard !additions.isEmpty else { return }
        configuration.translatedBundleIDs.append(contentsOf: additions.map(\.bundleIdentifier))
        viewModel.translatedApplications.append(contentsOf: additions)
        applyTranslationApplicationChanges()
    }

    public func removeTranslationApplication(bundleIdentifier: String) {
        guard started, configuration.translatedBundleIDs.contains(bundleIdentifier) else { return }
        configuration.translatedBundleIDs.removeAll { $0 == bundleIdentifier }
        viewModel.translatedApplications.removeAll { $0.bundleIdentifier == bundleIdentifier }
        applyTranslationApplicationChanges()
    }

    private func applyTranslationApplicationChanges() {
        let shouldResume = configuration.autoTranslateEnabled || automaticEnablePending
        automaticRequestToken &+= 1
        automaticEnableTask?.cancel()
        automaticEnableTask = nil
        automaticEnablePending = false
        backendHealthToken &+= 1
        backendRefreshTask?.cancel()
        backendRefreshTask = nil
        rebuildSession()
        configuration.autoTranslateEnabled = shouldResume
        viewModel.isAutomaticTranslationEnabled = false
        if viewModel.backendReady, let backend = try? components.backendFactory.makeBackend(
            kind: configuration.backend, configuration: configuration, credentials: components.credentialStore
        ) {
            applySessionBackends(overlay: backend, configuration: configuration)
            if shouldResume { maybeStartPersistedSession() }
        } else {
            scheduleBackendRefresh(startPersistedSession: shouldResume)
        }
        queueSave()
    }

    public func clearCache() async throws {
        await session?.clearCache()
    }

    public func openLogs() {
        NSWorkspace.shared.activateFileViewerSelecting([paths.logURL])
    }

    public func quit() {
        components.logger.event("application_quit_requested", fields: [:])
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.stop()
            self.onQuit()
        }
    }

    private func disableAutomaticTranslation() {
        automaticRequestToken &+= 1
        automaticEnableTask?.cancel()
        automaticEnableTask = nil
        automaticEnablePending = false
        viewModel.isAutomaticTranslationEnabled = false
        configuration.autoTranslateEnabled = false
        session?.setBridgeActive(false)
        session?.stop()
        applyStatus(.off)
        queueSave()
    }
}

private final class InMemoryCredentialStore: CredentialStoring, @unchecked Sendable {
    private var value: String?

    init(value: String?) { self.value = value }
    func save(apiKey: String) throws { value = apiKey }
    func read() throws -> String? { value }
    func delete() throws { value = nil }
}
