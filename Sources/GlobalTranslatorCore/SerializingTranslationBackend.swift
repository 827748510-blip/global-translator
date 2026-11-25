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
/// overlapping `translate()` calls. This type keeps an explicit FIFO.
public actor SerializingTranslationBackend: TranslationBackend {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    public nonisolated let kind: BackendKind
    private let base: any TranslationBackend
    private var busy = false
    private var waiters: [Waiter] = []
    private var waiterHead = 0

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

    private func acquire() async throws {
        try Task.checkCancellation()
        if !busy {
            busy = true
            return
        }
        let waiterID = UUID()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                enqueueOrCancel(id: waiterID, continuation: continuation)
            }
        }, onCancel: {
            Task { await self.cancelWaiter(id: waiterID) }
        })
    }

    private func enqueueOrCancel(id: UUID, continuation: CheckedContinuation<Void, Error>) {
        if Task.isCancelled {
            continuation.resume(throwing: CancellationError())
            return
        }
        waiters.append(Waiter(id: id, continuation: continuation))
    }

    private func cancelWaiter(id: UUID) {
        guard waiterHead < waiters.count else { return }
        for index in waiterHead..<waiters.count where waiters[index].id == id {
            let waiter = waiters.remove(at: index)
            compactWaitersIfNeeded()
            waiter.continuation.resume(throwing: CancellationError())
            return
        }
    }

    private func release() {
        while waiterHead < waiters.count {
            let next = waiters[waiterHead]
            waiterHead += 1
            compactWaitersIfNeeded()
            next.continuation.resume(returning: ())
            return
        }
        busy = false
    }

    private func compactWaitersIfNeeded() {
        if waiterHead >= waiters.count {
            waiters.removeAll(keepingCapacity: true)
            waiterHead = 0
        } else if waiterHead > 32 && waiterHead * 2 >= waiters.count {
            waiters.removeFirst(waiterHead)
            waiterHead = 0
        }
    }
}
