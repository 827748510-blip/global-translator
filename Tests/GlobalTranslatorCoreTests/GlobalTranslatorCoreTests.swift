import Foundation
import Testing
@testable import GlobalTranslatorCore

struct GlobalTranslatorCoreTests {
    @Test
    func configurationDefaultsAndAtomic0600Persistence() async throws {
        let configuration = AppConfiguration()
        #expect(!configuration.autoTranslateEnabled)
        #expect(configuration.backend == .deepSeekCloud)
        #expect(!configuration.visionFallbackEnabled)
        #expect(configuration.localBaseURL.absoluteString == "http://127.0.0.1:11434/v1")
        #expect(configuration.localModel.isEmpty)
        #expect(configuration.translatedBundleIDs.isEmpty)

        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ConfigStore(url: path)
        try await store.save(configuration)
        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue
        #expect(mode == 0o600)
        #expect(try await store.load() == configuration)
    }

    @Test
    func legacyExclusionListNeverBecomesTranslationAllowList() throws {
        let legacyJSON = Data(#"{"autoTranslateEnabled":true,"backend":"local","localBaseURL":"http:\/\/127.0.0.1:11434\/v1","localModel":"m","excludedBundleIDs":["com.example.blocked"]}"#.utf8)
        let decoded = try JSONDecoder().decode(AppConfiguration.self, from: legacyJSON)
        #expect(decoded.translatedBundleIDs.isEmpty)
        #expect(decoded.autoTranslateEnabled)

        let allowJSON = Data(#"{"translatedBundleIDs":["com.google.Chrome"]}"#.utf8)
        let allow = try JSONDecoder().decode(AppConfiguration.self, from: allowJSON)
        #expect(allow.translatedBundleIDs == ["com.google.Chrome"])
        #expect(!allow.autoTranslateEnabled)
    }

    @Test
    func textFilterDistinguishesSimplifiedAndTraditionalChinese() {
        #expect(!TextFilter.shouldTranslate("这是简体中文"))
        #expect(!TextFilter.shouldTranslate("你好世界"))
        #expect(TextFilter.shouldTranslate("這是繁體中文"))
        #expect(!TextFilter.shouldTranslate("   \n\t"))
        #expect(!TextFilter.shouldTranslate("123,!?"))
        #expect(!TextFilter.shouldTranslate("https://example.com/a"))
        #expect(!TextFilter.shouldTranslate("name@example.com"))
        #expect(!TextFilter.shouldTranslate("/Users/example/file.txt"))
        #expect(!TextFilter.shouldTranslate("⌘⇧P"))
        #expect(TextFilter.shouldTranslate("Translate this sentence"))
    }

    @Test
    func translationCacheUsesLruAndSeparatesKeys() async {
        let cache = TranslationCache(capacity: 2)
        let keyA = TranslationCacheKey(source: "hello", backend: .local, model: "a", targetLanguage: "zh-Hans")
        let keyB = TranslationCacheKey(source: "hello", backend: .local, model: "b", targetLanguage: "zh-Hans")
        let keyC = TranslationCacheKey(source: "world", backend: .local, model: "a", targetLanguage: "zh-Hans")
        await cache.insert("你好", for: keyA)
        await cache.insert("您好", for: keyB)
        let firstValue = await cache.value(for: keyA)
        #expect(firstValue != nil)
        await cache.insert("世界", for: keyC)
        let retainedValue = await cache.value(for: keyA)
        let evictedValue = await cache.value(for: keyB)
        let newestValue = await cache.value(for: keyC)
        #expect(retainedValue != nil)
        #expect(evictedValue == nil)
        #expect(newestValue != nil)
    }

    @Test
    func endpointValidatorAcceptsOnlyLoopbackHttp() {
        expectNoThrow {
            _ = try EndpointValidator.validateLocalBaseURL(URL(string: "http://127.0.0.1:11434/v1")!)
        }
        expectNoThrow {
            _ = try EndpointValidator.validateLocalBaseURL(URL(string: "http://localhost/v1")!)
        }
        expectNoThrow {
            _ = try EndpointValidator.validateLocalBaseURL(URL(string: "http://[::1]:11434/v1")!)
        }
        expectThrow {
            _ = try EndpointValidator.validateLocalBaseURL(URL(string: "https://127.0.0.1/v1")!)
        }
        expectThrow {
            _ = try EndpointValidator.validateLocalBaseURL(URL(string: "http://127.0.0.1.evil/v1")!)
        }
        expectThrow {
            _ = try EndpointValidator.validateLocalBaseURL(URL(string: "http://127.0.0.1/v1?next=https://evil")!)
        }
        expectThrow {
            _ = try EndpointValidator.validateLocalBaseURL(URL(string: "http://user:pass@127.0.0.1/v1")!)
        }
        expectThrow {
            _ = try EndpointValidator.validateLocalBaseURL(URL(string: "http://[::ffff:127.0.0.1]/v1")!)
        }
    }

    @Test
    func cloudPayloadOmitsScreenMetadataAndMapsUnauthorized() async throws {
        let transport = FakeTransport(responses: [
            HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"output":[{"type":"message","content":[{"type":"output_text","text":"{\"translations\":[{\"segmentId\":\"00000000-0000-0000-0000-000000000001\",\"text\":\"你好\"}]}"}]}]}"#.utf8))
        ])
        let credentials = FakeCredentialStore(value: "secret")
        let backend = DeepSeekBackend(transport: transport, credentialStore: credentials)
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let request = TranslationRequest(windowRevision: 7, items: [TranslationItem(id: id, sourceText: "hello")])
        let result = try await backend.translate(request)
        #expect(result.translations.first?.simplifiedChineseText == "你好")
        #expect(result.windowRevision == 7)
        let requests = await transport.requests
        #expect(requests.count == 1)
        #expect(requests[0].url?.absoluteString == "https://api.deepseek.com/responses")
        let body = try #require(requests[0].httpBody)
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let text = try #require(object["text"] as? [String: Any])
        let format = try #require(text["format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        let serialized = String(data: try JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
        #expect(serialized.contains("segmentId"))
        #expect(!serialized.contains("screenFrame"))
        #expect(!serialized.contains("confidence"))
        #expect(!serialized.contains("windowRevision"))

        let unauthorized = FakeTransport(responses: [HTTPResponse(statusCode: 401, headers: [:], body: Data())])
        let unauthorizedBackend = DeepSeekBackend(transport: unauthorized, credentialStore: credentials)
        do {
            _ = try await unauthorizedBackend.translate(request)
            Issue.record("expected unauthorized")
        } catch let error as TranslationError {
            #expect(error == .unauthorized)
        }
    }

    @Test
    func deepSeekAcceptsReasoningOutputAlongsideSingleMessage() async throws {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let response = #"{"output":[{"type":"reasoning","content":[{"type":"reasoning_text","text":""}]},{"type":"message","content":[{"type":"output_text","text":"{\"translations\":[{\"segmentId\":\"00000000-0000-0000-0000-000000000001\",\"text\":\"你好\"}]}"}]}]}"#
        let backend = DeepSeekBackend(
            transport: FakeTransport(responses: [
                HTTPResponse(statusCode: 200, headers: [:], body: Data(response.utf8))
            ]),
            credentialStore: FakeCredentialStore(value: "key")
        )

        let result = try await backend.translate(
            TranslationRequest(windowRevision: 8, items: [TranslationItem(id: id, sourceText: "hello")])
        )

        #expect(result.translations.first?.simplifiedChineseText == "你好")
    }

    @Test
    func cloudRejectsDuplicateOrMissingResultIdsAndMapsRateLimit() async throws {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let duplicateText = #"{"output":[{"type":"message","content":[{"type":"output_text","text":"{\"translations\":[{\"segmentId\":\"00000000-0000-0000-0000-000000000001\",\"text\":\"一\"},{\"segmentId\":\"00000000-0000-0000-0000-000000000001\",\"text\":\"二\"}]}"}]}]}"#
        let transport = FakeTransport(responses: [
            HTTPResponse(statusCode: 200, headers: [:], body: Data(duplicateText.utf8))
        ])
        let backend = DeepSeekBackend(transport: transport, credentialStore: FakeCredentialStore(value: "key"))
        do {
            _ = try await backend.translate(TranslationRequest(windowRevision: 1, items: [TranslationItem(id: id, sourceText: "x")]))
            Issue.record("expected invalid response")
        } catch let error as TranslationError {
            guard case .invalidResponse = error else {
                Issue.record("unexpected error")
                return
            }
        }

        let limited = FakeTransport(responses: [HTTPResponse(statusCode: 429, headers: ["Retry-After": "3"], body: Data())])
        let limitedBackend = DeepSeekBackend(transport: limited, credentialStore: FakeCredentialStore(value: "key"))
        do {
            _ = try await limitedBackend.translate(TranslationRequest(windowRevision: 1, items: [TranslationItem(id: id, sourceText: "x")]))
            Issue.record("expected rate limit")
        } catch let error as TranslationError {
            #expect(error == .rateLimited(retryAfter: 3))
        }
    }

    @Test
    func localSendsSlimPromptJsonObjectAndScaledMaxTokens() async throws {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let transport = FakeTransport(responses: [
            HTTPResponse(statusCode: 200, headers: [:], body: try chatEnvelope(["0": "你好"]))
        ])
        let backend = try LocalOpenAIBackend(baseURL: URL(string: "http://[::1]:11434/v1")!, model: "qwen-local", transport: transport)
        let result = try await backend.translate(TranslationRequest(windowRevision: 2, items: [TranslationItem(id: id, sourceText: "hello")]))
        #expect(result.translations.first?.simplifiedChineseText == "你好")
        #expect(result.translations.first?.segmentId == id)
        #expect(result.windowRevision == 2)
        let requests = await transport.requests
        #expect(requests.count == 1)
        let body = try #require(requests[0].httpBody)
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["stream"] as? Bool == false)
        #expect(object["temperature"] as? Double == 0)
        #expect(intValue(object["max_tokens"]) == 128)
        #expect(LocalOpenAIBackend.maxTokens(itemCount: 1) == 128)
        #expect(LocalOpenAIBackend.maxTokens(itemCount: 3) == 256)
        let format = try #require(object["response_format"] as? [String: Any])
        #expect(format["type"] as? String == "json_object")
        #expect(!format.keys.contains("json_schema"))
        let messages = try #require(object["messages"] as? [[String: Any]])
        #expect(messages[0]["content"] as? String == LocalTranslationPrompt.system)
        #expect(!(messages[0]["content"] as? String ?? "").contains("segmentId"))
        let user = try #require(messages[1]["content"] as? String)
        #expect(user == "0:hello")
        #expect(!user.contains("segmentId"))
        #expect(!user.contains(id.uuidString))
        #expect(user.count < 80)

        let unavailableTransport = FakeTransport(responses: [HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"data":[]}"#.utf8))])
        let unavailableBackend = try LocalOpenAIBackend(baseURL: URL(string: "http://127.0.0.1:11434/v1")!, model: "missing", transport: unavailableTransport)
        let health = await unavailableBackend.healthCheck()
        #expect(health.status == .modelUnavailable)
    }

    @Test
    func localBatchPayloadUsesCompactKeysNotUUIDs() async throws {
        let first = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let second = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let third = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let transport = FakeTransport(responses: [
            HTTPResponse(statusCode: 200, headers: [:], body: try chatEnvelope(["0": "一", "1": "二", "2": "三"]))
        ])
        let backend = try LocalOpenAIBackend(baseURL: URL(string: "http://127.0.0.1:11434/v1")!, model: "qwen-local", transport: transport)
        let result = try await backend.translate(TranslationRequest(windowRevision: 3, items: [
            TranslationItem(id: first, sourceText: "one"),
            TranslationItem(id: second, sourceText: "two"),
            TranslationItem(id: third, sourceText: "three")
        ]))
        #expect(result.translations.map(\.simplifiedChineseText) == ["一", "二", "三"])
        #expect(result.translations.map(\.segmentId) == [first, second, third])
        let body = try #require(await transport.requests.first?.httpBody)
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(intValue(object["max_tokens"]) == 256)
        let user = try #require((object["messages"] as? [[String: Any]])?[1]["content"] as? String)
        #expect(user == "0:one\n1:two\n2:three")
        #expect(!user.contains("segmentId"))
        #expect(!user.contains(first.uuidString))
    }

    @Test
    func localParserAcceptsCommonOllamaJsonObjectShapes() async throws {
        // Redacted Mac Ollama samples (no emails/UUIDs/source text). These
        // are the shapes that used to throw translation JSON is invalid.
        let first = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let second = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let samples: [(Any, [UUID], [String])] = [
            (["0": "你好"] as Any, [first], ["你好"]),
            (["a": "你好", "b": "世界"] as Any, [first, second], ["你好", "世界"]),
            (["t": ["甲", "乙"]] as Any, [first, second], ["甲", "乙"]),
            (["t": "你好"] as Any, [first], ["你好"]),
            (["translation": "你好"] as Any, [first], ["你好"]),
            (["translations": [["translation": "你好"]]] as Any, [first], ["你好"]),
            (["translations": [["zh": "你好"], ["zh": "世界"]]] as Any, [first, second], ["你好", "世界"]),
            (["Hello": "你好"] as Any, [first], ["你好"]),
            ([["segmentId": "deadbeef-0000-0000-0000-000000000099", "text": "你好"],
              ["segmentId": "deadbeef-0000-0000-0000-000000000098", "text": "世界"]] as Any, [first, second], ["你好", "世界"]),
            (["你好", "世界"] as Any, [first, second], ["你好", "世界"])
        ]
        for (content, ids, expected) in samples {
            let transport = FakeTransport(responses: [
                HTTPResponse(statusCode: 200, headers: [:], body: try chatEnvelope(content))
            ])
            let backend = try LocalOpenAIBackend(baseURL: URL(string: "http://127.0.0.1:11434/v1")!, model: "qwen-local", transport: transport)
            let items = ids.enumerated().map { index, id in
                TranslationItem(id: id, sourceText: index == 0 ? "hello" : "world")
            }
            let result = try await backend.translate(TranslationRequest(windowRevision: 4, items: items))
            #expect(result.translations.map(\.segmentId) == ids)
            #expect(result.translations.map(\.simplifiedChineseText) == expected)
        }
    }

    @Test
    func localParserAcceptsTrailingCommaContentPartsAndThinkTags() async throws {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let trailing = #"{"choices":[{"message":{"content":"{\"0\":\"你好\",}"}}]}"#
        let trailingBackend = try LocalOpenAIBackend(
            baseURL: URL(string: "http://127.0.0.1:11434/v1")!,
            model: "qwen-local",
            transport: FakeTransport(responses: [HTTPResponse(statusCode: 200, headers: [:], body: Data(trailing.utf8))])
        )
        #expect(try await trailingBackend.translate(TranslationRequest(windowRevision: 6, items: [TranslationItem(id: id, sourceText: "hello")])).translations.first?.simplifiedChineseText == "你好")

        let parts = try JSONSerialization.data(withJSONObject: [
            "choices": [["message": ["content": [["type": "text", "text": "{\"0\":\"你好\"}"]]]]]
        ])
        let partsBackend = try LocalOpenAIBackend(
            baseURL: URL(string: "http://127.0.0.1:11434/v1")!,
            model: "qwen-local",
            transport: FakeTransport(responses: [HTTPResponse(statusCode: 200, headers: [:], body: parts)])
        )
        #expect(try await partsBackend.translate(TranslationRequest(windowRevision: 6, items: [TranslationItem(id: id, sourceText: "hello")])).translations.first?.simplifiedChineseText == "你好")

        let think = #"{"choices":[{"message":{"content":"<think>redacted</think>{\"0\":\"你好\"}"}}]}"#
        let thinkBackend = try LocalOpenAIBackend(
            baseURL: URL(string: "http://127.0.0.1:11434/v1")!,
            model: "qwen-local",
            transport: FakeTransport(responses: [HTTPResponse(statusCode: 200, headers: [:], body: Data(think.utf8))])
        )
        #expect(try await thinkBackend.translate(TranslationRequest(windowRevision: 6, items: [TranslationItem(id: id, sourceText: "hello")])).translations.first?.simplifiedChineseText == "你好")
    }

    @Test
    func localParserRejectsCountMismatchWithoutCloudFallback() async throws {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let output = #"{"choices":[{"message":{"role":"assistant","content":"{\"translations\":[]}"}}]}"#
        let transport = FakeTransport(responses: [
            HTTPResponse(statusCode: 200, headers: [:], body: Data(output.utf8))
        ])
        let backend = try LocalOpenAIBackend(baseURL: URL(string: "http://127.0.0.1:11434/v1")!, model: "qwen-local", transport: transport)
        do {
            _ = try await backend.translate(TranslationRequest(windowRevision: 5, items: [TranslationItem(id: id, sourceText: "hello")]))
            Issue.record("expected invalid response")
        } catch let error as TranslationError {
            guard case .invalidResponse = error else {
                Issue.record("unexpected error")
                return
            }
        }
        #expect(await transport.requests.count == 1)
    }

    private func expectNoThrow(_ operation: () throws -> Void) {
        do {
            try operation()
        } catch {
            Issue.record("unexpected error")
        }
    }

    private func expectThrow(_ operation: () throws -> Void) {
        do {
            try operation()
            Issue.record("expected an error")
        } catch {
        }
    }

    private func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let double = value as? Double { return Int(double) }
        return nil
    }

