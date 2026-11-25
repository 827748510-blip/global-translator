import Foundation

public struct TranslationCacheKey: Hashable, Sendable {
    public let source: String
    public let backend: BackendKind
    public let model: String
    public let targetLanguage: String
    public let sourceLanguage: TranslationSourceLanguage?
    public let cacheScope: String?

    public init(
        source: String,
        backend: BackendKind,
        model: String,
        targetLanguage: String,
        sourceLanguage: TranslationSourceLanguage? = nil,
        cacheScope: String? = nil
    ) {
        self.source = source
        self.backend = backend
        self.model = model
        self.targetLanguage = targetLanguage
        self.sourceLanguage = sourceLanguage
        self.cacheScope = cacheScope
    }

    public init(sourceText: String, backend: BackendKind, model: String, targetLanguage: String) {
        self.init(source: sourceText, backend: backend, model: model, targetLanguage: targetLanguage)
    }

    public var sourceText: String { source }
    public var target: String { targetLanguage }
}

public actor TranslationCache {
    public typealias Key = TranslationCacheKey

    private struct Node {
        let key: TranslationCacheKey
        var value: String
        var byteCost: Int
        var prev: Int?
        var next: Int?
        var active: Bool
    }

    public let capacity: Int
    public let maxTotalBytes: Int
    private var indices: [TranslationCacheKey: Int] = [:]
    private var nodes: [Node] = []
    private var freeIndices: [Int] = []
    private var head: Int?
    private var tail: Int?
    private var activeCount = 0
    private var totalBytes = 0

    public init(capacity: Int = 2_000, maxTotalBytes: Int = 16 * 1024 * 1024) {
        self.capacity = max(0, capacity)
        self.maxTotalBytes = max(0, maxTotalBytes)
    }

    public var count: Int {
        activeCount
    }

    public var currentTotalBytes: Int {
        totalBytes
    }

    public func value(for key: TranslationCacheKey) -> String? {
        guard let index = indices[key] else { return nil }
        moveToFront(index)
        return nodes[index].value
    }

    public func values(for keys: [TranslationCacheKey]) -> [TranslationCacheKey: String] {
        guard !keys.isEmpty, activeCount > 0 else { return [:] }
        var result: [TranslationCacheKey: String] = [:]
        result.reserveCapacity(keys.count)
        for key in keys {
            guard let index = indices[key] else { continue }
            moveToFront(index)
            result[key] = nodes[index].value
        }
        return result
    }

    public func insert(_ value: String, for key: TranslationCacheKey) {
        guard capacity > 0, maxTotalBytes > 0 else { return }
        let cost = key.source.utf8.count + value.utf8.count
        guard cost <= maxTotalBytes else { return }

        if let index = indices[key] {
            totalBytes += cost - nodes[index].byteCost
            nodes[index].value = value
            nodes[index].byteCost = cost
            moveToFront(index)
        } else {
            let index = allocateNode(key: key, value: value, byteCost: cost)
            indices[key] = index
            insertAtFront(index)
            activeCount += 1
            totalBytes += cost
        }
        evictIfNeeded()
    }

    public func insertBatch(_ entries: [(key: TranslationCacheKey, value: String)]) {
        for entry in entries {
            insert(entry.value, for: entry.key)
        }
    }

    public func removeValue(for key: TranslationCacheKey) {
        guard let index = indices.removeValue(forKey: key) else { return }
        unlinkAndFree(index)
    }

    public func removeAll() {
        indices.removeAll(keepingCapacity: true)
        nodes.removeAll(keepingCapacity: true)
        freeIndices.removeAll(keepingCapacity: true)
        head = nil
        tail = nil
        activeCount = 0
        totalBytes = 0
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

    private func allocateNode(key: TranslationCacheKey, value: String, byteCost: Int) -> Int {
        let node = Node(key: key, value: value, byteCost: byteCost, prev: nil, next: nil, active: true)
        if let free = freeIndices.popLast() {
            nodes[free] = node
            return free
        }
        nodes.append(node)
        return nodes.count - 1
    }

    private func insertAtFront(_ index: Int) {
        nodes[index].prev = nil
        nodes[index].next = head
        if let currentHead = head {
            nodes[currentHead].prev = index
        }
        head = index
        if tail == nil {
            tail = index
        }
    }

    private func moveToFront(_ index: Int) {
        guard head != index else { return }
        let prev = nodes[index].prev
        let next = nodes[index].next
        if let prev {
            nodes[prev].next = next
        }
        if let next {
            nodes[next].prev = prev
        } else {
            tail = prev
        }
        insertAtFront(index)
    }

    private func unlinkAndFree(_ index: Int) {
        guard nodes[index].active else { return }
        let prev = nodes[index].prev
        let next = nodes[index].next
        if let prev {
            nodes[prev].next = next
        } else {
            head = next
        }
        if let next {
            nodes[next].prev = prev
        } else {
            tail = prev
        }
        totalBytes -= nodes[index].byteCost
        activeCount -= 1
        nodes[index].active = false
        nodes[index].value = ""
        nodes[index].prev = nil
        nodes[index].next = nil
        freeIndices.append(index)
    }

    private func evictIfNeeded() {
        while activeCount > capacity || totalBytes > maxTotalBytes {
            guard let oldest = tail else { break }
            let key = nodes[oldest].key
            indices.removeValue(forKey: key)
            unlinkAndFree(oldest)
        }
    }
}
