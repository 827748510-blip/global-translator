import Foundation
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
    func allowedOriginStaysPinnedToTheShippedExtensionId() {
        #expect(ExtensionBridgeServer.allowedOrigin == "chrome-extension://fjggaipmhcfmgikhkjppkdliaoopaefc")
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
            texts.map { $0 == "skip" ? nil : "译:" + $0 }
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
        #expect((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Access-Control-Allow-Origin") == ExtensionBridgeServer.allowedOrigin)
    }

    @Test
    func missingOrForeignOriginIsRejected() async throws {
        let server = ExtensionBridgeServer(port: 0) { texts in texts.map { $0 } }
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
    func healthEndpointAnswersForExtensionOnly() async throws {
        let server = ExtensionBridgeServer(port: 0) { texts in texts.map { $0 } }
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
        #expect(((try await session.data(for: post)).1 as? HTTPURLResponse)?.statusCode == 200)

        let postDenied = request(port, method: "POST", path: "/health", origin: "https://evil.example")
        #expect(((try await session.data(for: postDenied)).1 as? HTTPURLResponse)?.statusCode == 403)
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
        let server = ExtensionBridgeServer(port: 0) { texts in texts.map { $0 } }
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
        #expect(result == ["你好 Hello there", nil, "你好 General Kenobi"])
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
        #expect(try await session.translateBridgeTexts(["Hello there"]) == ["你好 Hello there"])
        session.stop()
        #expect(!session.isRunning)
        #expect(session.isBridgeActive)
        #expect(try await session.translateBridgeTexts(["Hello there"]) == ["你好 Hello there"])
        session.start()
        #expect(try await session.translateBridgeTexts(["Hello there"]) == ["你好 Hello there"])
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
        #expect(try await session.translateBridgeTexts(["Hello there"]) == ["你好 Hello there"])

        permission.update(PermissionSnapshot(
            accessibilityTrusted: true,
            screenCaptureAuthorized: false,
            secureInputEnabled: false,
            sessionLocked: false
        ))
        controller.refreshPermissions()
        #expect(session.isRunning)
        #expect(try await session.translateBridgeTexts(["Hello there"]) == ["你好 Hello there"])
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
        #expect(try await session.translateBridgeTexts(["Hello there"]) == ["你好 Hello there"])
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
        #expect(try await session.translateBridgeTexts(["Hello there"]) == ["你好 Hello there"])
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
        #expect(try await session.translateBridgeTexts(["Hello there"]) == ["你好 Hello there"])

        session.start()
        monitor.emit(ActiveWindowDescriptor(
            pid: 42, bundleIdentifier: "qa.editor",
            frame: CGRect(x: 0, y: 0, width: 800, height: 600), revision: 1
        ))
        try await waitForCapture { controller.viewModel.status == .missingPermission }
        #expect(overlay.lastTranslations.isEmpty)
        #expect(try await session.translateBridgeTexts(["Hello there"]) == ["你好 Hello there"])
        await controller.stop()
    }
}
