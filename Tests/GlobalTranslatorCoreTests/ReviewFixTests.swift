import Foundation
import Testing
@testable import GlobalTranslatorCore

struct ReviewFixTests {
    @Test
    func deepSeekUsesFixedEndpointInstructionAndOnePost() async throws {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let output = #"{"output":[{"type":"message","content":[{"type":"output_text","text":"{\"translations\":[{\"segmentId\":\"00000000-0000-0000-0000-000000000001\",\"text\":\"你好\"}]}"}]}]}"#
        let transport = ReviewTransport(responses: [
            HTTPResponse(statusCode: 200, headers: [:], body: Data(output.utf8))
        ])
        let backend = DeepSeekBackend(transport: transport, credentialStore: ReviewCredentials(value: "key"))
        let result = try await backend.translate(TranslationRequest(windowRevision: 8, items: [TranslationItem(id: id, sourceText: "hello")]))
        #expect(result.translations.first?.simplifiedChineseText == "你好")
        let requests = await transport.requests
        #expect(requests.count == 1)
        #expect(requests[0].url?.absoluteString == "https://api.deepseek.com/responses")
        let body = try #require(requests[0].httpBody)
        let payload = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(payload["model"] as? String == "deepseek-chat")
        let input = try #require(payload["input"] as? [[String: Any]])
        #expect(input.count == 2)
        #expect(input[0]["role"] as? String == "system")
        #expect((input[0]["content"] as? String)?.isEmpty == false)
        #expect(input[1]["role"] as? String == "user")
        let userData = try #require((input[1]["content"] as? String)?.data(using: .utf8))
        let userItems = try #require(try JSONSerialization.jsonObject(with: userData) as? [[String: Any]])
        #expect(userItems.count == 1)
        #expect(Set(userItems[0].keys) == Set(["segmentId", "sourceText"]))
        expectNestedReasoningNone(payload)
        if let temperature = payload["temperature"] as? Double {
            #expect(abs(temperature - 0.1) < 0.001)
        } else {
            Issue.record("missing temperature")
        }
    }

    @Test
    func deepSeekPlainCompletionOmitsTranslationSchema() async throws {
        let output = #"{"output":[{"type":"message","content":[{"type":"output_text","text":"主体：雨中女孩"}]}]}"#
        let transport = ReviewTransport(responses: [
            HTTPResponse(statusCode: 200, headers: [:], body: Data(output.utf8))
        ])
        let backend = DeepSeekBackend(transport: transport, credentialStore: ReviewCredentials(value: "key"))
        let text = try await backend.completePlain(
            system: PromptOptimizationInstructions.system,
            user: PromptOptimizationInstructions.userContent(for: "一个女孩站在雨里")
        )
        #expect(text == "主体：雨中女孩")
        let body = try #require(await transport.requests.first?.httpBody)
        let payload = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(payload["text"] == nil)
        if let tokens = payload["max_output_tokens"] as? Int {
            #expect(tokens == 2_048)
        } else if let tokens = payload["max_output_tokens"] as? Double {
            #expect(Int(tokens) == 2_048)
        } else {
            Issue.record("missing max_output_tokens")
        }
        expectNestedReasoningNone(payload)
        let input = try #require(payload["input"] as? [[String: Any]])
        #expect((input[0]["content"] as? String)?.contains("workplace or social communication") == true)
        #expect((input[1]["content"] as? String)?.contains("一个女孩站在雨里") == true)
        if let temperature = payload["temperature"] as? Double {
            #expect(abs(temperature - 0.3) < 0.001)
        } else {
            Issue.record("missing temperature")
        }
    }

