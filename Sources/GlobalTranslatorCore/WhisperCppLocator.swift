import Foundation

/// Resolves a local Whisper.cpp CLI and English ggml model. Never downloads
/// weights and never points at a network endpoint.
public struct WhisperCppLocator: Equatable, Sendable {
    public let binaryURL: URL?
    public let modelURL: URL?

    public var isAvailable: Bool { binaryURL != nil && modelURL != nil }

    public init(binaryURL: URL?, modelURL: URL?) {
        self.binaryURL = binaryURL
        self.modelURL = modelURL
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
        }
    ) -> WhisperCppLocator {
        let binary = uniqued(
            binaryCandidates(environment: environment, extra: extraBinaryCandidates)
        ).first { fileExists($0) && isExecutable($0) }

        var models: [URL] = []
        if let raw = environment[modelEnvironmentKey], !raw.isEmpty {
            models.append(URL(fileURLWithPath: raw))
        }
        models.append(contentsOf: extraModelCandidates)
        if let binary {
            let folder = binary.deletingLastPathComponent()
            models.append(contentsOf: wellKnownModelNames.map { folder.appendingPathComponent($0) })
        }
        let model = uniqued(models).first { fileExists($0) }
        return WhisperCppLocator(binaryURL: binary, modelURL: model)
    }

    private static func binaryCandidates(environment: [String: String], extra: [URL]) -> [URL] {
        var urls: [URL] = []
        if let raw = environment[binaryEnvironmentKey], !raw.isEmpty {
            urls.append(URL(fileURLWithPath: raw))
        }
        urls.append(contentsOf: extra)
        for directory in wellKnownBinaryDirectories() {
            urls.append(contentsOf: wellKnownBinaryNames.map { directory.appendingPathComponent($0) })
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
