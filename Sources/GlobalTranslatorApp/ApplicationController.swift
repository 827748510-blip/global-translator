import AppKit
import Foundation
import GlobalTranslatorCapture
import GlobalTranslatorCore
import GlobalTranslatorEngine
import GlobalTranslatorUI
import GlobalTranslatorRuntime

@MainActor
public final class ApplicationController: NSObject, ApplicationControlling, SettingsActions {
    public let paths: RuntimePaths
    public internal(set) var configuration = AppConfiguration()
    public private(set) var started = false
    private var settingsRequested = false
    public private(set) lazy var viewModel = SettingsViewModel(actions: self)

    public var configurationStore: any ConfigurationStoring { components.configurationStore }
    public var credentialStore: any CredentialStoring { components.credentialStore }
    public var permissionController: any PermissionControlling { components.permissionController }

    let components: ApplicationControllerComponents
    let persistence: ConfigurationPersistence
    let onQuit: @MainActor @Sendable () -> Void
    var statusItem: (any StatusItemControlling)?
    var overlay: (any OverlayControlling)?
    var session: TranslationSession?
    var selectionTranslate: SelectionTranslateController?
    var screenshotTranslate: ScreenshotTranslateController?
    var hotkeyRecordingMonitor: Any?
    var callbackBox: WindowCallbackBox?
    var automaticRequestToken: UInt64 = 0
    var automaticEnablePending = false
    var backendHealthToken: UInt64 = 0
    var permissionRefreshToken: UInt64 = 0
    var configurationLoadFailed = false
    var backendRefreshTask: Task<Void, Never>?
    var automaticEnableTask: Task<Void, Never>?
    var permissionRefreshTask: Task<Void, Never>?
    var backendRetryTask: Task<Void, Never>?
    var backendRetryAttempt = 0
    /// Serial reconciler for the Homebrew Ollama service. The latest backend
    /// selection wins, so a fast cloud→local toggle cannot leave it stopped.
    var ollamaLifecycleTask: Task<Void, Never>?
    var pendingOllamaBackend: BackendKind?
    /// Interval between startup health-check retries; tests shrink it.
    var backendRetryInterval: TimeInterval = 10
    /// Cold local backends (model unloaded after sleep) can flunk the startup
    /// health check; retry for a few minutes before giving up.
    static let maxBackendRetryAttempts = 30
    var applicationPicker: NSOpenPanel?
    var screenshotDirectoryPicker: NSOpenPanel?
    var bridgeServer: ExtensionBridgeServer?
    var videoASR: VideoAudioASRController?
    private var applicationDisplayNameCache: [String: String] = [:]

    public init(
        paths: RuntimePaths,
        components: ApplicationControllerComponents? = nil,
        onQuit: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        let resolvedComponents = components ?? ApplicationControllerComponents.production(paths: paths)
        self.paths = paths
        self.components = resolvedComponents
        self.persistence = ConfigurationPersistence(store: resolvedComponents.configurationStore)
        self.onQuit = onQuit
        super.init()
    }

    public func start() async throws {
        guard !started else { return }
        try paths.prepareDirectories()
        _ = viewModel
        statusItem = components.statusItemFactory(viewModel)
        overlay = components.overlayFactory()
        wireOverlayHoverSuppression()
        started = true
        configurationLoadFailed = false
        do {
            let loaded = try await persistence.load()
            guard Self.isUsable(loaded) else { throw ConfigStoreError.invalidData }
            configuration = loaded
            var seen = Set<String>()
            configuration.translatedBundleIDs = loaded.translatedBundleIDs.filter {
                Self.isSafeBundleIdentifier($0) && $0 != Bundle.main.bundleIdentifier
                    && $0 != "com.maodashu.global-translator" && seen.insert($0).inserted
            }
            // 视觉兜底已从设置移除；旧配置里的 true 必须强制关闭，
            // 避免升级后仍静默上传局部截图。
            if configuration.visionFallbackEnabled {
                configuration.visionFallbackEnabled = false
                queueSave()
            }
        } catch {
            configurationLoadFailed = true
            configuration = AppConfiguration()
            viewModel.healthMessage = "配置无效，已使用安全默认值"
            components.logger.event("config_invalid", fields: ["status": "defaults"])
        }
        pushConfigurationState()
        if settingsRequested { statusItem?.showSettings(fromLaunch: true) }
        makeSession()
        makeSelectionTranslate()
        makeScreenshotTranslate()
        makeVideoASR()
        startExtensionBridge()
        if configurationLoadFailed {
            viewModel.backendReady = false
            viewModel.healthMessage = "配置无效，已使用安全默认值"
            applyStatus(.off)
            return
        }
        scheduleBackendRefresh(startPersistedSession: true)
    }

