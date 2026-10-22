import Foundation
import Testing
@testable import GlobalTranslatorCore

/// Opt-in smoke test against a real local Ollama. The default suite stays
/// hermetic; run this only on a machine with the model installed:
///
/// ```bash
/// GT_LIVE_OLLAMA=1 swift test --filter LiveOllamaSelectionSmokeTests
/// ```
///
/// Override the model with `GT_LIVE_OLLAMA_MODEL` (default
/// `global-translator-local:qwen3-4b`). This reproduces the real 2026-10-20
/// failure: the structured `json_object` call echoes brand names, the quality
/// gate rejects the echo, and the plain fallback prompt must recover a useful
/// answer instead of 「翻译失败」.
struct LiveOllamaSelectionSmokeTests {
    private static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["GT_LIVE_OLLAMA"] == "1"
    }

    private static var model: String {
        ProcessInfo.processInfo.environment["GT_LIVE_OLLAMA_MODEL"]
            ?? "global-translator-local:qwen3-4b"
    }

    @Test(.enabled(if: isEnabled))
    func plainFallbackRecoversProperNounsTheStructuredCallEchoes() async throws {
        let backend = try LocalOpenAIBackend(
            baseURL: URL(string: "http://127.0.0.1:11434/v1")!,
            model: Self.model
        )
        for source in ["Figma", "Spotify", "Python"] {
            let raw = try await backend.completePlain(
                system: SelectionFallbackInstructions.system,
                user: SelectionFallbackInstructions.userContent(for: source)
            )
            let cleaned = SelectionTranslateSupport.cleanPlainFallback(raw)
            #expect(!cleaned.isEmpty, "plain fallback returned empty for \(source)")
            #expect(
                !CopiedSourceDetector.translationCopiesSource(cleaned, source: source),
                "plain fallback echoed \(source) unchanged; the selection would fall back to 「专有名词，无需翻译」"
            )
        }
    }

    @Test(.enabled(if: isEnabled))
    func structuredCallRejectsEchoedBrandName() async throws {
        let backend = try LocalOpenAIBackend(
            baseURL: URL(string: "http://127.0.0.1:11434/v1")!,
            model: Self.model
        )
        let item = TranslationItem(id: UUID(), sourceText: "Figma")
        let request = TranslationRequest(
            windowRevision: 0,
            items: [item],
            copiedSourcePolicy: .reject
        )
        await #expect(throws: TranslationError.invalidResponse("translation copied the source")) {
            _ = try await backend.translate(request)
        }
    }
}
