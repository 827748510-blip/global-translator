import Foundation
import Testing
@testable import GlobalTranslatorApp
import GlobalTranslatorCore
import GlobalTranslatorRuntime

private actor FakeOllamaLifecycle: OllamaLifecycleControlling {
    private(set) var suspendCount = 0
    private(set) var resumeCount = 0
    var suspendOutcome: OllamaLifecycleOutcome = .stopped
    var resumeOutcome: OllamaLifecycleOutcome = .started
    var suspendDelay: Duration?

    func setSuspendDelay(_ delay: Duration?) { suspendDelay = delay }

    func suspend() async -> OllamaLifecycleOutcome {
        suspendCount += 1
        if let suspendDelay { try? await Task.sleep(for: suspendDelay) }
        return suspendOutcome
    }

    func resume(baseURL: URL) async -> OllamaLifecycleOutcome {
        resumeCount += 1
        return resumeOutcome
    }
}

private actor FakeBrewRunner: OllamaCommandRunning {
    private(set) var running = true
    private(set) var installed = true
    private(set) var registered = false
    private(set) var commands: [[String]] = []

    func setRunning(_ value: Bool) { running = value }
    func setInstalled(_ value: Bool) { installed = value }
    func setRegistered(_ value: Bool) { registered = value }

    func run(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> OllamaCommandResult {
        commands.append(arguments)
        switch arguments {
        case ["services", "info", "ollama", "--json"]:
            let services: [[String: Any]] = installed
                ? [[
                    "name": "ollama",
                    "running": running,
                    "loaded": running,
                    "registered": registered,
                    "schedulable": registered,
                    "pid": running ? 75_627 : 0
                ]]
                : []
            let data = try JSONSerialization.data(withJSONObject: services)
            return OllamaCommandResult(
                exitCode: 0,
                output: String(decoding: data, as: UTF8.self)
            )
        case ["services", "stop", "--keep", "ollama"]:
            running = false
            return OllamaCommandResult(exitCode: 0, output: "stopped")
        case ["services", "run", "ollama"]:
            running = true
            return OllamaCommandResult(exitCode: 0, output: "started")
        case ["services", "start", "ollama"]:
            running = true
            registered = true
            return OllamaCommandResult(exitCode: 0, output: "started")
        default:
            return OllamaCommandResult(exitCode: 1, output: "")
        }
    }
}

struct HomebrewOllamaLifecycleTests {
    @Test
    func suspendAndResumeUseOnlyHomebrewServiceCommands() async {
        let runner = FakeBrewRunner()
        let lifecycle = HomebrewOllamaLifecycle(
            brewURL: URL(fileURLWithPath: "/tmp/fake-brew"),
            runner: runner,
            commandTimeout: 1,
            waitTimeout: 1,
            statusPollInterval: .milliseconds(1),
            readinessProbe: { _ in true }
        )
        #expect(await lifecycle.suspend() == .stopped)
        #expect(await runner.running == false)
        #expect(await lifecycle.suspend() == .alreadyStopped)
        #expect(await lifecycle.resume(baseURL: URL(string: "http://127.0.0.1:11434/v1")!) == .started)
        #expect(await runner.running == true)
        #expect(await lifecycle.resume(baseURL: URL(string: "http://127.0.0.1:11434/v1")!) == .alreadyRunning)
        let commands = await runner.commands
        #expect(commands.contains(["services", "stop", "--keep", "ollama"]))
        // An initially unregistered service is restarted with `run` so the app
        // does not add an Ollama login item behind the user's back.
        #expect(commands.contains(["services", "run", "ollama"]))
        #expect(!commands.contains(["services", "start", "ollama"]))
    }

    @Test
    func previouslyRegisteredServiceIsRestartedWithStart() async {
        let runner = FakeBrewRunner()
        await runner.setRegistered(true)
        let lifecycle = HomebrewOllamaLifecycle(
            brewURL: URL(fileURLWithPath: "/tmp/fake-brew"),
            runner: runner,
            commandTimeout: 1,
            waitTimeout: 1,
            statusPollInterval: .milliseconds(1),
            readinessProbe: { _ in true }
        )
        #expect(await lifecycle.suspend() == .stopped)
        #expect(await lifecycle.resume(baseURL: URL(string: "http://127.0.0.1:11434/v1")!) == .started)
        let commands = await runner.commands
        #expect(commands.contains(["services", "stop", "--keep", "ollama"]))
        #expect(commands.contains(["services", "start", "ollama"]))
        #expect(!commands.contains(["services", "run", "ollama"]))
    }

    @Test
    func readinessURLPointsAtOllamaNativeAPI() {
        #expect(
            HomebrewOllamaLifecycle.readinessURL(
                for: URL(string: "http://127.0.0.1:11434/v1")!
            )?.absoluteString == "http://127.0.0.1:11434/api/tags"
        )
        #expect(
            HomebrewOllamaLifecycle.readinessURL(
                for: URL(string: "http://localhost:11434/v1/")!
            )?.absoluteString == "http://localhost:11434/api/tags"
        )
    }

    @Test
    func resumeFailsIfHTTPNeverBecomesReady() async {
        let runner = FakeBrewRunner()
        await runner.setRunning(false)
        await runner.setRegistered(true)
        let lifecycle = HomebrewOllamaLifecycle(
            brewURL: URL(fileURLWithPath: "/tmp/fake-brew"),
            runner: runner,
            commandTimeout: 1,
            waitTimeout: 0.1,
            statusPollInterval: .milliseconds(1),
            readinessProbe: { _ in false }
        )
        #expect(await lifecycle.resume(baseURL: URL(string: "http://127.0.0.1:11434/v1")!) == .failed("start_http_not_ready"))
    }

    @Test
    func registrationSurvivesANewLifecycleInstanceAfterAppRestart() async {
        let runner = FakeBrewRunner()
        await runner.setRegistered(true)
        let first = HomebrewOllamaLifecycle(
            brewURL: URL(fileURLWithPath: "/tmp/fake-brew"),
            runner: runner,
            commandTimeout: 1,
            waitTimeout: 1,
            statusPollInterval: .milliseconds(1),
            readinessProbe: { _ in true }
        )
        #expect(await first.suspend() == .stopped)

        // Simulate an app restart while the backend is still cloud: the
        // registration decision comes from `brew services info`, not memory.
        let second = HomebrewOllamaLifecycle(
            brewURL: URL(fileURLWithPath: "/tmp/fake-brew"),
            runner: runner,
            commandTimeout: 1,
            waitTimeout: 1,
            statusPollInterval: .milliseconds(1),
            readinessProbe: { _ in true }
        )
        #expect(await second.resume(baseURL: URL(string: "http://127.0.0.1:11434/v1")!) == .started)
        let commands = await runner.commands
        #expect(commands.contains(["services", "start", "ollama"]))
        #expect(!commands.contains(["services", "run", "ollama"]))
    }

    @Test
    func missingHomebrewServiceIsUnsupportedAndNotTouched() async {
        let runner = FakeBrewRunner()
        await runner.setInstalled(false)
        let lifecycle = HomebrewOllamaLifecycle(
            brewURL: URL(fileURLWithPath: "/tmp/fake-brew"),
            runner: runner,
            commandTimeout: 1,
            waitTimeout: 1,
            statusPollInterval: .milliseconds(1),
            readinessProbe: { _ in true }
        )
        #expect(await lifecycle.suspend() == .unsupported("brew_service_unavailable"))
        #expect(await lifecycle.resume(baseURL: URL(string: "http://127.0.0.1:11434/v1")!) == .unsupported("brew_service_unavailable"))
        let commands = await runner.commands
        #expect(!commands.contains(["services", "stop", "--keep", "ollama"]))
        #expect(!commands.contains(["services", "start", "ollama"]))
    }

    @Test
    func noBrewExecutableNeverRunsACommand() async {
        let runner = FakeBrewRunner()
        let lifecycle = HomebrewOllamaLifecycle(
            brewURL: nil,
            runner: runner,
            commandTimeout: 1,
            waitTimeout: 1,
            statusPollInterval: .milliseconds(1),
            readinessProbe: { _ in true }
        )
        #expect(await lifecycle.suspend() == .unsupported("brew_service_unavailable"))
        #expect(await lifecycle.resume(baseURL: URL(string: "http://127.0.0.1:11434/v1")!) == .unsupported("brew_service_unavailable"))
        #expect(await runner.commands.isEmpty)
    }

    @Test
    func systemRunnerExecutesAbsoluteExecutableWithoutAShell() async throws {
        let result = try await SystemOllamaCommandRunner().run(
            executable: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["ollama-lifecycle-probe"],
            timeout: 2
        )
        #expect(result.exitCode == 0)
        #expect(result.output.contains("ollama-lifecycle-probe"))
    }

    @Test
    func systemRunnerDrainsLargeOutputWithoutPipeDeadlock() async throws {
        // Output >128KB exceeds typical 64KB Darwin pipe capacity and would deadlock
        // if the runner waited for termination before draining the pipe.
        let result = try await SystemOllamaCommandRunner().run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "python3 - <<'EOF'\nprint('x' * 200000)\nEOF"],
            timeout: 5
        )
        #expect(result.exitCode == 0)
        #expect(result.output.utf8.count >= 200_000)
    }
}