    public func showSettings() {
        settingsRequested = true
        refreshPermissions()
        statusItem?.showSettings()
    }

    public func stop() async {
        guard started else { return }
        started = false
        settingsRequested = false
        applicationPicker?.cancel(nil)
        applicationPicker = nil
        screenshotDirectoryPicker?.cancel(nil)
        screenshotDirectoryPicker = nil
        backendHealthToken &+= 1
        automaticRequestToken &+= 1
        permissionRefreshToken &+= 1
        automaticEnablePending = false
        backendRefreshTask?.cancel()
        backendRefreshTask = nil
        backendRetryTask?.cancel()
        backendRetryTask = nil
        backendRetryAttempt = 0
        ollamaLifecycleTask?.cancel()
        ollamaLifecycleTask = nil
        pendingOllamaBackend = nil
        automaticEnableTask?.cancel()
        automaticEnableTask = nil
        permissionRefreshTask?.cancel()
        permissionRefreshTask = nil
        viewModel.isAutomaticTranslationEnabled = false
        callbackBox?.callback = nil
        callbackBox = nil
        session?.stop()
        session = nil
        selectionTranslate?.setEnabled(false)
        selectionTranslate = nil
        cancelScreenshotHotkeyRecording()
        screenshotTranslate?.stopHotkey()
        screenshotTranslate = nil
        videoASR?.stop()
        videoASR = nil
        bridgeServer?.stop()
        bridgeServer = nil
        statusItem?.stop()
        statusItem = nil
        overlay?.hideAll()
        overlay = nil
        do {
            try await persistence.flush()
        } catch {
            components.logger.event("config_flush_failed", fields: ["status": "write_failure"])
        }
    }

    func pushConfigurationState() {
        viewModel.selectedBackend = configuration.backend
        viewModel.localBaseURL = configuration.localBaseURL.absoluteString
        viewModel.localModel = configuration.localModel
        viewModel.translatedApplications = configuration.translatedBundleIDs.map { id in
            TranslatedApplication(bundleIdentifier: id, displayName: resolvedDisplayName(for: id))
        }
        viewModel.isSelectionTranslateEnabled = configuration.selectionTranslateEnabled
        viewModel.isVideoTranslateEnabled = configuration.videoTranslateEnabled
        viewModel.promptOptimizeMode = configuration.promptOptimizeMode
        viewModel.autoCopyScreenshotTranslation = configuration.autoCopyScreenshotTranslation
        viewModel.saveScreenshotImage = configuration.saveScreenshotImage
        viewModel.copyScreenshotImage = configuration.copyScreenshotImage
        viewModel.screenshotSaveDirectory = configuration.screenshotSaveDirectory
        viewModel.screenshotTranslateHotkey = configuration.screenshotTranslateHotkey
        viewModel.deepSeekModel = AppConfiguration.resolvedDeepSeekModel(configuration.deepSeekModel)
        viewModel.permissionSnapshot = components.permissionController.snapshot
        viewModel.keyConfigured = configuration.deepSeekAPIKeyConfigured
    }

    /// Persist the non-secret "key is configured" flag. Never logs or stores the secret.
    func persistDeepSeekAPIKeyConfigured(_ configured: Bool) {
        viewModel.keyConfigured = configured
        guard configuration.deepSeekAPIKeyConfigured != configured else { return }
        configuration.deepSeekAPIKeyConfigured = configured
        queueSave()
    }

