import Foundation

/// Records every CLI termination to a fixed, always-writable location.
///
/// A process that dies before it can log anything leaves no trace, and a process
/// that exits with an unexpected code leaves a misleading one. Appending the code
/// together with the launchd context turns both cases into evidence:
///
/// - **No audit line at all** → the failure happened before `main` ran, so it
///   belongs to spawn/Gatekeeper/TCC, not to this program.
/// - **Audit line present** → the exit code, arguments and job context are on
///   record, so it can be attributed instead of guessed at.
///
/// The path is deliberately fixed at the user log directory: a mis-parsed
/// `--runtime-root` must not be able to move the audit trail somewhere unreadable.
public enum CLIExitAudit {
    public static func auditURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("GlobalTranslator", isDirectory: true)
            .appendingPathComponent("cli.log", isDirectory: false)
    }

    public static func recordExit(
        _ code: Int32,
        arguments: [String],
        paths: RuntimePaths? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        now: Date = Date()
    ) {
        var fields: [String: Any] = [
            "event": "cli_exit",
            "code": Int(code),
            "command": truncated(arguments.joined(separator: " ")),
            "pid": Int(ProcessInfo.processInfo.processIdentifier),
            "managedByLaunchd": RuntimeManager.isManagedByLaunchd(environment: environment),
            "timestamp": ISO8601DateFormatter().string(from: now)
        ]
        if let root = paths?.rootDirectory.path {
            fields["runtimeRoot"] = root
        }
        // Only record the label when it really identifies a job: launchd also
        // sets "0" as a placeholder, which says nothing about supervision.
        if RuntimeManager.isManagedByLaunchd(environment: environment),
           let service = environment["XPC_SERVICE_NAME"] {
            fields["xpcServiceName"] = truncated(service)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return }

        let url = auditURL(homeDirectory: homeDirectory)
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let line = Data((text + "\n").utf8)
        if let handle = FileHandle(forWritingAtPath: url.path) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: url)
        }
    }

    private static func truncated(_ value: String, limit: Int = 200) -> String {
        value.count <= limit ? value : String(value.prefix(limit))
    }
}
