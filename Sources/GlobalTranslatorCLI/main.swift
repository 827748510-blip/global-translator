import Darwin
import Foundation
import GlobalTranslatorApp
import GlobalTranslatorRuntime

@main
struct GlobalTranslatorCLI {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let desktopLaunch = Bundle.main.bundleURL.pathExtension == "app"
            && (arguments.isEmpty || (arguments.count == 1 && arguments[0].hasPrefix("-psn_")))
        do {
            if desktopLaunch {
                try await GlobalTranslatorApplication.launchDesktop(paths: RuntimePaths.fromEnvironment())
                CLIExitAudit.recordExit(0, arguments: arguments)
                return
            }
            let invocation = try CLIParser.parseInvocation(arguments)
            let paths: RuntimePaths
            if let root = invocation.runtimeRoot {
                paths = try RuntimePaths(validatingRoot: root)
            } else {
                paths = try RuntimePaths.fromEnvironment()
            }
            try await dispatch(invocation.command, paths: paths, arguments: arguments)
            CLIExitAudit.recordExit(0, arguments: arguments, paths: paths)
        } catch let error as CLIParseError {
            writeStderr(error.description + "\n")
            CLIExitAudit.recordExit(2, arguments: arguments)
            exit(2)
        } catch {
            let message = CLIErrorFormatter.message(for: error)
            if desktopLaunch { GlobalTranslatorApplication.showLaunchError(message) }
            writeStderr(message + "\n")
            CLIExitAudit.recordExit(1, arguments: arguments)
            exit(1)
        }
    }

    private static func dispatch(_ command: CLICommand, paths: RuntimePaths, arguments: [String]) async throws {
        let manager = RuntimeManager(paths: paths)
        switch command {
        case .doctor:
            let report = Doctor(paths: paths).run()
            writeStdout(report.renderChinese())
            if report.hasFailure {
                CLIExitAudit.recordExit(1, arguments: arguments, paths: paths)
                exit(1)
            }
        case .start:
            switch try manager.start() {
            case let .started(pid):
                writeStdout("已启动，PID \(pid)\n")
            case let .alreadyRunning(pid):
                writeStdout("已在运行，PID \(pid)\n")
            }
        case .status:
            let response = manager.status()
            writeStdout(try encodeJSON(response))
            let code = CLIExitCode.status(response)
            CLIExitAudit.recordExit(code, arguments: arguments, paths: paths)
            exit(code)
        case .settings:
            _ = try manager.start()
            writeStdout(try encodeJSON(try manager.showSettings()))
        case let .logs(follow):
            if follow {
                try followLogs(paths: paths)
            } else {
                let lines = try manager.logs(limit: 200)
                if !lines.isEmpty {
                    writeStdout(lines.joined(separator: "\n") + "\n")
                }
            }
        case .stop:
            writeStdout(try encodeJSON(try manager.stop()))
        case let .run(mode):
            try await GlobalTranslatorApplication.run(paths: paths, mode: mode)
        }
    }

    private static func followLogs(paths: RuntimePaths) throws {
        let url = paths.logURL
        var offset: UInt64 = 0
        while true {
            var information = stat()
            guard Darwin.lstat(url.path, &information) == 0,
                  (information.st_mode & S_IFMT) == S_IFREG,
                  let data = FileManager.default.contents(atPath: url.path) else {
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
                continue
            }
            if UInt64(data.count) < offset {
                offset = 0
            }
            if UInt64(data.count) > offset {
                let start = Int(offset)
                let chunk = data.subdata(in: start..<data.count)
                writeStdout(RuntimeRedactor.redact(String(decoding: chunk, as: UTF8.self)))
                offset = UInt64(data.count)
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
        }
    }

    private static func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self) + "\n"
    }

    private static func writeStdout(_ value: String) {
        FileHandle.standardOutput.write(Data(value.utf8))
    }

    private static func writeStderr(_ value: String) {
        FileHandle.standardError.write(Data(value.utf8))
    }
}