    /// First real DeepSeek API use that obtained a model list also means a
    /// non-empty key was read. Startup/backend switching must not `read()`
    /// just to discover this.
    func migrateDeepSeekAPIKeyConfiguredIfNeeded(from health: BackendHealth) {
        guard configuration.backend == .deepSeekCloud else { return }
        guard !configuration.deepSeekAPIKeyConfigured else {
            viewModel.keyConfigured = true
            return
        }
        switch health.status {
        case .healthy:
            persistDeepSeekAPIKeyConfigured(true)
        case .modelUnavailable where !health.availableModels.isEmpty:
            persistDeepSeekAPIKeyConfigured(true)
        case .unavailable, .invalidCredentials, .invalidConfiguration, .modelUnavailable:
            break
        }
    }

    func applyDeepSeekSessionBackendsWithoutHealthCheck() {
        guard configuration.backend == .deepSeekCloud else { return }
        guard let backend = try? components.backendFactory.makeBackend(
            kind: .deepSeekCloud,
            configuration: configuration,
            credentials: components.credentialStore
        ) else { return }
        applySessionBackends(overlay: backend, configuration: configuration)
    }

    /// `configure()` always `stop()`s overlay capture. Snapshot running/bridge
    /// state, rewire DeepSeek backends to the current model, then restore.
    func rewireDeepSeekBackendsPreservingCapture() {
        let wasRunning = session?.isRunning == true
        let wasBridgeActive = session?.isBridgeActive == true
        applyDeepSeekSessionBackendsWithoutHealthCheck()
        if wasBridgeActive {
            session?.setBridgeActive(true)
        }
        if wasRunning {
            startWindowSessionIfPermitted()
        }
    }

    func makeSession() {
        guard session == nil, let overlay else { return }
        let allowed = Set(configuration.translatedBundleIDs)
        let box = WindowCallbackBox()
        let monitor = components.monitorFactory(allowed)
        let capture = components.capturePipelineFactory(allowed)
        let session = TranslationSession(
            monitor: monitor,
            capture: capture,
            overlay: overlay,
            permissions: components.permissionController,
            coordinatorFactory: components.coordinatorFactory,
            schedulerFactory: components.schedulerFactory,
            logger: components.logger,
            statusHandler: { [weak self] status in self?.applyStatus(status) },
            inPage: components.inPageFactory(),
            translatedBundleIdentifiers: allowed
        )
        monitor.setCallback { [weak box] descriptor in
            box?.callback?(descriptor)
        }
        box.callback = { [weak session] descriptor in
            session?.handleWindow(descriptor)
        }
        callbackBox = box
        self.session = session
    }

    func makeSelectionTranslate() {
        guard selectionTranslate == nil else { return }
        var own = Set<String>()
        if let id = Bundle.main.bundleIdentifier { own.insert(id) }
        own.insert("com.maodashu.global-translator")
        let controller = SelectionTranslateController(
            reader: components.selectedTextReaderFactory(),
            popover: components.selectionPopoverFactory(),
            monitor: components.selectionPointerMonitorFactory(),
            permissions: components.permissionController,
            logger: components.logger,
            translator: { [weak self] in self?.session },
            isCloudKeyConfigured: { [weak self] in
                self?.configuration.deepSeekAPIKeyConfigured == true
            },
            ownBundleIdentifiers: own,
            shouldSuppressPointer: { [weak self] in
                self?.screenshotTranslate?.isSelectingRegion == true
            }
        )
        selectionTranslate = controller
        controller.setOptimizeMode(configuration.promptOptimizeMode)
        controller.setBackend(configuration.backend)
        controller.onOptimizeModeChange = { [weak self] mode in
            self?.setPromptOptimizeMode(mode)
        }
        controller.onOpenSettings = { [weak self] in
            self?.openSettingsForRecovery(preferPermissions: false)
        }
        controller.setEnabled(configuration.selectionTranslateEnabled)
    }

