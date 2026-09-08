import Foundation
import GlobalTranslatorCapture
import GlobalTranslatorCore
import GlobalTranslatorEngine
import GlobalTranslatorUI

@MainActor
public final class TranslationSession {
    public private(set) var isRunning = false
    /// Menu-bar master switch for the extension bridge. Independent of
    /// `isRunning`, which only tracks window overlay capture.
    public private(set) var isBridgeActive = false
    public private(set) var activeRevision: UInt64 = 0

    private let monitor: any ActiveWindowMonitoring
    private let capture: any CapturePipelining
    private let overlay: any OverlayControlling
    private let permissions: any PermissionControlling
    private let coordinatorFactory: CoordinatorFactory
    private let schedulerFactory: SchedulerFactory
    private let logger: any AppRuntimeLogger
    private let statusHandler: @MainActor @Sendable (MenuBarStatus) -> Void
    /// When set (and applicable for the window's application), page text is
    /// replaced in place instead of drawing overlay bubbles.
    private let inPage: (any InPageTranslating)?
    /// Whitelist of applications eligible for translation; the in-page route
    /// must honor the same gate as the capture pipeline.
    private let translatedBundleIdentifiers: Set<String>
    private var inPageInFlight = false
    private var inPageCooldownUntil = Date.distantPast
    private var coordinator: (any TranslationCoordinating)?
    /// Dedicated coordinator for the browser-extension bridge. The bridge
    /// sends unversioned requests (revision 0), which the window pipeline's
    /// monotonically increasing revision gate would reject as stale — so the
    /// bridge must never share that coordinator.
    private var bridgeCoordinator: (any TranslationCoordinating)?
    private var scheduler: (any TranslationScheduling)?
    private var captureTask: Task<Void, Never>?
    private var protectionTask: Task<Void, Never>?
    private var backend: BackendKind = .deepSeekCloud
    private var model = ""
    private var visionFallbackEnabled = false
    private var activeWindow: ActiveWindowDescriptor?
    private var lastRendered: [RenderedTranslation] = []
    private var submittedRevision: UInt64?
    private var submittedRegions: [TextRegion] = []
    private var confirmedRevision: UInt64?
    private var confirmedRegions: [TextRegion] = []
    private var deferredOutput: EngineOutput?

    public init(
        monitor: any ActiveWindowMonitoring,
        capture: any CapturePipelining,
        overlay: any OverlayControlling,
        permissions: any PermissionControlling = SystemPermissionController(),
        coordinatorFactory: @escaping CoordinatorFactory,
        schedulerFactory: @escaping SchedulerFactory,
        logger: any AppRuntimeLogger,
        statusHandler: @escaping @MainActor @Sendable (MenuBarStatus) -> Void,
        inPage: (any InPageTranslating)? = nil,
        translatedBundleIdentifiers: Set<String> = []
    ) {
        self.monitor = monitor
        self.capture = capture
        self.overlay = overlay
        self.permissions = permissions
        self.coordinatorFactory = coordinatorFactory
        self.schedulerFactory = schedulerFactory
        self.logger = logger
        self.statusHandler = statusHandler
        self.inPage = inPage
        self.translatedBundleIdentifiers = translatedBundleIdentifiers
    }

