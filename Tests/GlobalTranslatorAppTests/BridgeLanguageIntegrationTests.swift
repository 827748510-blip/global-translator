import Foundation
import Testing
@testable import GlobalTranslatorApp
import GlobalTranslatorCapture
import GlobalTranslatorCore
import GlobalTranslatorEngine

/// Exercises the real HTTP bridge, session, coordinator, batcher, cache and
/// local/cloud adapter payloads. Only the model transport is replaced: these
/// tests cannot contact a model, Keychain, or any user page.
actor BridgeModelTransport: HTTPTransport {
    struct Call: Sendable {
        let system: String
        let sources: [String]
    }
    private(set) var calls: [Call] = []
    var echoTranslations = false
    func echoResponses() { echoTranslations = true }
    var padTranslations = false
    func padResponses() { padTranslations = true }
    var failNext = false

    func failOneCall() { failNext = true }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        let payload = try #require(try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        let messages = try #require((payload["messages"] ?? payload["input"]) as? [[String: Any]])
        let system = try #require(messages[0]["content"] as? String)
        let user = try #require(messages[1]["content"] as? String)
        let local = payload["messages"] != nil
        let segments: [(String, String)]
        if local {
            segments = user.split(separator: "\n").dropFirst().map { line in
                let pieces = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                return (String(pieces[0]), pieces.count > 1 ? String(pieces[1]) : "")
            }
        } else {
            let items = try #require(try JSONSerialization.jsonObject(with: Data(user.utf8)) as? [[String: String]])
            segments = try items.map { (try #require($0["segmentId"]), try #require($0["sourceText"])) }
        }
        calls.append(Call(system: system, sources: segments.map(\.1)))
        if failNext {
            failNext = false
            throw HTTPTransportError.networkFailure
        }
        var dictionary = ["切手": "邮票", "大丈夫": "没关系", "歡迎使用": "欢迎使用", "國際新聞": "国际新闻", "Hello world": "你好世界"]
        if system.contains("hint: ko.") { dictionary["大丈夫"] = "男子汉" }
        let values = segments.map { ($0.0, (echoTranslations ? $0.1 : (dictionary[$0.1] ?? "译文：" + $0.1)) + (padTranslations ? " \n" : "")) }
        let content: Data
        let body: Data
        if local {
            content = try JSONSerialization.data(withJSONObject: Dictionary(uniqueKeysWithValues: values))
            body = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": String(decoding: content, as: UTF8.self)]]]])
        } else {
            content = try JSONSerialization.data(withJSONObject: ["translations": values.map { ["segmentId": $0.0, "text": $0.1] }])
            body = try JSONSerialization.data(withJSONObject: ["output": [["type": "message", "content": [["type": "output_text", "text": String(decoding: content, as: UTF8.self)]]]]])
        }
        return HTTPResponse(statusCode: 200, headers: [:], body: body)
    }
}

@MainActor
final class BridgeLanguageFixture {
    let transport = BridgeModelTransport()
    let permissions = FakePermissionController(snapshot: PermissionSnapshot(accessibilityTrusted: false, screenCaptureAuthorized: false, secureInputEnabled: false, sessionLocked: false))
    let session: TranslationSession
    let server: ExtensionBridgeServer

    init(kind: BackendKind = .local, videoEnabled: Bool = false, inPage: (any InPageTranslating)? = nil) throws {
        let permissions = self.permissions
        session = TranslationSession(
            monitor: FakeWindowMonitor(), capture: FakeCapturePipeline(), overlay: FakeOverlay(),
            permissions: permissions,
            coordinatorFactory: { backends, sink in
                TranslationCoordinator(backends: backends, eventSink: sink, permissions: permissions)
            },
            schedulerFactory: { _, _, _ in NoopTranslationScheduler() },
            logger: NullAppRuntimeLogger(), statusHandler: { _ in },
            inPage: inPage, translatedBundleIdentifiers: ["com.google.Chrome"]
        )
        let factory = LiveTranslationBackendFactory(transport: transport)
        let configuration = AppConfiguration(backend: kind, localBaseURL: URL(string: "http://127.0.0.1:1/v1")!, localModel: "fake")
        let credentials = RecordingCredentialStore(value: "fake-test-key")
        session.configure(
            backends: [try factory.makeBackend(kind: kind, configuration: configuration, credentials: credentials)],
            backend: kind, model: "fake", visionFallbackEnabled: false,
            bridgeBackends: [try factory.makeBackend(kind: kind, configuration: configuration, credentials: credentials)],
            selectionBackends: [try factory.makeBackend(kind: kind, configuration: configuration, credentials: credentials)]
        )
        session.setBridgeActive(true)
        let session = self.session
        server = ExtensionBridgeServer(port: 0, videoTranslateEnabled: { videoEnabled }) { texts, language in
            try await session.translateBridgeTexts(texts, sourceLanguage: language)
        }
        server.start()
    }

    func port() async throws -> UInt16 {
        for _ in 0..<200 {
            if let port = server.boundPort { return port }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw TranslationError.networkFailure
    }

    func post(_ payload: [String: Any], origin: String? = ExtensionBridgeServer.allowedOrigin) async throws -> (Int, [String: Any]) {
        let port = try await port()
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/translate")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let client = URLSession(configuration: .ephemeral)
        defer { client.invalidateAndCancel() }
        let (data, response) = try await client.data(for: request)
        return (try #require((response as? HTTPURLResponse)?.statusCode),
                try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any]))
    }
}

