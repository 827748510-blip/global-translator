import Foundation
import GlobalTranslatorCore

public struct CLIParseError: Error, Equatable, Sendable, CustomStringConvertible {
    public let message: String

    public init(message: String = "参数无效") {
        self.message = message
    }

    public var description: String {
        message + "\n\n" + CLIParser.usage
    }
}

public enum CLICommand: Equatable, Sendable {
    case doctor
    case start
    case settings
    case status
    case logs(follow: Bool)
    case stop
    case run(mode: RunMode)
}

public struct CLIInvocation: Equatable, Sendable {
    public let command: CLICommand
    public let runtimeRoot: URL?

    public init(command: CLICommand, runtimeRoot: URL? = nil) {
        self.command = command
        self.runtimeRoot = runtimeRoot
    }
}

public enum CLIParser {
    public static let usage = "用法：global-translator doctor|start|settings|status|logs [--follow]|stop|run --foreground|run --daemon-child"

    public static func parse(_ arguments: [String]) throws -> CLICommand {
        try parseInvocation(arguments).command
    }

    public static func parseInvocation(_ arguments: [String]) throws -> CLIInvocation {
        var args = arguments[...]
        var runtimeRoot: URL?
        if args.first == "--runtime-root" {
            args.removeFirst()
            guard let value = args.first, value.hasPrefix("/") else {
                throw CLIParseError()
            }
            args.removeFirst()
            do {
                runtimeRoot = try RuntimePaths(validatingRoot: URL(fileURLWithPath: value, isDirectory: true)).rootDirectory
            } catch {
                throw CLIParseError()
            }
        }
        guard let command = args.first else {
            throw CLIParseError()
        }
        args.removeFirst()
        let parsed: CLICommand
        switch command {
        case "doctor":
            guard args.isEmpty else { throw CLIParseError() }
            parsed = .doctor
        case "start":
            guard args.isEmpty else { throw CLIParseError() }
            parsed = .start
        case "status":
            guard args.isEmpty else { throw CLIParseError() }
            parsed = .status
        case "settings":
            guard args.isEmpty else { throw CLIParseError() }
            parsed = .settings
        case "logs":
            if args.isEmpty {
                parsed = .logs(follow: false)
            } else if args.count == 1, args.first == "--follow" {
                parsed = .logs(follow: true)
            } else {
                throw CLIParseError()
            }
        case "stop":
            guard args.isEmpty else { throw CLIParseError() }
            parsed = .stop
        case "run":
            guard args.count == 1, let mode = args.first else {
                throw CLIParseError()
            }
            switch mode {
            case "--foreground":
                parsed = .run(mode: .foreground)
            case "--daemon-child":
                parsed = .run(mode: .daemonChild)
            default:
                throw CLIParseError()
            }
        default:
            throw CLIParseError()
        }
        return CLIInvocation(command: parsed, runtimeRoot: runtimeRoot)
    }
}

public enum CLIExitCode {
    public static func status(_ response: ControlResponse) -> Int32 {
        response.running ? 0 : 1
    }
}

public enum ChildEnvironment {
    public static let fixedPath = "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin"

    public static func minimal(
        from source: [String: String],
        validatedOverrideRoot: URL? = nil
    ) -> [String: String] {
        var result = ["PATH": fixedPath]
        for name in ["LANG", "LC_CTYPE"] {
            if let value = source[name], isSafeValue(value) {
                result[name] = value
            }
        }
        if let root = validatedOverrideRoot,
           root.isFileURL,
           root.path.hasPrefix("/"),
           !root.pathComponents.contains(".."),
           root.standardizedFileURL.path == root.resolvingSymlinksInPath().path {
            result["GLOBAL_TRANSLATOR_RUNTIME_ROOT"] = root.standardizedFileURL.path
        }
        return result
    }

    private static func isSafeValue(_ value: String) -> Bool {
        value.count <= 128 && !value.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\0" })
    }
}

public enum CLIErrorFormatter {
    public static func message(for error: Error) -> String {
        if let parseError = error as? CLIParseError {
            return parseError.description
        }
        if let runtimeError = error as? RuntimeError {
            return "错误：" + runtimeError.description
        }
        if let configError = error as? ConfigStoreError {
            switch configError {
            case .invalidData:
                return "错误：配置文件无效"
            case .encodingFailure, .writeFailure:
                return "错误：配置文件操作失败"
            }
        }
        return "错误：运行失败"
    }
}
