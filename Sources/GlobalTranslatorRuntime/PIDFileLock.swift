import Darwin
import Foundation

public final class PIDFileLock: @unchecked Sendable {
    public let url: URL
    public private(set) var pid: Int32?

    private let mutex = NSLock()
    private var descriptor: Int32 = -1
    private var ownsLock = false

    public init(url: URL) {
        self.url = url
    }

    deinit {
        release()
    }

    @discardableResult
    public func acquire() throws -> Bool {
        mutex.lock()
        defer { mutex.unlock() }
        if ownsLock {
            return true
        }
        let descriptor = Darwin.open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW, mode_t(S_IRUSR | S_IWUSR))
        guard descriptor >= 0 else {
            throw RuntimeError.ioFailure
        }
        guard Darwin.fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            Darwin.close(descriptor)
            throw RuntimeError.ioFailure
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            return false
        }
        self.descriptor = descriptor
        ownsLock = true
        let currentPID = Int32(getpid())
        pid = currentPID
        let bytes = Data("\(currentPID)\n".utf8)
        _ = Darwin.ftruncate(descriptor, 0)
        _ = Darwin.lseek(descriptor, 0, SEEK_SET)
        let written = bytes.withUnsafeBytes { buffer in
            Darwin.write(descriptor, buffer.baseAddress, bytes.count)
        }
        guard written == bytes.count else {
            flock(descriptor, LOCK_UN)
            Darwin.close(descriptor)
            self.descriptor = -1
            ownsLock = false
            pid = nil
            throw RuntimeError.ioFailure
        }
        _ = Darwin.fsync(descriptor)
        return true
    }

    public func release() {
        mutex.lock()
        defer { mutex.unlock() }
        guard ownsLock, descriptor >= 0 else {
            return
        }
        let descriptorToClose = descriptor
        descriptor = -1
        ownsLock = false
        let ownedPID = pid
        pid = nil
        _ = flock(descriptorToClose, LOCK_UN)
        _ = Darwin.close(descriptorToClose)
        if let ownedPID, Self.readPID(from: url) == ownedPID {
            try? FileManager.default.removeItem(at: url)
        }
    }

    public static func readPID(from url: URL) -> Int32? {
        guard let value = try? String(contentsOf: url, encoding: .utf8),
              let first = value.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\r" || $0 == "\t" }).first,
              let parsed = Int32(first), parsed > 0 else {
            return nil
        }
        return parsed
    }

    public static func isProcessAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else {
            return false
        }
        if Darwin.kill(pid, 0) == 0 {
            return true
        }
        return errno == EPERM
    }
}