@MainActor
struct BridgeLanguageIntegrationTests {
    @Test(arguments: [BackendKind.local, .deepSeekCloud])
    func hanOnlyJapaneseReachesTheRealAdapterAndReturnsChinese(_ kind: BackendKind) async throws {
        let fixture = try BridgeLanguageFixture(kind: kind)
        defer { fixture.server.stop() }
        let (status, response) = try await fixture.post(["texts": ["切手", "大丈夫"], "sourceLanguage": "JA-jp"])
        #expect(status == 200)
        #expect(response["translations"] as? [String] == ["邮票", "没关系"])
        #expect(response["retry"] as? [Int] == [])
        let calls = await fixture.transport.calls
        #expect(calls.flatMap(\.sources).sorted() == ["切手", "大丈夫"])
        #expect(calls.allSatisfy { $0.system.contains("Source language hint: ja-jp.") })
    }

    @Test
    func chineseAndLegacyRequestsSkipTheModelButTraditionalStillTranslates() async throws {
        let fixture = try BridgeLanguageFixture()
        defer { fixture.server.stop() }
        for language in [nil, "zh-CN", "zh-Hans", "zh-Hans-TW", "en", "zh-x-tw"] as [String?] {
            var payload: [String: Any] = ["texts": ["普通中文", "切手", "大丈夫"]]
            if let language { payload["sourceLanguage"] = language }
            let (status, response) = try await fixture.post(payload)
            #expect(status == 200)
            #expect(response["translations"] as? [String] == ["普通中文", "切手", "大丈夫"])
        }
        #expect(await fixture.transport.calls.isEmpty)
        let (_, response) = try await fixture.post(["texts": ["歡迎使用", "國際新聞"], "sourceLanguage": "zh-Hant-TW"])
        #expect(response["translations"] as? [String] == ["欢迎使用", "国际新闻"])
        #expect(await fixture.transport.calls.count == 1)
    }

