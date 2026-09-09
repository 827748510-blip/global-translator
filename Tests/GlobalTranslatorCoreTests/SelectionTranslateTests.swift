import Foundation
import CoreGraphics
import Testing
import GlobalTranslatorCore

struct SelectionTranslateDecisionTests {
    @Test(arguments: ["", "   ", "\n\t", "https://example.com/a", "name@example.com",
                      "/Users/example/file.txt", "⌘⇧P", "timeout_ms", "getUserProfile", "A", "123,!?"])
    func filterRejectsDoNotRequestTranslation(_ text: String) {
        #expect(TextFilter.selectionDecision(text) == .skip)
        #expect(!TextFilter.shouldTranslate(text))
        #expect(!TextFilter.shouldOfferPromptOptimization(text))
        #expect(!TextFilter.shouldOfferSelectionPopover(text))
    }

    @Test(arguments: ["这是简体中文", "你好世界", "使用 Qwen3 模型进行翻译"])
    func simplifiedChineseIsAlreadyTargetLanguage(_ text: String) {
        #expect(TextFilter.selectionDecision(text) == .alreadyTargetLanguage)
        #expect(!TextFilter.shouldTranslate(text))
    }

    @Test
    func nonChineseTargetStillTranslatesSimplifiedChinese() {
        #expect(TextFilter.selectionDecision("你好世界", targetLanguage: "en") == .translate)
    }

    @Test(arguments: ["Translate this sentence", "Open", "這是繁體中文",
                      "Visit https://example.com/help for instructions."])
    func naturalLanguageIsTranslated(_ text: String) {
        #expect(TextFilter.selectionDecision(text) == .translate)
        #expect(TextFilter.shouldTranslate(text))
        #expect(TextFilter.shouldOfferSelectionPopover(text))
        #expect(TextFilter.shouldAutoTranslateSelection(text))
        #expect(TextFilter.shouldOfferPromptOptimization(text))
    }

    @Test
    func chineseDraftStillOffersPromptOptimization() {
        #expect(TextFilter.selectionDecision("一个女孩站在雨里") == .alreadyTargetLanguage)
        #expect(!TextFilter.shouldAutoTranslateSelection("一个女孩站在雨里"))
        #expect(TextFilter.shouldOfferPromptOptimization("一个女孩站在雨里"))
        #expect(TextFilter.shouldOfferSelectionPopover("一个女孩站在雨里"))
        #expect(!TextFilter.shouldOfferPromptOptimization("https://example.com/a"))
        #expect(!TextFilter.shouldOfferSelectionPopover(""))
    }

    @Test(arguments: [
        "Swift 6 + SwiftUI + ScreenCaptureKit",
        "SwiftUI + ScreenCaptureKit",
        "NSView / SwiftUI",
        "Vision + OCR"
    ])
    func technicalTokenPhrasesDoNotCallTranslation(_ text: String) {
        #expect(TextFilter.selectionDecision(text) == .noTranslationNeeded)
        #expect(!TextFilter.shouldTranslate(text))
        #expect(!TextFilter.shouldAutoTranslateSelection(text))
        #expect(TextFilter.shouldOfferSelectionPopover(text))
        #expect(TextFilter.shouldOfferPromptOptimization(text))
    }

    @Test(arguments: [
        "Hello world", "Open", "Apply Settings", "Translate this sentence",
        "File / Edit", "Copy + Paste", "Save / Export", "Xcode 16 + Swift 6",
        "Sentence 0", "Sentence 1", "Sentence 6", "Hello from the page"
    ])
    func ordinaryEnglishStillTranslates(_ text: String) {
        #expect(TextFilter.selectionDecision(text) == .translate)
        #expect(TextFilter.shouldTranslate(text))
    }
}

struct SelectionPointerAndDebounceTests {
    @Test
    func mouseUpAfterDragSchedulesSettleAndDragCancels() {
        var state = SelectionPointerState()
        #expect(state.handle(.down) == .cancelPending)
        #expect(!state.didDrag)
        #expect(state.handle(.dragged) == .cancelPending)
        #expect(state.didDrag)
        #expect(state.handle(.dragged) == .cancelPending)
        #expect(state.handle(.up) == .scheduleSettle)
        #expect(!state.isButtonDown)
        #expect(state.didDrag)
    }

