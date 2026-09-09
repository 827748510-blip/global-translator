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
        #expect(state.handle(.up) == .scheduleSettle)
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
    func promptOptimizationInstructionsStayGeneric() {
        #expect(PromptOptimizationInstructions.system.contains("generic generative prompt"))
        #expect(PromptOptimizationInstructions.system.contains("untrusted data"))
        #expect(!PromptOptimizationInstructions.system.lowercased().contains("jimeng"))
        #expect(!PromptOptimizationInstructions.system.lowercased().contains("kling"))
        #expect(!PromptOptimizationInstructions.system.lowercased().contains("midjourney"))
        let chinese = PromptOptimizationInstructions.userContent(for: "一个女孩站在雨里")
        #expect(chinese.contains("Simplified Chinese"))
        #expect(chinese.contains("一个女孩站在雨里"))
        let english = PromptOptimizationInstructions.userContent(for: "A girl standing in the rain on a city street at night")
        #expect(PromptOptimizationSupport.prefersEnglishOutput("A girl standing in the rain on a city street at night"))
        #expect(english.contains("Keep the output in English"))
        #expect(!PromptOptimizationSupport.prefersEnglishOutput("一个女孩站在雨里"))
    }

    @Test
    func chineseTargetAliases() {
        #expect(SelectionTranslateSupport.isChineseTarget("zh-CN"))
        #expect(SelectionTranslateSupport.isChineseTarget("zh-Hans"))
        #expect(SelectionTranslateSupport.isChineseTarget("zh"))
        #expect(!SelectionTranslateSupport.isChineseTarget("en"))
    }
}