    func makeScreenshotTranslate() {
        guard screenshotTranslate == nil else { return }
        let controller = ScreenshotTranslateController(
            selector: components.regionSelectorFactory(),
            capturer: components.regionCapturerFactory(),
            ocr: components.regionOCRFactory(),
            popover: components.screenshotPopoverFactory(),
            permissions: components.permissionController,
            logger: components.logger,
            registrar: components.hotkeyRegistrarFactory(),
            translator: { [weak self] in self?.session },
            backendReadiness: { [weak self] in
                self?.screenshotBackendReadiness() ?? .localNotReady
            },
            requestScreenCapture: { [weak self] in
                _ = self?.components.permissionController.requestScreenCapturePermission()
                self?.refreshPermissions()
            },
            shortcut: configuration.screenshotTranslateHotkey
        )
        screenshotTranslate = controller
        controller.setBackend(configuration.backend)
        controller.setAutoCopy(configuration.autoCopyScreenshotTranslation)
        controller.setSaveImage(configuration.saveScreenshotImage)
        controller.setCopyImage(configuration.copyScreenshotImage)
        controller.setSaveDirectory(configuration.screenshotSaveDirectory)
        controller.onOpenSettings = { [weak self] in
            let missingPermission = !(self?.components.permissionController.snapshot.screenCaptureAuthorized ?? true)
            self?.openSettingsForRecovery(preferPermissions: missingPermission)
        }
        controller.startHotkey()
        if let message = controller.lastHotkeyError, !message.isEmpty {
            viewModel.screenshotHotkeyConflictMessage = message
        }
    }

    func screenshotBackendReadiness() -> ScreenshotBackendReadiness {
        switch configuration.backend {
        case .deepSeekCloud:
            return configuration.deepSeekAPIKeyConfigured ? .ready : .missingCloudKey
        case .local:
            let modelReady = !configuration.localModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let urlReady = (try? EndpointValidator.validateLocalBaseURL(configuration.localBaseURL)) != nil
            return modelReady && urlReady ? .ready : .localNotReady
        }
    }

    func makeVideoASR() {
        guard videoASR == nil else { return }
        let support = WhisperCppLocator.candidatesForSupportDirectory(paths.whisperDirectory)
        let scratch = paths.runtimeDirectory.appendingPathComponent("whisper-scratch", isDirectory: true)
        videoASR = VideoAudioASRController(
            permissions: components.permissionController,
            locate: {
                WhisperCppLocator.locate(
                    extraBinaryCandidates: support.binaries,
                    extraModelCandidates: support.models
                )
            },
            capturer: ScreenCaptureKitSystemAudioCapturer(permissions: components.permissionController),
            transcriber: WhisperCppTranscriber(
                locate: {
                    WhisperCppLocator.locate(
                        extraBinaryCandidates: support.binaries,
                        extraModelCandidates: support.models
                    )
                },
                scratchDirectory: scratch
            ),
            windowProvider: { [weak self] in
                await MainActor.run {
                    guard let self,
                          self.viewModel.isAutomaticTranslationEnabled,
                          self.configuration.videoTranslateEnabled,
                          let window = self.session?.currentWindow,
                          ChromiumBrowserBundles.contains(window.bundleIdentifier) else {
                        return nil
                    }
                    return window
                }
            },
            onEvent: { [weak self] code, fields in
                self?.components.logger.event(code, fields: fields)
            }
        )
        videoASR?.setVideoTranslateEnabled(configuration.videoTranslateEnabled)
    }

    func rebuildSession() {
        session?.stop()
        session = nil
        callbackBox = nil
        overlay = components.overlayFactory()
        wireOverlayHoverSuppression()
        makeSession()
    }

    private func wireOverlayHoverSuppression() {
        (overlay as? OverlayPanelController)?.shouldSuppressHoverRaise = { [weak self] in
            self?.shouldSuppressOverlayHoverRaise() ?? false
        }
    }

    private func shouldSuppressOverlayHoverRaise() -> Bool {
        if statusItem?.isDropdownVisible == true { return true }
        if selectionTranslate?.isPopoverVisible == true { return true }
        if screenshotTranslate?.isPopoverVisible == true { return true }
        return false
    }

    private func openSettingsForRecovery(preferPermissions: Bool) {
        if preferPermissions {
            viewModel.selectedTab = .advanced
        } else if !viewModel.canEnableAutomaticTranslation {
            viewModel.selectedTab = .backend
        } else {
            viewModel.selectedTab = .advanced
        }
        showSettings()
    }

    private func resolvedDisplayName(for bundleID: String) -> String {
        if let cached = applicationDisplayNameCache[bundleID] {
            return cached
        }
        let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { FileManager.default.displayName(atPath: $0.path) } ?? bundleID
        applicationDisplayNameCache[bundleID] = name
        return name
    }

