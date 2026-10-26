import Foundation
import Testing
@testable import GlobalTranslatorCore

struct DeepSeekUsageTests {
    @Test
    func parsesUsageAndCachedTokensFromResponsesEnvelope() throws {
        let body = try responseBody(
            segmentID: PromptStableIdentifier.id(for: "hello"),
            translation: "你好",
            usage: [
                "input_tokens": 1_200,
                "input_tokens_details": ["cached_tokens": 900],
                "output_tokens": 300,
                "total_tokens": 1_500
            ]
        )
        let usage = try #require(DeepSeekUsageParser.parse(body))
        #expect(usage.inputTokens == 1_200)
        #expect(usage.cachedInputTokens == 900)
        #expect(usage.outputTokens == 300)
        #expect(usage.totalTokens == 1_500)
        #expect(usage.cacheableInputTokens == 1_200)
        #expect(usage.cacheHitRate == 0.75)
    }

    @Test
    func usageParserRejectsMissingOrMalformedUsageWithoutThrowing() throws {
        let withoutUsage = try JSONSerialization.data(withJSONObject: [
            "output": [["type": "message", "content": [["type": "output_text", "text": "{}"]]]]
        ])
        #expect(DeepSeekUsageParser.parse(withoutUsage) == nil)

        let malformed = try JSONSerialization.data(withJSONObject: [
            "usage": ["input_tokens": 10]
        ])
        #expect(DeepSeekUsageParser.parse(malformed) == nil)
    }

    @Test
    func cachedTokensAreClampedToInputTokens() {
        let usage = DeepSeekTokenUsage(inputTokens: 100, cachedInputTokens: 150, outputTokens: 10)
        #expect(usage.cachedInputTokens == 100)
        #expect(usage.cacheHitRate == 1)
    }

    @Test
    func snapshotComputesCacheHitRateAndOutputSpeedFromTokenCounts() {
        let snapshot = DeepSeekUsageSnapshot(
            requestCount: 2,
            inputTokens: 1_000,
            cachedInputTokens: 750,
            outputTokens: 100,
            generationSeconds: 2
        )
        #expect(snapshot.cacheHitRate == 0.75)
        #expect(snapshot.outputTokensPerSecond == 50)
    }

    @Test
    func pricingUsesPeakAndOffPeakFlashRates() throws {
        let peakDate = try #require(utcDate(year: 2026, month: 10, day: 27, hour: 2))
        let offPeakDate = try #require(utcDate(year: 2026, month: 10, day: 31, hour: 2))
        #expect(DeepSeekPricing.isPeak(at: peakDate))
        #expect(!DeepSeekPricing.isPeak(at: offPeakDate))

        let usage = DeepSeekTokenUsage(
            inputTokens: 1_000_000,
            cachedInputTokens: 500_000,
            outputTokens: 1_000_000
        )
        #expect(abs(DeepSeekPricing.estimatedCostUSD(usage: usage, at: peakDate) - 1.353) < 0.000_001)
        #expect(abs(DeepSeekPricing.estimatedCostUSD(usage: usage, at: offPeakDate) - 0.6765) < 0.000_001)
    }

    @Test
    func peakHoursStopAtTheBoundaryAndSkipWeekends() throws {
        let mondayAtFour = try #require(utcDate(year: 2026, month: 10, day: 26, hour: 4))
        let mondayAtSix = try #require(utcDate(year: 2026, month: 10, day: 26, hour: 6))
        let saturdayAtNine = try #require(utcDate(year: 2026, month: 10, day: 31, hour: 9))
        #expect(!DeepSeekPricing.isPeak(at: mondayAtFour))
        #expect(DeepSeekPricing.isPeak(at: mondayAtSix))
        #expect(!DeepSeekPricing.isPeak(at: saturdayAtNine))
    }

