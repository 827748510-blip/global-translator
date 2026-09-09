import AppKit
import Foundation
import GlobalTranslatorCapture
import GlobalTranslatorCore
import GlobalTranslatorUI

public enum SelectionTranslateError: Error, Equatable, Sendable, UISafeError {
    case translatorUnavailable
    case emptyResult
    case noTranslationNeeded

    public var uiSafeDescription: String {
        switch self {
        case .translatorUnavailable:
            return "翻译服务未就绪"
        case .emptyResult:
            return "翻译失败"
        case .noTranslationNeeded:
            return SelectionTranslateSupport.noTranslationNeededCopy
        }
    }
}

@MainActor
public protocol SelectionTranslating: AnyObject {
    func translateSelection(_ text: String) async throws -> String
    func optimizePrompt(_ text: String, mode: PromptOptimizeMode) async throws -> String
}

@MainActor
public protocol SelectionPointerMonitoring: AnyObject {
    func start(_ handler: @escaping @MainActor (SelectionPointerPhase, CGPoint) -> Void)
    func stop()
}

@MainActor
public final class NullSelectionPointerMonitor: SelectionPointerMonitoring {
    public init() {}
    public func start(_ handler: @escaping @MainActor (SelectionPointerPhase, CGPoint) -> Void) {}
    public func stop() {}
}

@MainActor
public final class SystemSelectionPointerMonitor: SelectionPointerMonitoring {
    private var monitors: [Any] = []

    public init() {}

    public func start(_ handler: @escaping @MainActor (SelectionPointerPhase, CGPoint) -> Void) {
        stop()
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { event in
            handler(Self.phase(event.type), NSEvent.mouseLocation)
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
            handler(Self.phase(event.type), NSEvent.mouseLocation)
            return event
        }) {
            monitors.append(local)
        }
    }

    public func stop() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
    }

    private static func phase(_ type: NSEvent.EventType) -> SelectionPointerPhase {
        switch type {
        case .leftMouseDown:
            return .down
        case .leftMouseDragged:
            return .dragged
        default:
            return .up
        }
    }
}

/// Independent of window overlay capture and of the Chrome extension bridge.
/// Mouse-up in any app (after a short settle) reads AX selected text and
/// shows a nearby popover with the configured backend's translation. After a
/// real drag, empty AX may steal-and-restore the clipboard (⌘C) so Electron
/// apps such as Feishu still surface a popover.
@MainActor
public final class SelectionTranslateController {
    private let reader: any SelectedTextReading
    private let popover: any SelectionPopoverControlling
    private let monitor: any SelectionPointerMonitoring
    private let permissions: any PermissionControlling
    private let logger: any AppRuntimeLogger
    private let translator: () -> (any SelectionTranslating)?
    private let ownBundleIdentifiers: Set<String>
    private let frontmostBundleIdentifier: () -> String
    private let targetLanguage: String
    private let settleDelay: Duration
    private let unavailableDismissDelay: Duration

    private var enabled = false
    private var pointer = SelectionPointerState()
    /// Scene-menu / popover presses must still update `pointer`, but must not
    /// settle or dismiss. The menu window often closes before mouse-up, so the
    /// matching `.up` lands outside `containsInteraction`.
    private var pointerPressBeganOnOwnedUI = false
    private var settleGate = SelectionSettleGate()
    private var settleTask: Task<Void, Never>?
    private var translateTask: Task<Void, Never>?
    private var transientDismissTask: Task<Void, Never>?
    private var presentationGeneration: UInt64 = 0
    /// Source text the user just dismissed (Esc / outside click / new press).
    /// Settle will not re-show it until the selection changes or becomes empty.
    private var suppressedSource: String?
    private var optimizeMode: PromptOptimizeMode = .communicationPolish
    public var onOptimizeModeChange: ((PromptOptimizeMode) -> Void)?

    public var isEnabled: Bool { enabled }

