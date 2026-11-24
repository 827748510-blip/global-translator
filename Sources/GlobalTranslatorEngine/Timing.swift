import Foundation
import GlobalTranslatorCore

public protocol MonotonicClock: Sendable {
    func now() -> TimeInterval
}

public struct SystemMonotonicClock: MonotonicClock, Sendable {
    public init() {}

    public func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }
}

public protocol TranslationSleeper: Sendable {
    func sleep(for seconds: TimeInterval) async throws
}

public struct TaskTranslationSleeper: TranslationSleeper, Sendable {
    public init() {}

    public func sleep(for seconds: TimeInterval) async throws {
        let bounded = max(0, seconds)
        let nanoseconds = UInt64(min(bounded, Double(UInt64.max) / 1_000_000_000) * 1_000_000_000)
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}

public actor CircuitBreaker {
    public let failureThreshold: Int
    public let openDuration: TimeInterval

    private let clock: any MonotonicClock
    private var consecutiveFailures = 0
    private var openedUntil: TimeInterval?

    public init(
        clock: any MonotonicClock = SystemMonotonicClock(),
        failureThreshold: Int = 3,
        openDuration: TimeInterval = 30
    ) {
        self.clock = clock
        self.failureThreshold = max(1, failureThreshold)
        self.openDuration = max(0, openDuration)
    }

    public func check() throws {
        guard let openedUntil else { return }
        let remaining = openedUntil - clock.now()
        if remaining > 0 {
            throw TranslationCoordinatorError.circuitOpen(retryAfter: remaining)
        }
        self.openedUntil = nil
        consecutiveFailures = 0
    }

    public func recordSuccess() {
        consecutiveFailures = 0
        openedUntil = nil
    }

    public func recordFailure() {
        guard openedUntil == nil else { return }
        consecutiveFailures += 1
        if consecutiveFailures >= failureThreshold {
            openedUntil = clock.now() + openDuration
        }
    }

    public func recordFailure(_ error: TranslationError) {
        if case .rateLimited(let retryAfter) = error,
           let retryAfter,
           retryAfter.isFinite,
           retryAfter > 0 {
            let until = clock.now() + retryAfter
            if openedUntil == nil || openedUntil! < until {
                openedUntil = until
            }
            return
        }
        recordFailure()
    }

    public func reset() {
        consecutiveFailures = 0
        openedUntil = nil
    }

    public var isOpen: Bool {
        guard let openedUntil else { return false }
        return openedUntil > clock.now()
    }

    public var failureCount: Int {
        consecutiveFailures
    }
}
