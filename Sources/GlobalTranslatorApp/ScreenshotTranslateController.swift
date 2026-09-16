import AppKit
import Foundation
import GlobalTranslatorCapture
import GlobalTranslatorCore
import GlobalTranslatorUI

/// Hotkey → region overlay → ScreenCaptureKit crop → on-device Vision OCR
/// → the same `SelectionTranslating` path as 滑词翻译 → popover + optional copy.
@MainActor
public final class ScreenshotTranslateController {
    private let selector: any RegionSelectionPresenting
    private let capturer: any RegionScreenCapturing
    private let ocr: any RegionTextRecognizing
    private let popover: any SelectionPopoverControlling
    private let permissions: any PermissionControlling
    private let logger: any AppRuntimeLogger
    private let registrar: any HotkeyRegistering
    private let translator: () -> (any SelectionTranslating)?
    private let backendReadiness: () -> ScreenshotBackendReadiness
    private let pasteboardWriter: (String) throws -> Void
    private let mouseLocation: () -> CGPoint
    private let requestScreenCapture: () -> Void

    private var shortcut: KeyboardShortcutSpec
    private var autoCopy = false
    private var backend: BackendKind = .deepSeekCloud
    private var hotkeyEnabled = false
    private var runTask: Task<Void, Never>?
    private var presentationGeneration: UInt64 = 0

    public var lastHotkeyError: String?

    public init(
        selector: any RegionSelectionPresenting,
        capturer: any RegionScreenCapturing,
        ocr: any RegionTextRecognizing,
        popover: any SelectionPopoverControlling,
        permissions: any PermissionControlling,
        logger: any AppRuntimeLogger,
        registrar: any HotkeyRegistering,
        translator: @escaping () -> (any SelectionTranslating)?,
        backendReadiness: @escaping () -> ScreenshotBackendReadiness,
        pasteboardWriter: @escaping (String) throws -> Void = { text in
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            guard pasteboard.setString(text, forType: .string) else {
                throw SelectionCopyError.writeFailed
            }
        },
        mouseLocation: @escaping () -> CGPoint = { NSEvent.mouseLocation },
        requestScreenCapture: @escaping () -> Void = {},
        shortcut: KeyboardShortcutSpec = .screenshotTranslateDefault
    ) {
        self.selector = selector
        self.capturer = capturer
        self.ocr = ocr
        self.popover = popover
        self.permissions = permissions
        self.logger = logger
        self.registrar = registrar
        self.translator = translator
        self.backendReadiness = backendReadiness
        self.pasteboardWriter = pasteboardWriter
        self.mouseLocation = mouseLocation
        self.requestScreenCapture = requestScreenCapture
        self.shortcut = shortcut
        popover.onUserDismiss = { [weak self] in
            self?.cancelPresentation()
        }
        popover.onTranslate = { [weak self] in
            self?.retryCurrent()
        }
    }

    public func setBackend(_ kind: BackendKind) {
        backend = kind
    }

    public func setAutoCopy(_ enabled: Bool) {
        autoCopy = enabled
    }

    public func startHotkey() {
        hotkeyEnabled = true
        do {
            try registrar.register(
                id: ScreenshotTranslateSupport.hotkeyID,
                shortcut: shortcut,
                handler: { [weak self] in self?.handleHotkey() }
            )
            lastHotkeyError = shortcut.conflictWarning
        } catch let error as HotkeyRegistrationError {
            lastHotkeyError = error.userMessage
            logger.event("screenshot_hotkey_failed", fields: ["reason": "register"])
        } catch {
            lastHotkeyError = HotkeyRegistrationError.failed.userMessage
            logger.event("screenshot_hotkey_failed", fields: ["reason": "register"])
        }
    }

    public func stopHotkey() {
        hotkeyEnabled = false
        registrar.unregister(id: ScreenshotTranslateSupport.hotkeyID)
        selector.cancel()
        cancelPresentation()
        popover.dismiss()
    }

    public func setHotkeySuspended(_ suspended: Bool) {
        if suspended {
            registrar.unregister(id: ScreenshotTranslateSupport.hotkeyID)
        } else if hotkeyEnabled {
            startHotkey()
        }
    }

    public func updateHotkey(_ spec: KeyboardShortcutSpec) {
        shortcut = spec
        guard hotkeyEnabled else {
            lastHotkeyError = spec.isValid ? spec.conflictWarning : HotkeyRegistrationError.invalid.userMessage
            return
        }
        startHotkey()
    }

    public func handleHotkey() {
        logger.event("screenshot_hotkey", fields: [:])
        if selector.isSelecting {
            selector.cancel()
        }
        runTask?.cancel()
        cancelPresentation()
        runTask = Task { @MainActor [weak self] in
            await self?.runCaptureTranslate()
        }
    }

    public func completeSelectionForTesting(_ rect: CGRect?) async {
        await process(rect: rect)
    }

    private func retryCurrent() {
        guard let original = popover.currentContent?.original, !original.isEmpty,
              let frame = popover.currentContent?.screenFrame else { return }
        presentTranslation(original: original, screenFrame: frame)
    }

    private func runCaptureTranslate() async {
        if !permissions.snapshot.screenCaptureAuthorized {
            requestScreenCapture()
            guard permissions.snapshot.screenCaptureAuthorized else {
                logger.event("screenshot_permission_missing", fields: ["reason": "screenCapture"])
                presentFailure(original: "", message: ScreenshotTranslateSupport.missingScreenCaptureCopy)
                return
            }
        }
        let rect = await selector.selectRegion()
        guard !Task.isCancelled else { return }
        await process(rect: rect)
    }

