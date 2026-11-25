import Foundation
import Darwin
import Testing
@testable import GlobalTranslatorRuntime

struct RuntimeContractsTests {
    @Test
    func directWorkerStartRecoversAbandonedSocketAfterAcquiringPIDLock() throws {
        let paths = RuntimePaths(root: URL(fileURLWithPath: "/private/tmp/gt-direct-recovery-\(UUID().uuidString)"))
        try paths.prepareDirectories()
        let abandoned = try bindSocketLeavingPath(paths.socketURL.path)
        Darwin.close(abandoned)
        let worker = try RuntimeWorker(paths: paths)
        try worker.start()
        defer { worker.stop() }
        let response = try UnixControlClient(socketURL: paths.socketURL).request(.status)
        #expect(response.running)
        #expect(response.pid == getpid())
        worker.stop()
        #expect(!FileManager.default.fileExists(atPath: paths.socketURL.path))
        #expect(!FileManager.default.fileExists(atPath: paths.pidURL.path))
    }

    @Test
    func directWorkerStartPreservesLiveSocketEvenWithoutPIDFile() throws {
        let paths = RuntimePaths(root: URL(fileURLWithPath: "/private/tmp/gt-live-recovery-\(UUID().uuidString)"))
        let expected = ControlResponse(running: true, state: .running, pid: 42)
        let server = UnixControlServer(socketURL: paths.socketURL) { _ in expected }
        try server.start()
        defer { server.stop() }
        let worker = try RuntimeWorker(paths: paths)
        for _ in 0..<10 {
            #expect(throws: RuntimeError.socketInUse) { try worker.start() }
        }
        #expect(try UnixControlClient(socketURL: paths.socketURL).request(.status) == expected)
    }

    @Test(arguments: [false, true])
    func directWorkerRecoveryPreservesNonSocketFiles(symlink: Bool) throws {
        let paths = RuntimePaths(root: URL(fileURLWithPath: "/private/tmp/gt-file-recovery-\(UUID().uuidString)"))
        try paths.prepareDirectories()
        let marker = Data("keep this file".utf8)
        let target = paths.rootDirectory.appendingPathComponent("marker")
        try marker.write(to: target)
        if symlink {
            try FileManager.default.createSymbolicLink(at: paths.socketURL, withDestinationURL: target)
        } else {
            try marker.write(to: paths.socketURL)
        }
        let worker = try RuntimeWorker(paths: paths)
        #expect(throws: RuntimeError.socketInUse) { try worker.start() }
        #expect(try Data(contentsOf: paths.socketURL) == marker)
        #expect(try Data(contentsOf: target) == marker)
    }

    @Test
    func shutdownNotificationRunsAfterPIDAndSocketCleanup() throws {
        let paths = RuntimePaths(root: URL(fileURLWithPath: "/private/tmp/gt-clean-\(UUID().uuidString)"))
        let hook = CleanupObservationHook(paths: paths)
        let worker = try RuntimeWorker(paths: paths, hook: hook)
        try worker.start()
        worker.stop()
        #expect(hook.artifactsAbsentWhenNotified)
    }
    @Test
    func productionPathsMatchApplicationSupportAndLogsContract() {
        let home = URL(fileURLWithPath: "/Users/example")
        let paths = RuntimePaths(homeDirectory: home)
        #expect(paths.configURL.path == "/Users/example/Library/Application Support/GlobalTranslator/config.json")
        #expect(paths.pidURL.path == "/Users/example/Library/Application Support/GlobalTranslator/runtime/global-translator.pid")
        #expect(paths.socketURL.path == "/Users/example/Library/Application Support/GlobalTranslator/runtime/control.sock")
        #expect(paths.logURL.path == "/Users/example/Library/Logs/GlobalTranslator/runtime.log")
        #expect(paths.recommendedBinaryURL.path == "/Users/example/.local/bin/global-translator")
        #expect(paths.whisperDirectory.path == "/Users/example/Library/Application Support/GlobalTranslator/whisper")
    }

    @Test
    func stoppedStatusUsesNonzeroCliExitCode() {
        let stopped = ControlResponse(running: false, state: .stopped, pid: 0)
        let running = ControlResponse(running: true, state: .running, pid: 7)
        #expect(CLIExitCode.status(stopped) == 1)
        #expect(CLIExitCode.status(running) == 0)
    }

