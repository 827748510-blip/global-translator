import Foundation

public actor CoalescingTranslationBackend: TranslationBackend {
    public nonisolated let kind: BackendKind
    private let base: any TranslationBackend
    private struct Flight {
        let token: UUID
        let task: Task<[String: String], Error>
    }
    private var pending: [[String]: Flight] = [:]
    private var completed: (key: [String], values: [String: String])?

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
        let key = request.items.map(\.sourceText).sorted()
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

    private func remap(_ values: [String: String], to request: TranslationRequest) throws -> TranslationResult {
        let translations = try request.items.map { item in
            guard let text = values[item.sourceText] else { throw TranslationError.invalidResponse("translation is missing") }
            return Translation(segmentId: item.id, simplifiedChineseText: text)
        }
        return TranslationResult(windowRevision: request.windowRevision, translations: translations)
    }
}
