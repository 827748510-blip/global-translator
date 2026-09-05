import AppKit
import Foundation
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
                self.configuration.autoTranslateEnabled = false
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
                self.session?.stop()
                self.applyStatus(.off)
                return
            }
            self.viewModel.isAutomaticTranslationEnabled = true
            self.automaticEnablePending = false
            self.automaticEnableTask = nil
            self.configuration.autoTranslateEnabled = true
            self.session?.start()
            self.queueSave()
        }
    }

    public func selectBackend(_ kind: BackendKind) {
        guard configuration.backend != kind else { return }
        backendHealthToken &+= 1
        let previousSession = session
        disableAutomaticTranslation()
        configuration.backend = kind
        viewModel.selectedBackend = kind
        viewModel.backendReady = false
        viewModel.connectionTest = .idle
        viewModel.availableModels = []
        Task { await previousSession?.clearCache() }
        rebuildSession()
        queueSave()
        scheduleBackendRefresh()
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
        guard health.status == .healthy else {
            throw ApplicationActionError.backendUnhealthy(health.status)
        }
        try components.credentialStore.save(apiKey: value)
        viewModel.keyConfigured = true
        viewModel.backendReady = true
        viewModel.availableModels = health.availableModels
        viewModel.healthMessage = health.message
        if let backend = try? components.backendFactory.makeBackend(
            kind: configuration.backend,
            configuration: configuration,
            credentials: components.credentialStore
        ) {
            session?.configure(
                backends: [backend],
                backend: configuration.backend,
                model: modelIdentifier,
                visionFallbackEnabled: configuration.visionFallbackEnabled
            )
        }
        queueSave()
    }

    public func deleteAPIKey() async throws {
        try components.credentialStore.delete()
        viewModel.keyConfigured = false
        viewModel.backendReady = false
        viewModel.availableModels = []
        viewModel.isAutomaticTranslationEnabled = false
        configuration.autoTranslateEnabled = false
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
        return health
    }

    public func setVisionFallback(_ enabled: Bool) {
        configuration.visionFallbackEnabled = enabled
        viewModel.visionFallbackEnabled = enabled
        let previousSession = session
        disableAutomaticTranslation()
        Task { await previousSession?.clearCache() }
        rebuildSession()
        queueSave()
        scheduleBackendRefresh()
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

    public func requestPermission(_ kind: PermissionKind) {
        switch kind {
        case .accessibility:
            _ = components.permissionController.requestAccessibilityPermission()
        case .screenCapture:
            _ = components.permissionController.requestScreenCapturePermission()
        }
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
                let snapshot = self.components.permissionController.snapshot
                self.viewModel.permissionSnapshot = snapshot
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
    }

    public func addCurrentAppExclusion() {
        guard let application = NSWorkspace.shared.frontmostApplication,
              let bundleID = application.bundleIdentifier,
              !bundleID.isEmpty,
              application.processIdentifier != getpid(),
              bundleID != Bundle.main.bundleIdentifier else { return }
        guard !configuration.excludedBundleIDs.contains(bundleID) else { return }
        configuration.excludedBundleIDs.append(bundleID)
        viewModel.excludedApplications.append(
            ExcludedApplication(bundleIdentifier: bundleID, displayName: application.localizedName ?? bundleID)
        )
        let previousSession = session
        disableAutomaticTranslation()
        Task { await previousSession?.clearCache() }
        rebuildSession()
        queueSave()
    }

    public func removeExclusion(bundleIdentifier: String) {
        configuration.excludedBundleIDs.removeAll { $0 == bundleIdentifier }
        viewModel.excludedApplications.removeAll { $0.bundleIdentifier == bundleIdentifier }
        let previousSession = session
        disableAutomaticTranslation()
        Task { await previousSession?.clearCache() }
        rebuildSession()
        queueSave()
    }

    public func clearCache() async throws {
        await session?.clearCache()
    }

    public func openLogs() {
        NSWorkspace.shared.activateFileViewerSelecting([paths.logURL])
    }

    public func quit() {
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