    /// Serves the browser-extension bridge for the whole lifetime of the
    /// daemon; the handler resolves the session lazily so session rebuilds
    /// and backend reconfiguration need no server restart.
    private func startExtensionBridge() {
        let server = ExtensionBridgeServer(
            logger: components.logger,
            videoTranslateEnabled: { [weak self] in
                self?.configuration.videoTranslateEnabled == true
            },
            setVideoTranslateEnabled: { [weak self] enabled in
                guard let self else { return false }
                self.setVideoTranslate(enabled)
                return self.configuration.videoTranslateEnabled
            },
            autoTranslateEnabled: { [weak self] in
                self?.viewModel.isAutomaticTranslationEnabled == true
            },
            backendReady: { [weak self] in
                self?.viewModel.backendReady == true
            },
            blockedReason: { [weak self] in
                guard let self else { return nil }
                if !self.viewModel.isAutomaticTranslationEnabled {
                    return self.viewModel.automaticEnableBlockedReason ?? "桌面端未开启“自动翻译”"
                }
                return nil
            },
            videoASRSnapshot: { [weak self] in
                self?.videoASR?.snapshot() ?? .idle
            },
            videoASRSetNeeded: { [weak self] needed in
                self?.videoASR?.setCaptionsNeeded(needed)
            },
            scopedHandler: { [weak self] texts, sourceLanguage, pageOrigin in
                guard let session = self?.session else { throw ExtensionBridgeError.translatorUnavailable }
                return try await session.translateBridgeTexts(texts, sourceLanguage: sourceLanguage, pageOrigin: pageOrigin)
            }
        )
        server.start()
        bridgeServer = server
    }

    func refreshBackend() async {
        let healthToken = backendHealthToken
        let expectedConfiguration = configuration
        let health = await components.backendFactory.healthCheck(
            kind: expectedConfiguration.backend,
            configuration: expectedConfiguration,
            credentials: components.credentialStore
        )
        guard started,
              !Task.isCancelled,
              healthToken == backendHealthToken,
              expectedConfiguration.backend == configuration.backend,
              expectedConfiguration.localBaseURL == configuration.localBaseURL,
              expectedConfiguration.localModel == configuration.localModel,
              expectedConfiguration.deepSeekModel == configuration.deepSeekModel else { return }
        applyHealth(health)
        // Only `.unavailable` is transient (cold local model, sleeping
        // backend); credential/model problems need user action.
        if health.status == .unavailable {
            scheduleBackendRetry(healthToken: healthToken)
        }
        // Use the live configuration so an adopted DeepSeek model is the one
        // wired into the session, not the pre-health identifier.
        guard let backend = try? components.backendFactory.makeBackend(
            kind: configuration.backend,
            configuration: configuration,
            credentials: components.credentialStore
        ) else {
            session?.stop()
            return
        }
        applySessionBackends(overlay: backend, configuration: configuration)
    }

    /// Overlay, extension bridge, and 滑词翻译 each get their own coalescer
    /// wrapping the shared serial local backend. Sharing a coalescer would
    /// cancel in-flight work across those paths.
    func applySessionBackends(overlay: any TranslationBackend, configuration expected: AppConfiguration) {
        let bridge = (try? components.backendFactory.makeBackend(
            kind: expected.backend,
            configuration: expected,
            credentials: components.credentialStore
        )) ?? overlay
        let selection = (try? components.backendFactory.makeBackend(
            kind: expected.backend,
            configuration: expected,
            credentials: components.credentialStore
        )) ?? overlay
        session?.configure(
            backends: [overlay],
            backend: expected.backend,
            model: modelIdentifier,
            visionFallbackEnabled: false,
            bridgeBackends: [bridge],
            selectionBackends: [selection]
        )
    }

    /// Stops the Homebrew Ollama service when the active backend is cloud and
    /// starts it when local is selected. A single serial loop means the latest
    /// selection always wins even if the user toggles quickly.
    func scheduleOllamaLifecycleSync() {
        pendingOllamaBackend = configuration.backend
        guard ollamaLifecycleTask == nil else { return }
        ollamaLifecycleTask = Task { @MainActor [weak self] in
            await self?.reconcileOllamaLifecycle()
        }
    }

