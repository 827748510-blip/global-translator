import Foundation

public struct AudioPCMChunk: Sendable {
    public let pcm16Mono16k: Data
    public let startedAt: Date

    public init(pcm16Mono16k: Data, startedAt: Date = Date()) {
        self.pcm16Mono16k = pcm16Mono16k
        self.startedAt = startedAt
    }

    public var sampleCount: Int { pcm16Mono16k.count / 2 }

    public var duration: TimeInterval {
        Double(sampleCount) / Double(AudioPCM.whisperSampleRate)
    }
}

public struct WhisperTranscript: Equatable, Sendable {
    public let text: String
    public let duration: TimeInterval

    public init(text: String, duration: TimeInterval) {
        self.text = text
        self.duration = duration
    }
}

public enum WhisperTranscribeError: Error, Equatable, Sendable {
    case unavailable
    case failed
}

public protocol SpeechTranscribing: Sendable {
    var isAvailable: Bool { get }
    func transcribeEnglish(pcm16Mono16k: Data) async throws -> WhisperTranscript
}

public protocol WhisperProcessRunning: Sendable {
    func run(binary: URL, arguments: [String], timeout: TimeInterval) async throws -> String
}

public struct FoundationWhisperProcessRunner: WhisperProcessRunning, Sendable {
    public init() {}

    public func run(binary: URL, arguments: [String], timeout: TimeInterval) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let output = try Self.launch(binary: binary, arguments: arguments, timeout: timeout)
                    continuation.resume(returning: output)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func launch(binary: URL, arguments: [String], timeout: TimeInterval) throws -> String {
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(max(timeout, 1))
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            throw WhisperTranscribeError.failed
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = stderr.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        let fallback = String(data: err, encoding: .utf8) ?? ""
        if process.terminationStatus == 0 {
            return fallback
        }
        throw WhisperTranscribeError.failed
    }
}

public final class WhisperCppTranscriber: SpeechTranscribing, @unchecked Sendable {
    private let locate: @Sendable () -> WhisperCppLocator
    private let runner: any WhisperProcessRunning
    private let scratchDirectory: URL
    private let fileManager: FileManager
    private let timeout: TimeInterval

    public init(
        locate: @escaping @Sendable () -> WhisperCppLocator,
        scratchDirectory: URL,
        runner: any WhisperProcessRunning = FoundationWhisperProcessRunner(),
        fileManager: FileManager = .default,
        timeout: TimeInterval = 12
    ) {
        self.locate = locate
        self.scratchDirectory = scratchDirectory
        self.runner = runner
        self.fileManager = fileManager
        self.timeout = timeout
    }

    public var isAvailable: Bool { locate().isAvailable }

    public func transcribeEnglish(pcm16Mono16k: Data) async throws -> WhisperTranscript {
        let locator = locate()
        guard let binary = locator.binaryURL, let model = locator.modelURL else {
            throw WhisperTranscribeError.unavailable
        }
        let samples = AudioPCM.int16Array(from: pcm16Mono16k)
        let duration = Double(samples.count) / Double(AudioPCM.whisperSampleRate)
        try prepareScratch()
        let wavURL = scratchDirectory.appendingPathComponent("chunk-\(UUID().uuidString).wav")
        defer { try? fileManager.removeItem(at: wavURL) }
        let wav = AudioPCM.wavData(pcm16Mono: samples)
        try wav.write(to: wavURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: wavURL.path
        )
        let raw = try await runner.run(
            binary: binary,
            arguments: ["-m", model.path, "-f", wavURL.path, "-l", "en", "-nt", "-np"],
            timeout: timeout
        )
        let text = Self.parseTranscript(raw)
        guard !text.isEmpty else { throw WhisperTranscribeError.failed }
        return WhisperTranscript(text: text, duration: duration)
    }

    public static func parseTranscript(_ raw: String) -> String {
        let lines = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0) }
        var parts: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if shouldIgnore(trimmed) { continue }
            if let stamped = timestampedText(trimmed) {
                if !stamped.isEmpty { parts.append(stamped) }
                continue
            }
            parts.append(trimmed)
        }
        let joined = parts.joined(separator: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return joined
    }

    private func prepareScratch() throws {
        try fileManager.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: scratchDirectory.path
        )
    }

    private static func timestampedText(_ line: String) -> String? {
        guard let close = line.firstIndex(of: "]"), line.first == "[" else { return nil }
        let inner = line[line.index(after: line.startIndex)..<close]
        guard inner.contains("-->") else { return nil }
        return line[line.index(after: close)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func shouldIgnore(_ line: String) -> Bool {
        let lower = line.lowercased()
        if lower.hasPrefix("whisper_") { return true }
        if lower.hasPrefix("system_info") { return true }
        if lower.hasPrefix("main:") { return true }
        if lower.hasPrefix("ggml_") { return true }
        if lower.contains("error:") { return true }
        if lower.hasPrefix("log_") { return true }
        return false
    }
}
