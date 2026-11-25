import Foundation
import os
import Testing
@testable import GlobalTranslatorCapture
import GlobalTranslatorCore

struct AudioPCMTests {
    @Test
    func wavHeaderIsPcmMono16k() {
        let samples: [Int16] = [0, 1, -1, 32767]
        let wav = AudioPCM.wavData(pcm16Mono: samples, sampleRate: 16_000)
        #expect(Array(wav[0..<4]) == Array("RIFF".utf8))
        #expect(Array(wav[8..<12]) == Array("WAVE".utf8))
        #expect(Array(wav[12..<16]) == Array("fmt ".utf8))
        #expect(wav.count == 44 + samples.count * 2)
        let roundTrip = AudioPCM.int16Array(from: AudioPCM.data(from: samples))
        #expect(roundTrip == samples)
    }

    @Test
    func stereoFloatMixesToMono() {
        let mixed = AudioPCM.mixToMonoInt16(floatSamples: [1, -1, 0.5, 0.5], channels: 2)
        #expect(mixed.count == 2)
        #expect(mixed[0] == 0)
        #expect(mixed[1] > 0)
    }

    @Test
    func resampleHalvesSampleCount() {
        let input = (0..<16).map { Int16($0 * 100) }
        let output = AudioPCM.resampleLinear(samples: input, fromRate: 32_000, toRate: 16_000)
        #expect(output.count == 8)
    }

    @Test
    func silenceDetectorUsesRms() {
        let quiet = [Int16](repeating: 0, count: 1600)
        #expect(AudioPCM.isSilent(quiet))
        let loud = [Int16](repeating: 8000, count: 1600)
        #expect(!AudioPCM.isSilent(loud))
    }

    @Test
    func wavDataFromRawPCMDataMatchesInt16Overload() {
        let samples: [Int16] = [0, 123, -456, 32767, -32768]
        let raw = AudioPCM.data(from: samples)
        #expect(AudioPCM.wavData(pcm16MonoData: raw) == AudioPCM.wavData(pcm16Mono: samples))
    }
}

struct WhisperCppTranscriberTests {
    @Test
    func parseDropsGgmlNoiseAndKeepsSpeech() {
        let raw = """
        whisper_init_from_file_with_params
        [00:00:00.000 --> 00:00:02.000] Hello from the speaker
        ggml_metal_init
        """
        #expect(WhisperCppTranscriber.parseTranscript(raw) == "Hello from the speaker")
    }

    @Test
    func transcribeWritesScratchThenDeletes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gt-whisper-\(UUID().uuidString)")
        let binary = root.appendingPathComponent("whisper-cli")
        let model = root.appendingPathComponent("ggml-tiny.en.bin")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: binary.path, contents: Data())
        FileManager.default.createFile(atPath: model.path, contents: Data())
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: binary.path
        )
        let runner = ScriptedWhisperRunner(output: "Hello there")
        let transcriber = WhisperCppTranscriber(
            locate: { WhisperCppLocator(binaryURL: binary, modelURL: model) },
            scratchDirectory: root.appendingPathComponent("scratch"),
            runner: runner
        )
        let pcm = AudioPCM.data(from: [Int16](repeating: 400, count: 1600))
        let result = try await transcriber.transcribeEnglish(pcm16Mono16k: pcm)
        #expect(result.text == "Hello there")
        #expect(runner.arguments.contains("-l"))
        #expect(runner.arguments.contains("en"))
        let leftover = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("scratch").path)
        #expect(leftover.filter { $0.hasSuffix(".wav") }.isEmpty)
    }

    @Test
    func missingBinaryIsUnavailable() async {
        let transcriber = WhisperCppTranscriber(
            locate: { WhisperCppLocator(binaryURL: nil, modelURL: nil) },
            scratchDirectory: FileManager.default.temporaryDirectory
        )
        #expect(!transcriber.isAvailable)
        await #expect(throws: WhisperTranscribeError.unavailable) {
            _ = try await transcriber.transcribeEnglish(pcm16Mono16k: Data([0, 0]))
        }
    }
}

private final class ScriptedWhisperRunner: WhisperProcessRunning, @unchecked Sendable {
    let output: String
    private(set) var arguments: [String] = []

    init(output: String) { self.output = output }

    func run(binary: URL, arguments: [String], timeout: TimeInterval) async throws -> String {
        self.arguments = arguments
        return output
    }
}

