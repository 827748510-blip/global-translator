import CoreGraphics
import Foundation

public struct FingerprintKey: Hashable, Sendable {
    public let pid: Int32
    public let windowID: CGWindowID?

    public init(pid: Int32, windowID: CGWindowID?) {
        self.pid = pid
        self.windowID = windowID
    }
}

public final class InMemoryFingerprintStore: @unchecked Sendable {
    public let maximumEntries: Int
    private let lock = NSLock()
    private var values: [FingerprintKey: ImageFingerprint] = [:]
    private var order: [FingerprintKey] = []

    public init(maximumEntries: Int = 128) {
        self.maximumEntries = min(max(maximumEntries, 0), 128)
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return values.count
    }

    public func isUnchanged(_ fingerprint: ImageFingerprint, for key: FingerprintKey) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard values[key] == fingerprint else { return false }
        order.removeAll { $0 == key }
        order.append(key)
        return true
    }

    public func remember(_ fingerprint: ImageFingerprint, for key: FingerprintKey) {
        lock.lock()
        guard maximumEntries > 0 else {
            lock.unlock()
            return
        }
        values[key] = fingerprint
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > maximumEntries {
            let oldest = order.removeFirst()
            values.removeValue(forKey: oldest)
        }
        lock.unlock()
    }

    public func removeAll() {
        lock.lock()
        values.removeAll(keepingCapacity: false)
        order.removeAll(keepingCapacity: false)
        lock.unlock()
    }
}
