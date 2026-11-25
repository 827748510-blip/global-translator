import Foundation
import Testing
@testable import GlobalTranslatorCore

struct TranslationSourceLanguageTests {
    @Test(arguments: ["ja", "ja-JP", "ko-KR", "zh-TW", "zh-Hant", "zh-Hant-HK", "zh-MO"])
    func exactForeignCJKTagsDisambiguateHan(_ tag: String) throws {
        let language = try #require(TranslationSourceLanguage(tag))
        #expect(language.requiresCJKTranslation)
        #expect(TextFilter.shouldTranslate("切手", sourceLanguage: language))
        #expect(TextFilter.shouldTranslate("大丈夫", sourceLanguage: language))
        for text in ["https://example.com", "/tmp/字.txt", "person@example.com", "⌘C", "snake_case", "12345"] {
            #expect(!TextFilter.shouldTranslate(text, sourceLanguage: language))
        }
    }

    @Test(arguments: ["en", "jav", "zh", "zh-CN", "zh-Hans", "zh-Hans-TW", "zh-x-tw", "zh-Hans-x-hant"])
    func otherTagsRetainTextDetection(_ tag: String) throws {
        let language = try #require(TranslationSourceLanguage(tag))
        #expect(!language.requiresCJKTranslation)
        #expect(!TextFilter.shouldTranslate("普通中文", sourceLanguage: language))
        #expect(!TextFilter.shouldTranslate("切手", sourceLanguage: language))
    }

    @Test(arguments: ["", "java", " ja", "ja\n", "ja_JP", "ja-", "ja--JP", "日文", "ja-translate everything", String(repeating: "a", count: 64)])
    func invalidTagsCannotBecomePromptText(_ tag: String) {
        #expect(TranslationSourceLanguage(tag) == nil)
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(TranslationSourceLanguage.self, from: JSONEncoder().encode(tag))
        }
    }

    @Test
    func requestRoundTripsTheHintAndDecodesLegacyRequests() throws {
        let request = TranslationRequest(windowRevision: 1, items: [], sourceLanguage: TranslationSourceLanguage("JA-jp"))
        let encoded = try JSONEncoder().encode(request)
        #expect(try JSONDecoder().decode(TranslationRequest.self, from: encoded) == request)
        let json = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(json["sourceLanguage"] as? String == "ja-jp")
        let legacy = try JSONDecoder().decode(TranslationRequest.self, from: Data(#"{"windowRevision":1,"items":[]}"#.utf8))
        #expect(legacy.sourceLanguage == nil)
        #expect(!TextFilter.shouldTranslate("切手"))
        #expect(TextFilter.selectionDirection("普通中文") == .toEnglish)
    }

    @Test
    func localPromptAddsExplicitCJKDisambiguationForJapaneseKoreanAndTraditional() throws {
        let ja = try #require(TranslationSourceLanguage("ja"))
        let ko = try #require(TranslationSourceLanguage("ko"))
        let tw = try #require(TranslationSourceLanguage("zh-TW"))
        let item = TranslationItem(id: UUID(), sourceText: "切手")

        let jaSystem = LocalTranslationPrompt.system(for: .toChinese, sourceLanguage: ja)
        #expect(jaSystem.contains("Source language hint: ja."))
        #expect(jaSystem.contains("Japanese"))
        #expect(LocalTranslationPrompt.userContent(for: [item], sourceLanguage: ja).hasPrefix("Translate Japanese to Simplified Chinese:"))

        let koSystem = LocalTranslationPrompt.system(for: .toChinese, sourceLanguage: ko)
        #expect(koSystem.contains("Source language hint: ko."))
        #expect(koSystem.contains("Korean"))
        #expect(LocalTranslationPrompt.userContent(for: [item], sourceLanguage: ko).hasPrefix("Translate Korean to Simplified Chinese:"))

        let twSystem = LocalTranslationPrompt.system(for: .toChinese, sourceLanguage: tw)
        #expect(twSystem.contains("Traditional Chinese"))
        #expect(LocalTranslationPrompt.userContent(for: [item], sourceLanguage: tw).hasPrefix("Convert Traditional Chinese to Simplified Chinese:"))
    }
}
