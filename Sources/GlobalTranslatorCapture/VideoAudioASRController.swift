import Foundation
import GlobalTranslatorCore
import os

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

    /// Protects mutable ASR state. Closures passed to `withLock` are synchronous,
    /// so async start/transcribe never hold a lock across `await`.
    private struct State: Sendable {
        var enabled = false
        var needed = false
        var running = false
        var status: VideoASRStatus = .idle
        var message = ""
        var cues: [VideoASRCue] = []
        var seq = 0
        var lastText = ""
        var generation: UInt64 = 0
        var pcmBuffer: [Int16] = []
        var transcribing = false
        var pendingWindow: [Int16]?
        var lastAttempt: Date?
        var starting = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private var startTask: Task<Void, Never>?

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
        state.withLock { current in
            VideoASRSnapshot(
                enabled: current.enabled,
                needed: current.needed,
                running: current.running,
                status: current.status,
                message: current.message,
                target: capturer.activeTarget,
                cues: current.cues
            )
        }
    }

    public func setVideoTranslateEnabled(_ enabled: Bool) {
        state.withLock { current in
            current.enabled = enabled
            if !enabled {
                current.needed = false
            } else {
                current.status = .idle
                current.message = ""
                current.lastAttempt = nil
            }
        }
        reconcile()
    }

    public func setCaptionsNeeded(_ needed: Bool) {
        state.withLock { current in
            let previous = current.needed
            current.needed = needed
            if needed && !previous {
                current.status = .idle
                current.message = ""
                current.lastAttempt = nil
            }
        }
        reconcile()
    }

    public func stop() {
        state.withLock { current in
            current.enabled = false
            current.needed = false
        }
        stopCapture(status: .idle, message: "")
    }

    private func reconcile() {
        let shouldRun = state.withLock { current in
            let enabled = current.enabled
            let needed = current.needed
            return enabled && needed
        }
        if shouldRun {
            startIfNeeded()
        } else {
            stopCapture(status: .idle, message: "")
        }
    }

    private func startIfNeeded() {
        if state.withLock({ $0.running || $0.starting }) { return }
        let statusNow = state.withLock { $0.status }
        if statusNow == .denied || statusNow == .whisperMissing || statusNow == .error {
            let last = state.withLock { $0.lastAttempt } ?? .distantPast
            if Date().timeIntervalSince(last) < 15 { return }
        }
        let token = state.withLock { current -> UInt64 in
            current.starting = true
            return current.generation
        }
        startTask = Task { [weak self] in
            await self?.begin(token: token)
        }
    }

    private func begin(token: UInt64) async {
        defer {
            state.withLock { current in
                if current.generation == token { current.starting = false }
            }
        }
        guard state.withLock({ $0.generation == token && $0.enabled && $0.needed && !$0.running }) else { return }
        state.withLock { $0.lastAttempt = Date() }
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
            guard state.withLock({ $0.generation == token && $0.enabled && $0.needed }) else {
                capturer.stop()
                return
            }
            state.withLock { $0.running = true }
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
        let wasRunning = state.withLock { current -> Bool in
            let runningNow = current.running
            current.generation &+= 1
            current.running = false
            current.starting = false
            current.transcribing = false
            current.pendingWindow = nil
            current.pcmBuffer.removeAll(keepingCapacity: true)
            current.cues.removeAll()
            current.lastText = ""
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
        let windowToRun: [Int16]? = state.withLock { current in
            guard current.generation == token, current.enabled, current.needed else { return nil }
            current.pcmBuffer.append(contentsOf: samples)
            let windowCount = Int(VideoASRTiming.windowSeconds * Double(AudioPCM.whisperSampleRate))
            let hop = Int((VideoASRTiming.windowSeconds - VideoASRTiming.overlapSeconds) * Double(AudioPCM.whisperSampleRate))
            guard current.pcmBuffer.count >= windowCount else { return nil }
            let window = Array(current.pcmBuffer.prefix(windowCount))
            if current.pcmBuffer.count > hop {
                current.pcmBuffer.removeFirst(hop)
            } else {
                current.pcmBuffer.removeAll(keepingCapacity: true)
            }
            if current.transcribing {
                current.pendingWindow = window
                return nil
            }
            current.transcribing = true
            return window
        }
        if let windowToRun {
            Task { await self.transcribe(windowToRun, token: token) }
        }
    }

    private func transcribe(_ samples: [Int16], token: UInt64) async {
        defer {
            let next: [Int16]? = state.withLock { current in
                current.transcribing = false
                guard current.generation == token, let pending = current.pendingWindow else { return nil }
                current.pendingWindow = nil
                current.transcribing = true
                return pending
            }
            if let next {
                Task { await self.transcribe(next, token: token) }
            }
        }
        guard state.withLock({ $0.generation == token && $0.enabled && $0.needed }) else { return }
        if AudioPCM.isSilent(samples, threshold: VideoASRTiming.silenceRMS) {
            return
        }
        do {
            let transcript = try await transcriber.transcribeEnglish(pcm16Mono16k: AudioPCM.data(from: samples))
            let text = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count >= 2 else { return }
            guard state.withLock({ $0.generation == token && $0.enabled && $0.needed }) else { return }
            if state.withLock({ $0.lastText == text }) { return }
            let durationMs = max(1200, Int((transcript.duration * 1000).rounded()))
            state.withLock { current in
                current.seq += 1
                current.lastText = text
                current.cues.append(VideoASRCue(seq: current.seq, text: text, durationMs: durationMs))
                if current.cues.count > 6 {
                    current.cues.removeFirst(current.cues.count - 6)
                }
            }
            onEvent("video_asr_transcribe", [
                "chars": String(text.count),
                "ms": String(durationMs)
            ])
        } catch WhisperTranscribeError.unavailable {
            apply(status: .whisperMissing, message: VideoASRMessages.whisperMissing, running: state.withLock { $0.running })
            onEvent("video_asr_whisper_missing", [:])
        } catch {
            onEvent("video_asr_failed", ["kind": "whisper"])
        }
    }

    private func apply(status: VideoASRStatus, message: String, running: Bool) {
        state.withLock { current in
            current.status = status
            current.message = message
            current.running = running
        }
    }
}