struct VideoAudioASRControllerTests {
    @Test
    func staysIdleUnlessToggleAndCaptionsNeeded() async {
        let capturer = MockSystemAudioCapturer()
        let controller = VideoAudioASRController(
            permissions: FakePermissionController(snapshot: .allGranted),
            locate: { WhisperCppLocator(binaryURL: URL(fileURLWithPath: "/bin/echo"), modelURL: URL(fileURLWithPath: "/tmp/model.bin")) },
            capturer: capturer,
            transcriber: MockWhisper(available: true, text: "Hello from the speaker")
        )
        controller.setCaptionsNeeded(true)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(!controller.snapshot().running)
        #expect(capturer.startCount == 0)
        controller.setVideoTranslateEnabled(true)
        controller.setCaptionsNeeded(false)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(capturer.startCount == 0)
    }

    @Test
    func startStopAndCueFromMockedAudio() async {
        let capturer = MockSystemAudioCapturer()
        let whisper = MockWhisper(available: true, text: "Hello from the speaker")
        let events = RecordingASREvents()
        let controller = VideoAudioASRController(
            permissions: FakePermissionController(snapshot: .allGranted),
            locate: { WhisperCppLocator(binaryURL: URL(fileURLWithPath: "/bin/echo"), modelURL: URL(fileURLWithPath: "/tmp/model.bin")) },
            capturer: capturer,
            transcriber: whisper,
            windowProvider: {
                ActiveWindowDescriptor(
                    pid: 42,
                    bundleIdentifier: "com.google.Chrome",
                    windowID: 1,
                    frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                    revision: 1
                )
            },
            onEvent: { code, fields in events.append(code, fields) }
        )
        controller.setVideoTranslateEnabled(true)
        controller.setCaptionsNeeded(true)
        try? await Task.sleep(for: .milliseconds(80))
        #expect(capturer.startCount == 1)
        #expect(controller.snapshot().status == .running)
        capturer.emit(sineChunk(seconds: 3.2))
        try? await Task.sleep(for: .milliseconds(120))
        #expect(controller.snapshot().cues.first?.text == "Hello from the speaker")
        #expect(events.codes.contains("video_asr_start"))
        #expect(events.codes.contains("video_asr_transcribe"))
        #expect(events.fields.contains { $0["chars"] != nil && $0["text"] == nil })
        controller.setVideoTranslateEnabled(false)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(capturer.stopCount >= 1)
        #expect(!controller.snapshot().running)
        #expect(controller.snapshot().cues.isEmpty)
    }

    @Test
    func screenRecordingDeniedDoesNotStartCapture() async {
        let capturer = MockSystemAudioCapturer()
        let controller = VideoAudioASRController(
            permissions: FakePermissionController(snapshot: PermissionSnapshot(
                accessibilityTrusted: true,
                screenCaptureAuthorized: false,
                secureInputEnabled: false,
                sessionLocked: false
            )),
            locate: { WhisperCppLocator(binaryURL: URL(fileURLWithPath: "/bin/echo"), modelURL: URL(fileURLWithPath: "/tmp/model.bin")) },
            capturer: capturer,
            transcriber: MockWhisper(available: true, text: "Hello")
        )
        controller.setVideoTranslateEnabled(true)
        controller.setCaptionsNeeded(true)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(capturer.startCount == 0)
        #expect(controller.snapshot().status == .denied)
        #expect(controller.snapshot().message == VideoASRMessages.denied)
    }

    @Test
    func missingWhisperDoesNotCapture() async {
        let capturer = MockSystemAudioCapturer()
        let controller = VideoAudioASRController(
            permissions: FakePermissionController(snapshot: .allGranted),
            locate: { WhisperCppLocator(binaryURL: nil, modelURL: nil) },
            capturer: capturer,
            transcriber: MockWhisper(available: false, text: "Hello")
        )
        controller.setVideoTranslateEnabled(true)
        controller.setCaptionsNeeded(true)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(capturer.startCount == 0)
        #expect(controller.snapshot().status == .whisperMissing)
        #expect(controller.snapshot().message == VideoASRMessages.whisperMissing)
    }

    @Test
    func captureStartFailureIsMessageNotThrow() async {
        let capturer = MockSystemAudioCapturer()
        capturer.startError = SystemAudioCaptureError.permissionDenied
        let controller = VideoAudioASRController(
            permissions: FakePermissionController(snapshot: .allGranted),
            locate: { WhisperCppLocator(binaryURL: URL(fileURLWithPath: "/bin/echo"), modelURL: URL(fileURLWithPath: "/tmp/model.bin")) },
            capturer: capturer,
            transcriber: MockWhisper(available: true, text: "Hello"),
            windowProvider: {
                ActiveWindowDescriptor(
                    pid: 42,
                    bundleIdentifier: "com.google.Chrome",
                    windowID: 1,
                    frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                    revision: 1
                )
            }
        )
        controller.setVideoTranslateEnabled(true)
        controller.setCaptionsNeeded(true)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(controller.snapshot().status == .denied)
        #expect(!controller.snapshot().running)
    }

