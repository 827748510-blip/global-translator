import Darwin
import Foundation
import os

/// Result of a backend-switch lifecycle action. Reasons are fixed tokens, not
/// command output: brew may print local paths, and logs must stay metadata-only.
public enum OllamaLifecycleOutcome: Equatable, Sendable {
    case started
    case stopped
    case alreadyRunning
    case alreadyStopped
    case unsupported(String)
    case failed(String)

    public var logValue: String {
        switch self {
        case .started: return "started"
        case .stopped: return "stopped"
        case .alreadyRunning: return "already_running"
        case .alreadyStopped: return "already_stopped"
        case .unsupported(let reason): return "unsupported:\(reason)"
        case .failed(let reason): return "failed:\(reason)"
        }
    }
}

/// Controls only the Homebrew-managed Ollama service. The app never kills an
/// arbitrary `ollama serve` process it does not own, and never unloads models
/// through undocumented endpoints.
public protocol OllamaLifecycleControlling: Sendable {
    func suspend() async -> OllamaLifecycleOutcome
    func resume(baseURL: URL) async -> OllamaLifecycleOutcome
}

public struct NoopOllamaLifecycle: OllamaLifecycleControlling {
    public init() {}
    public func suspend() async -> OllamaLifecycleOutcome {
        .unsupported("lifecycle_not_configured")
    }
    public func resume(baseURL: URL) async -> OllamaLifecycleOutcome {
        .unsupported("lifecycle_not_configured")
    }
}

public struct OllamaCommandResult: Equatable, Sendable {
    public let exitCode: Int32
    public let output: String

    public init(exitCode: Int32, output: String) {
        self.exitCode = exitCode
        self.output = output
    }
}

public enum OllamaCommandError: Error, Equatable, Sendable {
    case launchFailed
    case timedOut
}

public protocol OllamaCommandRunning: Sendable {
    func run(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> OllamaCommandResult
}

/// Executes an absolute executable directly, never through a shell. Runs on a
/// detached thread because `Process.waitUntilExit()` must not block the main
/// actor that owns the settings UI.
public struct SystemOllamaCommandRunner: OllamaCommandRunning {
    public init() {}

    public func run(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> OllamaCommandResult {
        try await Task.detached(priority: .utility) {
            try Self.runBlocking(
                executable: executable,
                arguments: arguments,
                timeout: timeout
            )
        }.value
    }

    /// Synchronous on purpose: it is invoked from a detached thread, where a
    /// blocking wait is appropriate. `Thread.sleep` is rejected in async code.
    private nonisolated static func runBlocking(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval
    ) throws -> OllamaCommandResult {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        environment["HOMEBREW_NO_ANALYTICS"] = "1"
        environment["HOMEBREW_NO_INSTALL_CLEANUP"] = "1"
        process.environment = environment
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            throw OllamaCommandError.launchFailed
        }

        let buffer = OSAllocatedUnfairLock(initialState: Data())
        let readHandle = pipe.fileHandleForReading
        readHandle.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            buffer.withLock { $0.append(chunk) }
        }

        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            semaphore.signal()
        }
        let timeoutInterval = max(timeout, 1)
        let timedOut = semaphore.wait(timeout: .now() + timeoutInterval) == .timedOut
        if timedOut {
            process.terminate()
            if semaphore.wait(timeout: .now() + 1.0) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = semaphore.wait(timeout: .now() + 0.5)
            }
        }
        readHandle.readabilityHandler = nil
        let remaining = (try? readHandle.readToEnd()) ?? Data()
        if !remaining.isEmpty {
            buffer.withLock { $0.append(remaining) }
        }
        let data = buffer.withLock { $0 }
        if timedOut { throw OllamaCommandError.timedOut }
        return OllamaCommandResult(
            exitCode: process.terminationStatus,
            output: String(decoding: data, as: UTF8.self)
        )
    }
}

public typealias OllamaReadinessProbe = @Sendable (URL) async -> Bool

