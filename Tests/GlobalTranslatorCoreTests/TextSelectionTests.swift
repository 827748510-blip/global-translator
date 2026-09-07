import Testing
import GlobalTranslatorCore

struct TextSelectionTests {
    @Test(arguments: [
        "Visit https://example.com/help for instructions.",
        "Use /usr/local/bin to run this command.",
        "Save your report to C:\\Users\\Public\\report.txt.",
        "Please choose src/components/Button.swift and continue."
    ])
    func naturalLanguageContainingAddressesIsNotDiscarded(_ text: String) {
        #expect(TextFilter.shouldTranslate(text))
    }

    @Test(arguments: ["使用 Qwen3 模型进行翻译", "API 设置", "文件已保存为 PDF 格式", "当前 CPU 使用率为 20%"])
    func chineseInterfaceWithTechnicalNamesDoesNotNeedAnotherTranslation(_ text: String) {
        #expect(!TextFilter.shouldTranslate(text))
    }

    @Test(arguments: ["timeout_ms", "getUserProfile", "TranslationSession", "ApplicationController.swift M", "package.json U", ".gitignore", "0xDEADBEEF", "v1.2.3", "32 GB", "60 FPS", "A"])
    func identifiersAndUnitValuesAreNotNaturalLanguage(_ text: String) {
        #expect(!TextFilter.shouldTranslate(text))
    }

    @Test(arguments: ["Open", "SAVE", "Apply Settings", "Read Before Closing.txt", "This model supports 中文 output.", "請使用本地模型"])
    func meaningfulForeignLabelsAndSentencesStillTranslate(_ text: String) {
        #expect(TextFilter.shouldTranslate(text))
    }
}
