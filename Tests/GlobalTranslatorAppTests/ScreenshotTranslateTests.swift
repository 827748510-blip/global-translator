import AppKit
import Foundation
import os
import Testing
@testable import GlobalTranslatorApp
import GlobalTranslatorCapture
import GlobalTranslatorCore
import GlobalTranslatorEngine
import GlobalTranslatorRuntime
import GlobalTranslatorUI

/// 截图保存 / 复制动作现在在后台执行，注入的闭包必须是 `@Sendable`，不能再
/// 捕获可变局部变量。用一把锁把记录器封成线程安全的盒子。
final class ImageArtifactRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var savedDirectories: [URL] = []
    private var copiedPayloads = 0

    var saved: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return savedDirectories
    }

    var copiedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return copiedPayloads
    }

    func recordSave(_ directory: URL) {
        lock.lock()
        savedDirectories.append(directory)
        lock.unlock()
    }

    func recordCopy() {
        lock.lock()
        copiedPayloads += 1
        lock.unlock()
    }
}

/// 让第一次写盘卡住的后台保存器：用来模拟慢盘返回晚于下一次截图。
final class GatedImageSaver: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var saveCalls = 0
    private var copyCalls = 0

    var saveCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return saveCalls
    }

    var copyCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return copyCalls
    }

    func save(in directory: URL) -> URL {
        lock.lock()
        saveCalls += 1
        let index = saveCalls
        lock.unlock()
        if index == 1 { gate.wait() }
        return directory.appendingPathComponent("shot-\(index).png")
    }

    func release() {
        gate.signal()
    }

    func recordCopy() {
        lock.lock()
        copyCalls += 1
        lock.unlock()
    }
}

