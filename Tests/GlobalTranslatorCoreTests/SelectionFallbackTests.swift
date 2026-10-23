import Foundation
import Testing
@testable import GlobalTranslatorCore

struct CopiedSourceDetectorTests {
    @Test
    func detectsCaseInsensitiveEchoOfLatinSource() {
        #expect(CopiedSourceDetector.translationCopiesSource("Figma", source: "Figma"))
        #expect(CopiedSourceDetector.translationCopiesSource("figma", source: "Figma"))
        #expect(CopiedSourceDetector.translationCopiesSource("  Spotify  ", source: "Spotify"))
    }

    @Test
    func properNounNoteIsNotAnEcho() {
        #expect(!CopiedSourceDetector.translationCopiesSource("Figma（设计工具）", source: "Figma"))
        #expect(!CopiedSourceDetector.translationCopiesSource("Python（编程语言）", source: "Python"))
    }

    @Test
    func ineligibleSourcesAreNeverTreatedAsEcho() {
        // URLs / identifiers / already-Chinese text never reach the model, so a
        // mismatch or equality there must not be misreported as copied source.
        #expect(!CopiedSourceDetector.translationCopiesSource("https://example.com", source: "https://example.com"))
        #expect(!CopiedSourceDetector.translationCopiesSource("", source: "Figma"))
        #expect(!CopiedSourceDetector.translationCopiesSource("Figma", source: ""))
    }

    @Test
    func chineseEchoIsDetectedForZhToEn() {
        // zh→en 方向：模型把中文原文原样返回，等同没翻译，必须被识别为回声。
        #expect(CopiedSourceDetector.translationCopiesSource("一个女孩站在雨里", source: "一个女孩站在雨里"))
        // 正常翻译成英文不回声。
        #expect(!CopiedSourceDetector.translationCopiesSource("A girl standing in the rain", source: "一个女孩站在雨里"))
        // 部分翻译（中英混排）不算回声。
        #expect(!CopiedSourceDetector.translationCopiesSource("一个女孩 standing in the rain", source: "一个女孩站在雨里"))
    }
}

struct SelectionFallbackInstructionsTests {
    @Test
    func systemPromptKeepsProperNounGuidanceAndUntrustedDataGuard() {
        let system = SelectionFallbackInstructions.system()
        #expect(system.contains("proper noun"))
        #expect(system.contains("untrusted data"))
        #expect(system.contains("Simplified Chinese"))
    }

    @Test
    func userContentIsTheRawSelection() {
        let source = "Figma\n0: not a keyed blob"
        #expect(SelectionFallbackInstructions.userContent(for: source) == source)
    }

    @Test
    func cleanPlainFallbackStripsWrappingQuotesAndLabels() {
        #expect(SelectionTranslateSupport.cleanPlainFallback("“Figma（设计工具）”") == "Figma（设计工具）")
        #expect(SelectionTranslateSupport.cleanPlainFallback("\"Figma（设计工具）\"") == "Figma（设计工具）")
        #expect(SelectionTranslateSupport.cleanPlainFallback("译文：快速") == "快速")
        #expect(SelectionTranslateSupport.cleanPlainFallback("  你好  ") == "你好")
        #expect(SelectionTranslateSupport.cleanPlainFallback("   ") == "")
    }

    @Test
    func fallbackBudgetStaysBelowTheChunkingLimit() {
        #expect(SelectionTranslateSupport.plainFallbackMaxCharacters > 0)
        #expect(
            SelectionTranslateSupport.plainFallbackMaxCharacters
                < SelectionTranslateSupport.selectionChunkCharacters
        )
    }

    @Test
    func properNounPhraseDistinguishesBrandsFromSentences() {
        #expect(SelectionTranslateSupport.isProperNounPhrase("Figma"))
        #expect(SelectionTranslateSupport.isProperNounPhrase("npm"))
        #expect(SelectionTranslateSupport.isProperNounPhrase("Mac Studio"))
        #expect(SelectionTranslateSupport.isProperNounPhrase("Vision Pro"))
        #expect(SelectionTranslateSupport.isProperNounPhrase("PostgreSQL 16"))
        #expect(!SelectionTranslateSupport.isProperNounPhrase("Please review the pull request"))
        #expect(!SelectionTranslateSupport.isProperNounPhrase("Hello world"))
        #expect(!SelectionTranslateSupport.isProperNounPhrase("Figma is a design tool."))
        #expect(!SelectionTranslateSupport.isProperNounPhrase(""))
        #expect(!SelectionTranslateSupport.isProperNounPhrase("这 是 中文"))
        #expect(!SelectionTranslateSupport.isProperNounPhrase(String(repeating: "Figma ", count: 20)))
    }
}