    @Test
    func clickWithoutDragIsNotASelection() {
        var state = SelectionPointerState()
        #expect(state.handle(.down) == .cancelPending)
        #expect(state.handle(.up) == .scheduleSettle)
        #expect(!state.didDrag)
        #expect(state.handle(.down) == .cancelPending)
        #expect(!state.didDrag)
    }

    @Test
    func dragWithoutButtonDownIsIgnored() {
        var state = SelectionPointerState()
        #expect(state.handle(.dragged) == .ignore)
        #expect(!state.didDrag)
        #expect(state.handle(.up) == .ignore)
        #expect(!state.didDrag)
    }

    @Test
    func settleGateIgnoresStaleTokens() {
        var gate = SelectionSettleGate()
        let first = gate.next()
        #expect(gate.isCurrent(first))
        let second = gate.next()
        #expect(!gate.isCurrent(first))
        #expect(gate.isCurrent(second))
        gate.invalidate()
        #expect(!gate.isCurrent(second))
    }
}

struct SelectionPopoverContentTests {
    @Test
    func truncatedOriginalCapsLength() {
        let long = String(repeating: "a", count: 120)
        let preview = SelectionTranslateSupport.truncatedOriginal(long, limit: 80)
        #expect(preview.count == 81)
        #expect(preview.hasSuffix("…"))
    }

    @Test
    func alreadyChineseContentDoesNotExposeModelCallCopy() {
        let content = SelectionPopoverContent.alreadyChinese(
            original: "你好世界",
            screenFrame: CGRect(x: 10, y: 20, width: 40, height: 12)
        )
        #expect(content.displayTranslation == "已是中文")
        #expect(content.allowsCopy)
        #expect(content.copyText == "你好世界")
        #expect(content.originalPreview == "你好世界")
    }

    @Test
    func loadingAndTranslatedWireCopyToTranslation() {
        let loading = SelectionPopoverContent.loading(
            original: "Hello world",
            screenFrame: .zero
        )
        #expect(loading.displayTranslation == "翻译中…")
        #expect(!loading.allowsCopy)
        let done = SelectionPopoverContent.translated(
            original: "Hello world",
            translation: "你好，世界",
            screenFrame: .zero
        )
        #expect(done.displayTranslation == "你好，世界")
        #expect(done.allowsCopy)
        #expect(done.copyText == "你好，世界")
    }

    @Test
    func optimizedContentCopiesPromptAndKeepsActions() {
        let content = SelectionPopoverContent.optimized(
            original: "一个女孩站在雨里",
            prompt: "主体：雨中女孩，电影感布光。",
            screenFrame: .zero
        )
        #expect(content.status == .optimized)
        #expect(content.displayTranslation == "主体：雨中女孩，电影感布光。")
        #expect(content.allowsCopy)
        #expect(content.copyText == "主体：雨中女孩，电影感布光。")
        #expect(content.showsOptimizeAction)
        #expect(content.showsTranslateAction)
        let chinese = SelectionPopoverContent.alreadyChinese(
            original: "一个女孩站在雨里",
            screenFrame: .zero
        )
        #expect(chinese.showsOptimizeAction)
        #expect(!TextFilter.shouldAutoTranslateSelection(chinese.original))
    }

    @Test
    func noTranslationNeededContentKeepsOriginalAndOptimize() {
        let content = SelectionPopoverContent.noTranslationNeeded(
            original: "Swift 6 + SwiftUI + ScreenCaptureKit",
            screenFrame: CGRect(x: 10, y: 20, width: 40, height: 12)
        )
        #expect(content.status == .noTranslationNeeded)
        #expect(content.displayTranslation == "专有名词，无需翻译")
        #expect(content.allowsCopy)
        #expect(content.copyText == "Swift 6 + SwiftUI + ScreenCaptureKit")
        #expect(content.showsOptimizeAction)
        #expect(content.showsTranslateAction)
        #expect(content.displayTranslation != "服务返回异常，请稍后重试")
    }

