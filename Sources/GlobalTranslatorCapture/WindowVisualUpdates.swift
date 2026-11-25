import AppKit
import CoreMedia
import CoreVideo
import ScreenCaptureKit

final class WindowVisualUpdates: NSObject, SCStreamOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var sampleHistory = VisualSampleHistory()
    private var scratchSamples = [UInt16](repeating: 0, count: 64 * 64)
    private var activeStreamID: ObjectIdentifier?
    private let sampleQueue = DispatchQueue(label: "GlobalTranslator.visualChanges", qos: .utility)
    private let permissions: any PermissionControlling
    private let changed: @MainActor @Sendable () -> Void
    @MainActor private var stream: SCStream?
    @MainActor private var windowKey: String?

    init(
        permissions: any PermissionControlling = SystemPermissionController(),
        changed: @escaping @MainActor @Sendable () -> Void
    ) {
        self.permissions = permissions
        self.changed = changed
    }

    @MainActor
    func watch(_ descriptor: ActiveWindowDescriptor) async {
        let key = "\(descriptor.pid):\(descriptor.windowID ?? 0)"
        guard windowKey != key else { return }
        stop()
        let permissions = self.permissions.snapshot
        guard permissions.screenCaptureAuthorized, !permissions.secureInputEnabled, !permissions.sessionLocked else { return }
        windowKey = key
        let token = lock.withLock { generation }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard lock.withLock({ generation == token }) else { return }
            guard let screen = NSScreen.screens.first,
                  let window = content.windows.first(where: {
                      ScreenCaptureKitWindowCapturer.matches(candidateProcessID: Int32($0.owningApplication?.processID ?? -1), candidateWindowID: $0.windowID, candidateFrame: $0.frame, descriptor: descriptor, primaryDisplayFrame: screen.frame)
                  }) else { windowKey = nil; return }
            let configuration = SCStreamConfiguration()
            configuration.width = 64
            configuration.height = 64
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 4)
            configuration.queueDepth = 3
            configuration.showsCursor = false
            // Visual / OCR path only. Phase B2 system audio lives in
            // SystemAudioCapture.swift on a separate SCStream.
            configuration.capturesAudio = false
            let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration, delegate: nil)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
            self.stream = stream
            lock.withLock { activeStreamID = ObjectIdentifier(stream) }
            try await stream.startCapture()
            if !lock.withLock({ generation == token }) { try? await stream.stopCapture() }
        } catch {
            if lock.withLock({ generation == token }) { windowKey = nil; stream = nil }
        }
    }

    @MainActor
    func stop() {
        lock.withLock { generation &+= 1; sampleHistory.reset(); activeStreamID = nil }
        windowKey = nil
        let old = stream
        stream = nil
        if let old { Task { try? await old.stopCapture() } }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard lock.withLock({ activeStreamID == ObjectIdentifier(stream) }), type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              attachments.first?[.status] as? Int == SCFrameStatus.complete.rawValue,
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let permission = permissions.snapshot
        let token = lock.withLock { generation }
        guard !permission.secureInputEnabled, !permission.sessionLocked else {
            Task { @MainActor [weak self] in
                guard let self, self.lock.withLock({ self.generation == token }) else { return }
                self.stop()
                self.changed()
            }
            return
        }
        guard CVPixelBufferLockBaseAddress(pixels, .readOnly) == kCVReturnSuccess else { return }
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels) else { return }
        let width = CVPixelBufferGetWidth(pixels)
        let height = CVPixelBufferGetHeight(pixels)
        let strideBytes = CVPixelBufferGetBytesPerRow(pixels)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let sampleW = min(width, 64)
        let sampleH = min(height, 64)
        let stepX = max(1, width / 64)
        let stepY = max(1, height / 64)
        let targetCount = sampleW * sampleH
        let didChange = lock.withLock { () -> Bool in
            guard generation == token else { return false }
            if scratchSamples.count != targetCount {
                scratchSamples = [UInt16](repeating: 0, count: targetCount)
            }
            var writeIdx = 0
            var y = 0
            for _ in 0..<sampleH {
                let rowBase = y * strideBytes
                var x = 0
                for _ in 0..<sampleW {
                    let index = rowBase + x * 4
                    scratchSamples[writeIdx] = UInt16(bytes[index] >> 4)
                        | UInt16(bytes[index + 1] >> 4) << 4
                        | UInt16(bytes[index + 2] >> 4) << 8
                    writeIdx += 1
                    x += stepX
                }
                y += stepY
            }
            return sampleHistory.observeSwapping(&scratchSamples)
        }
        if didChange {
            Task { @MainActor [weak self] in
                guard let self, self.lock.withLock({ self.generation == token }) else { return }
                self.changed()
            }
        }
    }
}
