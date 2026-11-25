import Foundation
import GlobalTranslatorCore

public struct TranslationBatchEntry: Equatable, Sendable {
    public let item: TranslationItem
    public let sourceText: String
    public let regions: [TextRegion]

    public init(item: TranslationItem, sourceText: String, regions: [TextRegion]) {
        self.item = item
        self.sourceText = sourceText
        self.regions = regions
    }
}

public struct TranslationBatch: Equatable, Sendable {
    public let entries: [TranslationBatchEntry]
    public let request: TranslationRequest
    public let sourceCharacterCount: Int

    public init(
        entries: [TranslationBatchEntry],
        windowRevision: UInt64,
        copiedSourcePolicy: CopiedSourcePolicy = .reject,
        targetLanguage: String? = nil,
        sourceLanguage: TranslationSourceLanguage? = nil
    ) {
        self.entries = entries
        request = TranslationRequest(
            windowRevision: windowRevision,
            items: entries.map(\.item),
            copiedSourcePolicy: copiedSourcePolicy,
            targetLanguage: targetLanguage,
            sourceLanguage: sourceLanguage
        )
        sourceCharacterCount = entries.reduce(into: 0) { result, entry in
            result += entry.sourceText.count
        }
    }
}

public struct TranslationBatchPlan: Equatable, Sendable {
    public let entries: [TranslationBatchEntry]
    public let orderedRegions: [TextRegion]
    public let filteredRegionCount: Int

    public init(
        entries: [TranslationBatchEntry],
        orderedRegions: [TextRegion],
        filteredRegionCount: Int
    ) {
        self.entries = entries
        self.orderedRegions = orderedRegions
        self.filteredRegionCount = filteredRegionCount
    }

    public var eligibleRegionCount: Int {
        orderedRegions.count
    }
}

public struct TranslationBatcher: Sendable {
    public let maximumItems: Int
    public let maximumSourceCharacters: Int

    public init(maximumItems: Int = 24, maximumSourceCharacters: Int = 4_000) {
        self.maximumItems = min(max(maximumItems, 1), 24)
        self.maximumSourceCharacters = min(max(maximumSourceCharacters, 1), 4_000)
    }

    public func plan(regions: [TextRegion], requireTranslatable: Bool = true, sourceLanguage: TranslationSourceLanguage? = nil) -> TranslationBatchPlan {
        let sorted = regions.sorted(by: Self.readingOrder)
        var groupedRegions: [String: [TextRegion]] = [:]
        groupedRegions.reserveCapacity(sorted.count)
        var order: [String] = []
        order.reserveCapacity(sorted.count)
        var filteredCount = 0

        for region in sorted {
            let source = region.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !source.isEmpty else {
                filteredCount += 1
                continue
            }
            if groupedRegions[source] != nil {
                groupedRegions[source]?.append(region)
            } else {
                groupedRegions[source] = [region]
                order.append(source)
            }
        }

        var entries: [TranslationBatchEntry] = []
        entries.reserveCapacity(order.count)
        var orderedRegions: [TextRegion] = []
        orderedRegions.reserveCapacity(sorted.count)

        for source in order {
            guard let group = groupedRegions[source] else { continue }
            let translatable = !requireTranslatable || TextFilter.shouldTranslate(source, sourceLanguage: sourceLanguage)
            guard translatable, source.count <= maximumSourceCharacters else {
                filteredCount += group.count
                continue
            }
            // Stable per-source IDs keep repeated cloud batches byte-identical
            // so DeepSeek can fully reuse its prefix cache. Region IDs stay
            // unchanged in `orderedRegions` and are mapped back downstream.
            entries.append(TranslationBatchEntry(
                item: TranslationItem(id: PromptStableIdentifier.id(for: source), sourceText: source),
                sourceText: source,
                regions: group
            ))
            orderedRegions.append(contentsOf: group)
        }

        return TranslationBatchPlan(
            entries: entries,
            orderedRegions: orderedRegions,
            filteredRegionCount: filteredCount
        )
    }