    private func process(rect: CGRect?) async {
        guard !Task.isCancelled else { return }
        guard let rect else {
            logger.event("screenshot_cancelled", fields: [:])
            return
        }
        guard ScreenshotTranslateSupport.isUsableRegion(rect) else {
            logger.event("screenshot_region_empty", fields: [:])
            presentFailure(
                original: "",
                message: ScreenshotTranslateSupport.emptyRegionCopy,
                screenFrame: rect
            )
            return
        }
        let image: CGImage
        do {
            image = try await capturer.capture(rect: rect)
            try Task.checkCancellation()
        } catch is CancellationError {
            return
        } catch {
            logger.event("screenshot_capture_failed", fields: ["status": "error"])
            presentFailure(
                original: "",
                message: ScreenshotTranslateSupport.captureFailedCopy,
                screenFrame: rect
            )
            return
        }
        let recognized: String
        do {
            recognized = try await ocr.recognizeJoinedText(image: image)
            try Task.checkCancellation()
        } catch is CancellationError {
            return
        } catch {
            logger.event("screenshot_ocr_failed", fields: ["status": "error"])
            presentFailure(
                original: "",
                message: ScreenshotTranslateSupport.ocrFailedCopy,
                screenFrame: rect
            )
            return
        }
        let text = recognized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            logger.event("screenshot_ocr_empty", fields: [:])
            presentFailure(
                original: "",
                message: ScreenshotTranslateSupport.ocrEmptyCopy,
                screenFrame: rect
            )
            return
        }
        switch TextFilter.selectionDecision(text) {
        case .skip:
            presentFailure(
                original: text,
                message: ScreenshotTranslateSupport.notTranslatableCopy,
                screenFrame: rect
            )
        case .alreadyTargetLanguage:
            popover.show(
                SelectionPopoverContent.alreadyChinese(original: text, screenFrame: rect)
                    .asScreenshotResult()
            )
            autoCopyIfNeeded(text)
        case .noTranslationNeeded:
            popover.show(
                SelectionPopoverContent.noTranslationNeeded(original: text, screenFrame: rect)
                    .asScreenshotResult()
            )
        case .translate:
            presentTranslation(original: text, screenFrame: rect)
        }
    }

    private func presentTranslation(original: String, screenFrame: CGRect) {
        cancelPresentation()
        let generation = presentationGeneration
        switch backendReadiness() {
        case .missingCloudKey:
            presentFailure(
                original: original,
                message: ScreenshotTranslateSupport.missingDeepSeekKeyCopy,
                screenFrame: screenFrame
            )
            return
        case .localNotReady:
            presentFailure(
                original: original,
                message: ScreenshotTranslateSupport.localBackendNotReadyCopy,
                screenFrame: screenFrame
            )
            return
        case .ready:
            break
        }
        popover.show(
            SelectionPopoverContent.loading(original: original, screenFrame: screenFrame)
                .asScreenshotResult()
        )
        guard let translator = translator() else {
            presentFailure(
                original: original,
                message: ScreenshotTranslateSupport.translatorUnavailableCopy,
                screenFrame: screenFrame
            )
            return
        }
        runTask = Task { @MainActor [weak self] in
            do {
                let outcome = try await translator.translateSelection(original)
                guard let self, !Task.isCancelled, self.presentationGeneration == generation else { return }
                let text = outcome.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty {
                    self.presentFailure(
                        original: original,
                        message: ScreenshotTranslateSupport.message(for: .emptyResult),
                        screenFrame: screenFrame
                    )
                    return
                }
                self.popover.show(
                    SelectionPopoverContent.translated(
                        original: original,
                        translation: text,
                        screenFrame: screenFrame,
                        sourceWasTruncated: outcome.sourceWasTruncated
                    ).asScreenshotResult()
                )
                self.autoCopyIfNeeded(text)
            } catch is CancellationError {
                return
            } catch {
                guard let self, !Task.isCancelled, self.presentationGeneration == generation else { return }
                self.logger.event("screenshot_translate_failed", fields: ["status": "error"])
                self.presentFailure(
                    original: original,
                    message: self.describe(error),
                    screenFrame: screenFrame
                )
            }
        }
    }

    private func presentFailure(original: String, message: String, screenFrame: CGRect? = nil) {
        let frame = screenFrame ?? SelectionTranslateSupport.fallbackFrame(at: mouseLocation())
        popover.show(
            SelectionPopoverContent.failed(
                original: original,
                message: message,
                screenFrame: frame
            ).asScreenshotResult()
        )
    }

    private func autoCopyIfNeeded(_ text: String) {
        guard autoCopy else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? pasteboardWriter(trimmed)
    }

    private func cancelPresentation() {
        presentationGeneration &+= 1
        runTask?.cancel()
        runTask = nil
    }

    private func describe(_ error: Error) -> String {
        if let screenshot = error as? ScreenshotTranslateError {
            return ScreenshotTranslateSupport.message(for: screenshot)
        }
        if let selection = error as? SelectionTranslateError {
            return selection.uiSafeDescription
        }
        if let translation = error as? TranslationError {
            switch translation {
            case .invalidResponse, .invalidRequest:
                return ScreenshotTranslateSupport.message(for: .emptyResult)
            case .missingCredential:
                return ScreenshotTranslateSupport.missingDeepSeekKeyCopy
            case .networkFailure:
                return backend == .local
                    ? ScreenshotTranslateSupport.localBackendNotReadyCopy
                    : translation.uiSafeDescription
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