@MainActor
struct ScreenshotTranslateControllerTests {
    private func waitUntil(_ condition: @escaping () -> Bool, timeout: TimeInterval = 1) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(condition())
    }
    @Test
    func hotkeyCapturesOCRAndShowsTranslationWithoutAutoCopy() async throws {
        var copied: [String] = []
        let selector = FakeRegionSelector()
        let ocr = FakeRegionOCR()
        ocr.text = "Hello world"
        let popover = FakeSelectionPopover()
        let translator = StubSelectionTranslator()
        translator.result = "你好，世界"
        let registrar = RecordingHotkeyRegistrar()
        let controller = ScreenshotTranslateController(
            selector: selector,
            capturer: FakeRegionCapturer(),
            ocr: ocr,
            popover: popover,
            permissions: FakePermissionController(snapshot: .allGranted),
            logger: RecordingLogger(),
            registrar: registrar,
            translator: { translator },
            backendReadiness: { .ready },
            pasteboardWriter: { copied.append($0) }
        )
        controller.startHotkey()
        #expect(registrar.registered[ScreenshotTranslateSupport.hotkeyID] == .screenshotTranslateDefault)
        controller.handleHotkey()
        try await waitUntil { popover.currentContent?.status == .translated }
        #expect(selector.selectCount == 1)
        #expect(ocr.callCount == 1)
        #expect(translator.texts == ["Hello world"])
        #expect(popover.currentContent?.original == "Hello world")
        #expect(popover.currentContent?.displayTranslation == "你好，世界")
        #expect(popover.currentContent?.allowsCopy == true)
        #expect(popover.currentContent?.showsOptimizeAction == false)
        #expect(popover.currentContent?.showsTranslateAction == false)
        #expect(copied.isEmpty)
        controller.stopHotkey()
        #expect(registrar.registered.isEmpty)
        #expect(registrar.unregisterAllCount == 1)
    }

    @Test
    func autoCopyWritesTranslationWhenEnabled() async throws {
        var copied: [String] = []
        let popover = FakeSelectionPopover()
        let translator = StubSelectionTranslator()
        translator.result = "你好，世界"
        let controller = ScreenshotTranslateController(
            selector: FakeRegionSelector(),
            capturer: FakeRegionCapturer(),
            ocr: FakeRegionOCR(),
            popover: popover,
            permissions: FakePermissionController(snapshot: .allGranted),
            logger: RecordingLogger(),
            registrar: RecordingHotkeyRegistrar(),
            translator: { translator },
            backendReadiness: { .ready },
            pasteboardWriter: { copied.append($0) }
        )
        controller.setAutoCopy(true)
        controller.handleHotkey()
        try await waitUntil { popover.currentContent?.status == .translated }
        #expect(copied == ["你好，世界"])
    }

    @Test
    func missingScreenCaptureShowsExplicitMessage() async throws {
        let popover = FakeSelectionPopover()
        let selector = FakeRegionSelector()
        let permission = FakePermissionController(snapshot: PermissionSnapshot(
            accessibilityTrusted: true,
            screenCaptureAuthorized: false,
            secureInputEnabled: false,
            sessionLocked: false
        ))
        let controller = ScreenshotTranslateController(
            selector: selector,
            capturer: FakeRegionCapturer(),
            ocr: FakeRegionOCR(),
            popover: popover,
            permissions: permission,
            logger: RecordingLogger(),
            registrar: RecordingHotkeyRegistrar(),
            translator: { StubSelectionTranslator() },
            backendReadiness: { .ready },
            requestScreenCapture: { _ = permission.requestScreenCapturePermission() }
        )
        controller.handleHotkey()
        try await waitUntil { popover.currentContent?.status == .failed }
        #expect(popover.currentContent?.displayTranslation == ScreenshotTranslateSupport.missingScreenCaptureCopy)
        #expect(selector.selectCount == 0)
        #expect(permission.screenCaptureRequestCount == 1)
    }

    @Test
    func emptyRegionShowsExplicitMessage() async throws {
        let selector = FakeRegionSelector()
        selector.result = .completed(CGRect(x: 10, y: 10, width: 2, height: 2))
        let popover = FakeSelectionPopover()
        let ocr = FakeRegionOCR()
        let logger = RecordingLogger()
        let controller = ScreenshotTranslateController(
            selector: selector,
            capturer: FakeRegionCapturer(),
            ocr: ocr,
            popover: popover,
            permissions: FakePermissionController(snapshot: .allGranted),
            logger: logger,
            registrar: RecordingHotkeyRegistrar(),
            translator: { StubSelectionTranslator() },
            backendReadiness: { .ready }
        )
        controller.handleHotkey()
        try await waitUntil { popover.currentContent?.status == .failed }
        #expect(popover.currentContent?.displayTranslation == ScreenshotTranslateSupport.emptyRegionCopy)
        #expect(ocr.callCount == 0)
        #expect(logger.records.contains(where: { $0.0 == "screenshot_region_empty" }))
        #expect(!logger.records.contains(where: { $0.0 == "screenshot_cancelled" }))
    }

    @Test
    func emptyOCRIsNoTranslationInsteadOfFailure() async throws {
        // 截图里没有文字 = 没什么可翻的。旧行为弹红色「未识别到文字」，把正常
        // 结果报成了失败。
        let ocr = FakeRegionOCR()
        ocr.text = "   "
        let popover = FakeSelectionPopover()
        let translator = StubSelectionTranslator()
        let logger = RecordingLogger()
        let controller = ScreenshotTranslateController(
            selector: FakeRegionSelector(),
            capturer: FakeRegionCapturer(),
            ocr: ocr,
            popover: popover,
            permissions: FakePermissionController(snapshot: .allGranted),
            logger: logger,
            registrar: RecordingHotkeyRegistrar(),
            translator: { translator },
            backendReadiness: { .ready }
        )
        controller.handleHotkey()
        try await waitUntil { popover.currentContent?.status == .noTranslationNeeded }
        #expect(popover.currentContent?.displayTranslation == ScreenshotTranslateSupport.ocrEmptyCopy)
        #expect(popover.currentContent?.allowsCopy == false)
        #expect(translator.texts.isEmpty)
        #expect(logger.records.contains(where: { $0.0 == "screenshot_ocr_empty" }))
    }

    @Test
    func untranslatableOCRTextIsNoTranslationInsteadOfFailure() async throws {
        // 只识别到 URL / 版本号这类内容：不可译，但不是失败。
        let ocr = FakeRegionOCR()
        ocr.text = "https://example.com/docs/getting-started"
        let popover = FakeSelectionPopover()
        let translator = StubSelectionTranslator()
        let logger = RecordingLogger()
        let controller = ScreenshotTranslateController(
            selector: FakeRegionSelector(),
            capturer: FakeRegionCapturer(),
            ocr: ocr,
            popover: popover,
            permissions: FakePermissionController(snapshot: .allGranted),
            logger: logger,
            registrar: RecordingHotkeyRegistrar(),
            translator: { translator },
            backendReadiness: { .ready }
        )
        controller.handleHotkey()
        try await waitUntil { popover.currentContent?.status == .noTranslationNeeded }
        #expect(popover.currentContent?.displayTranslation == ScreenshotTranslateSupport.notTranslatableCopy)
        #expect(popover.currentContent?.allowsCopy == true)
        #expect(translator.texts.isEmpty)
        #expect(logger.records.contains(where: { $0.0 == "screenshot_not_translatable" }))
    }

    @Test
    func copiedSourceEchoIsNoTranslationInsteadOfFailure() async throws {
        // 模型原样回传唯一的原文（专有名词）时，滑词早就按「无需翻译」处理；
        // 截图此前会走红色「翻译失败」。
        let ocr = FakeRegionOCR()
        ocr.text = "Hello world"
        let popover = FakeSelectionPopover()
        let translator = StubSelectionTranslator()
        translator.error = SelectionTranslateError.noTranslationNeeded
        let controller = ScreenshotTranslateController(
            selector: FakeRegionSelector(),
            capturer: FakeRegionCapturer(),
            ocr: ocr,
            popover: popover,
            permissions: FakePermissionController(snapshot: .allGranted),
            logger: RecordingLogger(),
            registrar: RecordingHotkeyRegistrar(),
            translator: { translator },
            backendReadiness: { .ready }
        )
        controller.handleHotkey()
        try await waitUntil {
            popover.currentContent?.status == .translated
                || popover.currentContent?.status == .noTranslationNeeded
        }
        #expect(popover.currentContent?.status == .noTranslationNeeded)
        #expect(popover.currentContent?.displayTranslation == SelectionTranslateSupport.noTranslationNeededCopy)
    }

    @Test
    func ocrFailureShowsExplicitMessage() async throws {
        let ocr = FakeRegionOCR()
        ocr.error = CaptureError.ocrFailed
        let popover = FakeSelectionPopover()
        let controller = ScreenshotTranslateController(
            selector: FakeRegionSelector(),
            capturer: FakeRegionCapturer(),
            ocr: ocr,
            popover: popover,
            permissions: FakePermissionController(snapshot: .allGranted),
            logger: RecordingLogger(),
            registrar: RecordingHotkeyRegistrar(),
            translator: { StubSelectionTranslator() },
            backendReadiness: { .ready }
        )
        controller.handleHotkey()
        try await waitUntil { popover.currentContent?.status == .failed }
        #expect(popover.currentContent?.displayTranslation == ScreenshotTranslateSupport.ocrFailedCopy)
    }

    @Test
    func captureFailureShowsExplicitMessage() async throws {
        let capturer = FakeRegionCapturer(image: nil)
        let popover = FakeSelectionPopover()
        let ocr = FakeRegionOCR()
        let controller = ScreenshotTranslateController(
            selector: FakeRegionSelector(),
            capturer: capturer,
            ocr: ocr,
            popover: popover,
            permissions: FakePermissionController(snapshot: .allGranted),
            logger: RecordingLogger(),
            registrar: RecordingHotkeyRegistrar(),
            translator: { StubSelectionTranslator() },
            backendReadiness: { .ready }
        )
        controller.handleHotkey()
        try await waitUntil { popover.currentContent?.status == .failed }
        #expect(popover.currentContent?.displayTranslation == ScreenshotTranslateSupport.captureFailedCopy)
        #expect(ocr.callCount == 0)
    }

    @Test
    func missingDeepSeekKeyMatchesSelectionCopy() async throws {
        let popover = FakeSelectionPopover()
        let translator = StubSelectionTranslator()
        let controller = ScreenshotTranslateController(
            selector: FakeRegionSelector(),
            capturer: FakeRegionCapturer(),
            ocr: FakeRegionOCR(),
            popover: popover,
            permissions: FakePermissionController(snapshot: .allGranted),
            logger: RecordingLogger(),
            registrar: RecordingHotkeyRegistrar(),
            translator: { translator },
            backendReadiness: { .missingCloudKey }
        )
        controller.handleHotkey()
        try await waitUntil { popover.currentContent?.status == .failed }
        #expect(popover.currentContent?.displayTranslation == SelectionTranslateSupport.missingDeepSeekKeyCopy)
        #expect(translator.texts.isEmpty)
    }

    @Test
    func localBackendNotReadyShowsOllamaMessage() async throws {
        let popover = FakeSelectionPopover()
        let translator = StubSelectionTranslator()
        let controller = ScreenshotTranslateController(
            selector: FakeRegionSelector(),
            capturer: FakeRegionCapturer(),
            ocr: FakeRegionOCR(),
            popover: popover,
            permissions: FakePermissionController(snapshot: .allGranted),
            logger: RecordingLogger(),
            registrar: RecordingHotkeyRegistrar(),
            translator: { translator },
            backendReadiness: { .localNotReady }
        )
        controller.setBackend(.local)
        controller.handleHotkey()
        try await waitUntil { popover.currentContent?.status == .failed }
        #expect(popover.currentContent?.displayTranslation == ScreenshotTranslateSupport.localBackendNotReadyCopy)
        #expect(translator.texts.isEmpty)
    }

    @Test
    func translationFailureShowsFailedNotGenericServiceCopy() async throws {
        let popover = FakeSelectionPopover()
        let translator = StubSelectionTranslator()
        translator.error = SelectionTranslateError.emptyResult
        let controller = ScreenshotTranslateController(
            selector: FakeRegionSelector(),
            capturer: FakeRegionCapturer(),
            ocr: FakeRegionOCR(),
            popover: popover,
            permissions: FakePermissionController(snapshot: .allGranted),
            logger: RecordingLogger(),
            registrar: RecordingHotkeyRegistrar(),
            translator: { translator },
            backendReadiness: { .ready }
        )
        controller.handleHotkey()
        try await waitUntil { popover.currentContent?.status == .failed }
        #expect(popover.currentContent?.displayTranslation == "翻译失败")
        #expect(popover.currentContent?.displayTranslation != "服务返回异常，请稍后重试")
    }

    @Test
    func cancelledRegionDoesNotShowPopover() async throws {
        let selector = FakeRegionSelector()
        selector.result = .cancelled
        let popover = FakeSelectionPopover()
        let logger = RecordingLogger()
        let controller = ScreenshotTranslateController(
            selector: selector,
            capturer: FakeRegionCapturer(),
            ocr: FakeRegionOCR(),
            popover: popover,
            permissions: FakePermissionController(snapshot: .allGranted),
            logger: logger,
            registrar: RecordingHotkeyRegistrar(),
            translator: { StubSelectionTranslator() },
            backendReadiness: { .ready }
        )
        controller.handleHotkey()
        try await waitUntil { selector.selectCount == 1 }
        try await Task.sleep(for: .milliseconds(20))
        #expect(popover.shown.isEmpty)
        #expect(logger.records.contains(where: { $0.0 == "screenshot_cancelled" }))
        #expect(!logger.records.contains(where: { $0.0 == "screenshot_region_empty" }))
    }

    @Test
    func chineseOCRTranslatesToEnglish() async throws {
        // 双向互译：截图识别出的简体中文不再停在「已是中文」，而是译成英文。
        let ocr = FakeRegionOCR()
        ocr.text = "你好世界"
        let popover = FakeSelectionPopover()
        let translator = StubSelectionTranslator()
        translator.result = "Hello world"
        let controller = ScreenshotTranslateController(
            selector: FakeRegionSelector(),
            capturer: FakeRegionCapturer(),
            ocr: ocr,
            popover: popover,
            permissions: FakePermissionController(snapshot: .allGranted),
            logger: RecordingLogger(),
            registrar: RecordingHotkeyRegistrar(),
            translator: { translator },
            backendReadiness: { .ready }
        )
        controller.handleHotkey()
        try await waitUntil { popover.currentContent?.status == .translated }
        #expect(translator.texts == ["你好世界"])
        #expect(popover.currentContent?.displayTranslation == "Hello world")
        #expect(popover.currentContent?.showsOptimizeAction == false)
        #expect(popover.currentContent?.showsTranslateAction == false)
    }

    @Test
    func savesAndCopiesScreenshotWhenEnabled() async throws {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures/gt-shots", isDirectory: true)
        let recorder = ImageArtifactRecorder()
        let ocr = FakeRegionOCR()
        ocr.text = "Hello world"
        let popover = FakeSelectionPopover()
        let translator = StubSelectionTranslator()
        translator.result = "你好，世界"
        let controller = ScreenshotTranslateController(
            selector: FakeRegionSelector(),
            capturer: FakeRegionCapturer(),
            ocr: ocr,
            popover: popover,
            permissions: FakePermissionController(snapshot: .allGranted),
            logger: RecordingLogger(),
            registrar: RecordingHotkeyRegistrar(),
            translator: { translator },
            backendReadiness: { .ready },
            imageSaver: { _, dir in
                recorder.recordSave(dir)
                return dir.appendingPathComponent("shot.png")
            },
            imageCopier: { _ in recorder.recordCopy() }
        )
        controller.setSaveImage(true)
        controller.setCopyImage(true)
        controller.setSaveDirectory(directory.path)
        controller.handleHotkey()
        try await waitUntil { popover.currentContent?.status == .translated }
        #expect(recorder.saved == [directory])
        #expect(recorder.copiedCount == 1)
        // 落盘路径存原始绝对路径，弹层提示用 ~ 缩写。
        #expect(popover.currentContent?.savedImagePath == directory.path + "/shot.png")
        #expect(popover.currentContent?.savedImageHint == "已保存到 ~/Pictures/gt-shots/shot.png")
    }

    @Test
    func doesNotSaveOrCopyByDefault() async throws {
        let recorder = ImageArtifactRecorder()
        let ocr = FakeRegionOCR()
        ocr.text = "Hello world"
        let popover = FakeSelectionPopover()
        let translator = StubSelectionTranslator()
        translator.result = "你好，世界"
        let controller = ScreenshotTranslateController(
            selector: FakeRegionSelector(),
            capturer: FakeRegionCapturer(),
            ocr: ocr,
            popover: popover,
            permissions: FakePermissionController(snapshot: .allGranted),
            logger: RecordingLogger(),
            registrar: RecordingHotkeyRegistrar(),
            translator: { translator },
            backendReadiness: { .ready },
            imageSaver: { _, dir in
                recorder.recordSave(dir)
                return dir.appendingPathComponent("shot.png")
            },
            imageCopier: { _ in recorder.recordCopy() }
        )
        controller.handleHotkey()
        try await waitUntil { popover.currentContent?.status == .translated }
        #expect(recorder.saved.isEmpty)
        #expect(recorder.copiedCount == 0)
        #expect(popover.currentContent?.savedImagePath == nil)
    }

    /// 复制截图 + 自动复制译文同时开着时，译文不能无声覆盖刚生成的截图：
    /// 图片留在剪贴板，弹层给出提示，译文由用户点「拷贝」显式复制。
    @Test
    func autoCopyDoesNotOverwriteCopiedScreenshot() async throws {
        var copiedText: [String] = []
        let recorder = ImageArtifactRecorder()
        let ocr = FakeRegionOCR()
        ocr.text = "Hello world"
        let popover = FakeSelectionPopover()
        let translator = StubSelectionTranslator()
        translator.result = "你好，世界"
        let controller = ScreenshotTranslateController(
            selector: FakeRegionSelector(),
            capturer: FakeRegionCapturer(),
            ocr: ocr,
            popover: popover,
            permissions: FakePermissionController(snapshot: .allGranted),
            logger: RecordingLogger(),
            registrar: RecordingHotkeyRegistrar(),
            translator: { translator },
            backendReadiness: { .ready },
            pasteboardWriter: { copiedText.append($0) },
            imageSaver: { _, dir in dir.appendingPathComponent("shot.png") },
            imageCopier: { _ in recorder.recordCopy() }
        )
        controller.setAutoCopy(true)
        controller.setCopyImage(true)
        controller.handleHotkey()
        try await waitUntil { popover.currentContent?.status == .translated }
        #expect(recorder.copiedCount == 1)
        #expect(copiedText.isEmpty)
        #expect(popover.currentContent?.clipboardHint == SelectionTranslateSupport.clipboardImageKeptCopy)
        // 译文仍然可以手动复制。
        #expect(popover.currentContent?.allowsCopy == true)
    }

    /// 只有自动复制开着、但没复制截图时，照旧自动复制译文（不产生提示）。
    @Test
    func autoCopyStillWritesWhenScreenshotWasNotCopied() async throws {
        var copiedText: [String] = []
        let popover = FakeSelectionPopover()
        let translator = StubSelectionTranslator()
        translator.result = "你好，世界"
        let controller = ScreenshotTranslateController(
            selector: FakeRegionSelector(),
            capturer: FakeRegionCapturer(),
            ocr: FakeRegionOCR(),
            popover: popover,
            permissions: FakePermissionController(snapshot: .allGranted),
            logger: RecordingLogger(),
            registrar: RecordingHotkeyRegistrar(),
            translator: { translator },
            backendReadiness: { .ready },
            pasteboardWriter: { copiedText.append($0) }
        )
        controller.setAutoCopy(true)
        controller.setSaveImage(true)
        controller.handleHotkey()
        try await waitUntil { popover.currentContent?.status == .translated }
        #expect(copiedText == ["你好，世界"])
        #expect(popover.currentContent?.clipboardHint == nil)
    }

    /// 上一轮截图失败（权限、空选区、截图错误）时，不能沿用上一轮的
    /// 「截图已复制」提示与保存路径。
    @Test
    func failedCaptureClearsPreviousArtifactHints() async throws {
        let popover = FakeSelectionPopover()
        let capturer = FakeRegionCapturer()
        let translator = StubSelectionTranslator()
        translator.result = "你好，世界"
        let controller = ScreenshotTranslateController(
            selector: FakeRegionSelector(),
            capturer: capturer,
            ocr: FakeRegionOCR(),
            popover: popover,
            permissions: FakePermissionController(snapshot: .allGranted),
            logger: RecordingLogger(),
            registrar: RecordingHotkeyRegistrar(),
            translator: { translator },
            backendReadiness: { .ready },
            imageSaver: { _, dir in dir.appendingPathComponent("shot.png") },
            imageCopier: { _ in }
        )
        controller.setAutoCopy(true)
        controller.setSaveImage(true)
        controller.setCopyImage(true)
        controller.handleHotkey()
        try await waitUntil { popover.currentContent?.status == .translated }
        #expect(popover.currentContent?.savedImagePath != nil)
        #expect(popover.currentContent?.clipboardHint == SelectionTranslateSupport.clipboardImageKeptCopy)

        capturer.error = CaptureError.captureFailed
        controller.handleHotkey()
        try await waitUntil { popover.currentContent?.status == .failed }
        #expect(popover.currentContent?.savedImagePath == nil)
        #expect(popover.currentContent?.clipboardHint == nil)
    }

    /// 慢盘写盘结果晚于下一次截图返回时，过期结果不能改写新一轮的保存路径与剪贴板。
    @Test
    func staleScreenshotArtifactsDoNotOverwriteNewCapture() async throws {
        let directory = FileManager.default.temporaryDirectory
        let saver = GatedImageSaver()
        defer { saver.release() }
        let popover = FakeSelectionPopover()
        let translator = StubSelectionTranslator()
        translator.result = "你好，世界"
        let controller = ScreenshotTranslateController(
            selector: FakeRegionSelector(),
            capturer: FakeRegionCapturer(),
            ocr: FakeRegionOCR(),
            popover: popover,
            permissions: FakePermissionController(snapshot: .allGranted),
            logger: RecordingLogger(),
            registrar: RecordingHotkeyRegistrar(),
            translator: { translator },
            backendReadiness: { .ready },
            imageSaver: { _, dir in saver.save(in: dir) },
            imageCopier: { _ in saver.recordCopy() }
        )
        controller.setSaveImage(true)
        controller.setCopyImage(true)
        controller.setSaveDirectory(directory.path)
        controller.handleHotkey()
        try await waitUntil { saver.saveCount == 1 }

        controller.handleHotkey()
        let expected = directory.path + "/shot-2.png"
        try await waitUntil { popover.currentContent?.savedImagePath == expected }
        // 第二轮截图只复制一次；此时第一轮仍卡在写盘。
        #expect(saver.copyCount == 1)

        saver.release()
        try await waitUntil { popover.currentContent?.status == .translated }
        try await Task.sleep(for: .milliseconds(50))
        #expect(popover.currentContent?.savedImagePath == expected)
        #expect(saver.copyCount == 1)
    }

    @Test
    func saveFailureDoesNotBlockTranslation() async throws {
        let ocr = FakeRegionOCR()
        let popover = FakeSelectionPopover()
        let translator = StubSelectionTranslator()
        translator.result = "你好，世界"
        let logger = RecordingLogger()
        let controller = ScreenshotTranslateController(
            selector: FakeRegionSelector(),
            capturer: FakeRegionCapturer(),
            ocr: ocr,
            popover: popover,
            permissions: FakePermissionController(snapshot: .allGranted),
            logger: logger,
            registrar: RecordingHotkeyRegistrar(),
            translator: { translator },
            backendReadiness: { .ready },
            imageSaver: { _, _ in throw ScreenshotImageIO.SaveError.pngEncodingFailed },
            imageCopier: { _ in }
        )
        controller.setSaveImage(true)
        controller.handleHotkey()
        try await waitUntil { popover.currentContent?.status == .translated }
        #expect(popover.currentContent?.displayTranslation == "你好，世界")
        #expect(popover.currentContent?.savedImagePath == nil)
        #expect(logger.records.contains { $0.0 == "screenshot_save_failed" })
    }

    @Test
    func hotkeyConflictIsSurfaced() {
        let registrar = RecordingHotkeyRegistrar()
        registrar.errorToThrow = .alreadyInUse
        let controller = ScreenshotTranslateController(
            selector: FakeRegionSelector(),
            capturer: FakeRegionCapturer(),
            ocr: FakeRegionOCR(),
            popover: FakeSelectionPopover(),
            permissions: FakePermissionController(snapshot: .allGranted),
            logger: RecordingLogger(),
            registrar: registrar,
            translator: { nil },
            backendReadiness: { .ready }
        )
        controller.startHotkey()
        #expect(controller.lastHotkeyError == KeyboardShortcutSupport.alreadyInUseCopy)
    }

    @Test
    func secureInputAndSessionLockBlockScreenshotCapture() async {
        let state = OSAllocatedUnfairLock(initialState: (secure: true, locked: false))
        let perms = SystemPermissionController(snapshotProvider: {
            let current = state.withLock { $0 }
            return PermissionSnapshot(
                accessibilityTrusted: true,
                screenCaptureAuthorized: true,
                secureInputEnabled: current.secure,
                sessionLocked: current.locked
            )
        })
        let selector = FakeRegionSelector()
        let capturer = FakeRegionCapturer()
        let popover = FakeSelectionPopover()
        let controller = ScreenshotTranslateController(
            selector: selector,
            capturer: capturer,
            ocr: FakeRegionOCR(),
            popover: popover,
            permissions: perms,
            logger: RecordingLogger(),
            registrar: RecordingHotkeyRegistrar(),
            translator: { nil },
            backendReadiness: { .ready }
        )
        controller.handleHotkey()
        try? await Task.sleep(for: .milliseconds(40))
        #expect(!selector.isSelecting)
        #expect(!popover.isVisible)

        state.withLock { $0 = (secure: false, locked: true) }
        await controller.completeSelectionForTesting(.completed(CGRect(x: 0, y: 0, width: 100, height: 100)))
        #expect(!popover.isVisible)
    }

    @Test
    func artifactSaveOverlapsWithOCRAndCompletesBeforeTranslatedHints() async throws {
        let directory = FileManager.default.temporaryDirectory
        let saver = GatedImageSaver()
        defer { saver.release() }
        let ocr = FakeRegionOCR()
        ocr.text = "Parallel screenshot text"
        let popover = FakeSelectionPopover()
        let translator = StubSelectionTranslator()
        translator.result = "并行结果"
        let controller = ScreenshotTranslateController(
            selector: FakeRegionSelector(),
            capturer: FakeRegionCapturer(),
            ocr: ocr,
            popover: popover,
            permissions: FakePermissionController(snapshot: .allGranted),
            logger: RecordingLogger(),
            registrar: RecordingHotkeyRegistrar(),
            translator: { translator },
            backendReadiness: { .ready },
            imageSaver: { _, dir in saver.save(in: dir) },
            imageCopier: { _ in }
        )
        controller.setSaveImage(true)
        controller.setSaveDirectory(directory.path)
        controller.handleHotkey()

        // OCR and loading state progress immediately without waiting for slow disk save.
        try await waitUntil { saver.saveCount == 1 && popover.currentContent?.status == .loading && popover.currentContent?.original == "Parallel screenshot text" }
        saver.release()
        try await waitUntil { popover.currentContent?.status == .translated }
        #expect(popover.currentContent?.savedImagePath == directory.path + "/shot-1.png")
    }
}