    private func chatEnvelope(_ content: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "choices": [["message": ["role": "assistant", "content": content]]]
        ])
    }
}

struct SerializingTranslationBackendTests {
    @Test
    func concurrentTranslatesDoNotOverlapTheBaseBackend() async throws {
        let base = SlowRecordingBackend()
        let serial = SerializingTranslationBackend(base: base)
        let first = TranslationRequest(
            windowRevision: 1,
            items: [TranslationItem(id: UUID(), sourceText: "first window")]
        )
        let second = TranslationRequest(
            windowRevision: 2,
            items: [TranslationItem(id: UUID(), sourceText: "second bridge")]
        )
        async let firstResult = serial.translate(first)
        async let secondResult = serial.translate(second)
        _ = try await (firstResult, secondResult)
        #expect(await base.maxInFlight == 1)
        #expect(await base.started.count == 2)
        let finished = await base.finished
        let started = await base.started
        #expect(finished == started)
    }

    @Test
    func overlayCancelDoesNotAbortAQueuedBridgeTranslate() async throws {
        let base = SlowRecordingBackend()
        let serial = SerializingTranslationBackend(base: base)
        let overlay = CoalescingTranslationBackend(base: serial)
        let first = TranslationRequest(
            windowRevision: 1,
            items: [TranslationItem(id: UUID(), sourceText: "overlay scrape")]
        )
        let bridge = TranslationRequest(
            windowRevision: 0,
            items: [TranslationItem(id: UUID(), sourceText: "bridge batch")]
        )
        let overlayTask = Task { try await overlay.translate(first) }
        for _ in 0..<200 where await base.started.isEmpty { await Task.yield() }
        let bridgeTask = Task { try await serial.translate(bridge) }
        await overlay.cancelOutstandingRequests()
        overlayTask.cancel()
        let bridgeResult = try await bridgeTask.value
        _ = await overlayTask.result
        #expect(bridgeResult.translations.first?.simplifiedChineseText == "译:bridge batch")
        #expect(await base.finished.contains("bridge batch"))
    }
}

