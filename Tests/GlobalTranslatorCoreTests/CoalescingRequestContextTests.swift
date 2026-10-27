import Foundation
import Testing
@testable import GlobalTranslatorCore

private actor ContextBackend: TranslationBackend {
    let kind: BackendKind = .local
    private(set) var requests: [TranslationRequest] = []
    func healthCheck() async -> BackendHealth { BackendHealth(status: .healthy, message: "fake") }
    func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        requests.append(request)
        try await Task.sleep(for: .milliseconds(80))
        try Task.checkCancellation()
        return TranslationResult(windowRevision: request.windowRevision, translations: request.items.map {
            Translation(segmentId: $0.id, simplifiedChineseText: (request.sourceLanguage?.tag ?? "auto") + ":" + $0.sourceText)
        })
    }
}

struct CoalescingRequestContextTests {
    @Test
    func identicalContextStillCoalescesAndRemapsIDsAndRevision() async throws {
        let base = ContextBackend()
        let backend = CoalescingTranslationBackend(base: base)
        let first = TranslationRequest(windowRevision: 1, items: [TranslationItem(id: UUID(), sourceText: "same text")], sourceLanguage: TranslationSourceLanguage("ja"))
        let second = TranslationRequest(windowRevision: 2, items: [TranslationItem(id: UUID(), sourceText: "same text")], sourceLanguage: TranslationSourceLanguage("ja"))
        let task = Task { try await backend.translate(first) }
        for _ in 0..<200 where await base.requests.isEmpty { await Task.yield() }
        let result = try await backend.translate(second)
        _ = try await task.value
        #expect(await base.requests.count == 1)
        #expect(result.windowRevision == 2)
        #expect(result.translations.first?.segmentId == second.items[0].id)
        let cached = try await backend.translate(first)
        #expect(cached.windowRevision == 1)
        #expect(cached.translations.first?.segmentId == first.items[0].id)
        #expect(await base.requests.count == 1)
    }

    @Test
    func pendingDifferentLanguagesDoNotShareAFlight() async throws {
        let base = ContextBackend()
        let backend = CoalescingTranslationBackend(base: base)
        let items = [TranslationItem(id: UUID(), sourceText: "same text")]
        let first = Task { try await backend.translate(TranslationRequest(windowRevision: 1, items: items, sourceLanguage: TranslationSourceLanguage("ja"))) }
        for _ in 0..<200 where await base.requests.isEmpty { await Task.yield() }
        let result = try await backend.translate(TranslationRequest(windowRevision: 2, items: items, sourceLanguage: TranslationSourceLanguage("ko")))
        #expect(result.translations.first?.simplifiedChineseText == "ko:same text")
        await #expect(throws: CancellationError.self) { _ = try await first.value }
        #expect(await base.requests.count == 2)
    }
}