    @Test
    func usageStoreAggregatesAndResets() throws {
        let store = DeepSeekUsageStore()
        let date = try #require(utcDate(year: 2026, month: 10, day: 27, hour: 2))
        store.record(
            usage: DeepSeekTokenUsage(inputTokens: 1_000, cachedInputTokens: 600, outputTokens: 200),
            model: AppConfiguration.defaultDeepSeekModel,
            durationSeconds: 4,
            requestedAt: date
        )
        store.record(
            usage: DeepSeekTokenUsage(inputTokens: 500, cachedInputTokens: 500, outputTokens: 100),
            model: AppConfiguration.defaultDeepSeekModel,
            durationSeconds: 1,
            requestedAt: date
        )
        let snapshot = store.snapshot()
        #expect(snapshot.requestCount == 2)
        #expect(snapshot.inputTokens == 1_500)
        #expect(snapshot.cachedInputTokens == 1_100)
        #expect(snapshot.outputTokens == 300)
        #expect(snapshot.generationSeconds == 5)
        #expect(abs(snapshot.cacheHitRate - (1_100.0 / 1_500.0)) < 0.000_001)
        #expect(abs(snapshot.outputTokensPerSecond - 60) < 0.000_001)
        #expect(snapshot.estimatedCostUSD > 0)

        store.reset()
        #expect(store.snapshot().requestCount == 0)
        #expect(store.snapshot().estimatedCostUSD == 0)
    }

    @Test
    func backendRecordsUsageForEverySuccessfulResponsesCall() async throws {
        let item = TranslationItem(id: PromptStableIdentifier.id(for: "hello"), sourceText: "hello")
        let body = try responseBody(
            segmentID: item.id,
            translation: "你好",
            usage: [
                "input_tokens": 1_000,
                "input_tokens_details": ["cached_tokens": 800],
                "output_tokens": 100,
                "total_tokens": 1_100
            ]
        )
        let transport = UsageTransport(bodies: [body, body])
        let store = DeepSeekUsageStore()
        let backend = DeepSeekBackend(
            transport: transport,
            credentialStore: UsageCredentialStore(value: "test-key"),
            usageStore: store
        )

        _ = try await backend.translate(TranslationRequest(windowRevision: 1, items: [item]))
        _ = try await backend.completePlain(system: "system", user: "user")

        let snapshot = store.snapshot()
        #expect(snapshot.requestCount == 2)
        #expect(snapshot.inputTokens == 2_000)
        #expect(snapshot.cachedInputTokens == 1_600)
        #expect(snapshot.outputTokens == 200)
        #expect(snapshot.cacheHitRate == 0.8)
        #expect(snapshot.outputTokensPerSecond > 0)
    }

    @Test
    func backendDoesNotRecordMissingUsage() async throws {
        let item = TranslationItem(id: PromptStableIdentifier.id(for: "hello"), sourceText: "hello")
        let body = try JSONSerialization.data(withJSONObject: [
            "output": [["type": "message", "content": [[
                "type": "output_text",
                "text": "{\"translations\":[{\"segmentId\":\"\(item.id.uuidString)\",\"text\":\"你好\"}]}"
            ]]]]
        ])
        let store = DeepSeekUsageStore()
        let backend = DeepSeekBackend(
            transport: UsageTransport(bodies: [body]),
            credentialStore: UsageCredentialStore(value: "test-key"),
            usageStore: store
        )
        _ = try await backend.translate(TranslationRequest(windowRevision: 1, items: [item]))
        #expect(store.snapshot().requestCount == 0)
    }