private actor SlowRecordingBackend: TranslationBackend {
    let kind: BackendKind = .local
    private var inFlight = 0
    private(set) var maxInFlight = 0
    private(set) var started: [String] = []
    private(set) var finished: [String] = []

    func healthCheck() async -> BackendHealth {
        BackendHealth(status: .healthy, message: "ok")
    }

    func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        let text = request.items.first?.sourceText ?? ""
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        started.append(text)
        defer {
            inFlight -= 1
            finished.append(text)
        }
        try await Task.sleep(for: .milliseconds(80))
        try Task.checkCancellation()
        return TranslationResult(
            windowRevision: request.windowRevision,
            translations: request.items.map {
                Translation(segmentId: $0.id, simplifiedChineseText: "译:" + $0.sourceText)
            }
        )
    }
}

private actor FakeTransport: HTTPTransport {
    private var queuedResponses: [HTTPResponse]
    private(set) var requests: [URLRequest] = []

    init(responses: [HTTPResponse]) {
        queuedResponses = responses
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        guard !queuedResponses.isEmpty else {
            throw HTTPTransportError.networkFailure
        }
        return queuedResponses.removeFirst()
    }
}

private final class FakeCredentialStore: CredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: String?

    init(value: String?) {
        storedValue = value
    }

    func save(apiKey: String) throws {
        lock.lock()
        storedValue = apiKey
        lock.unlock()
    }

    func read() throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func delete() throws {
        lock.lock()
        storedValue = nil
        lock.unlock()
    }
}