@MainActor
extension ApplicationControllerTests {
    @Test
    func switchingToCloudStopsOllamaAndSwitchingBackStartsIt() async throws {
        let lifecycle = FakeOllamaLifecycle()
        let store = RecordingConfigurationStore(configuration: AppConfiguration(
            autoTranslateEnabled: false,
            backend: .local,
            localModel: "test"
        ))
        let controller = ApplicationController(
            paths: try RuntimePaths(validatingRoot: temporaryRoot()),
            components: makeComponents(store: store, ollamaLifecycle: lifecycle)
        )
        try await controller.start()
        await waitForStartupHealthCheck(controller)
        #expect(await lifecycle.suspendCount == 0)
        #expect(await lifecycle.resumeCount == 0)

        controller.selectBackend(.deepSeekCloud)
        try await waitForLifecycle { await lifecycle.suspendCount == 1 }
        #expect(await lifecycle.resumeCount == 0)
        #expect(controller.configuration.backend == .deepSeekCloud)

        controller.selectBackend(.local)
        try await waitForLifecycle { await lifecycle.resumeCount == 1 }
        #expect(await lifecycle.suspendCount == 1)
        #expect(controller.configuration.backend == .local)
        await controller.stop()
    }

    @Test
    func rapidCloudThenLocalLeavesOllamaRunning() async throws {
        let lifecycle = FakeOllamaLifecycle()
        await lifecycle.setSuspendDelay(.milliseconds(80))
        let store = RecordingConfigurationStore(configuration: AppConfiguration(
            autoTranslateEnabled: false,
            backend: .local,
            localModel: "test"
        ))
        let controller = ApplicationController(
            paths: try RuntimePaths(validatingRoot: temporaryRoot()),
            components: makeComponents(store: store, ollamaLifecycle: lifecycle)
        )
        try await controller.start()
        await waitForStartupHealthCheck(controller)

        controller.selectBackend(.deepSeekCloud)
        try await waitForLifecycle { await lifecycle.suspendCount == 1 }
        controller.selectBackend(.local)
        try await waitForLifecycle { await lifecycle.resumeCount == 1 }
        #expect(await lifecycle.suspendCount == 1)
        #expect(controller.configuration.backend == .local)
        await controller.stop()
    }

