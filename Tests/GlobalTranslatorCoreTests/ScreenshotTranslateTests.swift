import CoreGraphics
import Foundation
import Testing
@testable import GlobalTranslatorCore

struct ScreenshotTranslateCoreTests {
    @Test
    func autoCopyDefaultsOffAndLegacyJSONKeepsDefaultHotkey() throws {
        let configuration = AppConfiguration()
        #expect(!configuration.autoCopyScreenshotTranslation)
        #expect(configuration.screenshotTranslateHotkey == .screenshotTranslateDefault)
        #expect(configuration.screenshotTranslateHotkey.displayString == "⌃⇧T")
        #expect(configuration.screenshotTranslateHotkey.isValid)

        let legacy = Data(#"{"backend":"local","localModel":"qwen"}"#.utf8)
        let decoded = try JSONDecoder().decode(AppConfiguration.self, from: legacy)
        #expect(!decoded.autoCopyScreenshotTranslation)
        #expect(decoded.screenshotTranslateHotkey == .screenshotTranslateDefault)

        let encoded = try JSONEncoder().encode(AppConfiguration())
        let object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["autoCopyScreenshotTranslation"] as? Bool == false)
        #expect(object["screenshotTranslateHotkey"] != nil)
    }

    @Test
    func invalidPersistedHotkeyFallsBackToDefault() throws {
        let json = Data(#"{"screenshotTranslateHotkey":{"keyCode":17,"control":false,"option":false,"shift":true,"command":false}}"#.utf8)
        let decoded = try JSONDecoder().decode(AppConfiguration.self, from: json)
        #expect(decoded.screenshotTranslateHotkey == .screenshotTranslateDefault)
    }

    @Test
    func shortcutValidationAndConflictCopy() {
        #expect(!KeyboardShortcutSpec(keyCode: 17).isValid)
        #expect(!KeyboardShortcutSpec(keyCode: 17, shift: true).isValid)
        #expect(KeyboardShortcutSpec(keyCode: 17, control: true).isValid)
        #expect(!KeyboardShortcutSpec(keyCode: KeyboardShortcutSpec.KeyCode.escape, control: true).isValid)
        #expect(KeyboardShortcutSpec.screenshotTranslateDefault.conflictWarning == nil)
        let screenshot = KeyboardShortcutSpec(
            keyCode: KeyboardShortcutSpec.KeyCode.four,
            shift: true,
            command: true
        )
        #expect(screenshot.conflictWarning == KeyboardShortcutSupport.systemScreenshotConflictCopy)
        let quit = KeyboardShortcutSpec(keyCode: KeyboardShortcutSpec.KeyCode.q, command: true)
        #expect(quit.conflictWarning == KeyboardShortcutSupport.quitConflictCopy)
        #expect(HotkeyRegistrationError.alreadyInUse.userMessage == KeyboardShortcutSupport.alreadyInUseCopy)
        #expect(KeyboardShortcutSpec.screenshotTranslateDefault.carbonModifiers
                == KeyboardShortcutSpec.CarbonModifier.control | KeyboardShortcutSpec.CarbonModifier.shift)
    }

    @Test
    func punctuationKeysRenderAsSymbolsInsteadOfRawNumbers() {
        // Recording stores whatever key the user pressed, so punctuation must
        // render as the character rather than falling back to `Key<code>`.
        #expect(KeyboardShortcutSpec(keyCode: KeyboardShortcutSpec.KeyCode.grave, option: true).displayString == "⌥`")
        #expect(KeyboardShortcutSpec(keyCode: KeyboardShortcutSpec.KeyCode.minus, control: true).displayString == "⌃-")
        #expect(KeyboardShortcutSpec(keyCode: KeyboardShortcutSpec.KeyCode.equal, control: true).displayString == "⌃=")
        #expect(KeyboardShortcutSpec(keyCode: KeyboardShortcutSpec.KeyCode.leftBracket, option: true).displayString == "⌥[")
        #expect(KeyboardShortcutSpec(keyCode: KeyboardShortcutSpec.KeyCode.rightBracket, option: true).displayString == "⌥]")
        #expect(KeyboardShortcutSpec(keyCode: KeyboardShortcutSpec.KeyCode.backslash, option: true).displayString == "⌥\\")
        #expect(KeyboardShortcutSpec(keyCode: KeyboardShortcutSpec.KeyCode.semicolon, option: true).displayString == "⌥;")
        #expect(KeyboardShortcutSpec(keyCode: KeyboardShortcutSpec.KeyCode.quote, option: true).displayString == "⌥'")
        #expect(KeyboardShortcutSpec(keyCode: KeyboardShortcutSpec.KeyCode.comma, option: true).displayString == "⌥,")
        #expect(KeyboardShortcutSpec(keyCode: KeyboardShortcutSpec.KeyCode.period, option: true).displayString == "⌥.")
        #expect(KeyboardShortcutSpec(keyCode: KeyboardShortcutSpec.KeyCode.slash, option: true).displayString == "⌥/")
        #expect(KeyboardShortcutSpec(keyCode: KeyboardShortcutSpec.KeyCode.section, option: true).displayString == "⌥§")

        // Unmapped codes still fall back so nothing renders blank.
        #expect(KeyboardShortcutSpec.keyName(for: 96) == "Key96")
        // The shipped default is unaffected by the new table.
        #expect(KeyboardShortcutSpec.screenshotTranslateDefault.displayString == "⌃⇧T")
    }