    private func reconcileOllamaLifecycle() async {
        while let desired = pendingOllamaBackend {
            pendingOllamaBackend = nil
            guard !Task.isCancelled, started else { break }

            guard Self.shouldManageOllama(for: configuration) else {
                components.logger.event(
                    "ollama_lifecycle_skipped",
                    fields: ["reason": "endpoint_not_ollama", "backend": desired.rawValue]
                )
                if desired == .local, pendingOllamaBackend == nil, configuration.backend == .local {
                    scheduleBackendRefresh()
                }
                continue
            }

            let action = desired == .deepSeekCloud ? "suspend" : "resume"
            let outcome: OllamaLifecycleOutcome
            if desired == .deepSeekCloud {
                outcome = await components.ollamaLifecycle.suspend()
            } else {
                outcome = await components.ollamaLifecycle.resume(
                    baseURL: configuration.localBaseURL
                )
            }
            guard !Task.isCancelled else { break }
            components.logger.event(
                "ollama_lifecycle",
                fields: ["action": action, "result": outcome.logValue]
            )

            // Do not start a health check against a backend that the user has
            // already switched away from while brew was running.
            if desired == .local, pendingOllamaBackend == nil, configuration.backend == .local {
                scheduleBackendRefresh()
            }
        }

        ollamaLifecycleTask = nil
        if pendingOllamaBackend != nil {
            scheduleOllamaLifecycleSync()
        }
    }