    @Test
    func childEnvironmentKeepsOnlySafeAllowlistAndValidatedOverride() {
        let environment = [
            "PATH": "/attacker/bin",
            "LANG": "zh_CN.UTF-8",
            "LC_CTYPE": "zh_CN.UTF-8",
            "SAMPLE_API_KEY": "do-not-inherit",
            "SERVICE_TOKEN": "do-not-inherit",
            "DYLD_INSERT_LIBRARIES": "/tmp/inject.dylib",
            "ARBITRARY_SETTING": "do-not-inherit"
        ]
        let root = URL(fileURLWithPath: "/tmp/gt-env-\(UUID().uuidString)")
        let child = ChildEnvironment.minimal(from: environment, validatedOverrideRoot: root)
        #expect(child["PATH"] == ChildEnvironment.fixedPath)
        #expect(child["LANG"] == "zh_CN.UTF-8")
        #expect(child["LC_CTYPE"] == "zh_CN.UTF-8")
        #expect(child["GLOBAL_TRANSLATOR_RUNTIME_ROOT"] == root.path)
        #expect(child["SAMPLE_API_KEY"] == nil)
        #expect(child["SERVICE_TOKEN"] == nil)
        #expect(child["DYLD_INSERT_LIBRARIES"] == nil)
        #expect(child["ARBITRARY_SETTING"] == nil)
    }

    @Test
    func parserAcceptsRequiredCommandsAndRejectsInvalidChineseUsage() throws {
        #expect(try CLIParser.parse(["doctor"]) == .doctor)
        #expect(try CLIParser.parse(["start"]) == .start)
        #expect(try CLIParser.parse(["settings"]) == .settings)
        #expect(throws: CLIParseError.self) { try CLIParser.parse(["settings", "extra"]) }
        #expect(try CLIParser.parse(["status"]) == .status)
        #expect(try CLIParser.parse(["logs"]) == .logs(follow: false))
        #expect(try CLIParser.parse(["logs", "--follow"]) == .logs(follow: true))
        #expect(try CLIParser.parse(["stop"]) == .stop)
        #expect(try CLIParser.parse(["run", "--foreground"]) == .run(mode: .foreground))
        #expect(try CLIParser.parse(["run", "--daemon-child"]) == .run(mode: .daemonChild))
        do {
            _ = try CLIParser.parse(["unknown"])
            Issue.record("invalid command should fail")
        } catch let error as CLIParseError {
            #expect(error.description.contains("用法"))
        }
    }

