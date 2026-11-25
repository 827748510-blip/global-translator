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
            var terminated = false
        }
        private let state = OSAllocatedUnfairLock(initialState: State())
        private let semaphore = DispatchSemaphore(value: 0)

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
            semaphore.signal()
        }

        func signalTermination() {
            state.withLock { $0.terminated = true }
            semaphore.signal()
        }

        func wait(timeout: TimeInterval) {
            let alreadyDone = state.withLock { $0.cancelled || $0.terminated }
            if alreadyDone { return }
            _ = semaphore.wait(timeout: .now() + max(timeout, 1))
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

    fileprivate static func sanitizedEnvironment() -> [String: String] {
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
        process.terminationHandler = { _ in
            cancelState.signalTermination()
        }
        defer {
            process.terminationHandler = nil
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            cancelState.detach()
        }
        guard cancelState.attach(process) else {
            throw CancellationError()
        }
        try process.run()
        cancelState.wait(timeout: timeout)
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

    private struct CachedLocator: Sendable {
        var locator: WhisperCppLocator?
        var checkedAt: TimeInterval = -.infinity
    }

    private let locate: @Sendable () -> WhisperCppLocator
    private let runner: any WhisperProcessRunning
    private let scratchDirectory: URL
    private let fileManager: FileManager
    private let timeout: TimeInterval
    private let executionGate = OSAllocatedUnfairLock(initialState: ExecutionGateState())
    private let locatorCache = OSAllocatedUnfairLock(initialState: CachedLocator())
    private let scratchPrepared = OSAllocatedUnfairLock(initialState: false)
    private let persistentServer: PersistentWhisperServer?

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
        self.persistentServer = (runner is FoundationWhisperProcessRunner) ? PersistentWhisperServer() : nil
    }

    deinit {
        persistentServer?.stop()
    }

    public var isAvailable: Bool { resolvedLocator().isAvailable }

    private func resolvedLocator() -> WhisperCppLocator {
        let now = ProcessInfo.processInfo.systemUptime
        if let cached = locatorCache.withLock({ state -> WhisperCppLocator? in
            guard let locator = state.locator, locator.isAvailable, (now - state.checkedAt) < 5.0 else {
                return nil
            }
            return locator
        }) {
            return cached
        }
        let fresh = locate()
        locatorCache.withLock { state in
            state.locator = fresh
            state.checkedAt = now
        }
        return fresh
    }

    public func transcribeEnglish(pcm16Mono16k: Data) async throws -> WhisperTranscript {
        try await acquireExecutionGate()
        defer { releaseExecutionGate() }
        try Task.checkCancellation()

        let locator = resolvedLocator()
        guard let binary = locator.binaryURL, let model = locator.modelURL else {
            throw WhisperTranscribeError.unavailable
        }
        let sampleCount = pcm16Mono16k.count / 2
        let duration = Double(sampleCount) / Double(AudioPCM.whisperSampleRate)
        let wav = AudioPCM.wavData(pcm16MonoData: pcm16Mono16k)

        if let persistentServer, let serverBinary = locator.serverBinaryURL {
            do {
                let raw = try await persistentServer.transcribe(
                    wavData: wav,
                    serverBinary: serverBinary,
                    model: model,
                    timeout: timeout
                )
                let text = Self.parseTranscript(raw)
                if !text.isEmpty {
                    return WhisperTranscript(text: text, duration: duration)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Fall back to one-shot whisper-cli if persistent server fails.
            }
        }

        try ensureScratchPrepared()
        let wavURL = scratchDirectory.appendingPathComponent("chunk-\(UUID().uuidString).wav", isDirectory: false)
        defer { try? fileManager.removeItem(at: wavURL) }
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

    private func ensureScratchPrepared() throws {
        let alreadyPrepared = scratchPrepared.withLock { $0 }
        if alreadyPrepared, fileManager.fileExists(atPath: scratchDirectory.path) {
            return
        }
        try prepareScratch()
        scratchPrepared.withLock { $0 = true }
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

private final class PersistentWhisperServer: @unchecked Sendable {
    private struct State: @unchecked Sendable {
        var process: Process?
        var outHandle: FileHandle?
        var errHandle: FileHandle?
        var serverBinaryPath: String?
        var modelPath: String?
        var port: UInt16 = 0
        var idleTimer: DispatchWorkItem?
    }

    private struct InferenceJSON: Decodable {
        let text: String?
    }

    private let lock = NSLock()
    private var state = State()
    private let session: URLSession
    private let idleTimeout: TimeInterval = 45

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        self.session = URLSession(configuration: config)
    }

    deinit {
        stop()
        session.invalidateAndCancel()
    }

    func stop() {
        let (proc, outH, errH) = lock.withLock { () -> (Process?, FileHandle?, FileHandle?) in
            state.idleTimer?.cancel()
            state.idleTimer = nil
            let p = state.process
            let o = state.outHandle
            let e = state.errHandle
            state.process = nil
            state.outHandle = nil
            state.errHandle = nil
            state.serverBinaryPath = nil
            state.modelPath = nil
            state.port = 0
            return (p, o, e)
        }
        outH?.readabilityHandler = nil
        errH?.readabilityHandler = nil
        if let proc, proc.isRunning {
            proc.terminate()
        }
    }

    func transcribe(wavData: Data, serverBinary: URL, model: URL, timeout: TimeInterval) async throws -> String {
        let port = try await ensureRunning(serverBinary: serverBinary, model: model)
        scheduleIdleShutdown()
        guard let url = URL(string: "http://127.0.0.1:\(port)/inference") else {
            throw WhisperTranscribeError.failed
        }
        let boundary = "----GTWhisper-\(UUID().uuidString)"
        var body = Data(capacity: wavData.count + 512)
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"chunk.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(wavData)
        body.append(Data("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"response_format\"\r\n\r\njson\r\n--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = max(timeout, 2)
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                stop()
                throw WhisperTranscribeError.failed
            }
            scheduleIdleShutdown()
            if let decoded = try? JSONDecoder().decode(InferenceJSON.self, from: data), let text = decoded.text {
                return text
            }
            return String(decoding: data, as: UTF8.self)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            stop()
            throw error
        }
    }

    private func ensureRunning(serverBinary: URL, model: URL) async throws -> UInt16 {
        let existingPort = lock.withLock { () -> UInt16? in
            if let proc = state.process, proc.isRunning,
               state.serverBinaryPath == serverBinary.path,
               state.modelPath == model.path,
               state.port > 0 {
                return state.port
            }
            return nil
        }
        if let existingPort {
            return existingPort
        }

        stop()
        guard let port = Self.allocateFreeLoopbackPort() else {
            throw WhisperTranscribeError.failed
        }
        let process = Process()
        process.executableURL = serverBinary
        process.arguments = [
            "-m", model.path,
            "--host", "127.0.0.1",
            "--port", String(port),
            "-l", "en",
            "-nt",
            "-sns"
        ]
        process.environment = FoundationWhisperProcessRunner.sanitizedEnvironment()
        let outPipe = Pipe()
        let errPipe = Pipe()
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            if handle.availableData.isEmpty { handle.readabilityHandler = nil }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            if handle.availableData.isEmpty { handle.readabilityHandler = nil }
        }
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice
        try process.run()

        lock.withLock {
            state.process = process
            state.outHandle = outPipe.fileHandleForReading
            state.errHandle = errPipe.fileHandleForReading
            state.serverBinaryPath = serverBinary.path
            state.modelPath = model.path
            state.port = port
        }

        guard let healthURL = URL(string: "http://127.0.0.1:\(port)/") else {
            stop()
            throw WhisperTranscribeError.failed
        }
        let deadline = Date().addingTimeInterval(5.0)
        while Date() < deadline {
            try Task.checkCancellation()
            guard process.isRunning else {
                stop()
                throw WhisperTranscribeError.failed
            }
            var probe = URLRequest(url: healthURL)
            probe.timeoutInterval = 0.3
            if let (_, resp) = try? await session.data(for: probe),
               let http = resp as? HTTPURLResponse,
               (200..<500).contains(http.statusCode) {
                scheduleIdleShutdown()
                return port
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        stop()
        throw WhisperTranscribeError.failed
    }

    private func scheduleIdleShutdown() {
        lock.withLock {
            state.idleTimer?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.stop()
            }
            state.idleTimer = work
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + idleTimeout, execute: work)
        }
    }

    private static func allocateFreeLoopbackPort() -> UInt16? {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindOK = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        guard bindOK else { return nil }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameOK = withUnsafeMutablePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.getsockname(fd, sockPtr, &len) == 0
            }
        }
        guard nameOK else { return nil }
        let port = UInt16(bigEndian: addr.sin_port)
        return port > 0 ? port : nil
    }
}