    /// Only the default Ollama HTTP endpoint on loopback is managed. A custom
    /// local OpenAI-compatible endpoint (LM Studio, a remote tunnel, another
    /// port) must never cause us to stop a Homebrew service.
    static func shouldManageOllama(for configuration: AppConfiguration) -> Bool {
        guard let scheme = configuration.localBaseURL.scheme?.lowercased(),
              scheme == "http",
              let host = configuration.localBaseURL.host?.lowercased() else {
            return false
        }
        let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "::1"]
        guard loopbackHosts.contains(host) else { return false }
        return configuration.localBaseURL.port == 11434
    }

    func scheduleBackendRefresh(startPersistedSession: Bool = false) {
        backendRefreshTask?.cancel()
        backendRetryTask?.cancel()
        backendRetryTask = nil
        backendRetryAttempt = 0
        let healthToken = backendHealthToken
        backendRefreshTask = Task { @MainActor [weak self] in
            guard let self,
                  self.started,
                  self.backendHealthToken == healthToken,
                  !Task.isCancelled else { return }
            await self.refreshBackend()
            guard self.started,
                  self.backendHealthToken == healthToken,
                  !Task.isCancelled else { return }
            if startPersistedSession {
                self.maybeStartPersistedSession()
            }
            if self.backendHealthToken == healthToken {
                self.backendRefreshTask = nil
            }
        }
    }

    func applyHealth(_ health: BackendHealth) {
        migrateDeepSeekAPIKeyConfiguredIfNeeded(from: health)
        let supportedModels = configuration.backend == .deepSeekCloud
            ? health.availableModels.filter(AppConfiguration.isSupportedDeepSeekModel)
            : health.availableModels
        if !supportedModels.isEmpty {
            viewModel.availableModels = supportedModels
            if configuration.backend == .deepSeekCloud {
                adoptDeepSeekModel(from: supportedModels)
            }
        }
        let cloudModelReady = configuration.backend == .deepSeekCloud
            && !supportedModels.isEmpty
            && supportedModels.contains(AppConfiguration.resolvedDeepSeekModel(configuration.deepSeekModel))
        switch health.status {
        case .healthy:
            viewModel.backendReady = true
            viewModel.healthMessage = health.message
        case .modelUnavailable where cloudModelReady:
            viewModel.backendReady = true
            viewModel.healthMessage = "DeepSeek 后端已就绪"
        case .unavailable, .invalidCredentials, .modelUnavailable, .invalidConfiguration:
            viewModel.backendReady = false
            viewModel.healthMessage = health.status.uiSafeFailureMessage
            viewModel.status = .error
        }
    }

    private func adoptDeepSeekModel(from models: [String]) {
        let picked = AppConfiguration.preferredDeepSeekModel(current: configuration.deepSeekModel, available: models)
        if picked != configuration.deepSeekModel {
            configuration.deepSeekModel = picked
            queueSave()
        }
        viewModel.deepSeekModel = picked
    }

    /// Retries a transiently failing backend health check on a fixed cadence
    /// and, once healthy, runs the persisted auto-start. Without this a cold
    /// local model (unloaded after sleep) left the session off forever.
    func scheduleBackendRetry(healthToken: UInt64) {
        guard configuration.autoTranslateEnabled else { return }
        guard backendRetryAttempt < Self.maxBackendRetryAttempts else { return }
        backendRetryAttempt += 1
        let attempt = backendRetryAttempt
        let interval = backendRetryInterval
        backendRetryTask?.cancel()
        backendRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(interval))
            guard let self,
                  self.started,
                  !Task.isCancelled,
                  self.backendHealthToken == healthToken,
                  self.configuration.autoTranslateEnabled,
                  self.session?.isRunning != true else { return }
            self.components.logger.event("backend_retry", fields: ["attempt": String(attempt)])
            await self.refreshBackend()
            guard self.started, self.backendHealthToken == healthToken, !Task.isCancelled else { return }
            self.maybeStartPersistedSession()
        }
    }

    func maybeStartPersistedSession() {
        guard configuration.autoTranslateEnabled else {
            session?.setBridgeActive(false)
            applyStatus(.off)
            return
        }
        viewModel.permissionSnapshot = components.permissionController.snapshot
        guard viewModel.canEnableAutomaticTranslation else {
            viewModel.isAutomaticTranslationEnabled = false
            session?.setBridgeActive(false)
            viewModel.healthMessage = viewModel.automaticEnableBlockedReason
            applyStatus(.off)
            return
        }
        viewModel.isAutomaticTranslationEnabled = true
        session?.setBridgeActive(true)
        startWindowSessionIfPermitted()
    }

    /// Overlay capture still needs AX or Screen Recording. The extension
    /// bridge is already active via `setBridgeActive` and must not wait.
    func startWindowSessionIfPermitted() {
        viewModel.permissionSnapshot = components.permissionController.snapshot
        if viewModel.permissionSnapshot.hasCaptureAccess {
            session?.start()
        } else {
            applyStatus(.missingPermission)
        }
    }

    var modelIdentifier: String {
        switch configuration.backend {
        case .deepSeekCloud:
            return AppConfiguration.resolvedDeepSeekModel(configuration.deepSeekModel)
        case .local:
            return configuration.localModel
        }
    }

    func queueSave() {
        persistence.enqueue(configuration)
    }

    func applyStatus(_ status: MenuBarStatus) {
        viewModel.status = status
        switch status {
        case .missingPermission:
            let permission = components.permissionController.snapshot
            if permission.accessibilityTrusted && !permission.screenCaptureAuthorized {
                viewModel.healthMessage = "当前内容需要屏幕录制权限，请授权后重试"
            } else if permission.screenCaptureAuthorized && !permission.accessibilityTrusted {
                viewModel.healthMessage = "当前内容需要辅助功能权限，请授权后重试"
            } else {
                viewModel.healthMessage = "需要辅助功能或屏幕录制权限"
            }
        case .error where viewModel.healthMessage == nil:
            viewModel.healthMessage = UIFeedback.genericErrorMessage
        case .off, .listening, .translating, .error:
            break
        }
        statusItem?.applyStatus(status)
    }

    private static func isUsable(_ configuration: AppConfiguration) -> Bool {
        guard configuration.localModel.utf8.count <= 256 else { return false }
        guard configuration.deepSeekModel.utf8.count <= 256 else { return false }
        guard configuration.backend == .deepSeekCloud || configuration.backend == .local else { return false }
        if configuration.backend == .local {
            guard (try? EndpointValidator.validateLocalBaseURL(configuration.localBaseURL)) != nil else { return false }
        }
        return true
    }

    static func isSafeBundleIdentifier(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty, bytes.count <= 255 else { return false }
        return bytes.allSatisfy { byte in
            byte == 45 || byte == 46 || (byte >= 48 && byte <= 57) ||
                (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
        }
    }
}

@MainActor
final class WindowCallbackBox {
    var callback: ActiveWindowCallback?
}