    public init(
        reader: any SelectedTextReading,
        popover: any SelectionPopoverControlling,
        monitor: any SelectionPointerMonitoring,
        permissions: any PermissionControlling,
        logger: any AppRuntimeLogger,
        translator: @escaping () -> (any SelectionTranslating)?,
        ownBundleIdentifiers: Set<String> = [],
        frontmostBundleIdentifier: @escaping () -> String = {
            AXSelectedTextReader.systemFrontmostApplication()?.bundleIdentifier ?? ""
        },
        targetLanguage: String = SelectionTranslateSupport.defaultTargetLanguage,
        settleDelay: Duration = .milliseconds(SelectionTranslateSupport.settleDelayMilliseconds),
        unavailableDismissDelay: Duration = .milliseconds(
            SelectionTranslateSupport.unavailableDismissMilliseconds
        )
    ) {
        self.reader = reader
        self.popover = popover
        self.monitor = monitor
        self.permissions = permissions
        self.logger = logger
        self.translator = translator
        self.ownBundleIdentifiers = ownBundleIdentifiers
        self.frontmostBundleIdentifier = frontmostBundleIdentifier
        self.targetLanguage = targetLanguage
        self.settleDelay = settleDelay
        self.unavailableDismissDelay = unavailableDismissDelay
        let wired = self.popover
        wired.onUserDismiss = { [weak self] in
            self?.handleUserDismiss()
        }
        wired.onTranslate = { [weak self] in
            self?.performTranslate()
        }
        wired.onOptimize = { [weak self] in
            self?.performOptimize()
        }
        wired.onOptimizeModeChange = { [weak self] mode in
            self?.handleOptimizeModeChange(mode)
        }
        wired.optimizeMode = optimizeMode
    }

    public func setOptimizeMode(_ mode: PromptOptimizeMode) {
        optimizeMode = mode
        popover.optimizeMode = mode
    }

    public func setEnabled(_ enabled: Bool) {
        guard self.enabled != enabled else {
            if enabled { return }
            stopWork()
            return
        }
        self.enabled = enabled
        if enabled {
            monitor.start { [weak self] phase, location in
                self?.handlePointer(phase, location: location)
            }
        } else {
            monitor.stop()
            stopWork()
        }
    }

    public func handlePointer(_ phase: SelectionPointerPhase, location: CGPoint) {
        guard enabled else { return }
        let onOwnedUI = popover.containsInteraction(at: location)
        if phase == .down {
            pointerPressBeganOnOwnedUI = onOwnedUI
        }
        let action = pointer.handle(phase)
        let swallow = pointerPressBeganOnOwnedUI || onOwnedUI
        if phase == .up {
            pointerPressBeganOnOwnedUI = false
        }
        guard !swallow else { return }
        switch action {
        case .cancelPending:
            suppressCurrentSelectionIfShowing()
            cancelSettle()
            cancelPresentation()
            popover.dismiss()
        case .scheduleSettle:
            scheduleSettle(location: location)
        case .ignore:
            break
        }
    }

    private func handleUserDismiss() {
        suppressCurrentSelectionIfShowing()
        cancelSettle()
        cancelPresentation()
    }

    private func suppressCurrentSelectionIfShowing() {
        if let original = popover.currentContent?.original, !original.isEmpty {
            suppressedSource = original
        }
    }

    private func stopWork() {
        suppressedSource = nil
        pointerPressBeganOnOwnedUI = false
        cancelSettle()
        cancelPresentation()
        popover.dismiss()
    }

    private func cancelPresentation() {
        presentationGeneration &+= 1
        translateTask?.cancel()
        translateTask = nil
        transientDismissTask?.cancel()
        transientDismissTask = nil
    }

    private func cancelSettle() {
        settleGate.invalidate()
        settleTask?.cancel()
        settleTask = nil
    }

