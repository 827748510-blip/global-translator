import Foundation

public actor CoalescingTranslationBackend: TranslationBackend {
    public nonisolated let kind: BackendKind
    private let base: any TranslationBackend
    private struct Flight {
        let token: UUID
        let task: Task<[String: String], Error>
    }
    // IDs and revisions are remapped for each waiter. Every field that can
    // change translation content or acceptance must stay in the flight key.
    private struct Key: Hashable {
        let sources: [String]
        let sourceLanguage: TranslationSourceLanguage?
        let targetLanguage: String?
        let copiedSourcePolicy: String
    }
    private var pending: [Key: Flight] = [:]
    private var completed: (key: Key, values: [String: String])?

    public init(base: any TranslationBackend) {
        self.base = base
        self.kind = base.kind
    }

    public func healthCheck() async -> BackendHealth { await base.healthCheck() }

    public func cancelOutstandingRequests() async {
        for flight in pending.values { flight.task.cancel() }
        pending.removeAll()
        completed = nil
        await base.cancelOutstandingRequests()
    }

    public func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        try TranslationRequestValidator.validate(request)
        try Task.checkCancellation()
        let key = Key(
            sources: request.items.map(\.sourceText).sorted(),
            sourceLanguage: request.sourceLanguage,
            targetLanguage: request.targetLanguage,
            copiedSourcePolicy: request.copiedSourcePolicy.rawValue
        )
        if let completed, completed.key == key {
            return try remap(completed.values, to: request)
        }
        let flight: Flight
        if let existing = pending[key] {
            flight = existing
        } else {
            for existing in pending.values { existing.task.cancel() }
            pending.removeAll()
            completed = nil
            let task = Task<[String: String], Error> { [base] in
                let result = try await base.translate(request)
                try Task.checkCancellation()
                let ids = result.translations.map(\.segmentId)
                guard result.windowRevision == request.windowRevision,
                      ids.count == request.items.count, Set(ids).count == ids.count,
                      Set(ids) == Set(request.items.map(\.id)) else {
                    throw TranslationError.invalidResponse("translation IDs do not match request")
                }
                let sourceByID = Dictionary(uniqueKeysWithValues: request.items.map { ($0.id, $0.sourceText) })
                var values: [String: String] = [:]
                for translation in result.translations {
                    guard let source = sourceByID[translation.segmentId] else { continue }
                    values[source] = translation.simplifiedChineseText
                }
                return values
            }
            flight = Flight(token: UUID(), task: task)
            pending[key] = flight
        }
        defer {
            if pending[key]?.token == flight.token { pending.removeValue(forKey: key) }
        }
        let values = try await flight.task.value
        if pending[key]?.token == flight.token { completed = (key, values) }
        try Task.checkCancellation()
        return try remap(values, to: request)
    }

    /// Does not cancel in-flight translates. Overlay/bridge coalescers must
    /// not drop a live translation when 滑词 优化提示词 uses the same serial slot.
    public func completePlain(system: String, user: String) async throws -> String {
        try Task.checkCancellation()
        return try await base.completePlain(system: system, user: user)
    }

    public func streamPlain(
        system: String,
        user: String,
        onDelta: @escaping @Sendable (String) async -> Void
    ) async throws -> String {
        try Task.checkCancellation()
        return try await base.streamPlain(system: system, user: user, onDelta: onDelta)
    }

    private func remap(_ values: [String: String], to request: TranslationRequest) throws -> TranslationResult {
        let translations = try request.items.map { item in
            guard let text = values[item.sourceText] else { throw TranslationError.invalidResponse("translation is missing") }
            return Translation(segmentId: item.id, simplifiedChineseText: text)
        }
        return TranslationResult(windowRevision: request.windowRevision, translations: translations)
    }
}
