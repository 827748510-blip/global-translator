import Foundation
import Testing
@testable import GlobalTranslatorCapture
@testable import GlobalTranslatorCore
@testable import GlobalTranslatorEngine

struct SelectionDirectionCoordinatorTests {
    @Test
    func coordinatorThreadsTargetLanguageIntoRequestAndCacheKey() async throws {
        let backend = RecordingBackend(kind: .local) { request, _ in
            TranslationResult(
                windowRevision: request.windowRevision,
                translations: request.items.map { Translation(segmentId: $0.id, simplifiedChineseText: "译") }
            )
        }
        let coordinator = TranslationCoordinator(
            backends: [backend],
            permissions: SystemPermissionController(snapshotProvider: { .allGranted })
        )
        // 划词路径：中文源覆盖目标为英文，请求必须带上 targetLanguage=en。
        let zhSnapshot = makeSnapshot(regions: [makeRegion(text: "你好世界")], revision: 1)
        _ = try await coordinator.translate(
            snapshot: zhSnapshot,
            backend: .local,
            modelIdentifier: "qwen",
            visionFallbackEnabled: false,
            includeIneligibleText: true,
            targetLanguage: "en"
        )
        let englishRequest = await backend.requests.first
        #expect(englishRequest?.targetLanguage == "en")

        // 覆盖层 / 桥接路径不覆盖：请求 targetLanguage 仍为 nil（默认简体中文）。
        let defaultSnapshot = makeSnapshot(regions: [makeRegion(text: "Hello world")], revision: 2)
        _ = try await coordinator.translate(
            snapshot: defaultSnapshot,
            backend: .local,
            modelIdentifier: "qwen",
            visionFallbackEnabled: false
        )
        let defaultRequest = await backend.requests.last
        #expect(defaultRequest?.targetLanguage == nil)
    }

    @Test
    func cacheSeparatesChineseAndEnglishTranslationsOfTheSameText() async throws {
        let backend = RecordingBackend(kind: .local) { request, _ in
            TranslationResult(
                windowRevision: request.windowRevision,
                translations: request.items.map {
                    Translation(
                        segmentId: $0.id,
                        simplifiedChineseText: request.targetLanguage == "en" ? "English out" : "中文 out"
                    )
                }
            )
        }
        let coordinator = TranslationCoordinator(
            backends: [backend],
            permissions: SystemPermissionController(snapshotProvider: { .allGranted })
        )
        let snapshot = makeSnapshot(regions: [makeRegion(text: "你好世界")], revision: 1)
        let first = try await coordinator.translate(
            snapshot: snapshot, backend: .local, modelIdentifier: "qwen",
            visionFallbackEnabled: false, includeIneligibleText: true, targetLanguage: "en"
        )
        #expect(first.translations.first?.text == "English out")
        // 同一文本再按中文目标翻译：不能命中英文缓存。
        let second = try await coordinator.translate(
            snapshot: snapshot, backend: .local, modelIdentifier: "qwen",
            visionFallbackEnabled: false, includeIneligibleText: true, targetLanguage: "zh-Hans"
        )
        #expect(second.translations.first?.text == "中文 out")
        #expect(await backend.requests.count == 2)
    }
}
