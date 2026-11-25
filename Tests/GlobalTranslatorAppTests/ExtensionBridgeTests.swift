import Foundation
import os
import Testing
@testable import GlobalTranslatorApp
import GlobalTranslatorCapture
import GlobalTranslatorCore
import GlobalTranslatorEngine
import GlobalTranslatorRuntime

/// Pins why the extension bridge gets its own coordinator: the window
/// pipeline's revision gate rejects unversioned (revision 0) requests once
/// any real window revision has been translated.
struct ExtensionBridgeRevisionGateTests {
    @Test
    func unversionedRequestIsRejectedAfterWindowTranslation() async throws {
        let coordinator = TranslationCoordinator(
            backends: [StubBackend(kind: .local)],
            permissions: FakePermissionController(snapshot: .allGranted)
        )
        await coordinator.selectBackend(kind: .local, modelIdentifier: "test")
        _ = try await coordinator.translate(
            snapshot: snapshot(revision: 100), backend: .local,
            modelIdentifier: "test", visionFallbackEnabled: false)
        await #expect(throws: TranslationCoordinatorError.staleRevision) {
            _ = try await coordinator.translate(
                snapshot: snapshot(revision: 0), backend: .local,
                modelIdentifier: "test", visionFallbackEnabled: false)
        }
    }

    private func snapshot(revision: UInt64) -> CaptureSnapshot {
        let region = TextRegion(id: UUID(), sourceText: "Hello world", screenFrame: .zero,
                                confidence: 1, source: .accessibility, windowRevision: revision)
        let descriptor = ActiveWindowDescriptor(pid: 1, bundleIdentifier: "qa.bridge", windowID: nil,
                                                frame: .zero, revision: revision, invalidatesOverlay: false)
        return CaptureSnapshot(window: CapturedWindow(descriptor: descriptor, regions: [region], source: .accessibility))
    }
}

