import AppKit
import Foundation
import GlobalTranslatorCapture
import GlobalTranslatorCore
import GlobalTranslatorUI

public enum SelectionTranslateError: Error, Equatable, Sendable {
    case translatorUnavailable
    case emptyResult
}

@MainActor
public protocol SelectionTranslating: AnyObject {
    func translateSelection(_ text: String) async throws -> String
    func optimizePrompt(_ text: String) async throws -> String
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
/// shows a nearby popover with the configured backend's translation.
@MainActor
public final class SelectionTranslateController {
    private let reader: any SelectedTextReading
    private let popover: any SelectionPopoverControlling
    private let monitor: any SelectionPointerMonitoring
    private let permissions: any PermissionControlling
    private let logger: any AppRuntimeLogger
    private let translator: () -> (any SelectionTranslating)?
    private let ownBundleIdentifiers: Set<String>
    private let targetLanguage: String
    private let settleDelay: Duration

    private var enabled = false
    private var pointer = SelectionPointerState()
    private var settleGate = SelectionSettleGate()
    private var settleTask: Task<Void, Never>?
    private var translateTask: Task<Void, Never>?
    private var presentationGeneration: UInt64 = 0
    /// Source text the user just dismissed (Esc / outside click / new press).
    /// Settle will not re-show it until the selection changes or becomes empty.
    private var suppressedSource: String?

    public var isEnabled: Bool { enabled }

    public init(
        reader: any SelectedTextReading,
        popover: any SelectionPopoverControlling,
        monitor: any SelectionPointerMonitoring,
        permissions: any PermissionControlling,
        logger: any AppRuntimeLogger,
        translator: @escaping () -> (any SelectionTranslating)?,
        ownBundleIdentifiers: Set<String> = [],
        targetLanguage: String = SelectionTranslateSupport.defaultTargetLanguage,
        settleDelay: Duration = .milliseconds(SelectionTranslateSupport.settleDelayMilliseconds)
    ) {
        self.reader = reader
        self.popover = popover
        self.monitor = monitor
        self.permissions = permissions
        self.logger = logger
        self.translator = translator
        self.ownBundleIdentifiers = ownBundleIdentifiers
        self.targetLanguage = targetLanguage
        self.settleDelay = settleDelay
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
        if let frame = popover.panelFrame, frame.contains(location) {
            return
        }
        switch pointer.handle(phase) {
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
        cancelSettle()
        cancelPresentation()
        popover.dismiss()
    }

    private func cancelPresentation() {
        presentationGeneration &+= 1
        translateTask?.cancel()
        translateTask = nil
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
        switch reader.readSelection(mouseLocation: location) {
        case .empty:
            suppressedSource = nil
            popover.dismiss()
        case .unavailable:
            logger.event("selection_ax_unavailable", fields: ["reason": "ax"])
            popover.show(.unavailable(screenFrame: fallback))
        case .snapshot(let snapshot):
            if ownBundleIdentifiers.contains(snapshot.bundleIdentifier) {
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
            popover.show(.alreadyChinese(original: content.original, screenFrame: content.screenFrame))
        case .translate:
            presentTranslation(snapshot(from: content))
        }
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
        translateTask = Task { @MainActor [weak self] in
            do {
                let optimized = try await translator.optimizePrompt(original)
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

    private static func describe(_ error: Error) -> String {
        if let safe = error as? UISafeError {
            return safe.uiSafeDescription
        }
        if let selection = error as? SelectionTranslateError {
            switch selection {
            case .translatorUnavailable:
                return "翻译服务未就绪"
            case .emptyResult:
                return "翻译失败"
            }
        }
        return UIFeedback.genericErrorMessage
    }
}
