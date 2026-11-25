import Darwin
import Foundation
import os

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
    private static let maximumCapturedBytes = 1_048_576

    private final class CancellationState: @unchecked Sendable {
        struct State: Sendable {
            var process: Process?
            var cancelled = false
        }
        private let state = OSAllocatedUnfairLock(initialState: State())

        func attach(_ process: Process) -> Bool {
            state.withLock { current in
                if current.cancelled { return false }
                current.process = process
                return true
            }
        }

        func cancel() {
            let proc = state.withLock { current -> Process? in
                current.cancelled = true
                return current.process
            }
            if let proc, proc.isRunning {
                proc.terminate()
            }
        }

        var isCancelled: Bool { state.withLock { $0.cancelled } }

        func detach() {
            state.withLock { $0.process = nil }
        }
    }

    private final class BoundedPipeBuffer: @unchecked Sendable {
        private let limit: Int
        private let storage = OSAllocatedUnfairLock(initialState: Data())

        init(limit: Int) {
            self.limit = limit
        }

        func append(_ chunk: Data) {
            guard !chunk.isEmpty else { return }
            storage.withLock { buffer in
                guard buffer.count < limit else { return }
                let remaining = limit - buffer.count
                buffer.append(chunk.prefix(remaining))
            }
        }

        var data: Data {
            storage.withLock { $0 }
        }
    }

    public init() {}

    public func run(binary: URL, arguments: [String], timeout: TimeInterval) async throws -> String {
        let cancelState = CancellationState()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do {
                        let output = try Self.launch(
                            binary: binary,
                            arguments: arguments,
                            timeout: timeout,
                            cancelState: cancelState
                        )
                        continuation.resume(returning: output)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancelState.cancel()
        }
    }

    private static func sanitizedEnvironment() -> [String: String] {
        let current = ProcessInfo.processInfo.environment
        var env: [String: String] = [
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        ]
        for key in ["HOME", "TMPDIR", "LANG", "LC_ALL"] {
            if let value = current[key], !value.isEmpty {
                env[key] = value
            }
        }
        return env
    }

    private static func launch(
        binary: URL,
        arguments: [String],
        timeout: TimeInterval,
        cancelState: CancellationState
    ) throws -> String {
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        process.environment = sanitizedEnvironment()
        let stdout = Pipe()
        let stderr = Pipe()
        let outBuffer = BoundedPipeBuffer(limit: maximumCapturedBytes)
        let errBuffer = BoundedPipeBuffer(limit: maximumCapturedBytes)
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
            } else {
                outBuffer.append(chunk)
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
            } else {
                errBuffer.append(chunk)
            }
        }
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        defer {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            cancelState.detach()
        }
        guard cancelState.attach(process) else {
            throw CancellationError()
        }
        try process.run()
        let deadline = Date().addingTimeInterval(max(timeout, 1))
        while process.isRunning && !cancelState.isCancelled && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            throw cancelState.isCancelled ? CancellationError() : WhisperTranscribeError.failed
        }
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        outBuffer.append(stdout.fileHandleForReading.readDataToEndOfFile())
        errBuffer.append(stderr.fileHandleForReading.readDataToEndOfFile())
        if cancelState.isCancelled {
            throw CancellationError()
        }
        let text = String(data: outBuffer.data, encoding: .utf8) ?? ""
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        let fallback = String(data: errBuffer.data, encoding: .utf8) ?? ""
        if process.terminationStatus == 0 {
            return fallback
        }
        throw WhisperTranscribeError.failed
    }
}

public final class WhisperCppTranscriber: SpeechTranscribing, @unchecked Sendable {
    private struct ExecutionGateState {
        var active = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let locate: @Sendable () -> WhisperCppLocator
    private let runner: any WhisperProcessRunning
    private let scratchDirectory: URL
    private let fileManager: FileManager
    private let timeout: TimeInterval
    private let executionGate = OSAllocatedUnfairLock(initialState: ExecutionGateState())

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
        try await acquireExecutionGate()
        defer { releaseExecutionGate() }
        try Task.checkCancellation()

        let locator = locate()
        guard let binary = locator.binaryURL, let model = locator.modelURL else {
            throw WhisperTranscribeError.unavailable
        }
        let samples = AudioPCM.int16Array(from: pcm16Mono16k)
        let duration = Double(samples.count) / Double(AudioPCM.whisperSampleRate)
        try prepareScratch()
        let wavURL = scratchDirectory.appendingPathComponent("chunk-\(UUID().uuidString).wav", isDirectory: false)
        defer { try? fileManager.removeItem(at: wavURL) }
        let wav = AudioPCM.wavData(pcm16Mono: samples)
        try writeRestrictedWAV(wav, to: wavURL.path)
        let raw = try await runner.run(
            binary: binary,
            arguments: ["-m", model.path, "-f", wavURL.path, "-l", "en", "-nt", "-np"],
            timeout: timeout
        )
        let text = Self.parseTranscript(raw)
        guard !text.isEmpty else { throw WhisperTranscribeError.failed }
        return WhisperTranscript(text: text, duration: duration)
    }

    private func acquireExecutionGate() async throws {
        try Task.checkCancellation()
        let acquired = executionGate.withLock { current -> Bool in
            if current.active { return false }
            current.active = true
            return true
        }
        if !acquired {
            await withCheckedContinuation { continuation in
                let resumeNow = executionGate.withLock { current -> Bool in
                    if current.active {
                        current.waiters.append(continuation)
                        return false
                    }
                    current.active = true
                    return true
                }
                if resumeNow { continuation.resume() }
            }
        }
    }

    private func releaseExecutionGate() {
        let next = executionGate.withLock { current -> CheckedContinuation<Void, Never>? in
            guard !current.waiters.isEmpty else {
                current.active = false
                return nil
            }
            return current.waiters.removeFirst()
        }
        next?.resume()
    }

    private func writeRestrictedWAV(_ data: Data, to path: String) throws {
        var existing = Darwin.stat()
        if Darwin.lstat(path, &existing) == 0 {
            throw WhisperTranscribeError.failed
        }
        let fd = Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else {
            throw WhisperTranscribeError.failed
        }
        defer { Darwin.close(fd) }
        guard Darwin.fchmod(fd, 0o600) == 0 else {
            throw WhisperTranscribeError.failed
        }
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var written = 0
            while written < rawBuffer.count {
                let n = Darwin.write(fd, base.advanced(by: written), rawBuffer.count - written)
                if n > 0 {
                    written += n
                } else if n < 0 && Darwin.errno == EINTR {
                    continue
                } else {
                    throw WhisperTranscribeError.failed
                }
            }
        }
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
        var existing = Darwin.stat()
        if Darwin.lstat(scratchDirectory.path, &existing) == 0 {
            guard (existing.st_mode & S_IFMT) == S_IFDIR else {
                throw WhisperTranscribeError.failed
            }
        } else {
            try fileManager.createDirectory(
                at: scratchDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
            var created = Darwin.stat()
            guard Darwin.lstat(scratchDirectory.path, &created) == 0,
                  (created.st_mode & S_IFMT) == S_IFDIR else {
                throw WhisperTranscribeError.failed
            }
        }
        _ = Darwin.chmod(scratchDirectory.path, 0o700)
        // Clean up any stale chunk WAVs left by crashed runs.
        if let entries = try? fileManager.contentsOfDirectory(at: scratchDirectory, includingPropertiesForKeys: nil) {
            for entry in entries where entry.lastPathComponent.hasPrefix("chunk-") && entry.pathExtension == "wav" {
                try? fileManager.removeItem(at: entry)
            }
        }
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