    @Test
    func regionDragRequiresMinimumSize() {
        var drag = ScreenshotRegionDrag()
        #expect(drag.completePointerUp(clampedTo: nil) == nil)

        drag.begin(at: CGPoint(x: 10, y: 10))
        drag.move(to: CGPoint(x: 12, y: 11))
        let tiny = drag.completePointerUp(clampedTo: nil)
        #expect(tiny == .completed(CGRect(x: 10, y: 10, width: 2, height: 1)))
        #expect(!ScreenshotTranslateSupport.isUsableRegion(CGRect(x: 10, y: 10, width: 2, height: 1)))
        #expect(tiny != .cancelled)

        drag.begin(at: CGPoint(x: 100, y: 200))
        drag.move(to: CGPoint(x: 180, y: 260))
        let rect = drag.finish()
        #expect(rect == CGRect(x: 100, y: 200, width: 80, height: 60))
        #expect(ScreenshotTranslateSupport.isUsableRegion(rect))
        #expect(!drag.isDragging)
    }

    @Test
    func displayLocalSourceRectFlipsY() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let selection = CGRect(x: 100, y: 200, width: 80, height: 40)
        let source = RegionCaptureGeometry.displayLocalSourceRect(selection: selection, screenFrame: screen)
        #expect(source == CGRect(x: 100, y: 560, width: 80, height: 40))
        let crop = RegionCaptureGeometry.imageCropRect(
            selection: selection,
            screenFrame: screen,
            imageSize: CGSize(width: 1000, height: 800)
        )
        #expect(crop == CGRect(x: 100, y: 200, width: 80, height: 40))
        #expect(ScreenshotTranslateSupport.isUsableRegion(selection))
        #expect(!ScreenshotTranslateSupport.isUsableRegion(CGRect(x: 0, y: 0, width: 4, height: 4)))
    }

    @Test
    func retinaHalfScreenDoesNotLookLikeFullDisplayBuffer() {
        let screen = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        let half = CGRect(x: 0, y: 0, width: 500, height: 800)
        let scale: CGFloat = 2
        let expectedWidth = RegionCaptureGeometry.displayLocalSourceRect(
            selection: half,
            screenFrame: screen
        ).width
        let regionPixels = CGSize(width: 1_000, height: 1_600)

        // Pre-fix mixed units: pixels vs points. Half-screen Retina satisfies both.
        #expect(regionPixels.width > expectedWidth * 1.5)
        #expect(regionPixels.width >= screen.width * 0.8)

        #expect(!RegionCaptureGeometry.looksLikeFullDisplayBuffer(
            imageSize: regionPixels,
            selection: half,
            screenFrame: screen,
            scale: scale
        ))
    }

    @Test
    func retinaFullDisplayBufferStillLooksLikeFullDisplay() {
        let screen = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        let half = CGRect(x: 0, y: 0, width: 500, height: 800)
        #expect(RegionCaptureGeometry.looksLikeFullDisplayBuffer(
            imageSize: CGSize(width: 2_000, height: 1_600),
            selection: half,
            screenFrame: screen,
            scale: 2
        ))
    }

    @Test
    func oneXFullDisplayFallbackStillTriggers() {
        let screen = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        let half = CGRect(x: 0, y: 0, width: 500, height: 800)
        #expect(!RegionCaptureGeometry.looksLikeFullDisplayBuffer(
            imageSize: CGSize(width: 500, height: 800),
            selection: half,
            screenFrame: screen,
            scale: 1
        ))
        #expect(RegionCaptureGeometry.looksLikeFullDisplayBuffer(
            imageSize: CGSize(width: 1_000, height: 800),
            selection: half,
            screenFrame: screen,
            scale: 1
        ))
    }

    @Test
    func fullScreenSelectionDoesNotCropOnRetina() {
        let screen = CGRect(x: 1920, y: 0, width: 1_000, height: 800)
        #expect(!RegionCaptureGeometry.looksLikeFullDisplayBuffer(
            imageSize: CGSize(width: 2_000, height: 1_600),
            selection: screen,
            screenFrame: screen,
            scale: 2
        ))
    }

    @Test
    func wideShortBannerFullDisplayFallbackTriggersOnHeightMismatch() {
        let screen = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        let wideBanner = CGRect(x: 50, y: 100, width: 800, height: 80)
        #expect(RegionCaptureGeometry.looksLikeFullDisplayBuffer(
            imageSize: CGSize(width: 2_000, height: 1_600),
            selection: wideBanner,
            screenFrame: screen,
            scale: 2
        ))
    }

    @Test
    func imageCropRectMapsSelectionOntoRetinaFullBuffer() {
        let screen = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        let selection = CGRect(x: 100, y: 200, width: 80, height: 40)
        let crop = RegionCaptureGeometry.imageCropRect(
            selection: selection,
            screenFrame: screen,
            imageSize: CGSize(width: 2_000, height: 1_600)
        )
        #expect(crop == CGRect(x: 200, y: 400, width: 160, height: 80))
    }

    @Test
    func screenshotFailureCopyIsExplicit() {
        #expect(ScreenshotTranslateSupport.message(for: .missingScreenCapture)
                == ScreenshotTranslateSupport.missingScreenCaptureCopy)
        #expect(ScreenshotTranslateSupport.message(for: .emptyRegion)
                == ScreenshotTranslateSupport.emptyRegionCopy)
        #expect(ScreenshotTranslateSupport.message(for: .ocrEmpty)
                == ScreenshotTranslateSupport.ocrEmptyCopy)
        #expect(ScreenshotTranslateSupport.message(for: .ocrFailed)
                == ScreenshotTranslateSupport.ocrFailedCopy)
        #expect(ScreenshotTranslateSupport.missingDeepSeekKeyCopy
                == SelectionTranslateSupport.missingDeepSeekKeyCopy)
        #expect(ScreenshotTranslateSupport.recognitionLanguages == ["zh-Hans", "en-US", "zh-Hant", "ja-JP", "ko-KR"])
    }

    @Test
    func screenshotPopoverHidesPromptOptimizeAndAllowsCopyOriginal() {
        let content = SelectionPopoverContent.translated(
            original: "Hello",
            translation: "你好",
            screenFrame: .zero
        ).asScreenshotResult()
        #expect(!content.showsOptimizeAction)
        #expect(!content.showsTranslateAction)
        #expect(content.allowsCopyOriginal)
        #expect(content.originalCopyText == "Hello")
        #expect(content.allowsCopy)
        #expect(content.copyText == "你好")

        let noTranslation = SelectionPopoverContent.noTranslationNeeded(
            original: "https://example.com",
            screenFrame: .zero,
            message: ScreenshotTranslateSupport.notTranslatableCopy
        ).asScreenshotResult()
        #expect(!noTranslation.allowsCopyOriginal)
        #expect(noTranslation.allowsCopy)
        #expect(noTranslation.copyText == "https://example.com")

        let emptyOriginal = SelectionPopoverContent.noTranslationNeeded(
            original: "   ",
            screenFrame: .zero,
            message: ScreenshotTranslateSupport.ocrEmptyCopy
        ).asScreenshotResult()
        #expect(!emptyOriginal.allowsCopyOriginal)
        #expect(!emptyOriginal.allowsCopy)

        let failedWithOCR = SelectionPopoverContent.failed(
            original: "Detected OCR source",
            message: "翻译失败",
            screenFrame: .zero
        ).asScreenshotResult()
        #expect(failedWithOCR.allowsCopyOriginal)
        #expect(failedWithOCR.originalCopyText == "Detected OCR source")

        let withOptimize = SelectionPopoverContent.translated(
            original: "Hello",
            translation: "你好",
            screenFrame: .zero
        )
        #expect(withOptimize.showsOptimizeAction)
        #expect(!withOptimize.allowsCopyOriginal)
    }
}
