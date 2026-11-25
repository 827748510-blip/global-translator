import AppKit
import AudioToolbox
import CoreAudio
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Independent ScreenCaptureKit **audio** capture for video-translate Phase B2.
///
/// This is intentionally **not** `WindowVisualUpdates`. The pre-existing
/// visual / OCR stream keeps `capturesAudio = false`. This type starts a
/// separate SCStream, captures system and/or window audio, and never enables
/// microphone input.
public protocol SystemAudioCapturing: AnyObject, Sendable {
    var activeTarget: String? { get }
    func start(
        window: ActiveWindowDescriptor?,
        handler: @escaping @Sendable (AudioPCMChunk) -> Void
    ) async throws
    func stop()
}

public enum SystemAudioCaptureError: Error, Equatable, Sendable {
    case permissionDenied
    case unavailable
}

@available(macOS 14.0, *)
public final class ScreenCaptureKitSystemAudioCapturer: NSObject, SystemAudioCapturing, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let permissions: any PermissionControlling
    private var generation: UInt64 = 0
    private var handler: (@Sendable (AudioPCMChunk) -> Void)?
    private var activeStreamID: ObjectIdentifier?
    private var _activeTarget: String?
    public var activeTarget: String? { lock.withLock { _activeTarget } }
    private var stream: SCStream?
    private let sampleQueue = DispatchQueue(label: "GlobalTranslator.systemAudio", qos: .userInitiated)

    public init(permissions: any PermissionControlling = SystemPermissionController()) {
        self.permissions = permissions
        super.init()
    }

    public func start(
        window: ActiveWindowDescriptor?,
        handler: @escaping @Sendable (AudioPCMChunk) -> Void
    ) async throws {
        stop()
        let snapshot = permissions.snapshot
        guard !snapshot.sessionLocked, !snapshot.secureInputEnabled else {
            throw SystemAudioCaptureError.unavailable
        }
        guard snapshot.screenCaptureAuthorized else {
            throw SystemAudioCaptureError.permissionDenied
        }
        guard let window else {
            throw SystemAudioCaptureError.unavailable
        }
        let token = lock.withLock { generation }
        lock.withLock { self.handler = handler }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard lock.withLock({ generation == token }) else { return }
            let postSnapshot = permissions.snapshot
            guard !postSnapshot.sessionLocked, !postSnapshot.secureInputEnabled else {
                throw SystemAudioCaptureError.unavailable
            }
            guard let filter = Self.windowFilter(window, content: content) else {
                throw SystemAudioCaptureError.unavailable
            }
            try await startStream(filter: filter, target: "window", token: token)
        } catch let error as SystemAudioCaptureError {
            throw error
        } catch {
            throw SystemAudioCaptureError.permissionDenied
        }
    }

    public func stop() {
        let old: SCStream? = lock.withLock {
            generation &+= 1
            handler = nil
            activeStreamID = nil
            _activeTarget = nil
            let previous = stream
            stream = nil
            return previous
        }
        if let old {
            Task { try? await old.stopCapture() }
        }
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        let snapshot = permissions.snapshot
        if snapshot.sessionLocked || snapshot.secureInputEnabled {
            stop()
            return
        }
        let token = lock.withLock { generation }
        guard lock.withLock({ activeStreamID == ObjectIdentifier(stream) && generation == token }) else { return }
        guard let pcm = Self.pcm16Mono16k(from: sampleBuffer), !pcm.isEmpty else { return }
        let chunk = AudioPCMChunk(pcm16Mono16k: AudioPCM.data(from: pcm), startedAt: Date())
        let currentHandler = lock.withLock { self.handler }
        currentHandler?(chunk)
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        _ = error
        stop()
    }

    private func startStream(filter: SCContentFilter, target: String, token: UInt64) async throws {
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.showsCursor = false
        configuration.queueDepth = 8
        configuration.sampleRate = AudioPCM.whisperSampleRate
        configuration.channelCount = 1
        if #available(macOS 15.0, *) {
            configuration.captureMicrophone = false
        }
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        // Some macOS builds refuse an audio-only stream; keep a discarded
        // 2×2 video output on THIS independent stream only.
        try? stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        let armed = lock.withLock { () -> Bool in
            guard generation == token else { return false }
            self.stream = stream
            activeStreamID = ObjectIdentifier(stream)
            _activeTarget = target
            return true
        }
        guard armed else { return }
        try await stream.startCapture()
        if !lock.withLock({ generation == token }) {
            try? await stream.stopCapture()
        }
    }

    private static func windowFilter(_ descriptor: ActiveWindowDescriptor, content: SCShareableContent) -> SCContentFilter? {
        guard let screen = NSScreen.screens.first else { return nil }
        guard let window = content.windows.first(where: {
            ScreenCaptureKitWindowCapturer.matches(
                candidateProcessID: Int32($0.owningApplication?.processID ?? -1),
                candidateWindowID: $0.windowID,
                candidateFrame: $0.frame,
                descriptor: descriptor,
                primaryDisplayFrame: screen.frame
            )
        }) else { return nil }
        return SCContentFilter(desktopIndependentWindow: window)
    }

    private static func displayFilter(_ content: SCShareableContent) -> SCContentFilter? {
        guard let display = content.displays.first else { return nil }
        let ownPID = pid_t(ProcessInfo.processInfo.processIdentifier)
        let ownApps = content.applications.filter { $0.processID == ownPID }
        return SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
    }

    static func pcm16Mono16k(from sampleBuffer: CMSampleBuffer) -> [Int16]? {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(format) else {
            return nil
        }
        let asbd = asbdPointer.pointee
        guard asbd.mFormatID == kAudioFormatLinearPCM else { return nil }
        let channels = Int(asbd.mChannelsPerFrame)
        let sampleRate = Int(asbd.mSampleRate.rounded())
        guard channels > 0, sampleRate > 0 else { return nil }

        var sizeNeeded = 0
        var unused: CMBlockBuffer?
        _ = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &sizeNeeded,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            blockBufferOut: &unused
        )
        guard sizeNeeded >= MemoryLayout<AudioBufferList>.size else { return nil }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: sizeNeeded, alignment: 16)
        defer { raw.deallocate() }
        let abl = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: abl,
            bufferListSize: sizeNeeded,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return nil }

        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isSignedInt = (asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0

        let mono: [Int16]? = withExtendedLifetime(blockBuffer) {
            let list = UnsafeMutableAudioBufferListPointer(abl)
            if isFloat && asbd.mBitsPerChannel == 32 && isNonInterleaved {
                var planes: [[Float]] = []
                for buffer in list {
                    let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                    guard let data = buffer.mData, count > 0 else { continue }
                    let pointer = data.bindMemory(to: Float.self, capacity: count)
                    planes.append(Array(UnsafeBufferPointer(start: pointer, count: count)))
                }
                return AudioPCM.mixPlanarToMonoInt16(channels: planes)
            } else if isFloat && asbd.mBitsPerChannel == 32 {
                guard let buffer = list.first, let data = buffer.mData else { return nil }
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                guard count > 0 else { return nil }
                let pointer = data.bindMemory(to: Float.self, capacity: count)
                let floats = Array(UnsafeBufferPointer(start: pointer, count: count))
                return AudioPCM.mixToMonoInt16(floatSamples: floats, channels: max(channels, 1))
            } else if isSignedInt && asbd.mBitsPerChannel == 16 && isNonInterleaved {
                var planes: [[Int16]] = []
                for buffer in list {
                    let count = Int(buffer.mDataByteSize) / MemoryLayout<Int16>.size
                    guard let data = buffer.mData, count > 0 else { continue }
                    let pointer = data.bindMemory(to: Int16.self, capacity: count)
                    planes.append(Array(UnsafeBufferPointer(start: pointer, count: count)))
                }
                guard let first = planes.first, !first.isEmpty else { return nil }
                let frames = first.count
                var mixed = [Int16](repeating: 0, count: frames)
                for frame in 0..<frames {
                    var sum = 0
                    for plane in planes where frame < plane.count {
                        sum += Int(plane[frame])
                    }
                    mixed[frame] = Int16(clamping: sum / max(planes.count, 1))
                }
                return mixed
            } else if isSignedInt && asbd.mBitsPerChannel == 16 {
                guard let buffer = list.first, let data = buffer.mData else { return nil }
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Int16>.size
                guard count > 0 else { return nil }
                let pointer = data.bindMemory(to: Int16.self, capacity: count)
                let samples = Array(UnsafeBufferPointer(start: pointer, count: count))
                if channels <= 1 {
                    return samples
                }
                let frames = samples.count / channels
                var mixed = [Int16](repeating: 0, count: frames)
                for frame in 0..<frames {
                    var sum = 0
                    for channel in 0..<channels {
                        sum += Int(samples[frame * channels + channel])
                    }
                    mixed[frame] = Int16(clamping: sum / channels)
                }
                return mixed
            }
            return nil
        }
        guard let mono, !mono.isEmpty else { return nil }
        return AudioPCM.resampleLinear(samples: mono, fromRate: sampleRate, toRate: AudioPCM.whisperSampleRate)
    }
}
