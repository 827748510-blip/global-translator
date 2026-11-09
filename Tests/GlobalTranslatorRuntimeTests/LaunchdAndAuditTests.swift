import Foundation
import Testing
@testable import GlobalTranslatorRuntime

struct LaunchdDetectionTests {
    @Test
    func launchdJobsAreDetectedButLaunchServicesAppsAreNot() {
        // An ordinary shell invocation carries no job label.
        #expect(!RuntimeManager.isManagedByLaunchd(environment: [:]))
        // launchd uses "0" as a placeholder in some contexts.
        #expect(!RuntimeManager.isManagedByLaunchd(environment: ["XPC_SERVICE_NAME": "0"]))
        // A real LaunchAgent / LaunchDaemon job.
        #expect(RuntimeManager.isManagedByLaunchd(
            environment: ["XPC_SERVICE_NAME": "com.maodashu.global-translator.daemon"]
        ))
        // LaunchServices namespaces GUI launches. Those must keep the detach
        // path, otherwise opening the app would block in the foreground.
        #expect(!RuntimeManager.isManagedByLaunchd(
            environment: ["XPC_SERVICE_NAME": "application.com.maodashu.global-translator.293704032.293704037"]
        ))
        #expect(!RuntimeManager.isManagedByLaunchd(
            environment: ["XPC_SERVICE_NAME": "application.com.maodashu.global-translator"]
        ))
    }
}

struct CLIExitAuditTests {
    private func makeHome() throws -> URL {
        let home = URL(fileURLWithPath: "/private/tmp/gt-audit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private func readLines(home: URL) throws -> [String] {
        let text = try String(contentsOf: CLIExitAudit.auditURL(homeDirectory: home), encoding: .utf8)
        return text.split(separator: "\n").map(String.init)
    }

    @Test
    func auditLineRecordsCodeCommandAndLaunchdContext() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = RuntimePaths(root: home.appendingPathComponent("runtime-root", isDirectory: true))

        CLIExitAudit.recordExit(
            71,
            arguments: ["--runtime-root", "/tmp/x", "status"],
            paths: paths,
            environment: ["XPC_SERVICE_NAME": "com.maodashu.global-translator.daemon"],
            homeDirectory: home
        )

        let line = try #require(try readLines(home: home).first)
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        )
        #expect(object["event"] as? String == "cli_exit")
        #expect(object["code"] as? Int == 71)
        #expect(object["command"] as? String == "--runtime-root /tmp/x status")
        #expect(object["managedByLaunchd"] as? Bool == true)
        #expect(object["xpcServiceName"] as? String == "com.maodashu.global-translator.daemon")
        #expect(object["runtimeRoot"] as? String == paths.rootDirectory.path)
        #expect(object["pid"] as? Int == Int(ProcessInfo.processInfo.processIdentifier))
        #expect(object["timestamp"] as? String != nil)
    }

    @Test
    func auditAppendsSoEarlierExitsSurvive() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        for code in [1, 2, 71] as [Int32] {
            CLIExitAudit.recordExit(code, arguments: ["status"], homeDirectory: home)
        }

        let codes = try readLines(home: home).compactMap { line -> Int? in
            let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            return object?["code"] as? Int
        }
        #expect(codes == [1, 2, 71])
    }

    @Test
    func auditTruncatesLongCommandsAndOmitsMissingRoot() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        CLIExitAudit.recordExit(
            2,
            arguments: [String(repeating: "a", count: 400)],
            environment: [:],
            homeDirectory: home
        )

        let line = try #require(try readLines(home: home).first)
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        )
        #expect((object["command"] as? String)?.count == 200)
        #expect(object["runtimeRoot"] == nil)
        #expect(object["managedByLaunchd"] as? Bool == false)
        #expect(object["xpcServiceName"] == nil)
    }
}
