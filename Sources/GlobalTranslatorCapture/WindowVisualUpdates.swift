import AppKit
import CoreMedia
import CoreVideo
import ScreenCaptureKit

final class WindowVisualUpdates: NSObject, SCStreamOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var previous: [UInt16]?
    private var activeStreamID: ObjectIdentifier?
    private let changed: @MainActor @Sendable () -> Void
    @MainActor private var stream: SCStream?
    @MainActor private var windowKey: String?

    init(changed: @escaping @MainActor @Sendable () -> Void) {
        self.changed = changed
    }

    @MainActor
    func watch(_ descriptor: ActiveWindowDescriptor) async {
        let key = "\(descriptor.pid):\(descriptor.windowID ?? 0)"
        guard windowKey != key else { return }
        stop()
        let permissions = SystemPermissionController().snapshot
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
            configuration.width = 256
            configuration.height = 256
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 4)
            configuration.queueDepth = 3
            configuration.showsCursor = false
            configuration.capturesAudio = false
            let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration, delegate: nil)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "GlobalTranslator.visualChanges", qos: .utility))
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
        lock.withLock { generation &+= 1; previous = nil; activeStreamID = nil }
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
        let permission = SystemPermissionController().snapshot
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
        var samples = [UInt16]()
        samples.reserveCapacity(4096)
        for y in stride(from: 0, to: height, by: max(1, height / 64)) {
            for x in stride(from: 0, to: width, by: max(1, width / 64)) {
                let index = y * strideBytes + x * 4
                samples.append(UInt16(bytes[index] >> 4) | UInt16(bytes[index + 1] >> 4) << 4 | UInt16(bytes[index + 2] >> 4) << 8)
            }
        }
        let didChange = lock.withLock {
            guard generation == token else { return false }
            let changed = previous.map { old in
                old.count != samples.count || zip(old, samples).lazy.filter { $0 != $1 }.prefix(3).count >= 3
            } ?? true
            if changed { previous = samples }
            return changed
        }
        if didChange {
            Task { @MainActor [weak self] in
                guard let self, self.lock.withLock({ self.generation == token }) else { return }
                self.changed()
            }
        }
    }
}