    @Test
    func customLocalEndpointNeverStopsHomebrewOllama() async throws {
        let lifecycle = FakeOllamaLifecycle()
        let store = RecordingConfigurationStore(configuration: AppConfiguration(
            autoTranslateEnabled: false,
            backend: .local,
            localBaseURL: URL(string: "http://127.0.0.1:12345/v1")!,
            localModel: "test"
        ))
        let controller = ApplicationController(
            paths: try RuntimePaths(validatingRoot: temporaryRoot()),
            components: makeComponents(store: store, ollamaLifecycle: lifecycle)
        )
        try await controller.start()
        await waitForStartupHealthCheck(controller)
        controller.selectBackend(.deepSeekCloud)
        try await waitForLifecycle { controller.ollamaLifecycleTask == nil }
        #expect(await lifecycle.suspendCount == 0)
        await controller.stop()
    }

    @Test
    func defaultOllamaEndpointIsManaged() {
        #expect(ApplicationController.shouldManageOllama(for: AppConfiguration()))
        #expect(ApplicationController.shouldManageOllama(for: AppConfiguration(
            localBaseURL: URL(string: "http://localhost:11434/v1")!
        )))
        #expect(!ApplicationController.shouldManageOllama(for: AppConfiguration(
            localBaseURL: URL(string: "http://127.0.0.1:12345/v1")!
        )))
        #expect(!ApplicationController.shouldManageOllama(for: AppConfiguration(
            localBaseURL: URL(string: "http://192.168.1.20:11434/v1")!
        )))
        #expect(!ApplicationController.shouldManageOllama(for: AppConfiguration(
            localBaseURL: URL(string: "https://127.0.0.1:11434/v1")!
        )))
    }

    private func waitForLifecycle(
        timeout: TimeInterval = 2,
        _ condition: @escaping () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()), Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await condition())
    }
}