    public func configure(
        backends: [any TranslationBackend],
        backend: BackendKind,
        model: String,
        visionFallbackEnabled: Bool,
        bridgeBackends: [any TranslationBackend]? = nil
    ) {
        stop()
        self.backend = backend
        self.model = model
        self.visionFallbackEnabled = visionFallbackEnabled
        let coordinator = coordinatorFactory(backends, makeEventSink())
        self.coordinator = coordinator
        // A dedicated backend instance (when provided) so overlay coalescing
        // cannot cancel in-flight extension translations.
        self.bridgeCoordinator = coordinatorFactory(bridgeBackends ?? backends, makeEventSink())
        let outputHandler: @MainActor @Sendable (EngineOutput) -> Void = { [weak self] output in
            self?.receive(output)
        }
        let stateHandler: @MainActor @Sendable (EngineState) -> Void = { [weak self] state in
            guard let self, self.isRunning else { return }
            if state == .backendError || state == .circuitOpen || state == .missingPermission {
                self.cancelTranslation()
            }
            self.statusHandler(MenuBarStatus(engineState: state))
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
        // Keep both coordinators. stop/start only pauses window tracking; the
        // extension bridge stays available while `isBridgeActive` is true,
        // including after a permission-refresh bounce that calls stop() then
        // start() without configure(). Do not cancel in-flight bridge work.
        activeRevision &+= 1
        captureTask?.cancel()
        captureTask = nil
        cancelTranslation()
        confirmedRevision = nil
        confirmedRegions = []
        monitor.stop()
        overlay.hideAll()
        statusHandler(.off)
    }

    public func setVisionFallback(_ enabled: Bool) {
        visionFallbackEnabled = enabled
    }

    /// The extension bridge follows the menu-bar master switch, not window
    /// capture. `stop()` / `start()` only pause overlay tracking.
    public func setBridgeActive(_ active: Bool) {
        isBridgeActive = active
    }

    public func clearCache() async {
        await coordinator?.clearCache()
    }

    /// Translates texts arriving from the browser-extension bridge. Bypasses
    /// window tracking entirely — no overlays, no revisions — and uses a
    /// dedicated coordinator so the window pipeline's revision gate cannot
    /// reject these unversioned requests. The returned array is aligned with
    /// the input order; nil marks entries filtered out or left untranslated.
    /// Gated on `isBridgeActive` (the menu-bar master switch) rather than
    /// `isRunning`, so Chrome in-page translation works without Accessibility
    /// or Screen Recording. The coordinator itself outlives stop/start;
    /// only `configure()` replaces it.
    ///
    /// Local backends are translated one string at a time so a dense page
    /// (X.com, 30+ strings) cannot pile sequential Ollama round-trips into
    /// a single JSON-schema call that dies as `networkFailure` and opens the
    /// circuit. Transient item failures become nil rather than failing the
    /// whole HTTP request.
    public func translateBridgeTexts(_ texts: [String]) async throws -> [String?] {
        guard isBridgeActive else { throw ExtensionBridgeError.translatorInactive }
        guard bridgeCoordinator != nil else { throw ExtensionBridgeError.translatorUnavailable }
        let capped = Array(texts.prefix(400))
        if backend == .local {
            var results: [String?] = []
            results.reserveCapacity(capped.count)
            for text in capped {
                guard isBridgeActive else { throw ExtensionBridgeError.translatorInactive }
                do {
                    let part = try await translateBridgeSlice([text])
                    results.append(contentsOf: part)
                } catch let error as ExtensionBridgeError {
                    throw error
                } catch {
                    logger.event("bridge_item_failed", fields: ["reason": String(describing: error)])
                    results.append(nil)
                }
            }
            return results
        }
        return try await translateBridgeSlice(capped)
    }

    private func translateBridgeSlice(_ texts: [String]) async throws -> [String?] {
        guard let coordinator = bridgeCoordinator else { throw ExtensionBridgeError.translatorUnavailable }
        let regions = texts.map { text in
            TextRegion(id: UUID(), sourceText: text, screenFrame: .zero,
                       confidence: 1, source: .accessibility, windowRevision: 0)
        }
        let eligible = regions.filter { TextFilter.shouldTranslate($0.sourceText) && $0.sourceText.count <= 4_000 }
        guard !eligible.isEmpty else { return texts.map { _ in nil } }
        let descriptor = ActiveWindowDescriptor(
            pid: 0, bundleIdentifier: "extension.bridge", windowID: nil,
            frame: .zero, revision: 0, invalidatesOverlay: false)
        let snapshot = CaptureSnapshot(window: CapturedWindow(descriptor: descriptor, regions: eligible, source: .pageText))
        await coordinator.selectBackend(kind: backend, modelIdentifier: model)
        let output = try await coordinator.translate(
            snapshot: snapshot,
            backend: backend,
            modelIdentifier: model,
            visionFallbackEnabled: visionFallbackEnabled
        )
        var translated: [UUID: String] = [:]
        for translation in output.translations where !translation.text.isEmpty {
            translated[translation.region.id] = translation.text
        }
        return regions.map { translated[$0.id] }
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
        let sameWindow = activeWindow?.pid == descriptor.pid && activeWindow?.windowID == descriptor.windowID
        let sameGeometry = sameWindow && activeWindow?.frame == descriptor.frame
        logger.event("window_update", fields: ["status": descriptor.invalidatesOverlay || !sameGeometry ? "invalidate" : "metadata", "revision": String(descriptor.revision)])
        activeRevision = descriptor.revision
        activeWindow = descriptor
        captureTask?.cancel()
        if descriptor.invalidatesOverlay || !sameGeometry {
            // Visual churn (scrolls, redraws, AX notifications) must NOT kill
            // an in-flight request: the recapture below confirms whether the
            // text is unchanged (deferred output re-renders at the new
            // coordinates) or different (then we cancel and resubmit).
            confirmedRevision = nil
            confirmedRegions = []
            lastRendered = []
            // Existing bubbles stay on screen while the recapture/translation
            // settles — busy pages invalidate constantly and wiping here made
            // translations flash away faster than they could render. Only a
            // genuine window switch clears immediately.
            if !sameWindow {
                overlay.hideAll()
            }
        }
        statusHandler(.listening)
        let expectedRevision = descriptor.revision
        let capture = self.capture
        let inPage = self.inPage
        captureTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Browsers with a reachable in-page channel translate inside the
            // page (like native browser translation) — but only when the
            // focused window belongs to the debug-enabled browser instance:
            // isApplicable matches the window PID against the CDP browser
            // process, so windows of another browser process with the same
            // bundle identifier (main Chrome without a debug port) fall
            // through to bubbles instead of being silently swallowed. Once
            // the channel answers for this window it OWNS it: bubbles never
            // appear, even while the channel cools down or the page currently
            // has nothing translatable. Only a genuine channel failure drops
            // to the bubble pipeline.
            if let inPage,
               translatedBundleIdentifiers.contains(descriptor.bundleIdentifier),
               await inPage.isApplicable(bundleIdentifier: descriptor.bundleIdentifier, windowPID: descriptor.pid) {
                guard Date() >= self.inPageCooldownUntil else { return }
                guard !self.inPageInFlight else { return }
                self.inPageInFlight = true
                defer { self.inPageInFlight = false }
                switch await self.runInPageTranslation(descriptor: descriptor, inPage: inPage) {
                case .applied(let count) where count > 0:
                    return
                case .applied:
                    // Page already translated / nothing eligible: stay quiet,
                    // never fall back to bubbles on a healthy channel.
                    self.inPageCooldownUntil = Date().addingTimeInterval(5)
                    return
                case .channelFailed:
                    self.inPageCooldownUntil = Date().addingTimeInterval(5)
                }
            }
            await self.runCapturePipeline(descriptor: descriptor, expectedRevision: expectedRevision, capture: capture)
        }
    }

