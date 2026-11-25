import Darwin
import Foundation

public enum RunMode: String, Equatable, Sendable {
    case foreground
    case daemonChild
}

public enum StartOutcome: Equatable, Sendable {
    case started(pid: Int32)
    case alreadyRunning(pid: Int32)
}

public final class RuntimeManager: @unchecked Sendable {
    public let paths: RuntimePaths
    public let executableURL: URL

    private let readinessTimeout: TimeInterval
    private let stopTimeout: TimeInterval
    private let controlClientFactory: @Sendable (TimeInterval) -> any RuntimeControlClient

    public init(
        paths: RuntimePaths,
        executableURL: URL? = nil,
        readinessTimeout: TimeInterval = 1.0,
        stopTimeout: TimeInterval = 1.0,
        controlClientFactory: (@Sendable (TimeInterval) -> any RuntimeControlClient)? = nil
    ) {
        self.paths = paths
        self.executableURL = executableURL ?? Self.resolveExecutable()
        self.readinessTimeout = min(max(readinessTimeout, 0.1), 1.0)
        self.stopTimeout = min(max(stopTimeout, 0.1), 1.0)
        self.controlClientFactory = controlClientFactory ?? { timeout in
            UnixControlClient(socketURL: paths.socketURL, timeout: timeout)
        }
    }

    public func showSettings() throws -> ControlResponse {
        let client = controlClientFactory(0.2)
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(readinessTimeout * 1_000_000_000)
        var attempt = 0
        repeat {
            if let response = try? client.request(.showSettings), response.running, response.state == .running {
                return response
            }
            sleepBackoff(attempt: attempt)
            attempt += 1
        } while DispatchTime.now().uptimeNanoseconds < deadline
        throw RuntimeError.notReady
    }

    public func start() throws -> StartOutcome {
        try paths.prepareDirectories()
        let client = controlClientFactory(0.2)
        if let response = try? client.request(.status), response.running || response.state != .stopped {
            return .alreadyRunning(pid: response.pid)
        }
        if let existingPID = PIDFileLock.readPID(from: paths.pidURL), PIDFileLock.isProcessAlive(existingPID) {
            return .alreadyRunning(pid: existingPID)
        }
        try removeValidatedStaleSocket()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
        process.arguments = [executableURL.path, "run", "--daemon-child"]
        process.standardInput = FileHandle(forReadingAtPath: "/dev/null")
        let logHandle = try FileHandle(forWritingTo: paths.logURL)
        try logHandle.seekToEnd()
        process.standardOutput = logHandle
        process.standardError = logHandle
        process.environment = ChildEnvironment.minimal(
            from: ProcessInfo.processInfo.environment,
            validatedOverrideRoot: paths.usesOverrideRoot ? paths.rootDirectory : nil
        )
        do {
            try process.run()
            try logHandle.close()
        } catch {
            try? logHandle.close()
            throw RuntimeError.processLaunchFailure
        }

        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(readinessTimeout * 1_000_000_000)
        var attempt = 0
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if let response = try? client.request(.status), response.running {
                return .started(pid: response.pid > 0 ? response.pid : process.processIdentifier)
            }
            sleepBackoff(attempt: attempt)
            attempt += 1
        }
        if process.isRunning {
            process.terminate()
        }
        throw RuntimeError.notReady
    }

    public func status() -> ControlResponse {
        let client = controlClientFactory(0.2)
        if let response = try? client.request(.status) {
            return response
        }
        if let pid = PIDFileLock.readPID(from: paths.pidURL), PIDFileLock.isProcessAlive(pid) {
            return ControlResponse(running: true, state: .starting, pid: pid)
        }
        return ControlResponse(running: false, state: .stopped, pid: 0)
    }

    @discardableResult
    public func stop() throws -> ControlResponse {
        let client = controlClientFactory(0.5)
        let before: ControlResponse
        do {
            before = try client.request(.status)
        } catch {
            if !hasLiveArtifacts() {
                return ControlResponse(running: false, state: .stopped, pid: 0)
            }
            throw RuntimeError.notReady
        }
        guard before.running else {
            return before
        }
        do {
            let response = try client.request(.stop)
            if !response.running {
                return response
            }
            let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(stopTimeout * 1_000_000_000)
            var absentObservations = 0
            var attempt = 0
            while DispatchTime.now().uptimeNanoseconds < deadline {
                do {
                    let current = try client.request(.status)
                    if !current.running {
                        return current
                    }
                    absentObservations = 0
                } catch {
                    if hasLiveArtifacts() {
                        absentObservations = 0
                    } else {
                        absentObservations += 1
                        if absentObservations >= 2 {
                            return ControlResponse(running: false, state: .stopped, pid: 0)
                        }
                    }
                }
                sleepBackoff(attempt: attempt)
                attempt += 1
            }
            do {
                let final = try client.request(.status)
                if !final.running {
                    return final
                }
            } catch {
                if !hasLiveArtifacts() {
                    return ControlResponse(running: false, state: .stopped, pid: 0)
                }
            }
            throw RuntimeError.notReady
        } catch let error as RuntimeError where error == .connectionFailure || error == .socketUnavailable {
            if !hasLiveArtifacts() {
                return ControlResponse(running: false, state: .stopped, pid: 0)
            }
            throw RuntimeError.notReady
        } catch {
            throw error
        }
    }

    private func sleepBackoff(attempt: Int) {
        let microseconds: useconds_t
        switch attempt {
        case 0: microseconds = 2_000
        case 1: microseconds = 5_000
        case 2: microseconds = 10_000
        default: microseconds = 25_000
        }
        usleep(microseconds)
    }

    public func logs(limit: Int = 200) throws -> [String] {
        try RuntimeLogReader(url: paths.logURL).lastLines(limit: limit)
    }

    public func run(mode: RunMode, hook: any RuntimeWorkerHook = NoopRuntimeWorkerHook()) throws {
        let worker = try RuntimeWorker(paths: paths, hook: hook)
        try worker.run()
    }

    private func removeValidatedStaleSocket() throws {
        guard FileManager.default.fileExists(atPath: paths.socketURL.path) else {
            return
        }
        if let existingPID = PIDFileLock.readPID(from: paths.pidURL),
           PIDFileLock.isProcessAlive(existingPID) {
            throw RuntimeError.socketInUse
        }
        guard paths.isContained(paths.socketURL) else {
            throw RuntimeError.socketInUse
        }
        try recoverAbandonedControlSocket(at: paths.socketURL)
    }

    private func hasLiveArtifacts() -> Bool {
        let socketExists = FileManager.default.fileExists(atPath: paths.socketURL.path)
        let pidAlive = PIDFileLock.readPID(from: paths.pidURL).map(PIDFileLock.isProcessAlive) ?? false
        return socketExists || pidAlive
    }

    /// Whether this process was started by launchd as a job.
    ///
    /// Job processes carry `XPC_SERVICE_NAME`. A GUI app launched by
    /// LaunchServices also carries one, but its value is namespaced as
    /// `application.<bundle-id>.<...>`; those are not job-managed and must keep
    /// the normal detach path, so they are excluded explicitly.
    public static func isManagedByLaunchd(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard let name = environment["XPC_SERVICE_NAME"], !name.isEmpty, name != "0" else {
            return false
        }
        return !name.hasPrefix("application.")
    }

    private static func resolveExecutable() -> URL {
        let argument = CommandLine.arguments.first ?? "global-translator"
        if argument.hasPrefix("/") {
            return URL(fileURLWithPath: argument).standardizedFileURL.resolvingSymlinksInPath()
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(argument)
            .standardizedFileURL
            .resolvingSymlinksInPath()
    }
}
