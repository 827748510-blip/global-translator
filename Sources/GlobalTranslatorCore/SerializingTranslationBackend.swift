import Foundation

/// One-at-a-time wrapper around a translation backend.
///
/// Local Ollama typically runs a single generation. Overlay capture and the
/// extension bridge used to POST concurrently through separate
/// `LocalOpenAIBackend` instances that shared one `URLSession`, which reset
/// the in-flight connection (`networkFailure`) and opened the window
/// coordinator's circuit.
///
/// Swift actors reenter at `await`, so isolation alone does not serialize
/// overlapping `translate()` calls. This type keeps two explicit FIFOs so
/// interactive 滑词 / 截图 requests cut ahead of background bridge / overlay work.
public actor SerializingTranslationBackend: TranslationBackend {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    public nonisolated let kind: BackendKind
    private let base: any TranslationBackend
    private var busy = false
    private var highWaiters: [Waiter] = []
    private var highWaiterHead = 0
    private var normalWaiters: [Waiter] = []
    private var normalWaiterHead = 0

    public init(base: any TranslationBackend) {
        self.base = base
        self.kind = base.kind
    }

    public func healthCheck() async -> BackendHealth {
        do {
            try await acquire()
        } catch {
            return BackendHealth(status: .unavailable, message: "Health check cancelled")
        }
        defer { release() }
        return await base.healthCheck()
    }

    public func cancelOutstandingRequests() async {
        // Overlay and the extension bridge share this slot. Cancelling here
        // would abort whichever pipeline currently holds Ollama, including
        // the one that did not ask to cancel.
    }

    public func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        try Task.checkCancellation()
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await base.translate(request)
    }

    public func completePlain(system: String, user: String) async throws -> String {
        try Task.checkCancellation()
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await base.completePlain(system: system, user: user)
    }

    public func streamPlain(
        system: String,
        user: String,
        onDelta: @escaping @Sendable (String) async -> Void
    ) async throws -> String {
        try Task.checkCancellation()
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await base.streamPlain(system: system, user: user, onDelta: onDelta)
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        if !busy {
            busy = true
            return
        }
        let waiterID = UUID()
        let priority = TranslationPriorityContext.current
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                enqueueOrCancel(id: waiterID, priority: priority, continuation: continuation)
            }
        }, onCancel: {
            Task { await self.cancelWaiter(id: waiterID) }
        })
    }

    private func enqueueOrCancel(
        id: UUID,
        priority: TranslationRequestPriority,
        continuation: CheckedContinuation<Void, Error>
    ) {
        if Task.isCancelled {
            continuation.resume(throwing: CancellationError())
            return
        }
        let waiter = Waiter(id: id, continuation: continuation)
        switch priority {
        case .high:
            highWaiters.append(waiter)
        case .normal:
            normalWaiters.append(waiter)
        }
    }

    private func cancelWaiter(id: UUID) {
        if highWaiterHead < highWaiters.count {
            for index in highWaiterHead..<highWaiters.count where highWaiters[index].id == id {
                let waiter = highWaiters.remove(at: index)
                compactWaiters(&highWaiters, head: &highWaiterHead)
                waiter.continuation.resume(throwing: CancellationError())
                return
            }
        }
        if normalWaiterHead < normalWaiters.count {
            for index in normalWaiterHead..<normalWaiters.count where normalWaiters[index].id == id {
                let waiter = normalWaiters.remove(at: index)
                compactWaiters(&normalWaiters, head: &normalWaiterHead)
                waiter.continuation.resume(throwing: CancellationError())
                return
            }
        }
    }

    private func release() {
        if let next = dequeueNext(&highWaiters, head: &highWaiterHead) {
            next.continuation.resume(returning: ())
            return
        }
        if let next = dequeueNext(&normalWaiters, head: &normalWaiterHead) {
            next.continuation.resume(returning: ())
            return
        }
        busy = false
    }

    private func dequeueNext(_ waiters: inout [Waiter], head: inout Int) -> Waiter? {
        guard head < waiters.count else { return nil }
        let next = waiters[head]
        head += 1
        compactWaiters(&waiters, head: &head)
        return next
    }

    private func compactWaiters(_ waiters: inout [Waiter], head: inout Int) {
        if head >= waiters.count {
            waiters.removeAll(keepingCapacity: true)
            head = 0
        } else if head > 32 && head * 2 >= waiters.count {
            waiters.removeFirst(head)
            head = 0
        }
    }
}
