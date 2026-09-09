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
    /// Interval between startup health-check retries; tests shrink it.
    var backendRetryInterval: TimeInterval = 10
    /// Cold local backends (model unloaded after sleep) can flunk the startup
    /// health check; retry for a few minutes before giving up.
    static let maxBackendRetryAttempts = 30
    var applicationPicker: NSOpenPanel?
    var bridgeServer: ExtensionBridgeServer?

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
        } catch {
            configurationLoadFailed = true
            configuration = AppConfiguration()
            viewModel.healthMessage = "配置无效，已使用安全默认值"
            components.logger.event("config_invalid", fields: ["status": "defaults"])
        }
        pushConfigurationState()
        if settingsRequested { statusItem?.showSettings() }
        makeSession()
        makeSelectionTranslate()
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
        backendHealthToken &+= 1
        automaticRequestToken &+= 1
        permissionRefreshToken &+= 1
        automaticEnablePending = false
        backendRefreshTask?.cancel()
        backendRefreshTask = nil
        backendRetryTask?.cancel()
        backendRetryTask = nil
        backendRetryAttempt = 0
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
        viewModel.visionFallbackEnabled = configuration.visionFallbackEnabled
        viewModel.localBaseURL = configuration.localBaseURL.absoluteString
        viewModel.localModel = configuration.localModel
        viewModel.translatedApplications = configuration.translatedBundleIDs.map { id in
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
            return TranslatedApplication(bundleIdentifier: id,
                displayName: url.map { FileManager.default.displayName(atPath: $0.path) } ?? id)
        }
        viewModel.isSelectionTranslateEnabled = configuration.selectionTranslateEnabled
        viewModel.promptOptimizeMode = configuration.promptOptimizeMode
        viewModel.deepSeekModel = AppConfiguration.resolvedDeepSeekModel(configuration.deepSeekModel)
        viewModel.permissionSnapshot = components.permissionController.snapshot
        // Probe Keychain once at launch for any backend. Switching to DeepSeek
        // later must not re-read the item (that can pop a system prompt and
        // an empty key form).
        let storedKey = try? components.credentialStore.read()
        viewModel.keyConfigured = !(storedKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
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
            ownBundleIdentifiers: own
        )
        selectionTranslate = controller
        controller.setOptimizeMode(configuration.promptOptimizeMode)
        controller.onOptimizeModeChange = { [weak self] mode in
            self?.setPromptOptimizeMode(mode)
        }
        controller.setEnabled(configuration.selectionTranslateEnabled)
    }

    func rebuildSession() {
        session?.stop()
        session = nil
        callbackBox = nil
        overlay = components.overlayFactory()
        makeSession()
    }

    /// Serves the browser-extension bridge for the whole lifetime of the
    /// daemon; the handler resolves the session lazily so session rebuilds
    /// and backend reconfiguration need no server restart.
    private func startExtensionBridge() {
        let server = ExtensionBridgeServer(logger: components.logger) { [weak self] texts in
            guard let session = self?.session else { throw ExtensionBridgeError.translatorUnavailable }
            return try await session.translateBridgeTexts(texts)
        }
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
            visionFallbackEnabled: expected.visionFallbackEnabled,
            bridgeBackends: [bridge],
            selectionBackends: [selection]
        )
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
        if !health.availableModels.isEmpty {
            viewModel.availableModels = health.availableModels
            if configuration.backend == .deepSeekCloud {
                adoptDeepSeekModel(from: health.availableModels)
            }
        }
        let cloudModelReady = configuration.backend != .deepSeekCloud
            || viewModel.availableModels.contains(AppConfiguration.resolvedDeepSeekModel(configuration.deepSeekModel))
        switch health.status {
        case .healthy:
            viewModel.backendReady = true
            viewModel.healthMessage = health.message
        case .modelUnavailable where cloudModelReady && !viewModel.availableModels.isEmpty:
            viewModel.backendReady = true
            viewModel.healthMessage = "DeepSeek backend is ready"
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