    @Test
    func injectedPathsUseContainedDirectoriesAndSecurePermissions() throws {
        let root = URL(fileURLWithPath: "/tmp/gt-\(UUID().uuidString)")
        let paths = try RuntimePaths(validatingRoot: root)
        try paths.prepareDirectories()

        let fileManager = FileManager.default
        for directory in [paths.rootDirectory, paths.runtimeDirectory, paths.logsDirectory] {
            let attributes = try fileManager.attributesOfItem(atPath: directory.path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        }
        #expect(paths.isContained(paths.configURL))
        #expect(paths.isContained(paths.socketURL))
        #expect(!paths.isContained(paths.rootDirectory.deletingLastPathComponent()))
        #expect(paths.configURL.path.hasSuffix("config.json"))
        #expect(paths.pidURL.path.hasSuffix("runtime/global-translator.pid"))
    }

    @Test
    func pidLockIsExclusiveAndRemovesOnlyOwnedPid() throws {
        let root = URL(fileURLWithPath: "/tmp/gt-\(UUID().uuidString)")
        let paths = try RuntimePaths(validatingRoot: root)
        try paths.prepareDirectories()
        let first = PIDFileLock(url: paths.pidURL)
        let second = PIDFileLock(url: paths.pidURL)
        #expect(try first.acquire())
        #expect(!(try second.acquire()))
        #expect(first.pid == Int32(getpid()))
        second.release()
        #expect(FileManager.default.fileExists(atPath: paths.pidURL.path))
        first.release()
        #expect(!FileManager.default.fileExists(atPath: paths.pidURL.path))
    }

    @Test
    func controlSocketRoundTripsBoundedStatusAndStop() throws {
        let root = URL(fileURLWithPath: "/tmp/gt-\(UUID().uuidString)")
        let paths = try RuntimePaths(validatingRoot: root)
        try paths.prepareDirectories()
        let stopped = ControlResponse(running: true, state: .running, pid: 42)
        let server = UnixControlServer(socketURL: paths.socketURL) { request in
            request.action == .stop
                ? ControlResponse(running: true, state: .stopping, pid: 42)
                : stopped
        }
        try server.start()
        defer { server.stop() }

        let client = UnixControlClient(socketURL: paths.socketURL)
        #expect(try client.request(.status) == stopped)
        #expect(try client.request(.stop).state == .stopping)
        let payload = try JSONEncoder().encode(stopped)
        #expect(payload.count < 4_096)
        let attributes = try FileManager.default.attributesOfItem(atPath: paths.socketURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test
    func oversizedControlRequestIsRejectedWithoutUnboundedRead() throws {
        let root = URL(fileURLWithPath: "/tmp/gt-\(UUID().uuidString)")
        let paths = try RuntimePaths(validatingRoot: root)
        try paths.prepareDirectories()
        let server = UnixControlServer(socketURL: paths.socketURL) { _ in
            ControlResponse(running: true, state: .running, pid: 42)
        }
        try server.start()
        defer { server.stop() }

        let client = UnixControlClient(socketURL: paths.socketURL)
        let oversized = String(repeating: "x", count: 4_097)
        do {
            _ = try client.sendRaw(Data(oversized.utf8))
            Issue.record("oversized request should fail")
        } catch let error as RuntimeError {
            #expect(error == .requestTooLarge)
        }
    }

    @Test
    func responseContainsOnlyRunningStateAndPid() throws {
        let response = ControlResponse(running: true, state: .running, pid: 123)
        let object = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(response)) as? [String: Any]
        )
        #expect(Set(object.keys) == Set(["running", "state", "pid"]))
        #expect(object["pid"] as? Int == 123)
    }

    @Test
    func settingsCommandReachesExistingWorkerWithoutRestartingIt() throws {
        let paths = RuntimePaths(root: URL(fileURLWithPath: "/private/tmp/gt-settings-\(UUID().uuidString)"))
        let hook = SettingsRequestHook()
        let worker = try RuntimeWorker(paths: paths, hook: hook)
        try worker.start()
        defer { worker.stop() }
        let manager = RuntimeManager(paths: paths)
        let first = try manager.showSettings()
        let second = try manager.showSettings()
        #expect(first.pid == getpid())
        #expect(second == first)
        #expect(hook.settingsCount == 2)
        #expect(worker.isRunning)
    }

    @Test
    func settingsRequestFailsWhenWorkerIsAbsent() throws {
        let paths = RuntimePaths(root: URL(fileURLWithPath: "/private/tmp/gt-no-settings-\(UUID().uuidString)"))
        #expect(throws: RuntimeError.notReady) {
            try RuntimeManager(paths: paths, readinessTimeout: 0.1).showSettings()
        }
    }

    @Test
    func settingsRequestWaitsForConcurrentStartup() throws {
        let paths = RuntimePaths(root: URL(fileURLWithPath: "/private/tmp/gt-start-settings-\(UUID().uuidString)"))
        let ready = ControlResponse(running: true, state: .running, pid: 123)
        let client = SequencedControlClient(results: [
            .failure(TransientControlFailure()),
            .success(ControlResponse(running: true, state: .starting, pid: 123)),
            .success(ready)
        ])
        let manager = RuntimeManager(paths: paths, controlClientFactory: { _ in client })
        #expect(try manager.showSettings() == ready)
    }

