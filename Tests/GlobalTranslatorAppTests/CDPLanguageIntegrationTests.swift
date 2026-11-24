import Foundation
import Testing
@testable import GlobalTranslatorApp
import GlobalTranslatorCapture
import GlobalTranslatorCore

@MainActor
struct CDPLanguageIntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GT_BRIDGE_BROWSER"] == "1"), arguments: [BackendKind.local, .deepSeekCloud])
    func realCDPPageThroughProductionFactoryAndFakeModel(_ kind: BackendKind) async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let ready = FileManager.default.temporaryDirectory.appendingPathComponent("gt-cdp-ready-\(UUID().uuidString).json")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", root.appendingPathComponent("scripts/test-cdp-fixture.cjs").path, ready.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            try? FileManager.default.removeItem(at: ready)
        }
        for _ in 0..<500 where !FileManager.default.fileExists(atPath: ready.path) {
            try await Task.sleep(for: .milliseconds(20))
        }
        let info = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: ready)) as? [String: Int])
        let cdpPort = try #require(info["cdpPort"])
        let fixturePort = try #require(info["fixturePort"])
        let client = URLSession(configuration: .ephemeral)
        defer { client.invalidateAndCancel() }
        func navigate(_ name: String) async throws {
            _ = try await client.data(from: URL(string: "http://127.0.0.1:\(fixturePort)/navigate?case=\(name)")!)
        }
        func state() async throws -> [String] {
            let (data, _) = try await client.data(from: URL(string: "http://127.0.0.1:\(fixturePort)/state")!)
            return try JSONDecoder().decode([String].self, from: data)
        }
        for (name, expected) in [("ja", ["邮票", "没关系"]), ("ko", ["男子汉"]), ("traditional", ["欢迎使用"]), ("zh", ["普通中文"]), ("missing", ["普通中文"]), ("invalid", ["普通中文"])] {
            try await navigate(name)
            let translator = CDPInPageTranslator(port: UInt16(cdpPort))
            let fixture = try BridgeLanguageFixture(kind: kind, inPage: translator)
            await fixture.transport.padResponses()
            defer { fixture.session.stop(); fixture.server.stop() }
            fixture.session.start()
            fixture.session.handleWindow(ActiveWindowDescriptor(pid: 0, bundleIdentifier: "com.google.Chrome", windowID: 1, frame: CGRect(x: 0, y: 0, width: 800, height: 600), revision: 1))
            var actual = try await state()
            for _ in 0..<200 where actual != expected {
                try await Task.sleep(for: .milliseconds(20))
                actual = try await state()
            }
            #expect(actual == expected, "CDP case \(name) must display the fake response")
            let calls = await fixture.transport.calls
            if ["ja", "ko", "traditional"].contains(name) {
                #expect(calls.count == 1)
                let hint = name == "traditional" ? "zh-tw" : name
                #expect(calls.allSatisfy { $0.system.contains("hint: \(hint).") })
            } else {
                #expect(calls.isEmpty)
            }
            #expect(try await translator.extract(windowRevision: 2).isEmpty, "own padded translations must not be extracted again")
            print("CDP_LANGUAGE_CASE: \(name) => \(actual), model calls=\(calls.count)")
        }
    }
}
