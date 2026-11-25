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
    private let imageSaver: @Sendable (Data, URL) throws -> URL
    private let imageCopier: @Sendable (Data) -> Void

    private var shortcut: KeyboardShortcutSpec
    private var autoCopy = false
    private var backend: BackendKind = .deepSeekCloud
    private var hotkeyEnabled = false
    private var runTask: Task<Void, Never>?
    private var presentationGeneration: UInt64 = 0
    /// 每次截图（含选区流程）自增的身份。后台编码/写盘返回后据此丢弃过期结果，
    /// 避免上一轮截图覆盖新一轮的保存路径与剪贴板。
    private var captureGeneration: UInt64 = 0
    /// 保存截图 / 复制截图开关与目录（设置页可改）。
    private var saveImageEnabled = false
    private var copyImageEnabled = false
    private var saveDirectoryPath = AppConfiguration.defaultScreenshotSaveDirectory
    /// 最近一次成功落盘的截图路径；弹层用它显示「已保存到 …」。新一轮会清空。
    private var lastSavedImagePath: String?
    /// 本轮已经把截图放进剪贴板。自动复制译文必须让位，见 `autoCopyIfNeeded`。
    private var clipboardImageKept = false

    public var lastHotkeyError: String?
    public var onOpenSettings: (() -> Void)?
    public var isPopoverVisible: Bool { popover.isVisible }

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
        shortcut: KeyboardShortcutSpec = .screenshotTranslateDefault,
        imageSaver: @escaping @Sendable (Data, URL) throws -> URL = { data, directory in
            try ScreenshotImageIO.save(pngData: data, to: directory)
        },
        imageCopier: @escaping @Sendable (Data) -> Void = { data in
            ScreenshotImageIO.copyToClipboard(pngData: data)
        }
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
        self.imageSaver = imageSaver
        self.imageCopier = imageCopier
        popover.onUserDismiss = { [weak self] in
            self?.cancelPresentation()
        }
        popover.onTranslate = { [weak self] in
            self?.retryCurrent()
        }
        popover.onOpenSettings = { [weak self] in
            self?.onOpenSettings?()
        }
    }

    public func setBackend(_ kind: BackendKind) {
        backend = kind
    }

    public func setAutoCopy(_ enabled: Bool) {
        autoCopy = enabled
    }

    public func setSaveImage(_ enabled: Bool) {
        saveImageEnabled = enabled
    }

    public func setCopyImage(_ enabled: Bool) {
        copyImageEnabled = enabled
    }

    public func setSaveDirectory(_ path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        saveDirectoryPath = trimmed.isEmpty ? AppConfiguration.defaultScreenshotSaveDirectory : trimmed
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
        registrar.unregisterAll()
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

    public func completeSelectionForTesting(_ outcome: RegionSelectionOutcome) async {
        await process(outcome, capture: captureGeneration)
    }

    private func retryCurrent() {
        guard let original = popover.currentContent?.original, !original.isEmpty,
              let frame = popover.currentContent?.screenFrame else { return }
        presentTranslation(original: original, screenFrame: frame)
    }

    private func runCaptureTranslate() async {
        captureGeneration &+= 1
        let capture = captureGeneration
        // 新一轮开始就清空上一轮的全部制品状态：权限缺失、空选区、截图失败都在
        // `handleImageArtifacts` 之前返回，残留会让弹层误报「截图已保存/已复制」。
        lastSavedImagePath = nil
        clipboardImageKept = false
        if !permissions.snapshot.screenCaptureAuthorized {
            requestScreenCapture()
            guard permissions.snapshot.screenCaptureAuthorized else {
                logger.event("screenshot_permission_missing", fields: ["reason": "screenCapture"])
                presentFailure(
                    original: "",
                    message: ScreenshotTranslateSupport.missingScreenCaptureCopy,
                    showsOpenSettingsAction: true
                )
                return
            }
        }
        let outcome = await selector.selectRegion()
        guard !Task.isCancelled else { return }
        await process(outcome, capture: capture)
    }

    private func process(_ outcome: RegionSelectionOutcome, capture: UInt64) async {
        guard !Task.isCancelled, isCurrent(capture) else { return }
        switch outcome {
        case .cancelled:
            logger.event("screenshot_cancelled", fields: [:])
            return
        case .completed(let rect):
            await process(rect: rect, capture: capture)
        }
    }

    private func process(rect: CGRect, capture: UInt64) async {
        guard !Task.isCancelled, isCurrent(capture) else { return }
        guard ScreenshotTranslateSupport.isUsableRegion(rect) else {
            logger.event("screenshot_region_empty", fields: [:])
            presentFailure(
                original: "",
                message: ScreenshotTranslateSupport.emptyRegionCopy,
                screenFrame: rect
            )
            return
        }
        popover.show(
            SelectionPopoverContent.loading(
                original: "",
                screenFrame: rect,
                message: "正在识别文字…"
            ).asScreenshotResult()
        )
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
        // 保存 / 复制截图发生在 OCR 之前：即使识别不到文字，用户要的截图也已保留。
        await handleImageArtifacts(image, capture: capture)
        guard isCurrent(capture) else { return }
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
        guard isCurrent(capture) else { return }
        let text = recognized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            // 图里没有文字 = 没什么可翻的，不是失败：不弹红色，也不调模型。
            logger.event("screenshot_ocr_empty", fields: [:])
            presentNoTranslationNeeded(
                original: "",
                message: ScreenshotTranslateSupport.ocrEmptyCopy,
                screenFrame: rect
            )
            return
        }
        switch TextFilter.selectionDecision(text) {
        case .skip:
            // 只识别到 URL / 版本号 / 快捷键这类不可译内容：同样属于「无需翻译」。
            logger.event("screenshot_not_translatable", fields: [:])
            presentNoTranslationNeeded(
                original: text,
                message: ScreenshotTranslateSupport.notTranslatableCopy,
                screenFrame: rect
            )
        case .alreadyTargetLanguage:
            // 双向互译：截图识别出的简体中文也翻译成英文，不再只提示「已是中文」。
            presentTranslation(original: text, screenFrame: rect)
        case .noTranslationNeeded:
            presentNoTranslationNeeded(original: text, screenFrame: rect)
        case .translate:
            presentTranslation(original: text, screenFrame: rect)
        }
    }

    /// 「无需翻译」是独立成功状态：文案说明原因，弹层保持非失败样式。
    private func presentNoTranslationNeeded(
        original: String,
        message: String = SelectionTranslateSupport.noTranslationNeededCopy,
        screenFrame: CGRect
    ) {
        popover.show(withArtifactHints(
            SelectionPopoverContent.noTranslationNeeded(
                original: original,
                screenFrame: screenFrame,
                message: message
            ).asScreenshotResult()
        ))
    }

    private func presentTranslation(original: String, screenFrame: CGRect) {
        cancelPresentation()
        let generation = presentationGeneration
        switch backendReadiness() {
        case .missingCloudKey:
            presentFailure(
                original: original,
                message: ScreenshotTranslateSupport.missingDeepSeekKeyCopy,
                screenFrame: screenFrame,
                showsOpenSettingsAction: true
            )
            return
        case .localNotReady:
            presentFailure(
                original: original,
                message: ScreenshotTranslateSupport.localBackendNotReadyCopy,
                screenFrame: screenFrame,
                showsOpenSettingsAction: true
            )
            return
        case .ready:
            break
        }
        popover.show(withArtifactHints(
            SelectionPopoverContent.loading(original: original, screenFrame: screenFrame)
                .asScreenshotResult()
        ))
        guard let translator = translator() else {
            presentFailure(
                original: original,
                message: ScreenshotTranslateSupport.translatorUnavailableCopy,
                screenFrame: screenFrame,
                showsOpenSettingsAction: true
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
                self.popover.show(self.withArtifactHints(
                    SelectionPopoverContent.translated(
                        original: original,
                        translation: text,
                        screenFrame: screenFrame,
                        sourceWasTruncated: outcome.sourceWasTruncated
                    ).asScreenshotResult()
                ))
                self.autoCopyIfNeeded(text)
            } catch is CancellationError {
                return
            } catch {
                guard let self, !Task.isCancelled, self.presentationGeneration == generation else { return }
                // 模型原样回传唯一要翻的原文 = 专有名词，属于「无需翻译」而不是
                // 失败：滑词早就这么处理，截图此前会弹红色「翻译失败」。
                if let selection = error as? SelectionTranslateError, selection == .noTranslationNeeded {
                    self.presentNoTranslationNeeded(original: original, screenFrame: screenFrame)
                    return
                }
                self.logger.event("screenshot_translate_failed", fields: ["status": "error"])
                self.presentFailure(
                    original: original,
                    message: self.describe(error),
                    screenFrame: screenFrame
                )
            }
        }
    }

    private func presentFailure(
        original: String,
        message: String,
        screenFrame: CGRect? = nil,
        showsOpenSettingsAction: Bool = false
    ) {
        let frame = screenFrame ?? SelectionTranslateSupport.fallbackFrame(at: mouseLocation())
        popover.show(withArtifactHints(
            SelectionPopoverContent.failed(
                original: original,
                message: message,
                screenFrame: frame,
                showsOpenSettingsAction: showsOpenSettingsAction
            ).asScreenshotResult()
        ))
    }

    /// 自动复制译文。「复制截图」刚把图片放进剪贴板的这一轮不覆盖：用户要的是
    /// 那张图，译文已经显示在弹层里，需要时点「拷贝」显式覆盖即可。
    private func autoCopyIfNeeded(_ text: String) {
        guard autoCopy, !clipboardImageKept else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? pasteboardWriter(trimmed)
    }

    /// 保存 / 复制截图（按开关）。PNG 编码与写盘都在后台：4K 截图在主线程编码
    /// 会把弹层和快捷键一起卡住。失败只记日志，不阻断翻译流程。
    /// 后台结果返回后必须重新确认本轮截图仍然有效，否则过期结果会覆盖新一轮的
    /// 保存路径、清空或改写剪贴板（`Task.detached` 不随旧 run 取消）。
    private func handleImageArtifacts(_ image: CGImage, capture: UInt64) async {
        lastSavedImagePath = nil
        clipboardImageKept = false
        guard saveImageEnabled || copyImageEnabled else { return }
        guard let data = await ScreenshotImageIO.pngDataOffMain(image) else {
            if saveImageEnabled {
                logger.event("screenshot_save_failed", fields: ["status": "encode"])
            }
            return
        }
        guard isCurrent(capture) else { return }
        if saveImageEnabled {
            let directory = URL(fileURLWithPath: saveDirectoryPath, isDirectory: true)
            do {
                let savedPath = try await saveImageData(data, to: directory).path
                guard isCurrent(capture) else { return }
                lastSavedImagePath = savedPath
                logger.event("screenshot_saved", fields: [:])
            } catch {
                guard isCurrent(capture) else { return }
                logger.event("screenshot_save_failed", fields: ["status": "error"])
            }
        }
        if copyImageEnabled {
            guard isCurrent(capture) else { return }
            imageCopier(data)
            clipboardImageKept = true
            logger.event("screenshot_copied", fields: [:])
        }
    }

    /// 注入的写盘动作本身是同步的，包一层后台任务，主线程只等结果。
    private func saveImageData(_ data: Data, to directory: URL) async throws -> URL {
        let saver = imageSaver
        return try await Task.detached(priority: .userInitiated) {
            try saver(data, directory)
        }.value
    }

    /// 弹层内容带上「已保存到 …」路径提示与剪贴板保护提示。
    private func withArtifactHints(_ content: SelectionPopoverContent) -> SelectionPopoverContent {
        var copy = content
        copy.savedImagePath = lastSavedImagePath
        // 只有「自动复制译文」开着才谈得上被压制，否则这句提示是噪音。
        copy.clipboardHint = clipboardImageKept && autoCopy
            ? SelectionTranslateSupport.clipboardImageKeptCopy
            : nil
        return copy
    }

    /// 本轮截图是否仍然有效：被新一次截图取代或整个 run 已取消都算过期。
    private func isCurrent(_ capture: UInt64) -> Bool {
        capture == captureGeneration && !Task.isCancelled
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
