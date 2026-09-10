import Foundation
import GlobalTranslatorCore

public enum VideoASRStatus: String, Codable, Equatable, Sendable {
    case idle
    case running
    case denied
    case whisperMissing = "whisper_missing"
    case error
}

public enum VideoASRMessages {
    public static let denied = "系统音频未授权（请在屏幕录制中允许）"
    public static let whisperMissing = "未安装本地 Whisper 模型"
    public static let error = "语音转写暂时不可用"
}

public struct VideoASRCue: Equatable, Sendable {
    public let seq: Int
    public let text: String
    public let durationMs: Int

    public init(seq: Int, text: String, durationMs: Int) {
        self.seq = seq
        self.text = text
        self.durationMs = durationMs
    }
}

public struct VideoASRSnapshot: Equatable, Sendable {
    public var enabled: Bool
    public var needed: Bool
    public var running: Bool
    public var status: VideoASRStatus
    public var message: String
    public var target: String?
    public var cues: [VideoASRCue]

    public init(
        enabled: Bool = false,
        needed: Bool = false,
        running: Bool = false,
        status: VideoASRStatus = .idle,
        message: String = "",
        target: String? = nil,
        cues: [VideoASRCue] = []
    ) {
        self.enabled = enabled
        self.needed = needed
        self.running = running
        self.status = status
        self.message = message
        self.target = target
        self.cues = cues
    }

    public static let idle = VideoASRSnapshot()

    public func jsonObject() -> [String: Any] {
        [
            "ok": true,
            "enabled": enabled,
            "needed": needed,
            "running": running,
            "status": status.rawValue,
            "message": message,
            "target": target as Any? ?? NSNull(),
            "cues": cues.map { cue in
                [
                    "seq": cue.seq,
                    "text": cue.text,
                    "durationMs": cue.durationMs
                ]
            }
        ]
    }
}

public enum VideoASRTiming {
    public static let windowSeconds = 3.0
    public static let overlapSeconds = 0.4
    public static let silenceRMS = 0.01
}

/// Feature-flagged B2 coordinator: menu-bar 视频翻译 must be on **and** the
/// extension must report that no usable foreign caption track exists.
/// Capture / Whisper failures become overlay messages; they never pause media.
public final class VideoAudioASRController: @unchecked Sendable {
    public typealias EventSink = @Sendable (String, [String: String]) -> Void
    public typealias WindowProvider = @Sendable () async -> ActiveWindowDescriptor?

    private let permissions: any PermissionControlling
    private let locate: @Sendable () -> WhisperCppLocator
    private let capturer: any SystemAudioCapturing
    private let transcriber: any SpeechTranscribing
    private let windowProvider: WindowProvider
    private let onEvent: EventSink

    private let lock = NSLock()
    private var enabled = false
    private var needed = false
    private var running = false
    private var status: VideoASRStatus = .idle
    private var message = ""
    private var cues: [VideoASRCue] = []
    private var seq = 0
    private var lastText = ""
    private var generation: UInt64 = 0
    private var pcmBuffer: [Int16] = []
    private var transcribing = false
    private var pendingWindow: [Int16]?
    private var startTask: Task<Void, Never>?
    private var lastAttempt: Date?
    private var starting = false

    public init(
        permissions: any PermissionControlling,
        locate: @escaping @Sendable () -> WhisperCppLocator,
        capturer: any SystemAudioCapturing,
        transcriber: any SpeechTranscribing,
        windowProvider: @escaping WindowProvider = { nil },
        onEvent: @escaping EventSink = { _, _ in }
    ) {
        self.permissions = permissions
        self.locate = locate
        self.capturer = capturer
        self.transcriber = transcriber
        self.windowProvider = windowProvider
        self.onEvent = onEvent
    }

    public func snapshot() -> VideoASRSnapshot {
        lock.withLock {
            VideoASRSnapshot(
                enabled: enabled,
                needed: needed,
                running: running,
                status: status,
                message: message,
                target: capturer.activeTarget,
                cues: cues
            )
        }
    }

    public func setVideoTranslateEnabled(_ enabled: Bool) {
        lock.withLock {
            self.enabled = enabled
            if !enabled {
                self.needed = false
            } else {
                status = .idle
                message = ""
                lastAttempt = nil
            }
        }
        reconcile()
    }

    public func setCaptionsNeeded(_ needed: Bool) {
        lock.withLock {
            let previous = self.needed
            self.needed = needed
            if needed && !previous {
                status = .idle
                message = ""
                lastAttempt = nil
            }
        }
        reconcile()
    }

    public func stop() {
        lock.withLock {
            enabled = false
            needed = false
        }
        stopCapture(status: .idle, message: "")
    }

    private func reconcile() {
        let shouldRun = lock.withLock { enabled && needed }
        if shouldRun {
            startIfNeeded()
        } else {
            stopCapture(status: .idle, message: "")
        }
    }

    private func startIfNeeded() {
        if lock.withLock({ running || starting }) { return }
        let statusNow = lock.withLock { status }
        if statusNow == .denied || statusNow == .whisperMissing || statusNow == .error {
            let last = lock.withLock { lastAttempt } ?? .distantPast
            if Date().timeIntervalSince(last) < 15 { return }
        }
        let token = lock.withLock { () -> UInt64 in
            starting = true
            return generation
        }
        startTask = Task { [weak self] in
            await self?.begin(token: token)
        }
    }

