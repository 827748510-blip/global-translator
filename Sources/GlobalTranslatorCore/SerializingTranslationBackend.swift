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
    public nonisolated let kind: BackendKind
    private let base: any TranslationBackend
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(base: any TranslationBackend) {
        self.base = base
        self.kind = base.kind
    }

    public func healthCheck() async -> BackendHealth {
        await acquire()
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
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await base.translate(request)
    }

    public func completePlain(system: String, user: String) async throws -> String {
        try Task.checkCancellation()
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await base.completePlain(system: system, user: user)
    }

    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
            return
        }
        waiters.removeFirst().resume()
    }
}
