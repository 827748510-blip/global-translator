import Darwin
import Foundation

/// Resolves a local Whisper.cpp CLI and English ggml model. Never downloads
/// weights and never points at a network endpoint.
public struct WhisperCppLocator: Equatable, Sendable {
    public let binaryURL: URL?
    public let modelURL: URL?
    public let serverBinaryURL: URL?

    public var isAvailable: Bool { binaryURL != nil && modelURL != nil }

    public init(binaryURL: URL?, modelURL: URL?, serverBinaryURL: URL? = nil) {
        self.binaryURL = binaryURL
        self.modelURL = modelURL
        self.serverBinaryURL = serverBinaryURL
    }

    public static let binaryEnvironmentKey = "GLOBAL_TRANSLATOR_WHISPER_BIN"
    public static let modelEnvironmentKey = "GLOBAL_TRANSLATOR_WHISPER_MODEL"

    public static let wellKnownBinaryNames = [
        "whisper-cli",
        "whisper-cpp",
        "whisper"
    ]

    public static let wellKnownModelNames = [
        "ggml-base.en.bin",
        "ggml-tiny.en.bin",
        "ggml-small.en.bin",
        "ggml-base.bin",
        "ggml-tiny.bin",
        "ggml-small.bin"
    ]

    public static func wellKnownBinaryDirectories() -> [URL] {
        [
            URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
            URL(fileURLWithPath: "/usr/local/bin", isDirectory: true)
        ]
    }

    public static func candidatesForSupportDirectory(_ directory: URL) -> (binaries: [URL], models: [URL]) {
        (
            wellKnownBinaryNames.map { directory.appendingPathComponent($0) },
            wellKnownModelNames.map { directory.appendingPathComponent($0) }
        )
    }

    public static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        extraBinaryCandidates: [URL] = [],
        extraModelCandidates: [URL] = [],
        fileExists: @escaping @Sendable (URL) -> Bool = {
            FileManager.default.fileExists(atPath: $0.path)
        },
        isExecutable: @escaping @Sendable (URL) -> Bool = {
            FileManager.default.isExecutableFile(atPath: $0.path)
        },
        isTrustedPath: (@Sendable (URL, Bool) -> Bool)? = nil
    ) -> WhisperCppLocator {
        let trustCheck: @Sendable (URL, Bool) -> Bool = isTrustedPath ?? { url, requireExec in
            Self.isTrustedLocalFile(url, requireExecutable: requireExec)
        }
        let binary = uniqued(
            binaryCandidates(environment: environment, extra: extraBinaryCandidates)
        ).first { fileExists($0) && isExecutable($0) && trustCheck($0, true) }

        let serverBinary = uniqued(
            serverCandidates(near: binary, extra: extraBinaryCandidates)
        ).first { fileExists($0) && isExecutable($0) && trustCheck($0, true) }

        var models: [URL] = []
        if let raw = validatedEnvironmentPath(environment[modelEnvironmentKey]) {
            models.append(URL(fileURLWithPath: raw))
        }
        models.append(contentsOf: extraModelCandidates)
        if let binary {
            let folder = binary.deletingLastPathComponent()
            models.append(contentsOf: wellKnownModelNames.map { folder.appendingPathComponent($0) })
        }
        let model = uniqued(models).first { fileExists($0) && trustCheck($0, false) }
        return WhisperCppLocator(binaryURL: binary, modelURL: model, serverBinaryURL: serverBinary)
    }

    public static func isTrustedLocalFile(_ url: URL, requireExecutable: Bool) -> Bool {
        let rawPath = url.path
        guard rawPath.hasPrefix("/"), !url.pathComponents.contains("..") else { return false }

        var linkStat = Darwin.stat()
        guard Darwin.lstat(rawPath, &linkStat) == 0 else { return false }
        let rawParent = url.deletingLastPathComponent().path
        guard isTrustedDirectory(rawParent) else { return false }

        let resolvedURL: URL
        if (linkStat.st_mode & S_IFMT) == S_IFLNK {
            resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
            guard resolvedURL.path.hasPrefix("/"),
                  !resolvedURL.pathComponents.contains(".."),
                  isTrustedDirectory(resolvedURL.deletingLastPathComponent().path) else {
                return false
            }
        } else {
            resolvedURL = url.standardizedFileURL
        }

        var targetStat = Darwin.stat()
        guard Darwin.lstat(resolvedURL.path, &targetStat) == 0 else { return false }
        guard (targetStat.st_mode & S_IFMT) == S_IFREG else { return false }

        let uid = geteuid()
        guard targetStat.st_uid == uid || targetStat.st_uid == 0 else { return false }
        // Reject world- or group-writable binaries/models.
        guard (targetStat.st_mode & 0o022) == 0 else { return false }
        if requireExecutable, (targetStat.st_mode & 0o111) == 0 {
            return false
        }
        return true
    }

    private static func isTrustedDirectory(_ path: String) -> Bool {
        guard !path.isEmpty, path.hasPrefix("/") else { return false }
        var st = Darwin.stat()
        guard Darwin.lstat(path, &st) == 0 else { return false }
        guard (st.st_mode & S_IFMT) == S_IFDIR else { return false }
        let uid = geteuid()
        guard st.st_uid == uid || st.st_uid == 0 else { return false }
        // Reject world-writable directories (/tmp, /Users/Shared, etc.), and reject
        // group-writable directories not owned by the current user.
        if (st.st_mode & 0o002) != 0 { return false }
        if (st.st_mode & 0o020) != 0 && st.st_uid != uid { return false }
        return true
    }

    private static func validatedEnvironmentPath(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              trimmed.hasPrefix("/") else { return nil }
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.contains("..") else { return nil }
        return trimmed
    }

    private static func binaryCandidates(environment: [String: String], extra: [URL]) -> [URL] {
        var urls: [URL] = []
        if let raw = validatedEnvironmentPath(environment[binaryEnvironmentKey]) {
            urls.append(URL(fileURLWithPath: raw))
        }
        urls.append(contentsOf: extra)
        for directory in wellKnownBinaryDirectories() {
            urls.append(contentsOf: wellKnownBinaryNames.map { directory.appendingPathComponent($0) })
        }
        return urls
    }

    private static func serverCandidates(near binary: URL?, extra: [URL]) -> [URL] {
        var urls: [URL] = []
        if let binary {
            urls.append(binary.deletingLastPathComponent().appendingPathComponent("whisper-server"))
        }
        for candidate in extra {
            urls.append(candidate.deletingLastPathComponent().appendingPathComponent("whisper-server"))
        }
        for directory in wellKnownBinaryDirectories() {
            urls.append(directory.appendingPathComponent("whisper-server"))
        }
        return urls
    }

    private static func uniqued(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for url in urls {
            let key = url.standardizedFileURL.path
            if seen.insert(key).inserted {
                result.append(url.standardizedFileURL)
            }
        }
        return result
    }
}