    @Test
    func deepSeekResponsesPayloadsEncodeNestedReasoningNoneForChatAndV4() async throws {
        let models = ["deepseek-chat", "deepseek-v4-flash", "deepseek-v4-flash-vision-exp"]
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let translateOutput = #"{"output":[{"type":"message","content":[{"type":"output_text","text":"{\"translations\":[{\"segmentId\":\"00000000-0000-0000-0000-000000000001\",\"text\":\"你好\"}]}"}]}]}"#
        let plainOutput = #"{"output":[{"type":"message","content":[{"type":"output_text","text":"优化后"}]}]}"#
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let request = TranslationRequest(windowRevision: 1, items: [TranslationItem(id: id, sourceText: "hello")])

        for model in models {
            let translateTransport = ReviewTransport(responses: [
                HTTPResponse(statusCode: 200, headers: [:], body: Data(translateOutput.utf8))
            ])
            let translateBackend = DeepSeekBackend(
                transport: translateTransport,
                credentialStore: ReviewCredentials(value: "key"),
                model: model
            )
            _ = try await translateBackend.translate(request)
            let translatePayload = try #require(
                try JSONSerialization.jsonObject(with: try #require(await translateTransport.requests.first?.httpBody)) as? [String: Any]
            )
            #expect(translatePayload["model"] as? String == model)
            expectNestedReasoningNone(translatePayload)
            #expect(translatePayload["text"] != nil)

            let plainTransport = ReviewTransport(responses: [
                HTTPResponse(statusCode: 200, headers: [:], body: Data(plainOutput.utf8))
            ])
            let plainBackend = DeepSeekBackend(
                transport: plainTransport,
                credentialStore: ReviewCredentials(value: "key"),
                model: model
            )
            _ = try await plainBackend.completePlain(system: "sys", user: "draft")
            let plainPayload = try #require(
                try JSONSerialization.jsonObject(with: try #require(await plainTransport.requests.first?.httpBody)) as? [String: Any]
            )
            #expect(plainPayload["model"] as? String == model)
            expectNestedReasoningNone(plainPayload)
            #expect(plainPayload["text"] == nil)
            if let tokens = plainPayload["max_output_tokens"] as? Int {
                #expect(tokens == 2_048)
            } else if let tokens = plainPayload["max_output_tokens"] as? Double {
                #expect(Int(tokens) == 2_048)
            } else {
                Issue.record("missing max_output_tokens for \(model)")
            }

            let visionTransport = ReviewTransport(responses: [
                HTTPResponse(statusCode: 200, headers: [:], body: Data(translateOutput.utf8))
            ])
            let visionBackend = DeepSeekBackend(
                transport: visionTransport,
                credentialStore: ReviewCredentials(value: "key"),
                model: model
            )
            _ = try await visionBackend.translate(
                request,
                images: [VisionTranslationImage(segmentId: id, pngData: png)]
            )
            let visionPayload = try #require(
                try JSONSerialization.jsonObject(with: try #require(await visionTransport.requests.first?.httpBody)) as? [String: Any]
            )
            #expect(visionPayload["model"] as? String == model)
            expectNestedReasoningNone(visionPayload)
            let serialized = String(decoding: try JSONSerialization.data(withJSONObject: visionPayload), as: UTF8.self)
            #expect(serialized.contains("input_image"))
        }
    }