struct ExtensionBridgeServerTests {
    @Test
    func contentScriptUsesSmallChunksForLocalOllama() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("extension/content.js")
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(source.contains("const CHUNK_SIZE = 3;"))
        #expect(!source.contains("const CHUNK_SIZE = 30;"))
        #expect(source.contains("GlobalTranslatorTextFilter.shouldSendForPageTranslate"))
        #expect(source.contains("retry.has(i)"))
        #expect(source.contains("let retryPending = false;"))
        #expect(source.contains("retryPending = true;"))
        #expect(source.contains("scheduleRetry();"))
    }

    @Test
    func contentScriptTextFilterSkipsNonTranslatableFragments() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("extension/text-filter.js")
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(source.contains("function shouldSendForPageTranslate"))
        #expect(source.contains("function isURL("))
        #expect(source.contains("function isEmail("))
        #expect(source.contains("function isIdentifierOrUnit("))
        #expect(source.contains("function isTechnicalTokenPhrase("))
    }

    @Test
    func backgroundScriptSerializesLoopbackFetches() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("extension/background.js")
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(source.contains("function enqueueBridgeFetch("))
        #expect(source.contains("importScripts(\"bridge-queue.js\")"))
        #expect(source.contains("message.lane === \"video\""))
        #expect(source.contains("enqueueBridgeFetch(() =>"))
        #expect(source.contains("retry: Array.isArray(payload.retry) ? payload.retry : []"))
        #expect(source.contains("payload.videoTranslateEnabled === true"))
        #expect(source.contains("message.type === \"ping\""))
        #expect(!source.contains("enqueueBridgeFetch(() =>\n      fetch(ENDPOINT + \"/health\""))
    }

    @Test
    func extensionManifestBumpsWhenBackgroundQueueChanges() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("extension/manifest.json")
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(source.contains("\"version\": \"1.0.12\""))
        #expect(!source.contains("\"version\": \"1.0.11\""))
        #expect(source.contains("\"js\": [\"text-filter.js\", \"subtitle-cues.js\", \"youtube-captions.js\", \"video-asr.js\", \"content.js\", \"video-translate.js\"]"))
        #expect(source.contains("youtube-captions-page.js"))
        #expect(source.contains("\"world\": \"MAIN\""))
    }

    @Test
    func videoTranslatePhaseAIsOffByDefaultAndSkipsAsr() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let popup = try String(contentsOf: root.appendingPathComponent("extension/popup.html"), encoding: .utf8)
        let popupJs = try String(contentsOf: root.appendingPathComponent("extension/popup.js"), encoding: .utf8)
        let videoJs = try String(contentsOf: root.appendingPathComponent("extension/video-translate.js"), encoding: .utf8)
        let cuesJs = try String(contentsOf: root.appendingPathComponent("extension/subtitle-cues.js"), encoding: .utf8)
        let settings = try String(
            contentsOf: root.appendingPathComponent("Sources/GlobalTranslatorUI/SettingsSections.swift"),
            encoding: .utf8
        )
        let visual = try String(
            contentsOf: root.appendingPathComponent("Sources/GlobalTranslatorCapture/WindowVisualUpdates.swift"),
            encoding: .utf8
        )
        let youtubeJs = try String(contentsOf: root.appendingPathComponent("extension/youtube-captions.js"), encoding: .utf8)
        let youtubePage = try String(contentsOf: root.appendingPathComponent("extension/youtube-captions-page.js"), encoding: .utf8)
        let contentJs = try String(contentsOf: root.appendingPathComponent("extension/content.js"), encoding: .utf8)
        let audio = try String(
            contentsOf: root.appendingPathComponent("Sources/GlobalTranslatorCapture/SystemAudioCapture.swift"),
            encoding: .utf8
        )
        let asr = try String(
            contentsOf: root.appendingPathComponent("Sources/GlobalTranslatorCapture/VideoAudioASRController.swift"),
            encoding: .utf8
        )
        #expect(settings.contains("\"划词翻译\""))
        #expect(settings.contains("\"视频翻译\""))
        #expect(!popup.contains("id=\"videoTranslate\""))
        #expect(popup.contains("id=\"videoTranslateToggle\""))
        #expect(popup.contains("视频"))
        #expect(popupJs.contains("videoTranslateEnabled: false"))
        #expect(popupJs.contains("response.videoTranslateEnabled === true"))
        #expect(videoJs.contains("videoTranslateEnabled: false"))
        #expect(videoJs.contains("videoTranslateEnabled === true"))
        #expect(videoJs.contains("type: \"translate\""))
        #expect(!videoJs.contains("getUserMedia"))
        #expect(!videoJs.contains("mediaDevices"))
        #expect(!videoJs.contains("SpeechRecognition"))
        #expect(!videoJs.lowercased().contains("whisper"))
        #expect(cuesJs.contains("翻译服务不可用"))
        #expect(cuesJs.contains("未检测到外语内容"))
        #expect(cuesJs.contains("videoTranslateEnabled: false"))
        #expect(visual.contains("configuration.capturesAudio = false"))
        #expect(!visual.contains("capturesAudio = true"))
        #expect(audio.contains("capturesAudio = true"))
        #expect(audio.contains("captureMicrophone = false"))
        #expect(!audio.contains(".microphone"))
        #expect(asr.contains("enabled && needed"))
        #expect(asr.contains("OSAllocatedUnfairLock"))
        #expect(!asr.contains("NSLock()"))
        #expect(!asr.contains(".lock()"))
        #expect(!asr.contains(".unlock()"))
        #expect(videoJs.contains("type: \"video-asr\""))
        #expect(videoJs.contains("GlobalTranslatorVideoASR"))
        #expect(videoJs.contains("GlobalTranslatorYouTubeCaptions"))
        #expect(videoJs.contains("data-gt-video-translate"))
        #expect(!videoJs.contains("#movie_player"))
        #expect(!videoJs.contains("html5-main-video, video"))
        #expect(videoJs.contains("syncFromDom"))
        #expect(videoJs.contains("lane: \"video\""))
        #expect(videoJs.contains("desktopVideoPrefFromPing"))
        #expect(videoJs.contains("CUE_WAIT_MS"))
        #expect(cuesJs.contains("desktopVideoPrefFromPing"))
        #expect(youtubeJs.contains("\"skip\""))
        #expect(!videoJs.contains("all:initial"))
        #expect(youtubePage.contains("data-gt-ytcap"))
        #expect(youtubeJs.contains("adoptLiveCaption"))
        #expect(contentJs.contains("ytp-caption-segment"))
        #expect(!youtubeJs.lowercased().contains("whisper"))
        #expect(!youtubePage.contains("setOption"))
        #expect(!youtubePage.contains("loadModule"))
        #expect(!youtubePage.contains("getUserMedia"))
        #expect(youtubePage.contains("response.clone()"))
        #expect(popup.contains("YouTube 请先开启播放器原生字幕"))
        #expect(popupJs.contains("set-video-translate"))
    }

    @Test
    func setVideoTranslateEndpointRejectsForeignOriginAndInvalidPayload() async throws {
        let current = OSAllocatedUnfairLock(initialState: false)
        let session = URLSession(configuration: .ephemeral)
        let server = ExtensionBridgeServer(
            port: 0,
            videoTranslateEnabled: { current.withLock { $0 } },
            setVideoTranslateEnabled: { next in
                current.withLock {
                    $0 = next
                    return $0
                }
            }
        ) { texts, _ in
            ExtensionBridgeTranslation(translations: texts.map { $0 })
        }
        server.start()
        defer { server.stop() }
        let port = try await #require(waitForPort(server))

        let badOrigin = request(
            port,
            method: "POST",
            path: "/video-translate",
            origin: "https://evil.example",
            body: Data("{\"enabled\":true}".utf8)
        )
        let (_, badOriginRes) = try await session.data(for: badOrigin)
        #expect((badOriginRes as? HTTPURLResponse)?.statusCode == 403)
        #expect(!current.withLock { $0 })

        let badBody = request(
            port,
            method: "POST",
            path: "/video-translate",
            origin: ExtensionBridgeServer.allowedOrigin,
            body: Data("{\"enabled\":\"yes\"}".utf8)
        )
        let (_, badBodyRes) = try await session.data(for: badBody)
        #expect((badBodyRes as? HTTPURLResponse)?.statusCode == 400)

        let valid = request(
            port,
            method: "POST",
            path: "/video-translate",
            origin: ExtensionBridgeServer.allowedOrigin,
            body: Data("{\"enabled\":true}".utf8)
        )
        let (validData, validRes) = try await session.data(for: valid)
        #expect((validRes as? HTTPURLResponse)?.statusCode == 200)
        let json = try JSONSerialization.jsonObject(with: validData) as? [String: Any]
        #expect(json?["videoTranslateEnabled"] as? Bool == true)
        #expect(current.withLock { $0 })
    }

    @Test
    func allowedOriginStaysPinnedToTheShippedExtensionId() {
        #expect(ExtensionBridgeServer.allowedOrigin == "chrome-extension://fjggaipmhcfmgikhkjppkdliaoopaefc")
        #expect(ExtensionBridgeServer.allowedOrigins == [ExtensionBridgeServer.allowedOrigin])
    }
    private func waitForPort(_ server: ExtensionBridgeServer) async -> UInt16? {
        for _ in 0..<200 {
            if let port = server.boundPort { return port }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    private func request(_ port: UInt16, method: String, path: String, origin: String?, body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = method
        if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        return request
    }

    @Test
    func translateRoundTripsAndKeepsNullsAligned() async throws {
        let server = ExtensionBridgeServer(port: 0) { texts in
            ExtensionBridgeTranslation(translations: texts.map { $0 == "skip" ? nil : "译:" + $0 })
        }
        server.start()
        defer { server.stop() }
        let port = try await #require(waitForPort(server))

        let body = try JSONSerialization.data(withJSONObject: ["texts": ["hello", "skip", "world"]])
        let urlRequest = request(port, method: "POST", path: "/translate",
                                 origin: ExtensionBridgeServer.allowedOrigin, body: body)
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: urlRequest)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let translations = try #require(object["translations"] as? [Any])
        #expect(translations.count == 3)
        #expect(translations[0] as? String == "译:hello")
        #expect(translations[1] is NSNull)
        #expect(translations[2] as? String == "译:world")
        let retry = object["retry"] as? [Any]
        #expect(retry?.isEmpty == true)
        #expect((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Access-Control-Allow-Origin") == ExtensionBridgeServer.allowedOrigin)
    }

    @Test
    func translateResponseListsTransientFailureIndexesForRetry() async throws {
        let server = ExtensionBridgeServer(port: 0) { texts in
            ExtensionBridgeTranslation(
                translations: texts.map { $0 == "fail" ? nil : "译:" + $0 },
                retryIndexes: texts.enumerated().compactMap { $0.element == "fail" ? $0.offset : nil }
            )
        }
        server.start()
        defer { server.stop() }
        let port = try await #require(waitForPort(server))
        let body = try JSONSerialization.data(withJSONObject: ["texts": ["hello", "fail", "world"]])
        let urlRequest = request(port, method: "POST", path: "/translate",
                                 origin: ExtensionBridgeServer.allowedOrigin, body: body)
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: urlRequest)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let translations = try #require(object["translations"] as? [Any])
        #expect(translations[0] as? String == "译:hello")
        #expect(translations[1] is NSNull)
        #expect(translations[2] as? String == "译:world")
        let retryNumbers = try #require(object["retry"] as? [NSNumber])
        #expect(retryNumbers.map(\.intValue) == [1])
    }

    @Test
    func missingOrForeignOriginIsRejected() async throws {
        let server = ExtensionBridgeServer(port: 0) { texts in ExtensionBridgeTranslation(translations: texts.map { $0 }) }
        server.start()
        defer { server.stop() }
        let port = try await #require(waitForPort(server))
        let body = try JSONSerialization.data(withJSONObject: ["texts": ["hello"]])
        let session = URLSession(configuration: .ephemeral)

        let noOrigin = request(port, method: "POST", path: "/translate", origin: nil, body: body)
        #expect(((try await session.data(for: noOrigin)).1 as? HTTPURLResponse)?.statusCode == 403)

        let website = request(port, method: "POST", path: "/translate", origin: "https://evil.example", body: body)
        #expect(((try await session.data(for: website)).1 as? HTTPURLResponse)?.statusCode == 403)

        let preflight = request(port, method: "OPTIONS", path: "/translate", origin: ExtensionBridgeServer.allowedOrigin)
        let (_, preflightResponse) = try await session.data(for: preflight)
        #expect((preflightResponse as? HTTPURLResponse)?.statusCode == 204)

        let foreignPreflight = request(port, method: "OPTIONS", path: "/translate", origin: "https://evil.example")
        #expect(((try await session.data(for: foreignPreflight)).1 as? HTTPURLResponse)?.statusCode == 403)
    }

    @Test
    func legacySideloadOriginIsRejected() async throws {
        let server = ExtensionBridgeServer(port: 0) { texts in ExtensionBridgeTranslation(translations: texts.map { "译:" + $0 }) }
        server.start()
        defer { server.stop() }
        let port = try await #require(waitForPort(server))
        let body = try JSONSerialization.data(withJSONObject: ["texts": ["hello"]])
        // The extension now ships with exactly one whitelisted origin; the old
        // sideload ID must no longer reach the bridge.
        let legacy = "chrome-extension://fignfifoniblkonapihmkfakmlgkbkcf"
        let urlRequest = request(port, method: "POST", path: "/translate", origin: legacy, body: body)
        let (_, response) = try await URLSession(configuration: .ephemeral).data(for: urlRequest)
        #expect((response as? HTTPURLResponse)?.statusCode == 403)

        let preflight = request(port, method: "OPTIONS", path: "/translate", origin: legacy)
        let (_, preflightResponse) = try await URLSession(configuration: .ephemeral).data(for: preflight)
        #expect((preflightResponse as? HTTPURLResponse)?.statusCode == 403)
    }

    @Test
    func healthEndpointAnswersForExtensionOnly() async throws {
        let server = ExtensionBridgeServer(port: 0) { texts in ExtensionBridgeTranslation(translations: texts.map { $0 }) }
        server.start()
        defer { server.stop() }
        let port = try await #require(waitForPort(server))
        let session = URLSession(configuration: .ephemeral)

        let ok = request(port, method: "GET", path: "/health", origin: ExtensionBridgeServer.allowedOrigin)
        #expect(((try await session.data(for: ok)).1 as? HTTPURLResponse)?.statusCode == 200)

        let denied = request(port, method: "GET", path: "/health", origin: nil)
        #expect(((try await session.data(for: denied)).1 as? HTTPURLResponse)?.statusCode == 403)

        // The extension pings with POST because browsers omit Origin on GET.
        let post = request(port, method: "POST", path: "/health", origin: ExtensionBridgeServer.allowedOrigin)
        let (postData, postResponse) = try await session.data(for: post)
        #expect((postResponse as? HTTPURLResponse)?.statusCode == 200)
        let health = try #require(try JSONSerialization.jsonObject(with: postData) as? [String: Any])
        #expect(health["ok"] as? Bool == true)
        #expect(health["videoTranslateEnabled"] as? Bool == false)
        #expect(health["videoAsrStatus"] as? String == "idle")

        let postDenied = request(port, method: "POST", path: "/health", origin: "https://evil.example")
        #expect(((try await session.data(for: postDenied)).1 as? HTTPURLResponse)?.statusCode == 403)
    }

    @Test
    func healthReportsVideoTranslateToggle() async throws {
        let server = ExtensionBridgeServer(port: 0, videoTranslateEnabled: { true }) { texts in
            ExtensionBridgeTranslation(translations: texts.map { $0 })
        }
        server.start()
        defer { server.stop() }
        let port = try await #require(waitForPort(server))
        let post = request(port, method: "POST", path: "/health", origin: ExtensionBridgeServer.allowedOrigin)
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: post)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["ok"] as? Bool == true)
        #expect(object["videoTranslateEnabled"] as? Bool == true)
    }

    @Test
    func videoAsrEndpointIsOriginGatedAndReportsSnapshot() async throws {
        let neededFlag = OSAllocatedUnfairLock(initialState: false)
        let server = ExtensionBridgeServer(
            port: 0,
            videoTranslateEnabled: { true },
            videoASRSnapshot: {
                let needed = neededFlag.withLock { $0 }
                return VideoASRSnapshot(
                    enabled: true,
                    needed: needed,
                    running: needed,
                    status: needed ? .running : .idle,
                    message: "",
                    target: needed ? "display" : nil,
                    cues: needed ? [VideoASRCue(seq: 1, text: "Hello from the speaker", durationMs: 2500)] : []
                )
            },
            videoASRSetNeeded: { value in
                neededFlag.withLock { $0 = value }
            }
        ) { texts in ExtensionBridgeTranslation(translations: texts.map { $0 }) }
        server.start()
        defer { server.stop() }
        let port = try await #require(waitForPort(server))
        let session = URLSession(configuration: .ephemeral)

        let denied = request(port, method: "POST", path: "/video-asr", origin: nil,
                             body: try JSONSerialization.data(withJSONObject: ["needed": true]))
        #expect(((try await session.data(for: denied)).1 as? HTTPURLResponse)?.statusCode == 403)

        let body = try JSONSerialization.data(withJSONObject: ["needed": true])
        let ok = request(port, method: "POST", path: "/video-asr",
                         origin: ExtensionBridgeServer.allowedOrigin, body: body)
        let (data, response) = try await session.data(for: ok)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["ok"] as? Bool == true)
        #expect(object["enabled"] as? Bool == true)
        #expect(object["needed"] as? Bool == true)
        #expect(object["status"] as? String == "running")
        #expect(object["audio"] == nil)
        let cues = try #require(object["cues"] as? [[String: Any]])
        #expect(cues.first?["text"] as? String == "Hello from the speaker")
        #expect((cues.first?["durationMs"] as? NSNumber)?.intValue == 2500)
    }

    @Test
    func inactiveTranslatorMapsTo503() async throws {
        let server = ExtensionBridgeServer(port: 0) { _ in
            throw ExtensionBridgeError.translatorInactive
        }
        server.start()
        defer { server.stop() }
        let port = try await #require(waitForPort(server))
        let body = try JSONSerialization.data(withJSONObject: ["texts": ["hello"]])
        let urlRequest = request(port, method: "POST", path: "/translate",
                                 origin: ExtensionBridgeServer.allowedOrigin, body: body)
        let (_, response) = try await URLSession(configuration: .ephemeral).data(for: urlRequest)
        #expect((response as? HTTPURLResponse)?.statusCode == 503)
    }

    @Test
    func oversizedPayloadIsRejected() async throws {
        let server = ExtensionBridgeServer(port: 0) { texts in ExtensionBridgeTranslation(translations: texts.map { $0 }) }
        server.start()
        defer { server.stop() }
        let port = try await #require(waitForPort(server))
        let tooMany = try JSONSerialization.data(withJSONObject: ["texts": Array(repeating: "hi", count: 401)])
        let urlRequest = request(port, method: "POST", path: "/translate",
                                 origin: ExtensionBridgeServer.allowedOrigin, body: tooMany)
        let (_, response) = try await URLSession(configuration: .ephemeral).data(for: urlRequest)
        #expect((response as? HTTPURLResponse)?.statusCode == 400)
    }
}

