import Foundation
import Testing
@testable import GlobalTranslatorCore

private actor DirectionRecordingTransport: HTTPTransport {
    let response: HTTPResponse
    private(set) var requests: [URLRequest] = []

    init(response: HTTPResponse) { self.response = response }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        return response
    }
}

private final class DirectionCredentialStore: CredentialStoring, @unchecked Sendable {
    var value: String?
    init(value: String?) { self.value = value }
    func save(apiKey: String) throws { value = apiKey }
    func read() throws -> String? { value }
    func delete() throws { value = nil }
}

struct SelectionDirectionTests {
    @Test
    func selectionDirectionDetectsChineseVsEnglishAndSkipsIdentifiers() {
        #expect(TextFilter.selectionDirection("你好世界") == .toEnglish)
        #expect(TextFilter.selectionDirection("一个女孩站在雨里") == .toEnglish)
        #expect(TextFilter.selectionDirection("Hello world") == .toChinese)
        #expect(TextFilter.selectionDirection("The quick brown fox jumps over the lazy dog.") == .toChinese)
        #expect(TextFilter.selectionDirection("Swift 6 + SwiftUI + ScreenCaptureKit") == .toChinese)
        #expect(TextFilter.selectionDirection("https://example.com/path") == nil)
        #expect(TextFilter.selectionDirection("   ") == nil)
    }

    @Test
    func directionMapsToRequestTargetLanguage() {
        #expect(SelectionTranslationDirection.toEnglish.targetLanguage == "en")
        #expect(SelectionTranslationDirection.toChinese.targetLanguage == "zh-Hans")
        #expect(SelectionTranslationDirection(targetLanguage: "en") == .toEnglish)
        #expect(SelectionTranslationDirection(targetLanguage: "en-US") == .toEnglish)
        #expect(SelectionTranslationDirection(targetLanguage: "zh-Hans") == .toChinese)
        #expect(SelectionTranslationDirection(targetLanguage: nil) == nil)
    }

    @Test
    func localBackendUsesEnglishPromptForChineseSource() async throws {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let content = try JSONSerialization.data(withJSONObject: ["0": "Hello world"])
        let body = try JSONSerialization.data(withJSONObject: [
            "choices": [["message": ["role": "assistant", "content": String(decoding: content, as: UTF8.self)]]]
        ])
        let transport = DirectionRecordingTransport(response: HTTPResponse(statusCode: 200, headers: [:], body: body))
        let backend = try LocalOpenAIBackend(
            baseURL: URL(string: "http://127.0.0.1:11434/v1")!,
            model: "qwen-local",
            transport: transport
        )
        let request = TranslationRequest(
            windowRevision: 0,
            items: [TranslationItem(id: id, sourceText: "你好世界")],
            targetLanguage: "en"
        )
        _ = try await backend.translate(request)
        let sent = try #require(await transport.requests.first)
        let raw = try JSONSerialization.jsonObject(with: sent.httpBody ?? Data())
        let object = try #require(raw as? [String: Any])
        let messages = try #require(object["messages"] as? [[String: Any]])
        #expect(messages[0]["content"] as? String == LocalTranslationPrompt.system(for: .toEnglish))
        #expect(messages[0]["content"] as? String != LocalTranslationPrompt.system(for: .toChinese))
        let user = try #require(messages[1]["content"] as? String)
        #expect(user.hasPrefix("Translate to English:"))
        #expect(user.contains("你好世界"))
    }

    @Test
    func localBackendDefaultsToChinesePrompt() async throws {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let content = try JSONSerialization.data(withJSONObject: ["0": "你好"])
        let body = try JSONSerialization.data(withJSONObject: [
            "choices": [["message": ["role": "assistant", "content": String(decoding: content, as: UTF8.self)]]]
        ])
        let transport = DirectionRecordingTransport(response: HTTPResponse(statusCode: 200, headers: [:], body: body))
        let backend = try LocalOpenAIBackend(
            baseURL: URL(string: "http://127.0.0.1:11434/v1")!,
            model: "qwen-local",
            transport: transport
        )
        let request = TranslationRequest(windowRevision: 0, items: [TranslationItem(id: id, sourceText: "Hello")])
        _ = try await backend.translate(request)
        let sent = try #require(await transport.requests.first)
        let raw = try JSONSerialization.jsonObject(with: sent.httpBody ?? Data())
        let object = try #require(raw as? [String: Any])
        let messages = try #require(object["messages"] as? [[String: Any]])
        #expect(messages[0]["content"] as? String == LocalTranslationPrompt.system(for: .toChinese))
        #expect((messages[1]["content"] as? String)?.hasPrefix("Translate to Simplified Chinese:") == true)
    }

    @Test
    func cloudBackendUsesEnglishSystemPromptForChineseSource() async throws {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let body = try Self.deepSeekBody(id: id, text: "Hello world")
        let transport = DirectionRecordingTransport(response: HTTPResponse(statusCode: 200, headers: [:], body: body))
        let backend = DeepSeekBackend(transport: transport, credentialStore: DirectionCredentialStore(value: "key"))
        let request = TranslationRequest(
            windowRevision: 0,
            items: [TranslationItem(id: id, sourceText: "你好世界")],
            targetLanguage: "en"
        )
        _ = try await backend.translate(request)
        let sent = try #require(await transport.requests.first)
        let raw = try JSONSerialization.jsonObject(with: sent.httpBody ?? Data())
        let object = try #require(raw as? [String: Any])
        let input = try #require(object["input"] as? [[String: Any]])
        #expect(input[0]["content"] as? String == TranslationInstructions.system(for: .toEnglish))
        #expect(input[0]["content"] as? String != TranslationInstructions.system(for: .toChinese))
    }

    @Test
    func cloudBackendDefaultsToChineseSystemPrompt() async throws {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let body = try Self.deepSeekBody(id: id, text: "你好")
        let transport = DirectionRecordingTransport(response: HTTPResponse(statusCode: 200, headers: [:], body: body))
        let backend = DeepSeekBackend(transport: transport, credentialStore: DirectionCredentialStore(value: "key"))
        let request = TranslationRequest(windowRevision: 0, items: [TranslationItem(id: id, sourceText: "Hello")])
        _ = try await backend.translate(request)
        let sent = try #require(await transport.requests.first)
        let raw = try JSONSerialization.jsonObject(with: sent.httpBody ?? Data())
        let object = try #require(raw as? [String: Any])
        let input = try #require(object["input"] as? [[String: Any]])
        #expect(input[0]["content"] as? String == TranslationInstructions.system(for: .toChinese))
    }

    private static func deepSeekBody(id: UUID, text: String) throws -> Data {
        let translation = "{\"translations\":[{\"segmentId\":\"\(id.uuidString)\",\"text\":\"\(text)\"}]}"
        return try JSONSerialization.data(withJSONObject: [
            "output": [["type": "message", "content": [["type": "output_text", "text": translation]]]]
        ])
    }

    @Test
    func fallbackPromptIsDirectionAware() {
        let zh = SelectionFallbackInstructions.system(for: .toChinese)
        let en = SelectionFallbackInstructions.system(for: .toEnglish)
        #expect(zh.contains("Simplified Chinese"))
        #expect(en.contains("English"))
        #expect(!en.contains("proper noun"))
        #expect(en.contains("untrusted data"))
    }
}
