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
    /// Model id last passed to `configure`. Used to detect a stale
    /// `DeepSeekBackend` after health adopts a different identifier.
    public var configuredModel: String { model }
    public private(set) var activeRevision: UInt64 = 0
    /// Frontmost translated window, used by B2 window-audio capture.
    public var currentWindow: ActiveWindowDescriptor? { activeWindow }

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
    /// Dedicated coordinator for 滑词翻译 so overlay/bridge revision gates
    /// and coalescers cannot cancel or stale a selection request.
    private var selectionCoordinator: (any TranslationCoordinating)?
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
    /// Dedicated 滑词 coordinator still has a monotonic revision gate.
    /// Chunked selections must never restart at 1, or the next selection is stale.
    private var selectionRevision: UInt64 = 0

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
        bridgeBackends: [any TranslationBackend]? = nil,
        selectionBackends: [any TranslationBackend]? = nil
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
        self.selectionCoordinator = coordinatorFactory(
            selectionBackends ?? bridgeBackends ?? backends,
            makeEventSink()
        )
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

    /// The extension bridge follows the menu-bar master switch, not window
    /// capture. `stop()` / `start()` only pause overlay tracking.
    public func setBridgeActive(_ active: Bool) {
        isBridgeActive = active
        guard active, let activeWindow, shouldSkipOverlayForExtensionBridge(activeWindow.bundleIdentifier) else {
            return
        }
        overlay.hideAll()
        cancelTranslation()
        captureTask?.cancel()
        captureTask = nil
        logger.event("window_skipped_for_bridge", fields: [
            "bundle": activeWindow.bundleIdentifier,
            "revision": String(activeWindow.revision)
        ])
    }

    /// Chromium windows are translated by the extension. Overlay AX/OCR of
    /// Chrome while a bridge batch is in flight starves local Ollama.
    private func shouldSkipOverlayForExtensionBridge(_ bundleIdentifier: String) -> Bool {
        isBridgeActive && ChromiumBrowserBundles.contains(bundleIdentifier)
    }

    public func clearCache() async {
        await coordinator?.clearCache()
    }

    /// Translates texts arriving from the browser-extension bridge. Bypasses
    /// window tracking entirely — no overlays, no revisions — and uses a
    /// dedicated coordinator so the window pipeline's revision gate cannot
    /// reject these unversioned requests. The returned batch is aligned with
    /// the input order. Ineligible fragments (already Chinese, URLs,
    /// identifiers) return their source text as a successful keep-source
    /// result and never reach the backend. Transient local-backend failures
    /// are `nil` and listed in `retryIndexes` so the extension does not
    /// treat them as already asked.
    /// Gated on `isBridgeActive` (the menu-bar master switch) rather than
    /// `isRunning`, so Chrome in-page translation works without Accessibility
    /// or Screen Recording. The coordinator itself outlives stop/start;
    /// only `configure()` replaces it.
    ///
    /// Local backends are translated in small chunks so a dense page
    /// (X.com, 30+ strings) cannot pile one 30-item JSON-schema call that
    /// dies as `networkFailure`. Chunk size matches
    /// `TranslationCoordinator.localPageTextBatchSize` and the extension
    /// `CHUNK_SIZE`. Transient chunk failures do not 500 the whole HTTP
    /// request; those indexes go back to the extension as `retry`.
    public func translateBridgeTexts(_ texts: [String], sourceLanguage: TranslationSourceLanguage? = nil) async throws -> ExtensionBridgeTranslation {
        guard isBridgeActive else { throw ExtensionBridgeError.translatorInactive }
        guard bridgeCoordinator != nil else { throw ExtensionBridgeError.translatorUnavailable }
        let capped = Array(texts.prefix(400))
        if backend == .local {
            var results: [String?] = []
            var retryIndexes: [Int] = []
            results.reserveCapacity(capped.count)
            let chunkSize = TranslationCoordinator.localPageTextBatchSize
            var index = 0
            while index < capped.count {
                guard isBridgeActive else { throw ExtensionBridgeError.translatorInactive }
                let end = min(index + chunkSize, capped.count)
                let slice = Array(capped[index..<end])
                do {
                    let part = try await translateBridgeSlice(slice, sourceLanguage: sourceLanguage)
                    results.append(contentsOf: part)
                } catch let error as ExtensionBridgeError {
                    throw error
                } catch {
                    logger.event("bridge_item_failed", fields: ["reason": String(describing: error)])
                    for offset in 0..<slice.count {
                        results.append(nil)
                        retryIndexes.append(index + offset)
                    }
                }
                index = end
            }
            return ExtensionBridgeTranslation(translations: results, retryIndexes: retryIndexes)
        }
        do {
            return ExtensionBridgeTranslation(translations: try await translateBridgeSlice(capped, sourceLanguage: sourceLanguage))
        } catch let error as ExtensionBridgeError {
            throw error
        } catch {
            // Invalid model JSON used to 500 the whole /translate call, so
            // video cues stayed on `wait` with an empty overlay. Return retry
            // indexes like the local path; the extension can wait, then show
            // 翻译服务不可用 without stopping playback.
            logger.event("bridge_item_failed", fields: ["reason": String(describing: error)])
            return ExtensionBridgeTranslation(
                translations: Array(repeating: nil, count: capped.count),
                retryIndexes: Array(capped.indices)
            )
        }
    }

    private func translateBridgeSlice(_ texts: [String], sourceLanguage: TranslationSourceLanguage?) async throws -> [String?] {
        guard let coordinator = bridgeCoordinator else { throw ExtensionBridgeError.translatorUnavailable }
        let regions = texts.map { text in
            TextRegion(id: UUID(), sourceText: text, screenFrame: .zero,
                       confidence: 1, source: .accessibility, windowRevision: 0)
        }
        let eligible = regions.filter { TextFilter.shouldTranslate($0.sourceText, sourceLanguage: sourceLanguage) && $0.sourceText.count <= 4_000 }
        let eligibleIDs = Set(eligible.map(\.id))
        guard !eligible.isEmpty else { return texts.map { $0 as String? } }
        let descriptor = ActiveWindowDescriptor(
            pid: 0, bundleIdentifier: "extension.bridge", windowID: nil,
            frame: .zero, revision: 0, invalidatesOverlay: false)
        let snapshot = CaptureSnapshot(
            window: CapturedWindow(descriptor: descriptor, regions: eligible, source: .pageText),
            sourceLanguage: sourceLanguage
        )
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
        return regions.map { region in
            if let text = translated[region.id] { return text }
            if !eligibleIDs.contains(region.id) { return region.sourceText }
            return nil
        }
    }

    /// Single-string 滑词翻译. Not gated on overlay `isRunning` or the
    /// extension-bridge master switch; uses a dedicated coordinator so Chrome
    /// overlay-skip and bridge batches cannot stale this request.
    ///
    /// A detected code snippet is explained (not transpiled) through a separate
    /// plain-completion prompt before the prose filter runs. Some valid
    /// snippets (`foo()`, `x = 1`) look like identifiers to `TextFilter` and
    /// would otherwise be skipped without a popover.
    public func translateSelection(_ text: String) async throws -> SelectionTranslationOutcome {
        guard let coordinator = selectionCoordinator else { throw SelectionTranslateError.translatorUnavailable }
        let limited = SelectionTranslateSupport.limitSelectionSource(text)
        if let detection = CodeSnippetDetector.detect(limited.text) {
            return try await translateCodeSelection(
                text,
                detection: detection,
                coordinator: coordinator
            )
        }
        // 双向互译：简体中文源 → 英文；其余可翻译文本 → 简体中文。标识符 / URL
        // 仍然不弹层。
        switch TextFilter.selectionDecision(limited.text) {
        case .translate, .noTranslationNeeded, .alreadyTargetLanguage:
            break
        case .skip:
            throw SelectionTranslateError.emptyResult
        }
        // 方向先定，分片才能按目标语言的膨胀率取上限（中→英要留出加倍的输出空间）。
        let direction = TextFilter.selectionDirection(limited.text) ?? .toChinese
        let plan = SelectionTranslateSupport.prepareSource(text, direction: direction)
        guard !plan.chunks.isEmpty else { throw SelectionTranslateError.emptyResult }
        await coordinator.selectBackend(kind: backend, modelIdentifier: model)
        var parts: [String] = []
        parts.reserveCapacity(plan.chunks.count)
        for chunk in plan.chunks {
            try Task.checkCancellation()
            do {
                let translated = try await translateOneSelectionChunk(
                    chunk,
                    coordinator: coordinator,
                    revision: nextSelectionRevision(),
                    direction: direction
                )
                parts.append(translated)
            } catch let error as SelectionTranslateError
                where error == .noTranslationNeeded && plan.chunks.count > 1 {
                // One short brand-name chunk inside a longer selection must not
                // turn the whole translation into 「专有名词，无需翻译」.
                throw SelectionTranslateError.emptyResult
            }
        }
        let joined = SelectionTranslateSupport.joinTranslatedChunks(parts)
        guard !joined.isEmpty else { throw SelectionTranslateError.emptyResult }
        return SelectionTranslationOutcome(text: joined, sourceWasTruncated: plan.didTruncate)
    }

    /// Code selections use plain completion: the prose JSON schema and the
    /// copied-source quality gate are wrong for an explanation. Chunking is
    /// line-aware so a long snippet is not cut through the middle of a token.
    private func translateCodeSelection(
        _ text: String,
        detection: CodeSnippetDetection,
        coordinator: any TranslationCoordinating
    ) async throws -> SelectionTranslationOutcome {
        let plan = CodeTranslationSupport.prepareSource(text)
        guard !plan.chunks.isEmpty else { throw SelectionTranslateError.emptyResult }
        // Code has no reliable natural-language direction: a Chinese comment
        // does not make an English-language snippet a Chinese source. Use the
        // app's Simplified Chinese target instead of the prose auto-direction.
        let direction = SelectionTranslationDirection.toChinese
        logger.event("selection_code_detected", fields: ["language": detection.language.displayName])
        await coordinator.selectBackend(kind: backend, modelIdentifier: model)
        var parts: [String] = []
        parts.reserveCapacity(plan.chunks.count)
        for (index, chunk) in plan.chunks.enumerated() {
            try Task.checkCancellation()
            let raw = try await coordinator.completePlain(
                system: CodeTranslationInstructions.system(
                    for: direction,
                    language: detection.language
                ),
                user: CodeTranslationInstructions.userContent(
                    for: chunk,
                    language: detection.language,
                    partIndex: index + 1,
                    partCount: plan.chunks.count
                ),
                backend: backend
            )
            try Task.checkCancellation()
            let explanation = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !explanation.isEmpty else { throw SelectionTranslateError.emptyResult }
            let source = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            guard explanation.caseInsensitiveCompare(source) != .orderedSame else {
                // An echoed snippet is not an explanation. Fail honestly rather
                // than showing raw code as the translated result.
                throw SelectionTranslateError.emptyResult
            }
            parts.append(explanation)
        }
        let joined = SelectionTranslateSupport.joinTranslatedChunks(parts)
        guard !joined.isEmpty else { throw SelectionTranslateError.emptyResult }
        logger.event("selection_code_translated", fields: [
            "language": detection.language.displayName,
            "status": "success",
            "part_count": String(plan.chunks.count)
        ])
        return SelectionTranslationOutcome(text: joined, sourceWasTruncated: plan.didTruncate)
    }

    private func translateOneSelectionChunk(
        _ text: String,
        coordinator: any TranslationCoordinating,
        revision: UInt64,
        direction: SelectionTranslationDirection
    ) async throws -> String {
        do {
            return try await structuredSelectionChunk(
                text,
                coordinator: coordinator,
                revision: revision,
                direction: direction
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as TranslationError {
            guard Self.isRecoverableSelectionFailure(error) else {
                throw Self.selectionError(from: error)
            }
            return try await plainSelectionFallback(
                text,
                coordinator: coordinator,
                reason: Self.fallbackReason(for: error),
                direction: direction
            )
        } catch let error as SelectionTranslateError where error == .emptyResult {
            return try await plainSelectionFallback(
                text,
                coordinator: coordinator,
                reason: "empty",
                direction: direction
            )
        }
    }

    private func structuredSelectionChunk(
        _ text: String,
        coordinator: any TranslationCoordinating,
        revision: UInt64,
        direction: SelectionTranslationDirection
    ) async throws -> String {
        let region = TextRegion(
            id: UUID(),
            sourceText: text,
            screenFrame: .zero,
            confidence: 1,
            source: .accessibility,
            windowRevision: revision
        )
        let descriptor = ActiveWindowDescriptor(
            pid: 0,
            bundleIdentifier: "selection.translate",
            windowID: nil,
            frame: .zero,
            revision: revision,
            invalidatesOverlay: false
        )
        let snapshot = CaptureSnapshot(
            window: CapturedWindow(descriptor: descriptor, regions: [region], source: .pageText)
        )
        let output: EngineOutput
        do {
            output = try await Self.runSelectionTranslate(
                coordinator,
                snapshot: snapshot,
                backend: backend,
                model: model,
                targetLanguage: direction.targetLanguage
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as TranslationError {
            throw error
        }
        let translated = output.translations.first(where: { !$0.text.isEmpty })?.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let translated, !translated.isEmpty else { throw SelectionTranslateError.emptyResult }
        return translated
    }

    /// Format / quality failures are worth one plain-text retry: local models
    /// return brand names verbatim ("Figma", "Python", "npm") and occasionally
    /// emit truncated JSON, both of which surfaced as 「翻译失败」. Network,
    /// credential, and timeout failures are *not* replayed.
    private static func isRecoverableSelectionFailure(_ error: TranslationError) -> Bool {
        if case .invalidResponse = error { return true }
        return false
    }

    private static func fallbackReason(for error: TranslationError) -> String {
        if case .invalidResponse(let message) = error, message.contains("copied the source") {
            return "copied_source"
        }
        return "invalid_response"
    }

    /// Plain completion for 滑词. A proper-noun echo becomes
    /// 「专有名词，无需翻译」 instead of a red failure; a genuine translation is
    /// returned as-is. Long chunks stay on the structured path because the
    /// plain completion budget could silently truncate them.
    private func plainSelectionFallback(
        _ text: String,
        coordinator: any TranslationCoordinating,
        reason: String,
        direction: SelectionTranslationDirection
    ) async throws -> String {
        guard text.count <= SelectionTranslateSupport.plainFallbackMaxCharacters else {
            logger.event("selection_plain_fallback", fields: ["status": "skipped", "reason": "too_long"])
            throw SelectionTranslateError.emptyResult
        }
        let raw: String
        do {
            raw = try await coordinator.completePlain(
                system: SelectionFallbackInstructions.system(for: direction),
                user: SelectionFallbackInstructions.userContent(for: text),
                backend: backend
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.event("selection_plain_fallback", fields: ["status": "failed", "reason": reason])
            throw SelectionTranslateError.emptyResult
        }
        let cleaned = SelectionTranslateSupport.cleanPlainFallback(raw, original: text)
        guard !cleaned.isEmpty else {
            logger.event("selection_plain_fallback", fields: ["status": "failed", "reason": reason])
            throw SelectionTranslateError.emptyResult
        }
        if CopiedSourceDetector.translationCopiesSource(cleaned, source: text) {
            // A brand / product name is a soft skip. An echoed sentence means
            // the retry failed too, so keep it an honest failure.
            let properNoun = SelectionTranslateSupport.isProperNounPhrase(text)
            logger.event(
                "selection_plain_fallback",
                fields: ["status": properNoun ? "copied_source" : "failed", "reason": reason]
            )
            if properNoun {
                throw SelectionTranslateError.noTranslationNeeded
            }
            throw SelectionTranslateError.emptyResult
        }
        logger.event("selection_plain_fallback", fields: ["status": "success", "reason": reason])
        return cleaned
    }

    private func nextSelectionRevision() -> UInt64 {
        selectionRevision &+= 1
        return selectionRevision
    }

    private static func runSelectionTranslate(
        _ coordinator: any TranslationCoordinating,
        snapshot: CaptureSnapshot,
        backend: BackendKind,
        model: String,
        targetLanguage: String
    ) async throws -> EngineOutput {
        if let live = coordinator as? TranslationCoordinator {
            return try await live.translate(
                snapshot: snapshot,
                backend: backend,
                modelIdentifier: model,
                visionFallbackEnabled: false,
                includeIneligibleText: true,
                targetLanguage: targetLanguage
            )
        }
        return try await coordinator.translate(
            snapshot: snapshot,
            backend: backend,
            modelIdentifier: model,
            visionFallbackEnabled: false
        )
    }

    private static func selectionError(from error: TranslationError) -> Error {
        switch error {
        case .invalidResponse, .invalidRequest:
            return SelectionTranslateError.emptyResult
        default:
            return error
        }
    }

    /// Scene-based rewrite. Allows Simplified Chinese drafts (the
    /// already-Chinese skip is translate-only). Uses the selection coordinator's
    /// `completePlain` so overlay/bridge JSON translation is not involved.
    public func optimizePrompt(_ text: String) async throws -> String {
        try await optimizePrompt(text, mode: .communicationPolish)
    }

    public func optimizePrompt(_ text: String, mode: PromptOptimizeMode) async throws -> String {
        guard let coordinator = selectionCoordinator else { throw SelectionTranslateError.translatorUnavailable }
        let capped = SelectionTranslateSupport.cappedSource(text)
        guard TextFilter.shouldOfferPromptOptimization(capped) else {
            throw SelectionTranslateError.emptyResult
        }
        await coordinator.selectBackend(kind: backend, modelIdentifier: model)
        let optimized = try await coordinator.completePlain(
            system: PromptOptimizationInstructions.system(for: mode),
            user: PromptOptimizationInstructions.userContent(for: capped, mode: mode),
            backend: backend
        )
        let trimmed = optimized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SelectionTranslateError.emptyResult }
        return trimmed
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
            // process. Main Chrome without a debug port is owned by the
            // extension bridge: overlay AX/OCR is skipped so it cannot race
            // local Ollama. A genuine CDP failure also skips overlay while
            // the bridge is on. Other apps still use bubbles.
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
            // Normal Chrome (no debug port) used to fall through to overlay
            // bubbles. With the extension bridge on, that AX scrape races
            // `bridge_translate` on the same local Ollama process.
            if self.shouldSkipOverlayForExtensionBridge(descriptor.bundleIdentifier) {
                self.overlay.hideAll()
                self.cancelTranslation()
                self.logger.event("window_skipped_for_bridge", fields: [
                    "bundle": descriptor.bundleIdentifier,
                    "revision": String(descriptor.revision)
                ])
                return
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
            guard let coordinator else { return .channelFailed }
            await coordinator.selectBackend(kind: backend, modelIdentifier: model)
            logger.event("inpage_stage", fields: ["stage": "translating", "count": String(texts.count)])
            var replacements: [InPageReplacement] = []
            for (language, group) in Dictionary(grouping: texts, by: { $0.sourceLanguage }) {
                let regions = group.map { text in
                    TextRegion(id: text.id, sourceText: text.text, screenFrame: .zero,
                               confidence: 1, source: .accessibility, windowRevision: descriptor.revision)
                }
                let snapshot = CaptureSnapshot(
                    window: CapturedWindow(descriptor: descriptor, regions: regions, source: .pageText),
                    sourceLanguage: language
                )
                let output = try await coordinator.translate(
                    snapshot: snapshot, backend: backend, modelIdentifier: model,
                    visionFallbackEnabled: visionFallbackEnabled
                )
                let nodeByRegion = Dictionary(uniqueKeysWithValues: group.map { ($0.id, $0.nodeID) })
                replacements += output.translations.compactMap { translation -> InPageReplacement? in
                    guard let nodeID = nodeByRegion[translation.region.id], !translation.text.isEmpty else { return nil }
                    return InPageReplacement(nodeID: nodeID, text: translation.text)
                }
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