    private func begin(token: UInt64) async {
        defer { lock.withLock { if generation == token { starting = false } } }
        guard lock.withLock({ generation == token && enabled && needed && !running }) else { return }
        lock.withLock { lastAttempt = Date() }
        let snapshot = permissions.snapshot
        if snapshot.sessionLocked || snapshot.secureInputEnabled {
            apply(status: .error, message: VideoASRMessages.error, running: false)
            onEvent("video_asr_failed", ["kind": "protected"])
            return
        }
        if !snapshot.screenCaptureAuthorized {
            apply(status: .denied, message: VideoASRMessages.denied, running: false)
            onEvent("video_asr_denied", ["reason": "screen_capture"])
            return
        }
        if !locate().isAvailable || !transcriber.isAvailable {
            apply(status: .whisperMissing, message: VideoASRMessages.whisperMissing, running: false)
            onEvent("video_asr_whisper_missing", [:])
            return
        }
        apply(status: .running, message: "", running: false)
        let window = await windowProvider()
        do {
            try await capturer.start(window: window) { [weak self] chunk in
                self?.ingest(chunk, token: token)
            }
            guard lock.withLock({ generation == token && enabled && needed }) else {
                capturer.stop()
                return
            }
            lock.withLock { running = true }
            apply(status: .running, message: "", running: true)
            onEvent("video_asr_start", ["target": capturer.activeTarget ?? "unknown"])
        } catch SystemAudioCaptureError.permissionDenied {
            apply(status: .denied, message: VideoASRMessages.denied, running: false)
            onEvent("video_asr_denied", ["reason": "sck"])
        } catch {
            apply(status: .error, message: VideoASRMessages.error, running: false)
            onEvent("video_asr_failed", ["kind": "sck"])
        }
    }

    private func stopCapture(status: VideoASRStatus, message: String) {
        let wasRunning = lock.withLock { () -> Bool in
            let runningNow = running
            generation &+= 1
            running = false
            starting = false
            transcribing = false
            pendingWindow = nil
            pcmBuffer.removeAll(keepingCapacity: true)
            cues.removeAll()
            lastText = ""
            return runningNow
        }
        startTask?.cancel()
        startTask = nil
        capturer.stop()
        apply(status: status, message: message, running: false)
        if wasRunning {
            onEvent("video_asr_stop", [:])
        }
    }

    private func ingest(_ chunk: AudioPCMChunk, token: UInt64) {
        let samples = AudioPCM.int16Array(from: chunk.pcm16Mono16k)
        guard !samples.isEmpty else { return }
        var windowToRun: [Int16]?
        lock.lock()
        defer { lock.unlock() }
        guard generation == token, enabled, needed else { return }
        pcmBuffer.append(contentsOf: samples)
        let windowCount = Int(VideoASRTiming.windowSeconds * Double(AudioPCM.whisperSampleRate))
        let hop = Int((VideoASRTiming.windowSeconds - VideoASRTiming.overlapSeconds) * Double(AudioPCM.whisperSampleRate))
        if pcmBuffer.count >= windowCount {
            let window = Array(pcmBuffer.prefix(windowCount))
            if pcmBuffer.count > hop {
                pcmBuffer.removeFirst(hop)
            } else {
                pcmBuffer.removeAll(keepingCapacity: true)
            }
            if transcribing {
                pendingWindow = window
            } else {
                transcribing = true
                windowToRun = window
            }
        }
        if let windowToRun {
            Task { await self.transcribe(windowToRun, token: token) }
        }
    }

    private func transcribe(_ samples: [Int16], token: UInt64) async {
        defer {
            var next: [Int16]?
            lock.lock()
            transcribing = false
            if generation == token, let pending = pendingWindow {
                pendingWindow = nil
                transcribing = true
                next = pending
            }
            lock.unlock()
            if let next {
                Task { await self.transcribe(next, token: token) }
            }
        }
        guard lock.withLock({ generation == token && enabled && needed }) else { return }
        if AudioPCM.isSilent(samples, threshold: VideoASRTiming.silenceRMS) {
            return
        }
        do {
            let transcript = try await transcriber.transcribeEnglish(pcm16Mono16k: AudioPCM.data(from: samples))
            let text = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count >= 2 else { return }
            guard lock.withLock({ generation == token && enabled && needed }) else { return }
            if lock.withLock({ lastText == text }) { return }
            let durationMs = max(1200, Int((transcript.duration * 1000).rounded()))
            lock.lock()
            seq += 1
            lastText = text
            cues.append(VideoASRCue(seq: seq, text: text, durationMs: durationMs))
            if cues.count > 6 {
                cues.removeFirst(cues.count - 6)
            }
            lock.unlock()
            onEvent("video_asr_transcribe", [
                "chars": String(text.count),
                "ms": String(durationMs)
            ])
        } catch WhisperTranscribeError.unavailable {
            apply(status: .whisperMissing, message: VideoASRMessages.whisperMissing, running: lock.withLock { running })
            onEvent("video_asr_whisper_missing", [:])
        } catch {
            onEvent("video_asr_failed", ["kind": "whisper"])
        }
    }

    private func apply(status: VideoASRStatus, message: String, running: Bool) {
        lock.withLock {
            self.status = status
            self.message = message
            self.running = running
        }
    }
}