/// Serializes `brew services` mutations so a fast cloud↔local toggle cannot
/// interleave stop/start commands. Only a Homebrew service is managed.
public actor HomebrewOllamaLifecycle: OllamaLifecycleControlling {
    private let brewURL: URL?
    private let runner: any OllamaCommandRunning
    private let commandTimeout: TimeInterval
    private let waitTimeout: TimeInterval
    private let statusPollInterval: Duration
    private let readinessProbe: OllamaReadinessProbe
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(
        brewURL: URL? = HomebrewOllamaLifecycle.discoverBrew(),
        runner: any OllamaCommandRunning = SystemOllamaCommandRunner(),
        commandTimeout: TimeInterval = 75,
        waitTimeout: TimeInterval = 15,
        statusPollInterval: Duration = .seconds(1),
        readinessProbe: @escaping OllamaReadinessProbe = { url in
            var request = URLRequest(url: url)
            request.timeoutInterval = 1
            guard let (_, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse else {
                return false
            }
            return (200..<300).contains(http.statusCode)
        }
    ) {
        self.brewURL = brewURL
        self.runner = runner
        self.commandTimeout = commandTimeout
        self.waitTimeout = waitTimeout
        self.statusPollInterval = statusPollInterval
        self.readinessProbe = readinessProbe
    }

    /// Homebrew may live under either Apple Silicon or Intel prefixes.
    public static func discoverBrew() -> URL? {
        let candidates = [
            "/opt/homebrew/bin/brew",
            "/usr/local/bin/brew"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    public func suspend() async -> OllamaLifecycleOutcome {
        await acquire()
        defer { release() }
        switch await serviceStatus() {
        case .running:
            guard let brewURL else { return .unsupported("brew_not_found") }
            let result: OllamaCommandResult
            do {
                result = try await runner.run(
                    executable: brewURL,
                    // --keep preserves the LaunchAgent, so a registered login
                    // item survives an app quit/restart while Ollama is paused.
                    arguments: ["services", "stop", "--keep", "ollama"],
                    timeout: commandTimeout
                )
            } catch let error as OllamaCommandError {
                return .failed(error == .timedOut ? "stop_timeout" : "stop_launch_failed")
            } catch {
                return .failed("stop_launch_failed")
            }
            guard result.exitCode == 0 else {
                return .failed("stop_exit_\(result.exitCode)")
            }
            return await waitForRunning(false) ? .stopped : .failed("stop_not_observed")
        case .stopped:
            return .alreadyStopped
        case .unavailable:
            return .unsupported("brew_service_unavailable")
        case .failed(let reason):
            return .failed(reason)
        }
    }

    public func resume(baseURL: URL) async -> OllamaLifecycleOutcome {
        await acquire()
        defer { release() }
        switch await serviceStatus() {
        case .running:
            return .alreadyRunning
        case .stopped(let registered):
            guard let brewURL else { return .unsupported("brew_not_found") }
            // `--keep` leaves a registered service registered across process
            // and app restarts. A service that was never registered starts via
            // `run`, which deliberately does not add a login item.
            let command = registered ? "start" : "run"
            let result: OllamaCommandResult
            do {
                result = try await runner.run(
                    executable: brewURL,
                    arguments: ["services", command, "ollama"],
                    timeout: commandTimeout
                )
            } catch let error as OllamaCommandError {
                return .failed(error == .timedOut ? "start_timeout" : "start_launch_failed")
            } catch {
                return .failed("start_launch_failed")
            }
            guard result.exitCode == 0 else {
                return .failed("start_exit_\(result.exitCode)")
            }
            guard await waitForRunning(true) else {
                return .failed("start_not_observed")
            }
            guard let readyURL = Self.readinessURL(for: baseURL),
                  await waitForReady(readyURL) else {
                return .failed("start_http_not_ready")
            }
            return .started
        case .unavailable:
            return .unsupported("brew_service_unavailable")
        case .failed(let reason):
            return .failed(reason)
        }
    }

    /// Ollama's OpenAI-compatible base ends in `/v1`; the readiness endpoint is
    /// the native `/api/tags`. Probing it prevents the controller from running a
    /// health check while launchd has reported a PID but the HTTP server is not
    /// listening yet.
    static func readinessURL(for baseURL: URL) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.path = "/api/tags"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private enum ServiceStatus {
        case running(pid: Int?)
        case stopped(registered: Bool)
        case unavailable
        case failed(String)
    }

    private struct BrewServiceInfo: Decodable {
        let running: Bool?
        let loaded: Bool?
        let registered: Bool?
        let pid: Int?
    }

    private func serviceStatus() async -> ServiceStatus {
        guard let brewURL else { return .unavailable }
        let result: OllamaCommandResult
        do {
            result = try await runner.run(
                executable: brewURL,
                arguments: ["services", "info", "ollama", "--json"],
                timeout: commandTimeout
            )
        } catch let error as OllamaCommandError {
            return .failed(error == .timedOut ? "status_timeout" : "status_launch_failed")
        } catch {
            return .failed("status_launch_failed")
        }
        guard result.exitCode == 0 else { return .unavailable }
        guard let data = result.output.data(using: .utf8),
              let services = try? JSONDecoder().decode([BrewServiceInfo].self, from: data),
              let service = services.first else {
            return .unavailable
        }
        let running = service.running == true || service.loaded == true && service.pid != nil
        return running
            ? .running(pid: service.pid)
            : .stopped(registered: service.registered == true)
    }

    private func waitForRunning(_ expected: Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(max(waitTimeout, 0.1))
        var backoff = min(statusPollInterval, .milliseconds(100))
        let maxInterval = statusPollInterval
        while Date() < deadline {
            guard !Task.isCancelled else { return false }
            switch await serviceStatus() {
            case .running where expected:
                return true
            case .stopped where !expected:
                return true
            case .failed:
                return false
            case .unavailable:
                return false
            case .running, .stopped:
                break
            }
            try? await Task.sleep(for: backoff)
            backoff = min(backoff * 2, maxInterval)
        }
        return false
    }

    private func waitForReady(_ url: URL) async -> Bool {
        let deadline = Date().addingTimeInterval(max(waitTimeout, 0.1))
        var backoff = min(statusPollInterval, .milliseconds(100))
        let maxInterval = statusPollInterval
        while Date() < deadline {
            guard !Task.isCancelled else { return false }
            if await readinessProbe(url) { return true }
            try? await Task.sleep(for: backoff)
            backoff = min(backoff * 2, maxInterval)
        }
        return false
    }

    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
            return
        }
        waiters.removeFirst().resume()
    }
}