    private func runCapturePipeline(descriptor: ActiveWindowDescriptor, expectedRevision: UInt64, capture: any CapturePipelining) async {
        do {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(120))
            let snapshot = try await capture.capture(descriptor)
            try Task.checkCancellation()
            guard self.isRunning, self.activeRevision == expectedRevision else { return }
            let permission = self.permissions.snapshot
            try permission.validateCapture(source: snapshot.source)
            self.monitor.setVisualUpdatesEnabled(permission.screenCaptureAuthorized)
            let eligible = snapshot.regions.filter { TextFilter.shouldTranslate($0.sourceText) && $0.sourceText.count <= 4000 }
            self.confirmedRevision = expectedRevision
            self.confirmedRegions = eligible
            if self.submittedRevision != nil, self.sameContent(self.submittedRegions, eligible) {
                if let output = self.deferredOutput { self.receive(output) }
                return
            }
            // A deferred output (translation finished after the page already
            // moved on) must not be discarded wholesale: regions whose text
            // is still on screen render immediately at the fresh coordinates,
            // and only genuinely new text waits for the resubmission below.
            // Live pages (timeline counters, "show N posts" pills) otherwise
            // churn faster than translations complete and bubbles never show.
            let deferred = self.deferredOutput
            self.cancelTranslation()
            var retained = self.reusableTranslations(for: eligible)
            if let deferred {
                retained.append(contentsOf: self.deferredTranslations(deferred, matching: eligible, excluding: retained))
            }
            if self.display(retained, revision: expectedRevision) {
                self.logger.event("overlay_reused", fields: ["region_count": String(retained.count), "revision": String(expectedRevision)])
            }
            guard retained.count < eligible.count else { return }
            self.submittedRevision = expectedRevision
            self.submittedRegions = eligible
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
            self.cancelTranslation()
            self.confirmedRevision = nil
            self.confirmedRegions = []
            self.overlay.hideAll()
            self.lastRendered = []
            handle(error)
        } catch {
            guard self.isRunning, self.activeRevision == expectedRevision else { return }
            self.cancelTranslation()
            self.confirmedRevision = nil
            self.confirmedRegions = []
            self.overlay.hideAll()
            self.lastRendered = []
            logger.event("capture_failed", fields: ["status": "unknown"])
            statusHandler(.error)
        }
    }

    private func cancelTranslation() {
        scheduler?.cancel()
        submittedRevision = nil
        submittedRegions = []
        deferredOutput = nil
    }

    /// Result of an in-page translation attempt. The bubble pipeline is only
    /// retried on `.channelFailed`; a healthy channel that extracted or
    /// applied nothing means the page simply has nothing to translate.
    private enum InPageOutcome {
        case applied(Int)
        case channelFailed
    }

    /// Replaces page text in place: extract -> translate via the shared
    /// coordinator -> apply. Overlay bubbles are never used on this path.
    private func runInPageTranslation(descriptor: ActiveWindowDescriptor, inPage: any InPageTranslating) async -> InPageOutcome {
        do {
            logger.event("inpage_stage", fields: ["stage": "extract"])
            let texts = try await inPage.extract(windowRevision: descriptor.revision)
            logger.event("inpage_stage", fields: ["stage": "extracted", "count": String(texts.count)])
            guard !texts.isEmpty else { return .applied(0) }
            overlay.hideAll()
            lastRendered = []
            statusHandler(.translating)
            let regions = texts.map { text in
                TextRegion(id: text.id, sourceText: text.text, screenFrame: .zero,
                           confidence: 1, source: .accessibility, windowRevision: descriptor.revision)
            }
            let snapshot = CaptureSnapshot(window: CapturedWindow(
                descriptor: descriptor, regions: regions, source: .pageText))
            guard let coordinator else { return .channelFailed }
            await coordinator.selectBackend(kind: backend, modelIdentifier: model)
            logger.event("inpage_stage", fields: ["stage": "translating", "count": String(regions.count)])
            let output = try await coordinator.translate(
                snapshot: snapshot,
                backend: backend,
                modelIdentifier: model,
                visionFallbackEnabled: visionFallbackEnabled
            )
            let nodeByRegion = Dictionary(uniqueKeysWithValues: texts.map { ($0.id, $0.nodeID) })
            let replacements = output.translations.compactMap { translation -> InPageReplacement? in
                guard let nodeID = nodeByRegion[translation.region.id], !translation.text.isEmpty else { return nil }
                return InPageReplacement(nodeID: nodeID, text: translation.text)
            }
            try await inPage.apply(replacements)
            logger.event("inpage_rendered", fields: [
                "count": String(replacements.count), "revision": String(descriptor.revision)
            ])
            statusHandler(.listening)
            return .applied(replacements.count)
        } catch is CancellationError {
            return .applied(0)
        } catch let error as CustomStringConvertible {
            logger.event("inpage_failed", fields: ["status": "error", "reason": error.description])
            statusHandler(.listening)
            return .channelFailed
        } catch {
            logger.event("inpage_failed", fields: ["status": "error"])
            statusHandler(.listening)
            return .channelFailed
        }
    }

    private func sameContent(_ lhs: [TextRegion], _ rhs: [TextRegion]) -> Bool {
        lhs.map { "\($0.source.rawValue):\($0.sourceText)" }.sorted()
            == rhs.map { "\($0.source.rawValue):\($0.sourceText)" }.sorted()
    }

    private func receive(_ output: EngineOutput) {
        guard isRunning, output.windowRevision == submittedRevision else {
            logger.event("overlay_discarded", fields: ["status": "stale", "revision": String(output.windowRevision)])
            return
        }
        do {
            let permission = permissions.snapshot
            try permission.validateCapture()
            for translation in output.translations {
                try permission.validateCapture(source: translation.region.source == .accessibility ? .accessibility : .visionOCR)
            }
        } catch let error as CaptureError {
            handle(error)
            return
        } catch {
            cancelPendingWork()
            return
        }
        guard confirmedRevision == activeRevision else {
            deferredOutput = output
            return
        }
        guard sameContent(submittedRegions, confirmedRegions) else { return }
        var available = output.translations
        let remapped = confirmedRegions.compactMap { region -> RenderedTranslation? in
            guard let index = available.firstIndex(where: {
                $0.region.sourceText == region.sourceText && $0.region.source == region.source
            }) else { return nil }
            return RenderedTranslation(region: region, text: available.remove(at: index).text)
        }
        let translations = preservingIdentifiers(remapped)
        let updated = display(translations, revision: activeRevision)
        submittedRevision = nil
        submittedRegions = []
        deferredOutput = nil
        logger.event(updated ? "overlay_rendered" : "overlay_unchanged", fields: [
            "region_count": String(translations.count), "revision": String(activeRevision)
        ])
        statusHandler(.listening)
    }

    private func cancelPendingWork() {
        protectionTask?.cancel()
        protectionTask = nil
        activeWindow = nil
        lastRendered = []
        activeRevision &+= 1
        captureTask?.cancel()
        captureTask = nil
        cancelTranslation()
        confirmedRevision = nil
        confirmedRegions = []
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
                guard permission.hasCaptureAccess else {
                    self.statusHandler(.missingPermission)
                    return
                }
                self.monitor.stop()
                self.monitor.start()
                return
            }
        }
    }

    private func reusableTranslations(for regions: [TextRegion]) -> [RenderedTranslation] {
        var previous = lastRendered
        return regions.compactMap { region in
            guard let index = previous.firstIndex(where: { $0.region.sourceText == region.sourceText }) else { return nil }
            let retained = previous.remove(at: index)
            return RenderedTranslation(region: identifiedRegion(region, id: retained.id), text: retained.text)
        }
    }

    /// Deferred translations whose source text is still on screen, remapped
    /// onto the freshly captured regions so they render at the current
    /// coordinates. Regions already covered by `retained` are skipped.
    private func deferredTranslations(_ output: EngineOutput, matching regions: [TextRegion], excluding retained: [RenderedTranslation]) -> [RenderedTranslation] {
        var available = output.translations
        return regions.compactMap { region in
            guard !retained.contains(where: { $0.region.sourceText == region.sourceText }),
                  let index = available.firstIndex(where: {
                      $0.region.sourceText == region.sourceText && $0.region.source == region.source
                  }) else { return nil }
            return RenderedTranslation(region: region, text: available.remove(at: index).text)
        }
    }

    private func preservingIdentifiers(_ translations: [RenderedTranslation]) -> [RenderedTranslation] {
        var previous = lastRendered
        return translations.map { translation in
            guard let index = previous.firstIndex(where: { $0.region.sourceText == translation.region.sourceText }) else { return translation }
            let retained = previous.remove(at: index)
            return RenderedTranslation(region: identifiedRegion(translation.region, id: retained.id), text: translation.text)
        }
    }

    private func identifiedRegion(_ region: TextRegion, id: UUID) -> TextRegion {
        TextRegion(id: id, sourceText: region.sourceText, screenFrame: region.screenFrame, confidence: region.confidence,
                   source: region.source, windowRevision: region.windowRevision)
    }

    @discardableResult
    private func display(_ translations: [RenderedTranslation], revision: UInt64) -> Bool {
        let changed = translations.count != lastRendered.count || translations.contains { translation in
            !lastRendered.contains { previous in
                previous.id == translation.id && previous.text == translation.text && previous.region.screenFrame == translation.region.screenFrame
            }
        }
        if changed { overlay.update(translations: translations, revision: revision) }
        lastRendered = translations
        return changed
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
            guard isRunning, revision == activeRevision || revision == submittedRevision else { return }
            handle(error)
        }
    }
}