    @Test
    func deepSeekHealthDiscoversFixedModelAndReadFailureIsUnavailable() async {
        let models = Data(#"{"data":[{"id":"deepseek-chat"}]}"#.utf8)
        let transport = ReviewTransport(responses: [HTTPResponse(statusCode: 200, headers: [:], body: models)])
        let backend = DeepSeekBackend(transport: transport, credentialStore: ReviewCredentials(value: "key"))
        let healthy = await backend.healthCheck()
        #expect(healthy.status == .healthy)
        let requests = await transport.requests
        #expect(requests.count == 1)
        #expect(requests[0].url?.absoluteString == "https://api.deepseek.com/models")

        let unavailable = DeepSeekBackend(transport: ReviewTransport(responses: []), credentialStore: FailingCredentials())
        let health = await unavailable.healthCheck()
        #expect(health.status == .unavailable)
    }

    @Test
    func deepSeekUsesConfiguredModelAndHealthDoesNotRequireLegacyVisionId() async throws {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let output = #"{"output":[{"type":"message","content":[{"type":"output_text","text":"{\"translations\":[{\"segmentId\":\"00000000-0000-0000-0000-000000000001\",\"text\":\"你好\"}]}"}]}]}"#
        let transport = ReviewTransport(responses: [
            HTTPResponse(statusCode: 200, headers: [:], body: Data(output.utf8))
        ])
        let backend = DeepSeekBackend(
            transport: transport,
            credentialStore: ReviewCredentials(value: "key"),
            model: "deepseek-reasoner"
        )
        _ = try await backend.translate(TranslationRequest(windowRevision: 1, items: [TranslationItem(id: id, sourceText: "hello")]))
        let body = try #require(await transport.requests.first?.httpBody)
        let payload = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(payload["model"] as? String == "deepseek-reasoner")

        let listed = Data(#"{"data":[{"id":"deepseek-chat"},{"id":"deepseek-reasoner"}]}"#.utf8)
        let healthTransport = ReviewTransport(responses: [HTTPResponse(statusCode: 200, headers: [:], body: listed)])
        let defaultBackend = DeepSeekBackend(
            transport: healthTransport,
            credentialStore: ReviewCredentials(value: "key")
        )
        let healthy = await defaultBackend.healthCheck()
        #expect(healthy.status == .healthy)
        #expect(healthy.availableModels == ["deepseek-chat", "deepseek-reasoner"])
    }

    @Test
    func localHealthDiscoversModelsBeforeSelectedModelValidation() async {
        let transport = ReviewTransport(responses: [
            HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"data":[{"id":"qwen-local"}]}"#.utf8))
        ])
        let backend = try! LocalOpenAIBackend(
            baseURL: URL(string: "http://127.0.0.1:11434/v1")!,
            model: "",
            transport: transport
        )

        let health = await backend.healthCheck()

        #expect(health.status == .invalidConfiguration)
        #expect(health.availableModels == ["qwen-local"])
        let requests = await transport.requests
        #expect(requests.count == 1)
        #expect(requests[0].url?.path == "/v1/models")
    }

    @Test
    func localHealthRequiresSuccessfulStructuredTranslationSample() async {
        let sampleID = "00000000-0000-0000-0000-000000000000"
        let sample = #"{"choices":[{"message":{"role":"assistant","content":"{\"translations\":[{\"segmentId\":\"\#(sampleID)\",\"text\":\"你好\"}]}"}}]}"#
        let transport = ReviewTransport(responses: [
            HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"data":[{"id":"qwen-local"}]}"#.utf8)),
            HTTPResponse(statusCode: 200, headers: [:], body: Data(sample.utf8))
        ])
        let backend = try! LocalOpenAIBackend(
            baseURL: URL(string: "http://127.0.0.1:11434/v1")!,
            model: "qwen-local",
            transport: transport
        )

        let health = await backend.healthCheck()

        #expect(health.status == .healthy)
        #expect(health.availableModels == ["qwen-local"])
        let requests = await transport.requests
        #expect(requests.map(\.url?.path) == ["/v1/models", "/v1/chat/completions"])
    }

