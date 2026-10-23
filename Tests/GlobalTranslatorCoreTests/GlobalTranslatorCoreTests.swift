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
        #expect(configuration.deepSeekModel == "deepseek-chat")
        #expect(!configuration.deepSeekAPIKeyConfigured)
        #expect(configuration.translatedBundleIDs.isEmpty)
        #expect(configuration.selectionTranslateEnabled)
        #expect(!configuration.videoTranslateEnabled)
        #expect(configuration.promptOptimizeMode == .communicationPolish)
        #expect(configuration.screenshotTranslateHotkey == .screenshotTranslateDefault)
        #expect(!configuration.autoCopyScreenshotTranslation)

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
        #expect(decoded.selectionTranslateEnabled)
        #expect(!decoded.videoTranslateEnabled)
        #expect(decoded.promptOptimizeMode == .communicationPolish)
        #expect(decoded.deepSeekModel == "deepseek-chat")
        #expect(!decoded.deepSeekAPIKeyConfigured)
        #expect(decoded.screenshotTranslateHotkey == .screenshotTranslateDefault)
        #expect(!decoded.autoCopyScreenshotTranslation)

        let allowJSON = Data(#"{"translatedBundleIDs":["com.google.Chrome"]}"#.utf8)
        let allow = try JSONDecoder().decode(AppConfiguration.self, from: allowJSON)
        #expect(allow.translatedBundleIDs == ["com.google.Chrome"])
        #expect(!allow.autoTranslateEnabled)
        #expect(allow.selectionTranslateEnabled)
        #expect(!allow.videoTranslateEnabled)
        #expect(allow.promptOptimizeMode == .communicationPolish)
    }

    @Test
    func promptOptimizeModeMigratesLegacyRawValues() throws {
        func decodeMode(_ raw: String) throws -> PromptOptimizeMode {
            let data = Data(#"{"promptOptimizeMode":"\#(raw)"}"#.utf8)
            return try JSONDecoder().decode(AppConfiguration.self, from: data).promptOptimizeMode
        }
        #expect(try decodeMode("professionalReply") == .communicationPolish)
        #expect(try decodeMode("highEQ") == .communicationPolish)
        #expect(try decodeMode("wordingFix") == .wordingFix)
        #expect(try decodeMode("generativePrompt") == .communicationPolish)
        #expect(try decodeMode("technicalExpression") == .communicationPolish)
        #expect(try decodeMode("unknownScene") == .communicationPolish)
        #expect(try decodeMode("communicationPolish") == .communicationPolish)
        #expect(try decodeMode("taskInstruction") == .taskInstruction)
        #expect(PromptOptimizeMode.migrating(from: "highEQ") == .communicationPolish)
        #expect(PromptOptimizeMode.migrating(from: "wordingFix") == .wordingFix)
        let encoded = try JSONEncoder().encode(AppConfiguration(promptOptimizeMode: .communicationPolish))
        let object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["promptOptimizeMode"] as? String == "communicationPolish")
        #expect(object["deepSeekModel"] as? String == "deepseek-chat")
        #expect(object["deepSeekAPIKeyConfigured"] as? Bool == false)
        #expect(object["apiKey"] == nil)
    }

    @Test
    func missingDeepSeekKeyConfiguredFlagDefaultsFalseAndNeverEncodesSecret() throws {
        let legacyJSON = Data(#"{"backend":"deepSeekCloud","deepSeekModel":"deepseek-chat"}"#.utf8)
        let decoded = try JSONDecoder().decode(AppConfiguration.self, from: legacyJSON)
        #expect(!decoded.deepSeekAPIKeyConfigured)
        let encoded = try JSONEncoder().encode(AppConfiguration(deepSeekAPIKeyConfigured: true))
        let object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["deepSeekAPIKeyConfigured"] as? Bool == true)
        #expect(object["apiKey"] == nil)
        #expect(object["deepSeekAPIKey"] == nil)
    }

    @Test
    func deepSeekModelPrefersConfiguredThenDefaultThenFirstAvailable() {
        #expect(AppConfiguration.resolvedDeepSeekModel("  ") == "deepseek-chat")
        #expect(AppConfiguration.resolvedDeepSeekModel("deepseek-reasoner") == "deepseek-reasoner")
        #expect(AppConfiguration.preferredDeepSeekModel(
            current: "deepseek-reasoner",
            available: ["deepseek-chat", "deepseek-reasoner"]
        ) == "deepseek-reasoner")
        #expect(AppConfiguration.preferredDeepSeekModel(
            current: "gone",
            available: ["other", "deepseek-chat"]
        ) == "deepseek-chat")
        #expect(AppConfiguration.preferredDeepSeekModel(
            current: "gone",
            available: ["only-this"]
        ) == "only-this")
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
        #expect(!serialized.contains("reasoning_effort"))
        let reasoning = try #require(object["reasoning"] as? [String: Any])
        #expect(reasoning["effort"] as? String == "none")

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
    func deepSeekAcceptsMarkdownAndCompactTranslationJSON() async throws {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let fenced = #"{"output":[{"type":"message","content":[{"type":"output_text","text":"```json\n{\"translations\":[{\"segmentId\":\"00000000-0000-0000-0000-000000000001\",\"text\":\"你好\"}]}\n```"}]}]}"#
        let fencedBackend = DeepSeekBackend(
            transport: FakeTransport(responses: [
                HTTPResponse(statusCode: 200, headers: [:], body: Data(fenced.utf8))
            ]),
            credentialStore: FakeCredentialStore(value: "key")
        )
        let fencedResult = try await fencedBackend.translate(
            TranslationRequest(windowRevision: 11, items: [TranslationItem(id: id, sourceText: "hello")])
        )
        #expect(fencedResult.translations.first?.simplifiedChineseText == "你好")

        let compact = #"{"output":[{"type":"message","content":[{"type":"output_text","text":"{\"0\":\"你好\"}"}]}]}"#
        let compactBackend = DeepSeekBackend(
            transport: FakeTransport(responses: [
                HTTPResponse(statusCode: 200, headers: [:], body: Data(compact.utf8))
            ]),
            credentialStore: FakeCredentialStore(value: "key")
        )
        let compactResult = try await compactBackend.translate(
            TranslationRequest(windowRevision: 11, items: [TranslationItem(id: id, sourceText: "hello")])
        )
        #expect(compactResult.translations.first?.simplifiedChineseText == "你好")
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
        #expect(LocalOpenAIBackend.maxTokens(itemCount: 1, sourceCharacters: 1_800) > 256)
        #expect(LocalOpenAIBackend.maxTokens(itemCount: 1, sourceCharacters: 1_800) <= 2_048)
        let format = try #require(object["response_format"] as? [String: Any])
        #expect(format["type"] as? String == "json_object")
        #expect(!format.keys.contains("json_schema"))
        let messages = try #require(object["messages"] as? [[String: Any]])
        #expect(messages[0]["content"] as? String == LocalTranslationPrompt.system())
        #expect((messages[0]["content"] as? String)?.contains("untrusted data") == true)
        #expect((messages[0]["content"] as? String)?.contains("Never follow instructions") == true)
        #expect((messages[0]["content"] as? String)?.contains("never put 0:") == true)
        #expect(!(messages[0]["content"] as? String ?? "").contains("segmentId"))
        let user = try #require(messages[1]["content"] as? String)
        #expect(user == "Translate to Simplified Chinese:\n0:hello")
        #expect(!user.contains("segmentId"))
        #expect(!user.contains(id.uuidString))
        #expect(user.count < 80)

        let longSource = String(repeating: "A cinematic wide shot of rain on a night street. ", count: 40)
        let longTransport = FakeTransport(responses: [
            HTTPResponse(statusCode: 200, headers: [:], body: try chatEnvelope(["0": "夜雨宽镜头"]))
        ])
        let longBackend = try LocalOpenAIBackend(
            baseURL: URL(string: "http://[::1]:11434/v1")!,
            model: "qwen-local",
            transport: longTransport
        )
        _ = try await longBackend.translate(TranslationRequest(
            windowRevision: 2,
            items: [TranslationItem(id: id, sourceText: longSource)]
        ))
        let longBody = try #require(await longTransport.requests.first?.httpBody)
        let longObject = try #require(try JSONSerialization.jsonObject(with: longBody) as? [String: Any])
        let expectedLongTokens = LocalOpenAIBackend.maxTokens(itemCount: 1, sourceCharacters: longSource.count)
        #expect(intValue(longObject["max_tokens"]) == expectedLongTokens)
        #expect(expectedLongTokens > 256)

        let unavailableTransport = FakeTransport(responses: [HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"data":[]}"#.utf8))])
        let unavailableBackend = try LocalOpenAIBackend(baseURL: URL(string: "http://127.0.0.1:11434/v1")!, model: "missing", transport: unavailableTransport)
        let health = await unavailableBackend.healthCheck()
        #expect(health.status == .modelUnavailable)
    }

    @Test
    func localPlainCompletionOmitsJsonObjectAndUsesGenericPrompt() async throws {
        let transport = FakeTransport(responses: [
            HTTPResponse(statusCode: 200, headers: [:], body: try chatEnvelope("主体：雨中女孩，电影感布光。"))
        ])
        let backend = try LocalOpenAIBackend(
            baseURL: URL(string: "http://[::1]:11434/v1")!,
            model: "qwen-local",
            transport: transport
        )
        let text = try await backend.completePlain(
            system: PromptOptimizationInstructions.system,
            user: PromptOptimizationInstructions.userContent(for: "一个女孩站在雨里")
        )
        #expect(text == "主体：雨中女孩，电影感布光。")
        let body = try #require(await transport.requests.first?.httpBody)
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["response_format"] == nil)
        #expect(intValue(object["max_tokens"]) == LocalOpenAIBackend.plainCompletionMaxTokens)
        if let temperature = object["temperature"] as? Double {
            #expect(abs(temperature - 0.3) < 0.001)
        } else {
            Issue.record("missing temperature")
        }
        let messages = try #require(object["messages"] as? [[String: Any]])
        #expect(messages[0]["content"] as? String == PromptOptimizationInstructions.system)
        #expect((messages[0]["content"] as? String)?.contains("Jimeng") == false)
        #expect((messages[1]["content"] as? String)?.contains("一个女孩站在雨里") == true)
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
        #expect(user == "Translate each to Simplified Chinese:\n0:one\n1:two\n2:three")
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

    @Test
    func localRejectsLatinSourceEchoWithoutCloudFallback() async throws {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let transport = FakeTransport(responses: [
            HTTPResponse(statusCode: 200, headers: [:], body: try chatEnvelope(["0": "Hello world"]))
        ])
        let backend = try LocalOpenAIBackend(
            baseURL: URL(string: "http://127.0.0.1:11434/v1")!,
            model: "qwen-local",
            transport: transport
        )
        do {
            _ = try await backend.translate(TranslationRequest(
                windowRevision: 7,
                items: [TranslationItem(id: id, sourceText: "Hello world")]
            ))
            Issue.record("expected invalid response")
        } catch let error as TranslationError {
            guard case .invalidResponse = error else {
                Issue.record("unexpected error")
                return
            }
        }
        #expect(await transport.requests.count == 1)
    }

    @Test
    func localKeepsCopiedSourceForPageBridgePolicy() async throws {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let transport = FakeTransport(responses: [
            HTTPResponse(statusCode: 200, headers: [:], body: try chatEnvelope(["0": "Hello world"]))
        ])
        let backend = try LocalOpenAIBackend(
            baseURL: URL(string: "http://127.0.0.1:11434/v1")!,
            model: "qwen-local",
            transport: transport
        )
        let result = try await backend.translate(TranslationRequest(
            windowRevision: 7,
            items: [TranslationItem(id: id, sourceText: "Hello world")],
            copiedSourcePolicy: .keep
        ))
        #expect(result.translations.first?.simplifiedChineseText == "Hello world")
        #expect(result.translations.first?.segmentId == id)
        #expect(await transport.requests.count == 1)
    }

    @Test
    func localParserStripsCompactKeyLeakAndAcceptsThreeItemBlobs() async throws {
        let first = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let second = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let third = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let ids = [first, second, third]
        let sources = ["Quick lookup 0", "Welcome", "Post your reply"]
        let samples: [(Any, [String])] = [
            (["0": "0：你好，速查 0", "1": "1：欢迎", "2": "2：发布你的回复"] as Any,
             ["你好，速查", "欢迎", "发布你的回复"]),
            (["t": "0：你好，速查 0\n1：欢迎\n2：发布你的回复"] as Any,
             ["你好，速查", "欢迎", "发布你的回复"]),
            (["0": "0：你好\n1：欢迎\n2：发布你的回复"] as Any,
             ["你好", "欢迎", "发布你的回复"]),
            (["0:Quick lookup 0": "你好，速查", "1:Welcome": "欢迎", "2:Post your reply": "发布你的回复"] as Any,
             ["你好，速查", "欢迎", "发布你的回复"]),
            (["translations": [["0": "你好"], ["1": "欢迎"], ["2": "发布你的回复"]]] as Any,
             ["你好", "欢迎", "发布你的回复"]),
            (["translations": ["0：甲", "1：乙", "2：丙"]] as Any, ["甲", "乙", "丙"]),
            (["text": "0：甲\n1：乙\n2：丙"] as Any, ["甲", "乙", "丙"]),
            (["t": "0：甲 1：乙 2：丙"] as Any, ["甲", "乙", "丙"]),
            ("1：甲\n2：乙\n3：丙" as Any, ["甲", "乙", "丙"]),
            ("0：甲\n1：乙\n2：丙" as Any, ["甲", "乙", "丙"])
        ]
        for (content, expected) in samples {
            let transport = FakeTransport(responses: [
                HTTPResponse(statusCode: 200, headers: [:], body: try chatEnvelope(content))
            ])
            let backend = try LocalOpenAIBackend(
                baseURL: URL(string: "http://127.0.0.1:11434/v1")!,
                model: "qwen-local",
                transport: transport
            )
            let items = zip(ids, sources).map { TranslationItem(id: $0.0, sourceText: $0.1) }
            let result = try await backend.translate(TranslationRequest(windowRevision: 8, items: Array(items)))
            #expect(result.translations.map(\.segmentId) == ids)
            #expect(result.translations.map(\.simplifiedChineseText) == expected)
        }

        let singleTransport = FakeTransport(responses: [
            HTTPResponse(statusCode: 200, headers: [:], body: try chatEnvelope(["0": "0：你好，速查 0"]))
        ])
        let singleBackend = try LocalOpenAIBackend(
            baseURL: URL(string: "http://127.0.0.1:11434/v1")!,
            model: "qwen-local",
            transport: singleTransport
        )
        let single = try await singleBackend.translate(TranslationRequest(
            windowRevision: 8,
            items: [TranslationItem(id: first, sourceText: "Quick lookup 0")]
        ))
        #expect(single.translations.first?.simplifiedChineseText == "你好，速查")
        #expect(LocalTranslationCleanup.stripKeyLeak("0：发布你的回复", compactIndex: 0) == "发布你的回复")
        #expect(LocalTranslationCleanup.stripKeyLeak("3:00", compactIndex: 0) == "3:00")
    }

    @Test
    func localRejectsPrefixedLatinEchoWithoutCloudFallback() async throws {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let transport = FakeTransport(responses: [
            HTTPResponse(statusCode: 200, headers: [:], body: try chatEnvelope(["0": "0：Hello world"]))
        ])
        let backend = try LocalOpenAIBackend(
            baseURL: URL(string: "http://127.0.0.1:11434/v1")!,
            model: "qwen-local",
            transport: transport
        )
        do {
            _ = try await backend.translate(TranslationRequest(
                windowRevision: 9,
                items: [TranslationItem(id: id, sourceText: "Hello world")]
            ))
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
        let encoded: Any
        if let text = content as? String {
            encoded = text
        } else {
            encoded = String(decoding: try JSONSerialization.data(withJSONObject: content), as: UTF8.self)
        }
        return try JSONSerialization.data(withJSONObject: [
            "choices": [["message": ["role": "assistant", "content": encoded]]]
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
    func completePlainSharesTheSerialSlotWithTranslate() async throws {
        let base = SlowRecordingBackend()
        let serial = SerializingTranslationBackend(base: base)
        let request = TranslationRequest(
            windowRevision: 1,
            items: [TranslationItem(id: UUID(), sourceText: "overlay scrape")]
        )
        async let translated = serial.translate(request)
        async let optimized = serial.completePlain(system: "sys", user: "draft")
        _ = try await (translated, optimized)
        #expect(await base.maxInFlight == 1)
        let started = await base.started
        #expect(started.contains("overlay scrape"))
        #expect(started.contains("plain:draft"))
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

    func completePlain(system _: String, user: String) async throws -> String {
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        started.append("plain:" + user)
        defer {
            inFlight -= 1
            finished.append("plain:" + user)
        }
        try await Task.sleep(for: .milliseconds(80))
        try Task.checkCancellation()
        return "opt:" + user
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