extension ApplicationControllerTests {
    @Test
    func bridgeTranslatesEligibleTextsKeepingInputOrder() async throws {
        let store = RecordingConfigurationStore(configuration: AppConfiguration(
            autoTranslateEnabled: true, backend: .local, localModel: "test",
            translatedBundleIDs: ["com.google.Chrome"]))
        let controller = ApplicationController(
            paths: try RuntimePaths(validatingRoot: temporaryRoot()),
            components: makeComponents(store: store, coordinator: TranslatingCoordinator())
        )
        try await controller.start()
        await waitForStartupHealthCheck(controller)
        controller.session?.start()
        let session = try #require(controller.session)
        #expect(session.isBridgeActive)
        let result = try await session.translateBridgeTexts(["Hello there", "已经是中文", "General Kenobi"])
        #expect(result.translations == ["你好 Hello there", "已经是中文", "你好 General Kenobi"])
        #expect(result.retryIndexes.isEmpty)
        await controller.stop()
    }

    @Test
    func bridgeThrowsInactiveWhenMasterSwitchOff() async throws {
        let store = RecordingConfigurationStore(configuration: AppConfiguration(
            autoTranslateEnabled: false, backend: .local, localModel: "test",
            translatedBundleIDs: ["com.google.Chrome"]))
        let controller = ApplicationController(
            paths: try RuntimePaths(validatingRoot: temporaryRoot()),
            components: makeComponents(store: store, coordinator: TranslatingCoordinator())
        )
        try await controller.start()
        await waitForStartupHealthCheck(controller)
        let session = try #require(controller.session)
        #expect(!session.isBridgeActive)
        await #expect(throws: ExtensionBridgeError.translatorInactive) {
            _ = try await session.translateBridgeTexts(["Hello"])
        }
        await controller.stop()
    }

    @Test
    func bridgeSurvivesStopAndStartWithoutReconfigure() async throws {
        let store = RecordingConfigurationStore(configuration: AppConfiguration(
            autoTranslateEnabled: true, backend: .local, localModel: "test",
            translatedBundleIDs: ["com.google.Chrome"]))
        let controller = ApplicationController(
            paths: try RuntimePaths(validatingRoot: temporaryRoot()),
            components: makeComponents(store: store, coordinator: TranslatingCoordinator())
        )
        try await controller.start()
        await waitForStartupHealthCheck(controller)
        let session = try #require(controller.session)
        #expect(session.isBridgeActive)
        session.start()
        #expect(try await session.translateBridgeTexts(["Hello there"]).translations == ["你好 Hello there"])
        session.stop()
        #expect(!session.isRunning)
        #expect(session.isBridgeActive)
        #expect(try await session.translateBridgeTexts(["Hello there"]).translations == ["你好 Hello there"])
        session.start()
        #expect(try await session.translateBridgeTexts(["Hello there"]).translations == ["你好 Hello there"])
        await controller.stop()
    }

    @Test
    func permissionRefreshRestartKeepsBridgeTranslator() async throws {
        let permission = FakePermissionController(snapshot: .allGranted)
        let store = RecordingConfigurationStore(configuration: AppConfiguration(
            autoTranslateEnabled: true, backend: .local, localModel: "test",
            translatedBundleIDs: ["com.google.Chrome"]))
        let controller = ApplicationController(
            paths: try RuntimePaths(validatingRoot: temporaryRoot()),
            components: makeComponents(
                store: store,
                permission: permission,
                coordinator: TranslatingCoordinator()
            )
        )
        try await controller.start()
        await waitForStartupHealthCheck(controller)
        let session = try #require(controller.session)
        #expect(session.isRunning)
        #expect(try await session.translateBridgeTexts(["Hello there"]).translations == ["你好 Hello there"])

        permission.update(PermissionSnapshot(
            accessibilityTrusted: true,
            screenCaptureAuthorized: false,
            secureInputEnabled: false,
            sessionLocked: false
        ))
        controller.refreshPermissions()
        #expect(session.isRunning)
        #expect(try await session.translateBridgeTexts(["Hello there"]).translations == ["你好 Hello there"])
        await controller.stop()
    }

    @Test
    func bridgeTranslatesWithoutCapturePermissionsWhileSessionNotRunning() async throws {
        let denied = PermissionSnapshot(
            accessibilityTrusted: false,
            screenCaptureAuthorized: false,
            secureInputEnabled: false,
            sessionLocked: false
        )
        let permission = FakePermissionController(snapshot: denied)
        let monitor = FakeWindowMonitor()
        let store = RecordingConfigurationStore(configuration: AppConfiguration(
            autoTranslateEnabled: true, backend: .local, localModel: "test",
            translatedBundleIDs: ["com.google.Chrome"]))
        let controller = ApplicationController(
            paths: try RuntimePaths(validatingRoot: temporaryRoot()),
            components: makeComponents(
                store: store,
                permission: permission,
                monitor: monitor,
                coordinator: TranslatingCoordinator()
            )
        )
        try await controller.start()
        await waitForStartupHealthCheck(controller)
        let session = try #require(controller.session)
        #expect(controller.viewModel.backendReady)
        #expect(controller.viewModel.isAutomaticTranslationEnabled)
        #expect(session.isBridgeActive)
        #expect(!session.isRunning)
        #expect(monitor.startCount == 0)
        #expect(try await session.translateBridgeTexts(["Hello there"]).translations == ["你好 Hello there"])
        await controller.stop()
    }

    @Test
    func enablingAutoTranslateWithoutCapturePermissionsServesBridge() async throws {
        let denied = PermissionSnapshot(
            accessibilityTrusted: false,
            screenCaptureAuthorized: false,
            secureInputEnabled: false,
            sessionLocked: false
        )
        let permission = FakePermissionController(snapshot: denied)
        let monitor = FakeWindowMonitor()
        let store = RecordingConfigurationStore(configuration: AppConfiguration(
            autoTranslateEnabled: false, backend: .local, localModel: "test",
            translatedBundleIDs: ["com.google.Chrome"]))
        let controller = ApplicationController(
            paths: try RuntimePaths(validatingRoot: temporaryRoot()),
            components: makeComponents(
                store: store,
                permission: permission,
                monitor: monitor,
                coordinator: TranslatingCoordinator()
            )
        )
        try await controller.start()
        await waitForStartupHealthCheck(controller)
        #expect(controller.viewModel.canEnableAutomaticTranslation)
        #expect(!controller.viewModel.isAutomaticTranslationEnabled)
        controller.viewModel.setAutomaticTranslation(true)
        try await waitForCapture(timeout: 2) { controller.viewModel.isAutomaticTranslationEnabled }
        let session = try #require(controller.session)
        #expect(session.isBridgeActive)
        #expect(!session.isRunning)
        #expect(monitor.startCount == 0)
        #expect(try await session.translateBridgeTexts(["Hello there"]).translations == ["你好 Hello there"])
        await controller.stop()
    }

    @Test
    func windowOverlayRefusesWithoutCapturePermissionsWhileBridgeWorks() async throws {
        let denied = PermissionSnapshot(
            accessibilityTrusted: false,
            screenCaptureAuthorized: false,
            secureInputEnabled: false,
            sessionLocked: false
        )
        let permission = FakePermissionController(snapshot: denied)
        let monitor = FakeWindowMonitor()
        let overlay = FakeOverlay()
        let store = RecordingConfigurationStore(configuration: AppConfiguration(
            autoTranslateEnabled: true, backend: .local, localModel: "test",
            translatedBundleIDs: ["qa.editor"]))
        let controller = ApplicationController(
            paths: try RuntimePaths(validatingRoot: temporaryRoot()),
            components: makeComponents(
                store: store,
                permission: permission,
                monitor: monitor,
                overlay: overlay,
                coordinator: TranslatingCoordinator(),
                capture: SingleRegionCapturePipeline()
            )
        )
        try await controller.start()
        await waitForStartupHealthCheck(controller)
        let session = try #require(controller.session)
        #expect(monitor.startCount == 0)
        #expect(!session.isRunning)
        #expect(try await session.translateBridgeTexts(["Hello there"]).translations == ["你好 Hello there"])

        session.start()
        monitor.emit(ActiveWindowDescriptor(
            pid: 42, bundleIdentifier: "qa.editor",
            frame: CGRect(x: 0, y: 0, width: 800, height: 600), revision: 1
        ))
        try await waitForCapture { controller.viewModel.status == .missingPermission }
        #expect(overlay.lastTranslations.isEmpty)
        #expect(try await session.translateBridgeTexts(["Hello there"]).translations == ["你好 Hello there"])
        await controller.stop()
    }

    @Test
    func localBridgeTranslatesThirtyStringsWithoutABulkCoordinatorCall() async throws {
        let denied = PermissionSnapshot(
            accessibilityTrusted: false,
            screenCaptureAuthorized: false,
            secureInputEnabled: false,
            sessionLocked: false
        )
        let coordinator = OneItemCoordinator()
        let store = RecordingConfigurationStore(configuration: AppConfiguration(
            autoTranslateEnabled: true, backend: .local, localModel: "test"))
        let controller = ApplicationController(
            paths: try RuntimePaths(validatingRoot: temporaryRoot()),
            components: makeComponents(
                store: store,
                permission: FakePermissionController(snapshot: denied),
                coordinator: coordinator
            )
        )
        try await controller.start()
        await waitForStartupHealthCheck(controller)
        let session = try #require(controller.session)
        let texts = (0..<30).map { "Hello from page \($0) now" }
        let result = try await session.translateBridgeTexts(texts)
        #expect(result.translations == texts.map { "你好 " + $0 })
        #expect(result.retryIndexes.isEmpty)
        #expect(await coordinator.itemCounts == Array(repeating: 3, count: 10))
        #expect(!session.isRunning)
        await controller.stop()
    }

    @Test
    func localBridgeKeepsIneligibleFragmentsWithoutCallingBackend() async throws {
        let coordinator = RecordingBridgeCoordinator()
        let store = RecordingConfigurationStore(configuration: AppConfiguration(
            autoTranslateEnabled: true, backend: .local, localModel: "test"))
        let controller = ApplicationController(
            paths: try RuntimePaths(validatingRoot: temporaryRoot()),
            components: makeComponents(
                store: store,
                permission: FakePermissionController(snapshot: PermissionSnapshot(
                    accessibilityTrusted: false, screenCaptureAuthorized: false,
                    secureInputEnabled: false, sessionLocked: false)),
                coordinator: coordinator
            )
        )
        try await controller.start()
        await waitForStartupHealthCheck(controller)
        let session = try #require(controller.session)
        let result = try await session.translateBridgeTexts([
            "https://example.com/a",
            "name@example.com",
            "timeout_ms",
            "Hello there friends now",
            "已经是中文",
            "getUserProfile"
        ])
        #expect(result.translations == [
            "https://example.com/a",
            "name@example.com",
            "timeout_ms",
            "你好 Hello there friends now",
            "已经是中文",
            "getUserProfile"
        ])
        #expect(result.retryIndexes.isEmpty)
        #expect(await coordinator.sources == [["Hello there friends now"]])
        await controller.stop()
    }

    @Test
    func localBridgeKeepsCopiedSourceAsSuccessfulOriginal() async throws {
        let coordinator = EchoingCoordinator()
        let logger = RecordingLogger()
        let store = RecordingConfigurationStore(configuration: AppConfiguration(
            autoTranslateEnabled: true, backend: .local, localModel: "test"))
        let controller = ApplicationController(
            paths: try RuntimePaths(validatingRoot: temporaryRoot()),
            components: makeComponents(
                store: store,
                permission: FakePermissionController(snapshot: PermissionSnapshot(
                    accessibilityTrusted: false, screenCaptureAuthorized: false,
                    secureInputEnabled: false, sessionLocked: false)),
                coordinator: coordinator,
                logger: logger
            )
        )
        try await controller.start()
        await waitForStartupHealthCheck(controller)
        let session = try #require(controller.session)
        let result = try await session.translateBridgeTexts(["Hello world from the page"])
        #expect(result.translations == ["Hello world from the page"])
        #expect(result.retryIndexes.isEmpty)
        #expect(!logger.records.contains { $0.0 == "bridge_item_failed" })
        await controller.stop()
    }

    @Test
    func localBridgeKeepsGoingAfterATransientItemFailure() async throws {
        let coordinator = FlakySecondItemCoordinator()
        let store = RecordingConfigurationStore(configuration: AppConfiguration(
            autoTranslateEnabled: true, backend: .local, localModel: "test"))
        let controller = ApplicationController(
            paths: try RuntimePaths(validatingRoot: temporaryRoot()),
            components: makeComponents(
                store: store,
                permission: FakePermissionController(snapshot: PermissionSnapshot(
                    accessibilityTrusted: false, screenCaptureAuthorized: false,
                    secureInputEnabled: false, sessionLocked: false)),
                coordinator: coordinator
            )
        )
        try await controller.start()
        await waitForStartupHealthCheck(controller)
        let session = try #require(controller.session)
        let result = try await session.translateBridgeTexts([
            "Hello from page one now",
            "Hello from page two now",
            "Hello from page three now",
            "Hello from page four now",
            "Hello from page five now",
            "Hello from page six now"
        ])
        #expect(result.translations == [
            "你好 Hello from page one now",
            "你好 Hello from page two now",
            "你好 Hello from page three now",
            nil, nil, nil
        ])
        #expect(result.retryIndexes == [3, 4, 5])
        await controller.stop()
    }

    @Test
    func deepSeekBridgeInvalidJSONReturnsRetryInsteadOfThrowing() async throws {
        let coordinator = ThrowingJSONCoordinator()
        let store = RecordingConfigurationStore(configuration: AppConfiguration(
            autoTranslateEnabled: true, backend: .deepSeekCloud, localModel: "test"))
        let controller = ApplicationController(
            paths: try RuntimePaths(validatingRoot: temporaryRoot()),
            components: makeComponents(
                store: store,
                permission: FakePermissionController(snapshot: PermissionSnapshot(
                    accessibilityTrusted: false, screenCaptureAuthorized: false,
                    secureInputEnabled: false, sessionLocked: false)),
                coordinator: coordinator
            )
        )
        try await controller.start()
        await waitForStartupHealthCheck(controller)
        let session = try #require(controller.session)
        let result = try await session.translateBridgeTexts(["Hello from a youtube cue now"])
        #expect(result.translations == [nil])
        #expect(result.retryIndexes == [0])
        await controller.stop()
    }

    @Test
    func chromeWindowSkipsOverlayCaptureWhenBridgeIsActive() async throws {
        let monitor = FakeWindowMonitor()
        let capture = CountingCapturePipeline()
        let overlay = FakeOverlay()
        let schedulerBox = SchedulerBox()
        let logger = RecordingLogger()
        let store = RecordingConfigurationStore(configuration: AppConfiguration(
            autoTranslateEnabled: true, backend: .local, localModel: "test",
            translatedBundleIDs: ["com.google.Chrome"]))
        let controller = ApplicationController(
            paths: try RuntimePaths(validatingRoot: temporaryRoot()),
            components: makeComponents(
                store: store,
                monitor: monitor,
                overlay: overlay,
                coordinator: TranslatingCoordinator(),
                capture: capture,
                schedulerBox: schedulerBox,
                logger: logger
            )
        )
        try await controller.start()
        await waitForStartupHealthCheck(controller)
        let session = try #require(controller.session)
        #expect(session.isBridgeActive)
        session.start()
        monitor.emit(ActiveWindowDescriptor(
            pid: 42, bundleIdentifier: "com.google.Chrome",
            windowID: 17, frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            revision: 1, invalidatesOverlay: true
        ))
        try await Task.sleep(for: .milliseconds(300))
        #expect(await capture.count == 0)
        #expect(schedulerBox.value?.submitCount == 0)
        #expect(overlay.lastTranslations.isEmpty)
        #expect(logger.records.contains { $0.0 == "window_skipped_for_bridge" })
        #expect(try await session.translateBridgeTexts(["Hello there"]).translations == ["你好 Hello there"])
        await controller.stop()
    }

    @Test
    func editorWindowStillCapturesWhenBridgeIsActive() async throws {
        let monitor = FakeWindowMonitor()
        let capture = CountingCapturePipeline()
        let schedulerBox = SchedulerBox()
        let store = RecordingConfigurationStore(configuration: AppConfiguration(
            autoTranslateEnabled: true, backend: .local, localModel: "test",
            translatedBundleIDs: ["qa.editor"]))
        let controller = ApplicationController(
            paths: try RuntimePaths(validatingRoot: temporaryRoot()),
            components: makeComponents(
                store: store,
                monitor: monitor,
                coordinator: TranslatingCoordinator(),
                capture: capture,
                schedulerBox: schedulerBox
            )
        )
        try await controller.start()
        await waitForStartupHealthCheck(controller)
        let session = try #require(controller.session)
        session.start()
        monitor.emit(ActiveWindowDescriptor(
            pid: 42, bundleIdentifier: "qa.editor",
            windowID: 17, frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            revision: 1, invalidatesOverlay: true
        ))
        try await waitForCapture { await capture.count == 1 }
        #expect(await capture.count == 1)
        #expect(schedulerBox.value?.submitCount == 1)
        await controller.stop()
    }

    @Test
    func chromeWindowCapturesWhenBridgeIsInactive() async throws {
        let monitor = FakeWindowMonitor()
        let capture = CountingCapturePipeline()
        let schedulerBox = SchedulerBox()
        let store = RecordingConfigurationStore(configuration: AppConfiguration(
            autoTranslateEnabled: true, backend: .local, localModel: "test",
            translatedBundleIDs: ["com.google.Chrome"]))
        let controller = ApplicationController(
            paths: try RuntimePaths(validatingRoot: temporaryRoot()),
            components: makeComponents(
                store: store,
                monitor: monitor,
                coordinator: TranslatingCoordinator(),
                capture: capture,
                schedulerBox: schedulerBox
            )
        )
        try await controller.start()
        await waitForStartupHealthCheck(controller)
        let session = try #require(controller.session)
        session.start()
        session.setBridgeActive(false)
        monitor.emit(ActiveWindowDescriptor(
            pid: 42, bundleIdentifier: "com.google.Chrome",
            windowID: 17, frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            revision: 1, invalidatesOverlay: true
        ))
        try await waitForCapture { await capture.count == 1 }
        #expect(await capture.count == 1)
        #expect(schedulerBox.value?.submitCount == 1)
        await controller.stop()
    }

    @Test
    func bridgeKeepsTranslatingWhileChromeWindowRevisionsKeepRising() async throws {
        let monitor = FakeWindowMonitor()
        let capture = CountingCapturePipeline()
        let schedulerBox = SchedulerBox()
        let store = RecordingConfigurationStore(configuration: AppConfiguration(
            autoTranslateEnabled: true, backend: .local, localModel: "test",
            translatedBundleIDs: ["com.google.Chrome"]))
        let controller = ApplicationController(
            paths: try RuntimePaths(validatingRoot: temporaryRoot()),
            components: makeComponents(
                store: store,
                monitor: monitor,
                coordinator: TranslatingCoordinator(),
                capture: capture,
                schedulerBox: schedulerBox
            )
        )
        try await controller.start()
        await waitForStartupHealthCheck(controller)
        let session = try #require(controller.session)
        session.start()
        for revision in 1...8 {
            monitor.emit(ActiveWindowDescriptor(
                pid: 42, bundleIdentifier: "com.google.Chrome",
                windowID: 17, frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                revision: UInt64(revision), invalidatesOverlay: true
            ))
            let result = try await session.translateBridgeTexts([
                "Hello from explore \(revision) now"
            ])
            #expect(result.translations == ["你好 Hello from explore \(revision) now"])
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(await capture.count == 0)
        #expect(schedulerBox.value?.submitCount == 0)
        await controller.stop()
    }
}

struct BridgeRateLimiterTests {
    @Test
    func burstIsAllowedThenThrottled() {
        let limiter = BridgeRateLimiter(capacity: 3, refillPerSecond: 0, now: { 0 })
        #expect(limiter.allow())
        #expect(limiter.allow())
        #expect(limiter.allow())
        #expect(!limiter.allow())
    }

    @Test
    func tokensRefillOverTime() {
        var clock: TimeInterval = 0
        let limiter = BridgeRateLimiter(capacity: 2, refillPerSecond: 1, now: { clock })
        #expect(limiter.allow())
        #expect(limiter.allow())
        #expect(!limiter.allow())
        clock = 1
        #expect(limiter.allow())
        #expect(!limiter.allow())
    }

    @Test
    func refillIsCappedAtCapacity() {
        var clock: TimeInterval = 0
        let limiter = BridgeRateLimiter(capacity: 2, refillPerSecond: 10, now: { clock })
        #expect(limiter.allow())
        #expect(limiter.allow())
        #expect(!limiter.allow())
        clock = 100
        #expect(limiter.allow())
        #expect(limiter.allow())
        #expect(!limiter.allow())
    }
}
