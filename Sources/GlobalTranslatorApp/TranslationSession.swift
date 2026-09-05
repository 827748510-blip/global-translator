import Foundation
import GlobalTranslatorCapture
import GlobalTranslatorCore
import GlobalTranslatorEngine
import GlobalTranslatorUI

@MainActor
public final class TranslationSession {
    public private(set) var isRunning = false
    public private(set) var activeRevision: UInt64 = 0

    private let monitor: any ActiveWindowMonitoring
    private let capture: any CapturePipelining
    private let overlay: any OverlayControlling
    private let coordinatorFactory: CoordinatorFactory
    private let schedulerFactory: SchedulerFactory
    private let logger: any AppRuntimeLogger
    private let statusHandler: @MainActor @Sendable (MenuBarStatus) -> Void
    private var coordinator: (any TranslationCoordinating)?
    private var scheduler: (any TranslationScheduling)?
    private var captureTask: Task<Void, Never>?
    private var backend: BackendKind = .deepSeekCloud
    private var model = ""
    private var visionFallbackEnabled = false

    public init(
        monitor: any ActiveWindowMonitoring,
        capture: any CapturePipelining,
        overlay: any OverlayControlling,
        coordinatorFactory: @escaping CoordinatorFactory,
        schedulerFactory: @escaping SchedulerFactory,
        logger: any AppRuntimeLogger,
        statusHandler: @escaping @MainActor @Sendable (MenuBarStatus) -> Void
    ) {
        self.monitor = monitor
        self.capture = capture
        self.overlay = overlay
        self.coordinatorFactory = coordinatorFactory
        self.schedulerFactory = schedulerFactory
        self.logger = logger
        self.statusHandler = statusHandler
    }

    public func configure(
        backends: [any TranslationBackend],
        backend: BackendKind,
        model: String,
        visionFallbackEnabled: Bool
    ) {
        stop()
        self.backend = backend
        self.model = model
        self.visionFallbackEnabled = visionFallbackEnabled
        let coordinator = coordinatorFactory(backends, makeEventSink())
        self.coordinator = coordinator
        let outputHandler: @MainActor @Sendable (EngineOutput) -> Void = { [weak self] output in
            guard let self, output.windowRevision == self.activeRevision else { return }
            self.overlay.update(translations: output.translations, revision: output.windowRevision)
            self.statusHandler(.listening)
        }
        let stateHandler: @MainActor @Sendable (EngineState) -> Void = { [weak self] state in
            self?.statusHandler(MenuBarStatus(engineState: state))
        }
        scheduler = schedulerFactory(coordinator, outputHandler, stateHandler)
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        statusHandler(.listening)
        monitor.start()
    }

    public func stop() {
        isRunning = false
        activeRevision &+= 1
        captureTask?.cancel()
        captureTask = nil
        scheduler?.cancel()
        monitor.stop()
        overlay.hideAll()
        statusHandler(.off)
    }

    public func setVisionFallback(_ enabled: Bool) {
        visionFallbackEnabled = enabled
    }

    public func clearCache() async {
        await coordinator?.clearCache()
    }

    public func handleWindow(_ descriptor: ActiveWindowDescriptor?) {
        guard isRunning else { return }
        guard let descriptor else {
            cancelPendingWork()
            statusHandler(.listening)
            return
        }
        activeRevision = descriptor.revision
        captureTask?.cancel()
        scheduler?.cancel()
        overlay.hideAll()
        statusHandler(.listening)
        let expectedRevision = descriptor.revision
        let capture = self.capture
        captureTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                let snapshot = try await capture.capture(descriptor)
                try Task.checkCancellation()
                guard self.isRunning, self.activeRevision == expectedRevision else { return }
                guard !snapshot.regions.isEmpty else { return }
                statusHandler(.translating)
                scheduler?.submit(
                    snapshot: snapshot,
                    backend: backend,
                    modelIdentifier: model,
                    visionFallbackEnabled: visionFallbackEnabled
                )
                logger.event("capture_submitted", fields: [
                    "region_count": String(snapshot.regions.count),
                    "revision": String(expectedRevision)
                ])
            } catch is CancellationError {
            } catch let error as CaptureError {
                guard self.isRunning, self.activeRevision == expectedRevision else { return }
                handle(error)
            } catch {
                guard self.isRunning, self.activeRevision == expectedRevision else { return }
                logger.event("capture_failed", fields: ["status": "unknown"])
                statusHandler(.error)
            }
        }
    }

    private func cancelPendingWork() {
        activeRevision &+= 1
        captureTask?.cancel()
        captureTask = nil
        scheduler?.cancel()
        overlay.hideAll()
    }

    private func handle(_ error: CaptureError) {
        guard error != .cancelled else { return }
        let status: MenuBarStatus
        let code: String
        switch error {
        case .permissionRequired:
            status = .missingPermission
            code = "capture_permission_required"
        case .protected:
            status = .listening
            code = "capture_protected"
        case .excludedApplication:
            status = .listening
            code = "capture_excluded"
        case .selfApplication:
            status = .listening
            code = "capture_self"
        case .noActiveWindow:
            status = .listening
            code = "capture_no_window"
        case .accessibilityUnavailable, .captureFailed, .ocrFailed, .unsupported, .invalidWindow:
            status = .error
            code = "capture_failed"
        case .cancelled:
            return
        }
        logger.event(code, fields: ["status": status.rawValue])
        if status == .listening { overlay.hideAll() }
        statusHandler(status)
    }

    private func makeEventSink() -> EngineEventSink {
        { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handle(event)
            }
        }
    }

    private func handle(_ event: EngineEvent) {
        switch event {
        case .stateChanged(let state):
            logger.event("engine_state", fields: ["status": state.rawValue])
        case .snapshotReceived(let count, let revision):
            logger.event("engine_snapshot", fields: ["region_count": String(count), "revision": String(revision)])
        case .batchCompleted(let count):
            logger.event("engine_batch", fields: ["item_count": String(count)])
        case .completed(let metrics):
            logger.event("engine_completed", fields: [
                "status": metrics.status.rawValue,
                "translated_count": String(metrics.translatedRegionCount),
                "duration_ms": String(metrics.durationMilliseconds)
            ])
        case .failed(let status):
            logger.event("engine_failed", fields: ["status": status.rawValue])
        }
    }
}