    @Test
    func localHealthRejectsMalformedStructuredSampleAndKeepsModelList() async {
        let transport = ReviewTransport(responses: [
            HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"data":[{"id":"qwen-local"}]}"#.utf8)),
            HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"choices":[]}"#.utf8))
        ])
        let backend = try! LocalOpenAIBackend(
            baseURL: URL(string: "http://127.0.0.1:11434/v1")!,
            model: "qwen-local",
            transport: transport
        )

        let health = await backend.healthCheck()

        #expect(health.status == .unavailable)
        #expect(health.availableModels == ["qwen-local"])
    }

    @Test
    func localTranslatePostsOnceWithSystemInstructionAndTextContract() async throws {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let output = #"{"choices":[{"message":{"role":"assistant","content":"{\"translations\":[{\"segmentId\":\"00000000-0000-0000-0000-000000000001\",\"text\":\"你好\"}]}"}}]}"#
        let transport = ReviewTransport(responses: [HTTPResponse(statusCode: 200, headers: [:], body: Data(output.utf8))])
        let backend = try LocalOpenAIBackend(baseURL: URL(string: "http://127.0.0.1:11434/v1")!, model: "qwen-local", transport: transport)
        let result = try await backend.translate(TranslationRequest(windowRevision: 9, items: [TranslationItem(id: id, sourceText: "hello")]))
        #expect(result.translations.first?.simplifiedChineseText == "你好")
        let requests = await transport.requests
        #expect(requests.count == 1)
        let body = try #require(requests[0].httpBody)
        let payload = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(payload["messages"] as? [[String: Any]])
        #expect(messages.count == 2)
        #expect(messages[0]["role"] as? String == "system")
        #expect((messages[0]["content"] as? String)?.isEmpty == false)
        #expect(messages[1]["role"] as? String == "user")
        let user = try #require(messages[1]["content"] as? String)
        #expect(user.hasPrefix("Translate to Simplified Chinese:"))
        #expect(user.contains("0:hello"))
        #expect(!user.contains("segmentId"))
        #expect(!(messages[0]["content"] as? String ?? "").contains("segmentId"))
    }

    @Test
    func cacheStoresStringsRatherThanStaleSegmentIDs() async {
        let cache = TranslationCache(capacity: 1)
        let key = TranslationCacheKey(source: "hello", backend: .local, model: "qwen", targetLanguage: "zh-Hans")
        await cache.insert("你好", for: key)
        #expect(await cache.value(for: key) == "你好")
    }

    @Test
    func mixedScriptsRemainEligibleForTranslation() {
        #expect(TextFilter.shouldTranslate("Settings 设置"))
        #expect(TextFilter.shouldTranslate("これはテストです"))
        #expect(TextFilter.shouldTranslate("한국어 테스트"))
    }

    @Test
    func responseAccumulatorRejectsBodiesOverLimit() throws {
        var accumulator = HTTPResponseAccumulator(maximumBytes: 4)
        try accumulator.append(Data([1, 2, 3, 4]))
        do {
            try accumulator.append(Data([5]))
            Issue.record("expected responseTooLarge")
        } catch let error as HTTPTransportError {
            #expect(error == .responseTooLarge)
        }
        #expect(accumulator.data.count == 4)
    }

    @Test
    func credentialSaveRejectsWhitespaceAndOversizedValues() {
        let store = MacOSKeychainStore(service: "com.maodashu.test-\(UUID().uuidString)")
        expectInvalidCredential {
            try store.save(apiKey: " \n\t ")
        }
        expectInvalidCredential {
            try store.save(apiKey: String(repeating: "x", count: 4_097))
        }
    }

    private func expectNestedReasoningNone(_ payload: [String: Any]) {
        #expect(payload["reasoning_effort"] == nil)
        guard let reasoning = payload["reasoning"] as? [String: Any] else {
            Issue.record("missing nested reasoning object")
            return
        }
        #expect(reasoning["effort"] as? String == "none")
        #expect(Set(reasoning.keys) == Set(["effort"]))
    }

    private func expectInvalidCredential(_ operation: () throws -> Void) {
        do {
            try operation()
            Issue.record("expected invalid credential")
        } catch let error as CredentialStoreError {
            #expect(error == .invalidValue)
        } catch {
            Issue.record("unexpected credential error")
        }
    }
}

private actor ReviewTransport: HTTPTransport {
    private var responses: [HTTPResponse]
    private(set) var requests: [URLRequest] = []

    init(responses: [HTTPResponse]) {
        self.responses = responses
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else {
            throw HTTPTransportError.networkFailure
        }
        return responses.removeFirst()
    }
}

private final class ReviewCredentials: CredentialStoring, @unchecked Sendable {
    private let value: String?

    init(value: String?) {
        self.value = value
    }

    func save(apiKey: String) throws {}

    func read() throws -> String? {
        value
    }

    func delete() throws {}
}

private struct FailingCredentials: CredentialStoring {
    func save(apiKey: String) throws {}

    func read() throws -> String? {
        throw CredentialStoreError.keychainFailure(status: -1)
    }

    func delete() throws {}
}