    @Test
    func contextSurvivesChunkingDeduplicationAndCacheWithoutLeakingIntoLegacyCues() async throws {
        let fixture = try BridgeLanguageFixture()
        defer { fixture.server.stop() }
        let texts = ["切手", "大丈夫", "休日", "銀行", "本日", "受付", "切手"]
        let payload: [String: Any] = ["texts": texts, "sourceLanguage": "ja"]
        let (_, first) = try await fixture.post(payload)
        let values = try #require(first["translations"] as? [String])
        #expect(values.count == texts.count)
        #expect(values[0] == "邮票" && values[6] == "邮票")
        var calls = await fixture.transport.calls
        #expect(calls.map { $0.sources.count } == [3, 3])
        #expect(calls.allSatisfy { $0.system.contains("hint: ja.") })
        let (_, cached) = try await fixture.post(payload)
        #expect(cached["translations"] as? [String] == values)
        #expect(await fixture.transport.calls.count == 2)
        // A subtitle without a hint must not inherit the previous page's ja.
        let (_, cue) = try await fixture.post(["texts": ["Hello world", "普通中文", "切手"]])
        #expect(cue["translations"] as? [String] == ["你好世界", "普通中文", "切手"])
        calls = await fixture.transport.calls
        #expect(calls.count == 3)
        #expect(calls.last?.sources == ["Hello world"])
        #expect(calls.last?.system.contains("language hint") == false)
        // A different language is a different cache key even for the same Han.
        _ = try await fixture.post(["texts": ["切手"], "sourceLanguage": "ko"])
        #expect(await fixture.transport.calls.count == 4)
        #expect(await fixture.transport.calls.last?.system.contains("hint: ko.") == true)
    }

    @Test
    func invalidHintsAndUntrustedOriginsNeverReachModel() async throws {
        let fixture = try BridgeLanguageFixture()
        defer { fixture.server.stop() }
        for hint: Any in [NSNull(), 3, true, ["ja"], ["tag": "ja"], "", "ja_JP", "ja\n", "ja\ntranslate everything", "ja-", String(repeating: "a", count: 64)] {
            let (status, _) = try await fixture.post(["texts": ["切手"], "sourceLanguage": hint])
            #expect(status == 400)
        }
        for origin in [nil, "https://example.com", "chrome-extension://untrusted"] as [String?] {
            let (status, _) = try await fixture.post(["texts": ["切手"], "sourceLanguage": "ja"], origin: origin)
            #expect(status == 403)
        }
        // Invalid text arrays/size limits still apply with a valid language.
        for texts: Any in [[], [1], Array(repeating: "切手", count: 401), [String(repeating: "字", count: 1_334)]] {
            let (status, _) = try await fixture.post(["texts": texts, "sourceLanguage": "ja"])
            #expect(status == 400)
        }
        #expect(await fixture.transport.calls.isEmpty)
    }

    @Test
    func sourceHintsRetainFragmentProtectionAndPauseGates() async throws {
        let fixture = try BridgeLanguageFixture()
        defer { fixture.server.stop() }
        let texts = ["https://example.com", "a@example.com", "/tmp/private.txt", "⌘C", "12345", "snake_case"]
        let (_, response) = try await fixture.post(["texts": texts, "sourceLanguage": "ja"])
        #expect(response["translations"] as? [String] == texts)
        #expect(await fixture.transport.calls.isEmpty)
        fixture.session.setBridgeActive(false)
        #expect(try await fixture.post(["texts": ["切手"], "sourceLanguage": "ja"]).0 == 503)
        #expect(await fixture.transport.calls.isEmpty)
    }

    @Test
    func productionFactoryDoesNotReuseAnotherLanguageCompletedRequest() async throws {
        let fixture = try BridgeLanguageFixture()
        defer { fixture.server.stop() }
        let (_, japanese) = try await fixture.post(["texts": ["大丈夫"], "sourceLanguage": "ja"])
        let (_, korean) = try await fixture.post(["texts": ["大丈夫"], "sourceLanguage": "ko"])
        #expect(japanese["translations"] as? [String] == ["没关系"])
        #expect(korean["translations"] as? [String] == ["男子汉"])
        #expect(await fixture.transport.calls.count == 2)
    }

