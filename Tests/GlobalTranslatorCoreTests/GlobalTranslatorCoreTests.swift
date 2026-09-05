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
        #expect(configuration.excludedBundleIDs.isEmpty)

        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ConfigStore(url: path)
        try await store.save(configuration)
        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue
        #expect(mode == 0o600)
        #expect(try await store.load() == configuration)
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
        let serialized = String(data: try JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
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
    func localChecksModelAndSendsJsonObjectPayload() async throws {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let output = #"{"choices":[{"message":{"role":"assistant","content":"{\"translations\":[{\"segmentId\":\"00000000-0000-0000-0000-000000000001\",\"text\":\"你好\"}]}"}}]}"#
        let transport = FakeTransport(responses: [
            HTTPResponse(statusCode: 200, headers: [:], body: Data(output.utf8))
        ])
        let backend = try LocalOpenAIBackend(baseURL: URL(string: "http://[::1]:11434/v1")!, model: "qwen-local", transport: transport)
        let result = try await backend.translate(TranslationRequest(windowRevision: 2, items: [TranslationItem(id: id, sourceText: "hello")]))
        #expect(result.translations.first?.simplifiedChineseText == "你好")
        #expect(result.windowRevision == 2)
        let requests = await transport.requests
        #expect(requests.count == 1)
        let body = try #require(requests[0].httpBody)
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["stream"] as? Bool == false)
        #expect(object["temperature"] as? Double == 0)
        #expect(object["response_format"] as? [String: String] == ["type": "json_object"])

        let unavailableTransport = FakeTransport(responses: [HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"data":[]}"#.utf8))])
        let unavailableBackend = try LocalOpenAIBackend(baseURL: URL(string: "http://127.0.0.1:11434/v1")!, model: "missing", transport: unavailableTransport)
        let health = await unavailableBackend.healthCheck()
        #expect(health.status == .modelUnavailable)
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