extension ApplicationControllerTests {
    @Test
    func screenshotAutoCopyDefaultsOffAndTogglePersists() async throws {
        let store = RecordingConfigurationStore()
        let controller = ApplicationController(
            paths: try RuntimePaths(validatingRoot: temporaryRoot()),
            components: makeComponents(store: store)
        )
        try await controller.start()
        await waitForStartupHealthCheck(controller)
        #expect(!controller.configuration.autoCopyScreenshotTranslation)
        #expect(!controller.viewModel.autoCopyScreenshotTranslation)
        #expect(controller.configuration.screenshotTranslateHotkey == .screenshotTranslateDefault)
        controller.setAutoCopyScreenshotTranslation(true)
        try await controller.persistence.flush()
        #expect(controller.configuration.autoCopyScreenshotTranslation)
        #expect(await store.saved.last?.autoCopyScreenshotTranslation == true)
        let custom = KeyboardShortcutSpec(keyCode: KeyboardShortcutSpec.KeyCode.r, option: true)
        controller.setScreenshotTranslateHotkey(custom)
        try await controller.persistence.flush()
        #expect(controller.configuration.screenshotTranslateHotkey == custom)
        #expect(await store.saved.last?.screenshotTranslateHotkey == custom)
        await controller.stop()
    }
}
