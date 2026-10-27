import Foundation

public struct TranslationCacheKey: Hashable, Sendable {
    public let source: String
    public let backend: BackendKind
    public let model: String
    public let targetLanguage: String
    public let sourceLanguage: TranslationSourceLanguage?

    public init(source: String, backend: BackendKind, model: String, targetLanguage: String, sourceLanguage: TranslationSourceLanguage? = nil) {
        self.source = source
        self.backend = backend
        self.model = model
        self.targetLanguage = targetLanguage
        self.sourceLanguage = sourceLanguage
    }

    public init(sourceText: String, backend: BackendKind, model: String, targetLanguage: String) {
        self.init(source: sourceText, backend: backend, model: model, targetLanguage: targetLanguage)
    }

    public var sourceText: String { source }
    public var target: String { targetLanguage }
}

public actor TranslationCache {
    public typealias Key = TranslationCacheKey

    public let capacity: Int
    private var values: [TranslationCacheKey: String] = [:]
    private var recency: [TranslationCacheKey] = []

    public init(capacity: Int = 2_000) {
        self.capacity = max(0, capacity)
    }

    public var count: Int {
        values.count
    }

    public func value(for key: TranslationCacheKey) -> String? {
        guard let value = values[key] else { return nil }
        markRecentlyUsed(key)
        return value
    }

    public func insert(_ value: String, for key: TranslationCacheKey) {
        guard capacity > 0 else { return }
        values[key] = value
        markRecentlyUsed(key)
        while recency.count > capacity {
            let oldest = recency.removeFirst()
            values.removeValue(forKey: oldest)
        }
    }

    public func removeValue(for key: TranslationCacheKey) {
        values.removeValue(forKey: key)
        recency.removeAll { $0 == key }
    }

    public func removeAll() {
        values.removeAll(keepingCapacity: true)
        recency.removeAll(keepingCapacity: true)
    }

    public func translatedText(
        for source: String,
        backend: BackendKind,
        model: String,
        targetLanguage: String
    ) -> String? {
        value(for: TranslationCacheKey(source: source, backend: backend, model: model, targetLanguage: targetLanguage))
    }

    public func insert(
        _ value: String,
        source: String,
        backend: BackendKind,
        model: String,
        targetLanguage: String
    ) {
        insert(value, for: TranslationCacheKey(source: source, backend: backend, model: model, targetLanguage: targetLanguage))
    }

    private func markRecentlyUsed(_ key: TranslationCacheKey) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }
}