    public func makeBatches(
        from entries: [TranslationBatchEntry],
        windowRevision: UInt64,
        copiedSourcePolicy: CopiedSourcePolicy = .reject,
        targetLanguage: String? = nil,
        sourceLanguage: TranslationSourceLanguage? = nil
    ) -> [TranslationBatch] {
        var batches: [TranslationBatch] = []
        var current: [TranslationBatchEntry] = []
        var currentCharacters = 0

        for entry in entries {
            let entryCount = entry.sourceText.count
            let wouldExceedCount = current.count >= maximumItems
            let wouldExceedCharacters = currentCharacters + entryCount > maximumSourceCharacters
            if !current.isEmpty && (wouldExceedCount || wouldExceedCharacters) {
                batches.append(TranslationBatch(
                    entries: current,
                    windowRevision: windowRevision,
                    copiedSourcePolicy: copiedSourcePolicy,
                    targetLanguage: targetLanguage,
                    sourceLanguage: sourceLanguage
                ))
                current.removeAll(keepingCapacity: true)
                currentCharacters = 0
            }
            current.append(entry)
            currentCharacters += entryCount
        }
        if !current.isEmpty {
            batches.append(TranslationBatch(
                entries: current,
                windowRevision: windowRevision,
                copiedSourcePolicy: copiedSourcePolicy,
                targetLanguage: targetLanguage,
                sourceLanguage: sourceLanguage
            ))
        }
        return batches
    }

    public func makeBatches(
        from regions: [TextRegion],
        windowRevision: UInt64,
        copiedSourcePolicy: CopiedSourcePolicy = .reject,
        targetLanguage: String? = nil,
        sourceLanguage: TranslationSourceLanguage? = nil
    ) -> [TranslationBatch] {
        let plan = plan(regions: regions, sourceLanguage: sourceLanguage)
        return makeBatches(
            from: plan.entries,
            windowRevision: windowRevision,
            copiedSourcePolicy: copiedSourcePolicy,
            targetLanguage: targetLanguage,
            sourceLanguage: sourceLanguage
        )
    }

    private static func readingOrder(_ lhs: TextRegion, _ rhs: TextRegion) -> Bool {
        let leftFrame = lhs.screenFrame.standardized
        let rightFrame = rhs.screenFrame.standardized
        if leftFrame.maxY != rightFrame.maxY {
            return leftFrame.maxY > rightFrame.maxY
        }
        if leftFrame.minX != rightFrame.minX {
            return leftFrame.minX < rightFrame.minX
        }
        if leftFrame.minY != rightFrame.minY {
            return leftFrame.minY > rightFrame.minY
        }
        if leftFrame.width != rightFrame.width {
            return leftFrame.width < rightFrame.width
        }
        return uuidLessThan(lhs.id.uuid, rhs.id.uuid)
    }

    private static func uuidLessThan(_ a: uuid_t, _ b: uuid_t) -> Bool {
        if a.0 != b.0 { return a.0 < b.0 }
        if a.1 != b.1 { return a.1 < b.1 }
        if a.2 != b.2 { return a.2 < b.2 }
        if a.3 != b.3 { return a.3 < b.3 }
        if a.4 != b.4 { return a.4 < b.4 }
        if a.5 != b.5 { return a.5 < b.5 }
        if a.6 != b.6 { return a.6 < b.6 }
        if a.7 != b.7 { return a.7 < b.7 }
        if a.8 != b.8 { return a.8 < b.8 }
        if a.9 != b.9 { return a.9 < b.9 }
        if a.10 != b.10 { return a.10 < b.10 }
        if a.11 != b.11 { return a.11 < b.11 }
        if a.12 != b.12 { return a.12 < b.12 }
        if a.13 != b.13 { return a.13 < b.13 }
        if a.14 != b.14 { return a.14 < b.14 }
        return a.15 < b.15
    }
}
