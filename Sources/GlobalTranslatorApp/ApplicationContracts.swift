import AppKit
import Foundation
import GlobalTranslatorCapture
import GlobalTranslatorCore
import GlobalTranslatorEngine
import GlobalTranslatorRuntime
import GlobalTranslatorUI

public protocol ConfigurationStoring: Sendable {
    func load() async throws -> AppConfiguration
    func save(_ configuration: AppConfiguration) async throws
}

extension ConfigStore: ConfigurationStoring {}

public protocol AppRuntimeLogger: Sendable {
    func event(_ code: String, fields: [String: String])
}

public struct RuntimeLoggerAdapter: AppRuntimeLogger, Sendable {
    private let logger: RuntimeLogger

    public init(logger: RuntimeLogger) {
        self.logger = logger
    }

    public func event(_ code: String, fields: [String: String] = [:]) {
        var payload = fields
        payload["message"] = "application event"
        try? logger.write(level: "info", event: code, fields: payload)
    }
}

public struct NullAppRuntimeLogger: AppRuntimeLogger, Sendable {
    public init() {}
    public func event(_ code: String, fields: [String: String] = [:]) {}
}

public protocol TranslationBackendFactory: Sendable {
    func makeBackend(
        kind: BackendKind,
        configuration: AppConfiguration,
        credentials: any CredentialStoring
    ) throws -> any TranslationBackend

    func healthCheck(
        kind: BackendKind,
        configuration: AppConfiguration,
        credentials: any CredentialStoring
    ) async -> BackendHealth
}

public struct LiveTranslationBackendFactory: TranslationBackendFactory, Sendable {
    private let transport: any HTTPTransport

    public init(transport: any HTTPTransport = URLSessionHTTPTransport()) {
        self.transport = transport
    }

    public func makeBackend(
        kind: BackendKind,
        configuration: AppConfiguration,
        credentials: any CredentialStoring
    ) throws -> any TranslationBackend {
        switch kind {
        case .deepSeekCloud:
            return DeepSeekBackend(transport: transport, credentialStore: credentials)
        case .local:
            return CoalescingTranslationBackend(base: try LocalOpenAIBackend(
                baseURL: configuration.localBaseURL,
                model: configuration.localModel,
                transport: transport
            ))
        }
    }

    public func healthCheck(
        kind: BackendKind,
        configuration: AppConfiguration,
        credentials: any CredentialStoring
    ) async -> BackendHealth {
        do {
            let backend = try makeBackend(kind: kind, configuration: configuration, credentials: credentials)
            return await backend.healthCheck()
        } catch let error as EndpointValidationError {
            _ = error
            return BackendHealth(status: .invalidConfiguration, message: "Backend configuration is invalid")
        } catch {
            return BackendHealth(status: .unavailable, message: "Backend health check failed")
        }
    }
}

@MainActor
public protocol ActiveWindowMonitoring: AnyObject {
    var current: ActiveWindowDescriptor? { get }
    func setCallback(_ callback: @escaping ActiveWindowCallback)
    func start()
    func stop()
    func setVisualUpdatesEnabled(_ enabled: Bool)
    func retryCurrentWindowCapture()
}

public extension ActiveWindowMonitoring {
    func setVisualUpdatesEnabled(_ enabled: Bool) {}
    func retryCurrentWindowCapture() {}
}

@MainActor
public final class ActiveWindowMonitorAdapter: ActiveWindowMonitoring {
    private final class CallbackHolder {
        var callback: ActiveWindowCallback?
    }

    private let monitor: ActiveWindowMonitor
    private let holder: CallbackHolder

    public init(
        ownBundleIdentifier: String? = Bundle.main.bundleIdentifier,
        excludedBundleIdentifiers: Set<String> = []
    ) {
        let holder = CallbackHolder()
        self.holder = holder
        monitor = ActiveWindowMonitor(
            ownBundleIdentifier: ownBundleIdentifier,
            excludedBundleIdentifiers: excludedBundleIdentifiers,
            callback: { descriptor in holder.callback?(descriptor) }
        )
    }

    public var current: ActiveWindowDescriptor? { monitor.current }
    public func setVisualUpdatesEnabled(_ enabled: Bool) { monitor.setVisualUpdatesEnabled(enabled) }
    public func retryCurrentWindowCapture() { monitor.retryCurrentWindowCapture() }
    public func setCallback(_ callback: @escaping ActiveWindowCallback) { holder.callback = callback }
    public func start() { monitor.start() }
    public func stop() { monitor.stop() }
}

public protocol CapturePipelining: Sendable {
    func capture(_ descriptor: ActiveWindowDescriptor) async throws -> CaptureSnapshot
}

extension CapturePipeline: CapturePipelining {}

@MainActor
public protocol StatusItemControlling: AnyObject {
    func applyStatus(_ status: MenuBarStatus)
    func stop()
}

extension StatusItemController: StatusItemControlling {}

@MainActor
public protocol OverlayControlling: AnyObject {
    func update(translations: [RenderedTranslation], revision: UInt64)
    func hideAll()
}

extension OverlayPanelController: OverlayControlling {}

public protocol TranslationCoordinating: Sendable {
    func selectBackend(kind: BackendKind, modelIdentifier: String) async
    func clearCache() async
    func cancelPendingRequests() async
    func translate(
        snapshot: CaptureSnapshot,
        backend: BackendKind,
        modelIdentifier: String,
        visionFallbackEnabled: Bool
    ) async throws -> EngineOutput
}