    @Test
    func promptOptimizationInstructionsStayGeneric() {
        #expect(PromptOptimizeMode.allCases.count == 3)
        #expect(PromptOptimizationInstructions.system.contains("workplace or social communication"))
        #expect(PromptOptimizationInstructions.system.contains("untrusted data"))
        #expect(PromptOptimizationInstructions.system.contains("Do not turn the text into a generative image prompt"))
        #expect(!PromptOptimizationInstructions.system.lowercased().contains("jimeng"))
        #expect(!PromptOptimizationInstructions.system.lowercased().contains("kling"))
        #expect(!PromptOptimizationInstructions.system.lowercased().contains("midjourney"))
        let chinese = PromptOptimizationInstructions.userContent(for: "一个女孩站在雨里")
        #expect(chinese.contains("Simplified Chinese"))
        #expect(chinese.contains("一个女孩站在雨里"))
        #expect(chinese.contains("workplace or social communication"))
        let english = PromptOptimizationInstructions.userContent(for: "A girl standing in the rain on a city street at night")
        #expect(PromptOptimizationSupport.prefersEnglishOutput("A girl standing in the rain on a city street at night"))
        #expect(english.contains("Keep the output in English"))
        #expect(!PromptOptimizationSupport.prefersEnglishOutput("一个女孩站在雨里"))
    }

    @Test
    func promptOptimizationModesUseDistinctInstructions() {
        let systems = PromptOptimizeMode.allCases.map { PromptOptimizationInstructions.system(for: $0) }
        let uniqueSystems = Set(systems)
        #expect(uniqueSystems.count == PromptOptimizeMode.allCases.count)
        #expect(systems.allSatisfy { $0.contains("untrusted data") })
        #expect(systems.allSatisfy { $0.contains("Output only the rewritten text") })
        #expect(systems.allSatisfy { $0.contains("Do not turn the text into a generative image prompt") })
        #expect(PromptOptimizationInstructions.system(for: .communicationPolish).contains("workplace or social communication"))
        #expect(PromptOptimizationInstructions.system(for: .communicationPolish).contains("Do not flatter"))
        #expect(PromptOptimizationInstructions.system(for: .taskInstruction).contains("structured task brief"))
        #expect(PromptOptimizationInstructions.system(for: .taskInstruction).contains("no force-push"))
        #expect(PromptOptimizationInstructions.system(for: .taskInstruction).contains("mian"))
        #expect(PromptOptimizationInstructions.system(for: .wordingFix).contains("minimal edits"))
        #expect(PromptOptimizeMode.communicationPolish.title == "沟通润色")
        #expect(PromptOptimizeMode.taskInstruction.title == "任务指令")
        #expect(PromptOptimizeMode.wordingFix.title == "用词修正")
        #expect(PromptOptimizeMode.communicationPolish.optimizeAccessibilityHint.contains("得体"))
        #expect(PromptOptimizeMode.taskInstruction.optimizeAccessibilityHint.contains("结构化任务说明"))
        #expect(PromptOptimizeMode.wordingFix.optimizeAccessibilityHint.contains("错别字"))
        let polish = PromptOptimizationInstructions.userContent(for: "Use NSView", mode: .communicationPolish)
        let task = PromptOptimizationInstructions.userContent(for: "Use NSView", mode: .taskInstruction)
        let wording = PromptOptimizationInstructions.userContent(for: "Use NSView", mode: .wordingFix)
        #expect(polish != task)
        #expect(task != wording)
        #expect(polish.contains("workplace or social communication"))
        #expect(task.contains("structured task brief"))
        #expect(wording.contains("minimal changes"))
    }

    @Test
    func chineseTargetAliases() {
        #expect(SelectionTranslateSupport.isChineseTarget("zh-CN"))
        #expect(SelectionTranslateSupport.isChineseTarget("zh-Hans"))
        #expect(SelectionTranslateSupport.isChineseTarget("zh"))
        #expect(!SelectionTranslateSupport.isChineseTarget("en"))
    }
}
