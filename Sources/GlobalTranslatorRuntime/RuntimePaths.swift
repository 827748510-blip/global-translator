import Darwin
import Foundation

public struct RuntimePaths: Equatable, Sendable {
    public let rootDirectory: URL
    public let applicationSupportDirectory: URL
    public let configURL: URL
    public let runtimeDirectory: URL
    public let pidURL: URL
    public let socketURL: URL
    public let logsDirectory: URL
    public let logURL: URL
    public let recommendedBinaryURL: URL
    public let usesOverrideRoot: Bool

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let app = homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("GlobalTranslator", isDirectory: true)
        self.init(appDirectory: app, logsDirectory: homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("GlobalTranslator", isDirectory: true),
            recommendedBinaryURL: homeDirectory
                .appendingPathComponent(".local", isDirectory: true)
                .appendingPathComponent("bin", isDirectory: true)
                .appendingPathComponent("global-translator", isDirectory: false),
            usesOverrideRoot: false)
    }

    public init(root: URL) {
        self.init(appDirectory: root.standardizedFileURL, logsDirectory: root
            .standardizedFileURL
            .appendingPathComponent("logs", isDirectory: true),
            recommendedBinaryURL: root.standardizedFileURL
                .appendingPathComponent("bin", isDirectory: true)
                .appendingPathComponent("global-translator", isDirectory: false),
            usesOverrideRoot: true)
    }

    public init(rootDirectory: URL) {
        self.init(root: rootDirectory)
    }

    public init(validatingRoot root: URL) throws {
        guard root.isFileURL, root.path.hasPrefix("/"),
              !root.pathComponents.contains(".."),
              !root.path.isEmpty else {
            throw RuntimeError.invalidPath
        }
        let normalized = root.standardizedFileURL
        guard normalized.pathComponents.allSatisfy({ $0 != ".." }) else {
            throw RuntimeError.invalidPath
        }
        let resolved = normalized.resolvingSymlinksInPath()
        if FileManager.default.fileExists(atPath: normalized.path), resolved.path != normalized.path {
            throw RuntimeError.invalidPath
        }
        self.init(root: normalized)
    }

    public static func production(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> RuntimePaths {
        RuntimePaths(homeDirectory: homeDirectory)
    }

    public static func fromEnvironment(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> RuntimePaths {
        guard let rawRoot = environment["GLOBAL_TRANSLATOR_RUNTIME_ROOT"], !rawRoot.isEmpty else {
            return .production()
        }
        guard rawRoot.hasPrefix("/") else {
            throw RuntimeError.invalidPath
        }
        return try RuntimePaths(validatingRoot: URL(fileURLWithPath: rawRoot, isDirectory: true))
    }

    public func prepareDirectories() throws {
        let manager = FileManager.default
        do {
            if manager.fileExists(atPath: runtimeDirectory.path), isSymlink(runtimeDirectory.path) {
                throw RuntimeError.invalidPath
            }
            if manager.fileExists(atPath: logsDirectory.path), isSymlink(logsDirectory.path) {
                throw RuntimeError.invalidPath
            }
            try manager.createDirectory(at: applicationSupportDirectory, withIntermediateDirectories: true)
            try manager.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true)
            try manager.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
            for directory in [applicationSupportDirectory, runtimeDirectory, logsDirectory] {
                try manager.setAttributes([.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: directory.path)
            }
            if !manager.fileExists(atPath: logURL.path) {
                manager.createFile(atPath: logURL.path, contents: Data())
            }
            for file in [configURL, pidURL, logURL] where manager.fileExists(atPath: file.path) {
                guard !isSymlink(file.path) else {
                    throw RuntimeError.invalidPath
                }
                try manager.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: file.path)
            }
        } catch let error as RuntimeError {
            throw error
        } catch {
            throw RuntimeError.ioFailure
        }
    }

    public func isContained(_ url: URL) -> Bool {
        let root = rootDirectory.resolvingSymlinksInPath().path
        let candidate = url.resolvingSymlinksInPath().path
        guard candidate == root else {
            return candidate.hasPrefix(root + "/")
        }
        return true
    }

    private init(
        appDirectory: URL,
        logsDirectory: URL,
        recommendedBinaryURL: URL,
        usesOverrideRoot: Bool
    ) {
        let app = appDirectory.standardizedFileURL
        let runtime = app.appendingPathComponent("runtime", isDirectory: true)
        self.rootDirectory = app
        self.applicationSupportDirectory = app
        self.configURL = app.appendingPathComponent("config.json", isDirectory: false)
        self.runtimeDirectory = runtime
        self.pidURL = runtime.appendingPathComponent("global-translator.pid", isDirectory: false)
        self.socketURL = runtime.appendingPathComponent("control.sock", isDirectory: false)
        self.logsDirectory = logsDirectory.standardizedFileURL
        self.logURL = logsDirectory.standardizedFileURL.appendingPathComponent("runtime.log", isDirectory: false)
        self.recommendedBinaryURL = recommendedBinaryURL.standardizedFileURL
        self.usesOverrideRoot = usesOverrideRoot
    }

    private func isSymlink(_ path: String) -> Bool {
        var information = stat()
        guard Darwin.lstat(path, &information) == 0 else {
            return false
        }
        return (information.st_mode & S_IFMT) == S_IFLNK
    }
}