    @Test
    func missingTargetWindowFailsClosedWithoutCapturing() async {
        let capturer = MockSystemAudioCapturer()
        let controller = VideoAudioASRController(
            permissions: FakePermissionController(snapshot: .allGranted),
            locate: { WhisperCppLocator(binaryURL: URL(fileURLWithPath: "/bin/echo"), modelURL: URL(fileURLWithPath: "/tmp/model.bin")) },
            capturer: capturer,
            transcriber: MockWhisper(available: true, text: "Hello"),
            windowProvider: { nil }
        )
        controller.setVideoTranslateEnabled(true)
        controller.setCaptionsNeeded(true)
        try? await Task.sleep(for: .milliseconds(60))
        #expect(capturer.startCount == 0)
        #expect(!controller.snapshot().running)
    }

    @Test
    func sessionLockOrSecureInputStopsRunningASRAndClearsCues() async {
        let protectedFlag = OSAllocatedUnfairLock(initialState: false)
        let perms = SystemPermissionController(snapshotProvider: {
            let blocked = protectedFlag.withLock { $0 }
            return PermissionSnapshot(
                accessibilityTrusted: true,
                screenCaptureAuthorized: true,
                secureInputEnabled: blocked,
                sessionLocked: false
            )
        })
        let capturer = MockSystemAudioCapturer()
        let controller = VideoAudioASRController(
            permissions: perms,
            locate: { WhisperCppLocator(binaryURL: URL(fileURLWithPath: "/bin/echo"), modelURL: URL(fileURLWithPath: "/tmp/model.bin")) },
            capturer: capturer,
            transcriber: MockWhisper(available: true, text: "Secret speech"),
            windowProvider: {
                ActiveWindowDescriptor(
                    pid: 42,
                    bundleIdentifier: "com.google.Chrome",
                    windowID: 1,
                    frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                    revision: 1
                )
            }
        )
        controller.setVideoTranslateEnabled(true)
        controller.setCaptionsNeeded(true)
        try? await Task.sleep(for: .milliseconds(60))
        #expect(controller.snapshot().running)
        capturer.emit(sineChunk(seconds: 3.2))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!controller.snapshot().cues.isEmpty)

        protectedFlag.withLock { $0 = true }
        let protectedSnap = controller.snapshot()
        #expect(!protectedSnap.running)
        #expect(protectedSnap.cues.isEmpty)
        #expect(capturer.stopCount >= 1)
    }
}

final class MockSystemAudioCapturer: SystemAudioCapturing, @unchecked Sendable {
    var startCount = 0
    var stopCount = 0
    var startError: Error?
    var activeTarget: String? = "display"
    private var handler: (@Sendable (AudioPCMChunk) -> Void)?

    func start(window: ActiveWindowDescriptor?, handler: @escaping @Sendable (AudioPCMChunk) -> Void) async throws {
        if let startError { throw startError }
        startCount += 1
        self.handler = handler
        activeTarget = window == nil ? "display" : "window"
    }

    func stop() {
        stopCount += 1
        handler = nil
    }

    func emit(_ chunk: AudioPCMChunk) {
        handler?(chunk)
    }
}

struct MockWhisper: SpeechTranscribing, Sendable {
    let available: Bool
    let text: String
    var isAvailable: Bool { available }

    func transcribeEnglish(pcm16Mono16k: Data) async throws -> WhisperTranscript {
        WhisperTranscript(text: text, duration: 2.5)
    }
}

final class RecordingASREvents: @unchecked Sendable {
    private(set) var codes: [String] = []
    private(set) var fields: [[String: String]] = []
    private let lock = NSLock()

    func append(_ code: String, _ payload: [String: String]) {
        lock.lock()
        codes.append(code)
        fields.append(payload)
        lock.unlock()
    }
}

private func sineChunk(seconds: Double) -> AudioPCMChunk {
    let count = Int(Double(AudioPCM.whisperSampleRate) * seconds)
    var samples = [Int16](repeating: 0, count: count)
    for index in 0..<count {
        let value = sin(Double(index) * 2 * Double.pi * 440 / Double(AudioPCM.whisperSampleRate))
        samples[index] = Int16((value * 12000).rounded())
    }
    return AudioPCMChunk(pcm16Mono16k: AudioPCM.data(from: samples))
}