    private func scheduleSettle(location: CGPoint) {
        cancelSettle()
        let token = settleGate.next()
        settleTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: self?.settleDelay ?? .milliseconds(150))
            } catch {
                return
            }
            guard let self, !Task.isCancelled, self.enabled, self.settleGate.isCurrent(token) else { return }
            await self.processSettledSelection(location: location)
        }
    }

    private func processSettledSelection(location: CGPoint) async {
        let fallback = SelectionTranslateSupport.fallbackFrame(at: location)
        guard permissions.snapshot.accessibilityTrusted else {
            logger.event("selection_ax_unavailable", fields: ["reason": "permission"])
            return
        }
        if permissions.snapshot.secureInputEnabled {
            popover.dismiss()
            return
        }
        switch reader.readSelection(
            mouseLocation: location,
            allowClipboardFallback: pointer.didDrag && !isOwnFrontmostApplication()
        ) {
        case .empty:
            suppressedSource = nil
            cancelPresentation()
            popover.dismiss()
        case .unavailable:
            logger.event("selection_ax_unavailable", fields: ["reason": "ax"])
            if pointer.didDrag {
                presentUnavailable(screenFrame: fallback)
            } else {
                popover.dismiss()
            }
        case .snapshot(let snapshot):
            if isOwnApplication(snapshot.bundleIdentifier) {
                popover.dismiss()
                return
            }
            switch TextFilter.selectionDecision(snapshot.text, targetLanguage: targetLanguage) {
            case .skip:
                popover.dismiss()
            case .alreadyTargetLanguage:
                guard snapshot.text != suppressedSource else { return }
                suppressedSource = nil
                presentAlreadyChinese(snapshot)
            case .noTranslationNeeded:
                guard snapshot.text != suppressedSource else { return }
                suppressedSource = nil
                presentNoTranslationNeeded(snapshot)
            case .translate:
                guard snapshot.text != suppressedSource else { return }
                suppressedSource = nil
                presentTranslation(snapshot)
            }
        }
    }

    private func performTranslate() {
        guard enabled, let content = popover.currentContent, !content.original.isEmpty else { return }
        switch TextFilter.selectionDecision(content.original, targetLanguage: targetLanguage) {
        case .skip:
            return
        case .alreadyTargetLanguage:
            presentAlreadyChinese(snapshot(from: content))
        case .noTranslationNeeded, .translate:
            presentTranslation(snapshot(from: content))
        }
    }

    private func handleOptimizeModeChange(_ mode: PromptOptimizeMode) {
        guard optimizeMode != mode else { return }
        optimizeMode = mode
        popover.optimizeMode = mode
        onOptimizeModeChange?(mode)
    }

    private func performOptimize() {
        guard enabled, let content = popover.currentContent, !content.original.isEmpty else { return }
        guard TextFilter.shouldOfferPromptOptimization(content.original, targetLanguage: targetLanguage) else { return }
        presentOptimize(original: content.original, screenFrame: content.screenFrame)
    }

    private func snapshot(from content: SelectionPopoverContent) -> SelectedTextSnapshot {
        SelectedTextSnapshot(
            text: content.original,
            screenFrame: content.screenFrame,
            source: .accessibility,
            bundleIdentifier: ""
        )
    }

    private func presentAlreadyChinese(_ snapshot: SelectedTextSnapshot) {
        if popover.currentContent?.original == snapshot.text,
           popover.currentContent?.status == .alreadyChinese {
            return
        }
        cancelPresentation()
        popover.show(.alreadyChinese(original: snapshot.text, screenFrame: snapshot.screenFrame))
    }

    private func presentNoTranslationNeeded(_ snapshot: SelectedTextSnapshot) {
        if popover.currentContent?.original == snapshot.text,
           popover.currentContent?.status == .noTranslationNeeded {
            return
        }
        cancelPresentation()
        popover.show(.noTranslationNeeded(original: snapshot.text, screenFrame: snapshot.screenFrame))
    }

    private func presentUnavailable(screenFrame: CGRect) {
        cancelPresentation()
        let generation = presentationGeneration
        popover.show(.unavailable(screenFrame: screenFrame))
        transientDismissTask = Task { @MainActor [weak self] in
            guard let delay = self?.unavailableDismissDelay else { return }
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled, self.presentationGeneration == generation else { return }
            if self.popover.currentContent?.status == .unavailable {
                self.popover.dismiss()
            }
        }
    }

    private func presentTranslation(_ snapshot: SelectedTextSnapshot) {
        if popover.currentContent?.original == snapshot.text,
           popover.currentContent?.status == .translated {
            return
        }
        cancelPresentation()
        let generation = presentationGeneration
        popover.show(.loading(original: snapshot.text, screenFrame: snapshot.screenFrame))
        guard let translator = translator() else {
            popover.show(.failed(original: snapshot.text, message: "翻译服务未就绪", screenFrame: snapshot.screenFrame))
            return
        }
        translateTask = Task { @MainActor [weak self] in
            do {
                let translated = try await translator.translateSelection(snapshot.text)
                guard let self, !Task.isCancelled, self.presentationGeneration == generation else { return }
                let text = translated.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty {
                    self.popover.show(.failed(
                        original: snapshot.text,
                        message: "翻译失败",
                        screenFrame: snapshot.screenFrame
                    ))
                    return
                }
                self.popover.show(.translated(
                    original: snapshot.text,
                    translation: text,
                    screenFrame: snapshot.screenFrame
                ))
            } catch is CancellationError {
                return
            } catch {
                guard let self, !Task.isCancelled, self.presentationGeneration == generation else { return }
                if let selection = error as? SelectionTranslateError, selection == .noTranslationNeeded {
                    self.presentNoTranslationNeeded(snapshot)
                    return
                }
                self.logger.event("selection_translate_failed", fields: ["status": "error"])
                self.popover.show(.failed(
                    original: snapshot.text,
                    message: Self.describe(error),
                    screenFrame: snapshot.screenFrame
                ))
            }
        }
    }

    private func presentOptimize(original: String, screenFrame: CGRect) {
        cancelPresentation()
        let generation = presentationGeneration
        popover.show(.optimizing(original: original, screenFrame: screenFrame))
        guard let translator = translator() else {
            popover.show(.failed(
                original: original,
                message: "翻译服务未就绪",
                screenFrame: screenFrame
            ))
            return
        }
        let mode = optimizeMode
        translateTask = Task { @MainActor [weak self] in
            do {
                let optimized = try await translator.optimizePrompt(original, mode: mode)
                guard let self, !Task.isCancelled, self.presentationGeneration == generation else { return }
                let text = optimized.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty {
                    self.popover.show(.failed(
                        original: original,
                        message: SelectionTranslateSupport.optimizeFailedCopy,
                        screenFrame: screenFrame
                    ))
                    return
                }
                self.popover.show(.optimized(original: original, prompt: text, screenFrame: screenFrame))
            } catch is CancellationError {
                return
            } catch {
                guard let self, !Task.isCancelled, self.presentationGeneration == generation else { return }
                self.logger.event("selection_optimize_failed", fields: ["status": "error"])
                self.popover.show(.failed(
                    original: original,
                    message: SelectionTranslateSupport.optimizeFailedCopy,
                    screenFrame: screenFrame
                ))
            }
        }
    }

    private func isOwnFrontmostApplication() -> Bool {
        isOwnApplication(frontmostBundleIdentifier())
    }

    private func isOwnApplication(_ bundleIdentifier: String) -> Bool {
        !bundleIdentifier.isEmpty && ownBundleIdentifiers.contains(bundleIdentifier)
    }

    private static func describe(_ error: Error) -> String {
        if let selection = error as? SelectionTranslateError {
            return selection.uiSafeDescription
        }
        if let translation = error as? TranslationError {
            switch translation {
            case .invalidResponse, .invalidRequest:
                return SelectionTranslateError.emptyResult.uiSafeDescription
            default:
                return translation.uiSafeDescription
            }
        }
        if let safe = error as? UISafeError {
            return safe.uiSafeDescription
        }
        return UIFeedback.genericErrorMessage
    }
}
