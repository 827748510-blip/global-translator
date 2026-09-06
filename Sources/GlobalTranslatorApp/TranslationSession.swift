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
    private let permissions: any PermissionControlling
    private let coordinatorFactory: CoordinatorFactory
    private let schedulerFactory: SchedulerFactory
    private let logger: any AppRuntimeLogger
    private let statusHandler: @MainActor @Sendable (MenuBarStatus) -> Void
    private var coordinator: (any TranslationCoordinating)?
    private var scheduler: (any TranslationScheduling)?
    private var captureTask: Task<Void, Never>?
    private var protectionTask: Task<Void, Never>?
    private var backend: BackendKind = .deepSeekCloud
    private var model = ""
    private var visionFallbackEnabled = false
    private var activeWindow: ActiveWindowDescriptor?
    private var lastRendered: [RenderedTranslation] = []

    public init(
        monitor: any ActiveWindowMonitoring,
        capture: any CapturePipelining,
        overlay: any OverlayControlling,
        permissions: any PermissionControlling = SystemPermissionController(),
        coordinatorFactory: @escaping CoordinatorFactory,
        schedulerFactory: @escaping SchedulerFactory,
        logger: any AppRuntimeLogger,
        statusHandler: @escaping @MainActor @Sendable (MenuBarStatus) -> Void
    ) {
        self.monitor = monitor
        self.capture = capture
        self.overlay = overlay
        self.permissions = permissions
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
            guard let self else { return }
            guard self.isRunning, output.windowRevision == self.activeRevision else {
                self.logger.event("overlay_discarded", fields: ["status": "stale", "revision": String(output.windowRevision)])
                return
            }
            let permission = self.permissions.snapshot
            do {
                try permission.validateCapture()
                for translation in output.translations {
                    try permission.validateCapture(source: translation.region.source == .accessibility ? .accessibility : .visionOCR)
                }
            } catch let error as CaptureError {
                self.handle(error)
                return
            } catch {
                self.cancelPendingWork()
                return
            }
            self.overlay.update(translations: output.translations, revision: output.windowRevision)
            self.lastRendered = output.translations
            var fields = ["region_count": String(output.translations.count), "revision": String(output.windowRevision)]
            if let panels = self.overlay as? OverlayPanelController { fields["panel_count"] = String(panels.panelCount) }
            self.logger.event("overlay_rendered", fields: fields)
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
        protectionTask?.cancel()
        protectionTask = nil
        activeWindow = nil
        lastRendered = []
        if let coordinator { Task { await coordinator.cancelPendingRequests() } }
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
        protectionTask?.cancel()
        protectionTask = nil
        guard let descriptor else {
            cancelPendingWork()
            statusHandler(.listening)
            return
        }
        activeRevision = descriptor.revision
        let sameGeometry = activeWindow?.pid == descriptor.pid && activeWindow?.windowID == descriptor.windowID && activeWindow?.frame == descriptor.frame
        logger.event("window_update", fields: ["status": descriptor.invalidatesOverlay || !sameGeometry ? "invalidate" : "metadata", "revision": String(descriptor.revision)])
        activeWindow = descriptor
        captureTask?.cancel()
        scheduler?.cancel()
        if descriptor.invalidatesOverlay || !sameGeometry {
            overlay.hideAll()
            lastRendered = []
        }
        statusHandler(.listening)
        let expectedRevision = descriptor.revision
        let capture = self.capture
        captureTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(120))
                let snapshot = try await capture.capture(descriptor)
                try Task.checkCancellation()
                guard self.isRunning, self.activeRevision == expectedRevision else { return }
                let permission = self.permissions.snapshot
                try permission.validateCapture(source: snapshot.source)
                self.monitor.setVisualUpdatesEnabled(permission.screenCaptureAuthorized)
                guard !snapshot.regions.isEmpty else {
                    self.overlay.hideAll()
                    self.lastRendered = []
                    return
                }
                if self.matchesRendered(snapshot.regions) { return }
                self.overlay.hideAll()
                self.lastRendered = []
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
                self.overlay.hideAll()
                self.lastRendered = []
                handle(error)
            } catch {
                guard self.isRunning, self.activeRevision == expectedRevision else { return }
                self.overlay.hideAll()
                self.lastRendered = []
                logger.event("capture_failed", fields: ["status": "unknown"])
                statusHandler(.error)
            }
        }
    }

    private func cancelPendingWork() {
        protectionTask?.cancel()
        protectionTask = nil
        activeWindow = nil
        lastRendered = []
        activeRevision &+= 1
        captureTask?.cancel()
        captureTask = nil
        scheduler?.cancel()
        if let coordinator { Task { await coordinator.cancelPendingRequests() } }
        monitor.setVisualUpdatesEnabled(false)
        overlay.hideAll()
    }

    private func waitForProtectionToEnd() {
        guard isRunning, protectionTask == nil else { return }
        monitor.setVisualUpdatesEnabled(false)
        protectionTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard let self, self.isRunning else { return }
                let permission = self.permissions.snapshot
                guard !permission.secureInputEnabled, !permission.sessionLocked else { continue }
                self.protectionTask = nil
                guard permission.accessibilityTrusted || permission.screenCaptureAuthorized else {
                    self.statusHandler(.missingPermission)
                    return
                }
                self.monitor.stop()
                self.monitor.start()
                return
            }
        }
    }

    private func matchesRendered(_ regions: [TextRegion]) -> Bool {
        guard !lastRendered.isEmpty else { return false }
        let eligible = regions.filter { TextFilter.shouldTranslate($0.sourceText) && $0.sourceText.count <= 4000 }
        return eligible.count == lastRendered.count && eligible.allSatisfy { region in
            lastRendered.contains { $0.region.sourceText == region.sourceText && $0.region.screenFrame == region.screenFrame }
        }
    }

    private func handle(_ error: CaptureError) {
        guard error != .cancelled else { return }
        if error == .unsupported || error == .captureFailed || error == .invalidWindow {
            monitor.retryCurrentWindowCapture()
        }
        let status: MenuBarStatus
        let code: String
        switch error {
        case .permissionRequired:
            cancelPendingWork()
            status = .missingPermission
            code = "capture_permission_required"
        case .protected:
            cancelPendingWork()
            waitForProtectionToEnd()
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
        var fields = ["status": status.rawValue]
        if code == "capture_failed" { fields["reason"] = error.description }
        logger.event(code, fields: fields)
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
        case .captureBlocked(let error, let revision):
            guard isRunning, revision == activeRevision else { return }
            handle(error)
        }
    }
}