    @Test
    func loggerRedactsBearerAndKeyLikeValuesAndRotatesBackups() throws {
        let root = URL(fileURLWithPath: "/tmp/gt-\(UUID().uuidString)")
        let logURL = root.appendingPathComponent("runtime.log")
        let logger = try RuntimeLogger(url: logURL, maximumBytes: 256, backupCount: 3)
        for index in 0..<20 {
            try logger.write(level: "info", event: "test", fields: [
                "message": "Bearer super-secret-\(index) api_key=very-secret-value"
            ])
        }
        let content = try String(contentsOf: logURL, encoding: .utf8)
        #expect(!content.contains("super-secret"))
        #expect(!content.contains("very-secret-value"))
        #expect(content.contains("[REDACTED]"))
        #expect(FileManager.default.fileExists(atPath: logURL.appendingPathExtension("1").path))
        let attributes = try FileManager.default.attributesOfItem(atPath: logURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test
    func doctorClassifiesInjectedReadinessWithoutSecrets() {
        let inputs = DoctorInputs(
            operatingSystemMajor: 26,
            architecture: "x86_64",
            physicalMemoryGiB: 8,
            accessibilityTrusted: false,
            screenCapturePreflight: false,
            binaryAtRecommendedPath: false,
            keychainReadable: false,
            configurationDecodable: false
        )
        let report = Doctor(inputs: inputs).run()
        #expect(report.checks.contains { $0.level == .fail })
        #expect(report.renderChinese().contains("FAIL"))
        #expect(!report.renderChinese().contains("api_key"))
        let whisperMissing = DoctorInputs(
            operatingSystemMajor: 27,
            architecture: "arm64",
            physicalMemoryGiB: 16,
            accessibilityTrusted: true,
            screenCapturePreflight: true,
            binaryAtRecommendedPath: true,
            keychainReadable: true,
            configurationDecodable: true,
            whisperAvailable: false
        )
        let whisperReport = Doctor(inputs: whisperMissing).run()
        #expect(!whisperReport.hasFailure)
        #expect(whisperReport.renderChinese().contains("本地 Whisper.cpp"))
        #expect(whisperReport.renderChinese().contains("WARN"))
    }

    @Test
    func doctorResolvesRecommendedBinaryAcrossPathAndSymlinks() throws {
        let root = URL(fileURLWithPath: "/tmp/gt-doctor-bin-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binDir = root.appendingPathComponent("bin", isDirectory: true)
        let appDir = root.appendingPathComponent("App", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)

        let targetBinary = appDir.appendingPathComponent("global-translator")
        try Data("#!/bin/sh\n".utf8).write(to: targetBinary)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: targetBinary.path)

        let recommendedSymlink = binDir.appendingPathComponent("global-translator")
        try FileManager.default.createSymbolicLink(at: recommendedSymlink, withDestinationURL: targetBinary)

        #expect(DoctorInputs.isBinaryAtRecommendedPath(
            argv0: "global-translator",
            pathEnvironment: "/usr/bin:\(binDir.path)",
            recommendedBinaryURL: recommendedSymlink
        ))
        #expect(DoctorInputs.isBinaryAtRecommendedPath(
            argv0: targetBinary.path,
            pathEnvironment: nil,
            recommendedBinaryURL: recommendedSymlink
        ))
        #expect(!DoctorInputs.isBinaryAtRecommendedPath(
            argv0: "global-translator",
            pathEnvironment: "/usr/bin:\(binDir.path)",
            recommendedBinaryURL: root.appendingPathComponent("missing/global-translator")
        ))
    }

    @Test
    func managerStopThrowsWhenDaemonDoesNotStopByDeadline() throws {
        let root = URL(fileURLWithPath: "/tmp/gt-stop-timeout-\(UUID().uuidString)")
        let paths = try RuntimePaths(validatingRoot: root)
        try paths.prepareDirectories()
        let server = UnixControlServer(socketURL: paths.socketURL) { request in
            request.action == .stop
                ? ControlResponse(running: true, state: .stopping, pid: 17)
                : ControlResponse(running: true, state: .running, pid: 17)
        }
        try server.start()
        defer { server.stop() }
        let manager = RuntimeManager(paths: paths, readinessTimeout: 0.1)
        do {
            _ = try manager.stop()
            Issue.record("stop should fail when daemon remains running")
        } catch let error as RuntimeError {
            #expect(error == .notReady)
        }
    }

    @Test
    func managerStopDoesNotTreatTransientStatusFailureAsStoppedWhileSocketRemains() throws {
        let root = URL(fileURLWithPath: "/tmp/gt-stop-transient-\(UUID().uuidString)")
        let paths = try RuntimePaths(validatingRoot: root)
        try paths.prepareDirectories()
        let staleDescriptor = try bindSocketLeavingPath(paths.socketURL.path)
        Darwin.close(staleDescriptor)
        let fake = SequencedControlClient(results: [
            .success(ControlResponse(running: true, state: .running, pid: 31)),
            .success(ControlResponse(running: true, state: .stopping, pid: 31)),
            .failure(TransientControlFailure()),
            .success(ControlResponse(running: true, state: .running, pid: 31))
        ])
        let manager = RuntimeManager(
            paths: paths,
            stopTimeout: 0.1,
            controlClientFactory: { _ in fake }
        )
        do {
            _ = try manager.stop()
            Issue.record("transient failure must not imply stopped while socket exists")
        } catch let error as RuntimeError {
            #expect(error == .notReady)
        }
        _ = unlink(paths.socketURL.path)
    }

    @Test
    func managerStopIsIdempotentWhenServerAlreadyReportsStopped() throws {
        let root = URL(fileURLWithPath: "/tmp/gt-stop-idempotent-\(UUID().uuidString)")
        let paths = try RuntimePaths(validatingRoot: root)
        try paths.prepareDirectories()
        let counter = LockedCounter()
        let server = UnixControlServer(socketURL: paths.socketURL) { request in
            if request.action == .stop {
                counter.increment()
            }
            return ControlResponse(running: false, state: .stopped, pid: 0)
        }
        try server.start()
        defer { server.stop() }
        let manager = RuntimeManager(paths: paths)
        #expect(try manager.stop() == ControlResponse(running: false, state: .stopped, pid: 0))
        #expect(counter.value == 0)
        #expect(FileManager.default.fileExists(atPath: paths.runtimeDirectory.path))
    }

    @Test
    func controlServerWaitsForARequestAfterAcceptingConnection() throws {
        let paths = RuntimePaths(root: URL(fileURLWithPath: "/private/tmp/gtd-\(UUID().uuidString)"))
        try paths.prepareDirectories()
        let server = UnixControlServer(socketURL: paths.socketURL) { _ in
            ControlResponse(running: false, state: .stopped, pid: 0)
        }
        try server.start()
        defer { server.stop() }
        let client = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(client >= 0)
        defer { Darwin.close(client) }
        var noSignal: Int32 = 1
        _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(paths.socketURL.path.utf8) + [0]
        try #require(bytes.count <= MemoryLayout.size(ofValue: address.sun_path))
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(client, $0, socklen_t(MemoryLayout<sa_family_t>.size + bytes.count))
            }
        }
        try #require(connected == 0)
        usleep(50_000)
        let payload = try JSONEncoder().encode(ControlRequest(action: .status))
        let sent = payload.withUnsafeBytes { Darwin.send(client, $0.baseAddress, $0.count, 0) }
        #expect(sent == payload.count)
        _ = Darwin.shutdown(client, SHUT_WR)
        var response = [UInt8](repeating: 0, count: 4096)
        let received = Darwin.recv(client, &response, response.count, 0)
        #expect(received > 0)
    }

    @Test
    func managerStopReturnsConfirmedStoppedState() throws {
        let root = URL(fileURLWithPath: "/tmp/gt-stop-final-\(UUID().uuidString)")
        let paths = try RuntimePaths(validatingRoot: root)
        try paths.prepareDirectories()
        let fake = SequencedControlClient(results: [
            .success(ControlResponse(running: true, state: .running, pid: 41)),
            .success(ControlResponse(running: true, state: .stopping, pid: 41)),
            .success(ControlResponse(running: false, state: .stopped, pid: 0))
        ])
        let manager = RuntimeManager(paths: paths, controlClientFactory: { _ in fake })

        let response = try manager.stop()

        #expect(response.running == false)
        #expect(response.state == .stopped)
    }

    @Test
    func staleContainedSocketWithoutPidIsRemovedOnlyAfterUnresponsiveCheck() throws {
        let root = URL(fileURLWithPath: "/tmp/gt-stale-no-pid-\(UUID().uuidString)")
        let paths = try RuntimePaths(validatingRoot: root)
        try paths.prepareDirectories()
        let staleDescriptor = try bindSocketLeavingPath(paths.socketURL.path)
        Darwin.close(staleDescriptor)
        #expect(PIDFileLock.readPID(from: paths.pidURL) == nil)

        let manager = RuntimeManager(
            paths: paths,
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            readinessTimeout: 0.1
        )
        do {
            _ = try manager.start()
            Issue.record("the test executable cannot become a runtime worker")
        } catch let error as RuntimeError {
            #expect(error == .notReady)
        }
        #expect(!FileManager.default.fileExists(atPath: paths.socketURL.path))
    }

    @Test
    func workerStopRunsHookExactlyOnceWhenCalledConcurrently() throws {
        let root = URL(fileURLWithPath: "/tmp/gt-worker-stop-\(UUID().uuidString)")
        let paths = try RuntimePaths(validatingRoot: root)
        let hook = CountingHook()
        let worker = try RuntimeWorker(paths: paths, hook: hook)
        try worker.start()
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            worker.stop()
        }
        #expect(worker.currentState == .stopped)
        #expect(hook.stopCount == 1)
    }

    @Test
    func cliErrorFormattingNeverIncludesArbitraryErrorText() {
        let runtime = CLIErrorFormatter.message(for: RuntimeError.ioFailure)
        let unknown = CLIErrorFormatter.message(for: NSError(
            domain: "SensitiveDomain",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Bearer secret-token"]
        ))
        #expect(runtime == "错误：文件操作失败")
        #expect(unknown == "错误：运行失败")
        #expect(!unknown.contains("secret-token"))
    }

    @Test
    func loggerRotationAndBackwardLogReaderHandleLargeFiles() throws {
        let root = URL(fileURLWithPath: "/private/tmp/gt-log-\(UUID().uuidString)")
        let paths = try RuntimePaths(validatingRoot: root)
        try paths.prepareDirectories()
        defer { try? FileManager.default.removeItem(at: root) }

        let logger = try RuntimeLogger(url: paths.logURL, maximumBytes: 65_536, backupCount: 1)
        for index in 0..<250 {
            try logger.write(
                level: "info",
                event: "perf_event",
                fields: ["idx": String(index), "payload": String(repeating: "a", count: 220)]
            )
        }
        let lines = try RuntimeLogReader(url: paths.logURL).lastLines(limit: 5)
        #expect(lines.count == 5)
        #expect(lines.last?.contains("\"idx\":\"249\"") == true)
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

private final class CleanupObservationHook: RuntimeWorkerHook, @unchecked Sendable {
    let paths: RuntimePaths
    private(set) var artifactsAbsentWhenNotified = false
    init(paths: RuntimePaths) { self.paths = paths }
    func workerDidStart() {}
    func workerWillStop() {
        artifactsAbsentWhenNotified = !FileManager.default.fileExists(atPath: paths.pidURL.path)
            && !FileManager.default.fileExists(atPath: paths.socketURL.path)
    }
}

private final class CountingHook: RuntimeWorkerHook, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var stopCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func workerDidStart() {}

    func workerWillStop() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

private struct TransientControlFailure: Error, Sendable {}

private final class SettingsRequestHook: RuntimeWorkerHook, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var settingsCount: Int { lock.withLock { count } }
    func workerDidStart() {}
    func workerWillStop() {}
    func workerDidRequestSettings() { lock.withLock { count += 1 } }
}

private final class SequencedControlClient: RuntimeControlClient, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<ControlResponse, Error>]

    init(results: [Result<ControlResponse, Error>]) {
        self.results = results
    }

    func request(_ action: ControlAction) throws -> ControlResponse {
        lock.lock()
        defer { lock.unlock() }
        guard !results.isEmpty else {
            throw TransientControlFailure()
        }
        let result = results.removeFirst()
        return try result.get()
    }
}

private func bindSocketLeavingPath(_ path: String) throws -> Int32 {
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
        throw RuntimeError.ioFailure
    }
    var address = sockaddr_un()
    let bytes = Array(path.utf8) + [0]
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
        Darwin.close(descriptor)
        throw RuntimeError.invalidPath
    }
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { storage in
        storage.copyBytes(from: bytes)
    }
    let length = socklen_t(MemoryLayout<sa_family_t>.size + bytes.count)
    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
            Darwin.bind(descriptor, sockaddrPointer, length)
        }
    }
    guard result == 0 else {
        Darwin.close(descriptor)
        throw RuntimeError.ioFailure
    }
    return descriptor
}