    @Test
    func repeatedContentSendsByteIdenticalPayloadsRegardlessOfInputOrder() async throws {
        let items = [
            TranslationItem(id: PromptStableIdentifier.id(for: "hello"), sourceText: "hello"),
            TranslationItem(id: PromptStableIdentifier.id(for: "world"), sourceText: "world")
        ]
        let response = try responseBody(
            translations: [(items[0].id, "你好"), (items[1].id, "世界")],
            usage: nil
        )
        let transport = UsageTransport(bodies: [response, response])
        let backend = DeepSeekBackend(
            transport: transport,
            credentialStore: UsageCredentialStore(value: "test-key"),
            usageStore: DeepSeekUsageStore()
        )

        _ = try await backend.translate(TranslationRequest(windowRevision: 1, items: items))
        _ = try await backend.translate(TranslationRequest(windowRevision: 2, items: Array(items.reversed())))

        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(requests[0].httpBody == requests[1].httpBody)

        let body = try #require(requests[0].httpBody)
        let payload = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(payload["stream"] as? Bool == false)
        #expect(payload["temperature"] as? Double == 0.1)
        #expect(payload["max_output_tokens"] as? Int == 8_192)
        let reasoning = try #require(payload["reasoning"] as? [String: Any])
        #expect(reasoning["effort"] as? String == "none")
        let text = try #require(payload["text"] as? [String: Any])
        let format = try #require(text["format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
    }

    @Test
    func stableIdentifierIsDeterministicAcrossCaptures() {
        let first = PromptStableIdentifier.id(for: "hello")
        let second = PromptStableIdentifier.id(for: "hello")
        let other = PromptStableIdentifier.id(for: "world")
        #expect(first == second)
        #expect(first != other)
    }

    @Test
    func snapshotConvertsUSDToRMBAtDisplayRate() {
        let snapshot = DeepSeekUsageSnapshot(estimatedCostUSD: 0.001796)
        #expect(abs(snapshot.estimatedCostCNY - 0.0129312) < 0.000_000_1)
    }

    @Test
    func translationPromptKeepsALongSharedPrefixAcrossDirections() {
        let chinese = TranslationInstructions.system(for: .toChinese)
        let english = TranslationInstructions.system(for: .toEnglish)
        let shared = commonPrefix(chinese, english)
        #expect(shared.count >= 400)
        #expect(shared.contains("untrusted data"))
        #expect(shared.contains("segmentId"))
        #expect(chinese.hasSuffix("Simplified Chinese"))
        #expect(english.hasSuffix("English"))
    }

    private func commonPrefix(_ lhs: String, _ rhs: String) -> String {
        var prefix = ""
        for (left, right) in zip(lhs, rhs) {
            guard left == right else { break }
            prefix.append(left)
        }
        return prefix
    }

    private func responseBody(
        segmentID: UUID,
        translation: String,
        usage: [String: Any]?
    ) throws -> Data {
        try responseBody(translations: [(segmentID, translation)], usage: usage)
    }

    private func responseBody(
        translations: [(UUID, String)],
        usage: [String: Any]?
    ) throws -> Data {
        let entries = translations.map { id, text in
            "{\"segmentId\":\"\(id.uuidString)\",\"text\":\"\(text)\"}"
        }.joined(separator: ",")
        let content = "{\"translations\":[\(entries)]}"
        var root: [String: Any] = [
            "output": [["type": "message", "content": [["type": "output_text", "text": content]]]]
        ]
        if let usage {
            root["usage"] = usage
        }
        return try JSONSerialization.data(withJSONObject: root)
    }

    private func utcDate(year: Int, month: Int, day: Int, hour: Int) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))
    }
}

private actor UsageTransport: HTTPTransport {
    private var bodies: [Data]
    private(set) var requests: [URLRequest] = []

    init(bodies: [Data]) {
        self.bodies = bodies
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        guard !bodies.isEmpty else {
            throw HTTPTransportError.networkFailure
        }
        return HTTPResponse(statusCode: 200, headers: [:], body: bodies.removeFirst())
    }
}

private final class UsageCredentialStore: CredentialStoring, @unchecked Sendable {
    private let value: String?

    init(value: String?) {
        self.value = value
    }

    func save(apiKey: String) throws {}
    func read() throws -> String? { value }
    func delete() throws {}
}