extension TranslationCoordinator: TranslationCoordinating {}

public extension TranslationCoordinating {
    func cancelPendingRequests() async {}
}

@MainActor
public protocol TranslationScheduling: AnyObject {
    func submit(
        snapshot: CaptureSnapshot,
        backend: BackendKind,
        modelIdentifier: String,
        visionFallbackEnabled: Bool
    )
    func cancel()
}

extension RealtimeTranslationScheduler: TranslationScheduling {}

@MainActor
public final class NoopTranslationScheduler: TranslationScheduling {
    public init() {}
    public func submit(
        snapshot: CaptureSnapshot,
        backend: BackendKind,
        modelIdentifier: String,
        visionFallbackEnabled: Bool
    ) {}
    public func cancel() {}
}

@MainActor
public protocol ApplicationRuntimeWorker: AnyObject {
    var isRunning: Bool { get }
    func start() throws
    func stop()
}

@MainActor
public final class RuntimeWorkerAdapter: ApplicationRuntimeWorker {
    private let worker: RuntimeWorker

    public init(worker: RuntimeWorker) {
        self.worker = worker
    }

    public var isRunning: Bool { worker.isRunning }
    public func start() throws { try worker.start() }
    public func stop() { worker.stop() }
}

@MainActor
public protocol ApplicationControlling: AnyObject {
    func start() async throws
    func stop() async
}

@MainActor
public protocol ApplicationEventLoop: AnyObject {
    func prepare()
    func run(onStarted: @escaping @MainActor @Sendable () -> Void) async
    func stop()
}

@MainActor
protocol NSApplicationDriving: AnyObject {
    func run()
    func finishLaunching()
    func stop(_ sender: Any?)
    func postEvent(_ event: NSEvent, atStart flag: Bool)
}

extension NSApplication: NSApplicationDriving {}

private final class NSApplicationDriverBox: @unchecked Sendable {
    let application: any NSApplicationDriving

    init(_ application: any NSApplicationDriving) {
        self.application = application
    }
}

@MainActor
public final class NSApplicationEventLoop: ApplicationEventLoop {
    private let application: any NSApplicationDriving
    private var prepared = false

    public init(application: NSApplication = .shared) {
        self.application = application
    }

    init(applicationDriver: any NSApplicationDriving) {
        self.application = applicationDriver
    }

    public func prepare() {
        guard !prepared else { return }
        application.finishLaunching()
        prepared = true
    }

    public func run(onStarted: @escaping @MainActor @Sendable () -> Void) async {
        prepare()
        let applicationBox = NSApplicationDriverBox(application)
        await withCheckedContinuation { continuation in
            RunLoop.main.perform {
                RunLoop.main.perform {
                    MainActor.assumeIsolated {
                        onStarted()
                    }
                }
                MainActor.assumeIsolated {
                    applicationBox.application.run()
                }
                continuation.resume()
            }
        }
    }

    public func stop() {
        application.stop(nil)
        guard let wakeEvent = NSEvent.otherEvent(
            with: .applicationDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            subtype: 0,
            data1: 0,
            data2: 0
        ) else { return }
        application.postEvent(wakeEvent, atStart: false)
    }
}

public typealias MonitorFactory = @MainActor (Set<String>) -> any ActiveWindowMonitoring
public typealias CaptureFactory = @MainActor (Set<String>) -> any CapturePipelining
public typealias StatusFactory = @MainActor (SettingsViewModel) -> any StatusItemControlling
public typealias OverlayFactory = @MainActor () -> any OverlayControlling
public typealias CoordinatorFactory = @Sendable ([any TranslationBackend], EngineEventSink?) -> any TranslationCoordinating
public typealias SchedulerFactory = @MainActor (
    TranslationCoordinating,
    @escaping RealtimeTranslationScheduler.OutputHandler,
    @escaping RealtimeTranslationScheduler.StateHandler
) -> any TranslationScheduling

@MainActor
public struct ApplicationControllerComponents {
    public let configurationStore: any ConfigurationStoring
    public let credentialStore: any CredentialStoring
    public let permissionController: any PermissionControlling
    public let backendFactory: any TranslationBackendFactory
    public let monitorFactory: MonitorFactory
    public let capturePipelineFactory: CaptureFactory
    public let statusItemFactory: StatusFactory
    public let overlayFactory: OverlayFactory
    public let coordinatorFactory: CoordinatorFactory
    public let schedulerFactory: SchedulerFactory
    public let logger: any AppRuntimeLogger

    public init(
        configurationStore: any ConfigurationStoring,
        credentialStore: any CredentialStoring,
        permissionController: any PermissionControlling,
        backendFactory: any TranslationBackendFactory,
        monitorFactory: @escaping MonitorFactory,
        capturePipelineFactory: @escaping CaptureFactory,
        statusItemFactory: @escaping StatusFactory,
        overlayFactory: @escaping OverlayFactory,
        coordinatorFactory: @escaping CoordinatorFactory,
        schedulerFactory: @escaping SchedulerFactory,
        logger: any AppRuntimeLogger
    ) {
        self.configurationStore = configurationStore
        self.credentialStore = credentialStore
        self.permissionController = permissionController
        self.backendFactory = backendFactory
        self.monitorFactory = monitorFactory
        self.capturePipelineFactory = capturePipelineFactory
        self.statusItemFactory = statusItemFactory
        self.overlayFactory = overlayFactory
        self.coordinatorFactory = coordinatorFactory
        self.schedulerFactory = schedulerFactory
        self.logger = logger
    }

}