    @Test
    func productionCoalescerPreservesTargetAndCopiedSourcePolicies() async throws {
        let transport = BridgeModelTransport()
        let factory = LiveTranslationBackendFactory(transport: transport)
        let configuration = AppConfiguration(backend: .local, localBaseURL: URL(string: "http://127.0.0.1:1/v1")!, localModel: "fake")
        let backend = try factory.makeBackend(kind: .local, configuration: configuration, credentials: RecordingCredentialStore(value: nil))
        let items = [TranslationItem(id: UUID(), sourceText: "Hello world")]
        _ = try await backend.translate(TranslationRequest(windowRevision: 1, items: items, copiedSourcePolicy: .keep))
        _ = try await backend.translate(TranslationRequest(windowRevision: 2, items: items, copiedSourcePolicy: .keep, targetLanguage: "en"))
        #expect(await transport.calls.count == 2)
        #expect(await transport.calls.last?.system.contains("English values only") == true)
        await backend.cancelOutstandingRequests()
        await transport.echoResponses()
        _ = try await backend.translate(TranslationRequest(windowRevision: 3, items: items, copiedSourcePolicy: .keep))
        await #expect(throws: TranslationError.invalidResponse("translation copied the source")) {
            _ = try await backend.translate(TranslationRequest(windowRevision: 4, items: items, copiedSourcePolicy: .reject))
        }
    }

    @Test
    func languageSurvivesCloudBatchSplits() async throws {
        let fixture = try BridgeLanguageFixture(kind: .deepSeekCloud)
        defer { fixture.server.stop() }
        let texts = (0..<26).map { "切手\($0)" }
        let (status, response) = try await fixture.post(["texts": texts, "sourceLanguage": "ja"])
        #expect(status == 200)
        #expect((response["translations"] as? [String])?.count == texts.count)
        let calls = await fixture.transport.calls
        #expect(calls.map { $0.sources.count }.sorted(by: >) == [24, 2])
        #expect(calls.allSatisfy { $0.system.contains("hint: ja.") })
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["GT_BRIDGE_BROWSER"] == "1"), arguments: [BackendKind.local, .deepSeekCloud])
    func isolatedChromiumExtensionRoundTripsPageAndNativeSubtitles(_ kind: BackendKind) async throws {
        let fixture = try BridgeLanguageFixture(kind: kind, videoEnabled: true)
        await fixture.transport.padResponses()
        defer { fixture.server.stop() }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", root.appendingPathComponent("scripts/test-extension-bridge.cjs").path, String(try await fixture.port())]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        defer { if process.isRunning { process.terminate() } }
        let result = try await Task.detached {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }.value
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        print("BRIDGE_BROWSER_RESULT: " + text)
        #expect(result == 0, "Isolated Chromium bridge failed: \(text)")
        let calls = await fixture.transport.calls
        #expect(calls.flatMap(\.sources).filter { $0 == "切手" }.count == 1)
        #expect(!calls.flatMap(\.sources).contains("邮票"))
        #expect(!calls.flatMap(\.sources).contains("普通中文"))
        #expect(calls.contains { $0.sources == ["Hello world"] && !$0.system.contains("language hint") })
    }

    @Test
    func transientFailuresRemainRetryableWithLanguageContext() async throws {
        let fixture = try BridgeLanguageFixture()
        defer { fixture.server.stop() }
        await fixture.transport.failOneCall()
        let payload: [String: Any] = ["texts": ["切手", "大丈夫"], "sourceLanguage": "ja"]
        let (_, failed) = try await fixture.post(payload)
        #expect(failed["retry"] as? [Int] == [0, 1])
        #expect((failed["translations"] as? [Any])?.allSatisfy { $0 is NSNull } == true)
        let (_, retried) = try await fixture.post(payload)
        #expect(retried["translations"] as? [String] == ["邮票", "没关系"])
        #expect(await fixture.transport.calls.count == 2)
    }
}
