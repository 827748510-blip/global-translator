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
        targetLanguage: String? = nil
    ) {
        self.entries = entries
        request = TranslationRequest(
            windowRevision: windowRevision,
            items: entries.map(\.item),
            copiedSourcePolicy: copiedSourcePolicy,
            targetLanguage: targetLanguage
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

    public func plan(regions: [TextRegion], requireTranslatable: Bool = true) -> TranslationBatchPlan {
        let sorted = regions.sorted(by: Self.readingOrder)
        var groups: [String: TranslationBatchEntry] = [:]
        var order: [String] = []
        var filteredCount = 0

        for region in sorted {
            let source = region.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
            let translatable = !requireTranslatable || TextFilter.shouldTranslate(source)
            guard translatable, source.count <= maximumSourceCharacters else {
                filteredCount += 1
                continue
            }
            if var group = groups[source] {
                group = TranslationBatchEntry(item: group.item, sourceText: source, regions: group.regions + [region])
                groups[source] = group
            } else {
                // Stable per-source IDs keep repeated cloud batches byte-identical
                // so DeepSeek can fully reuse its prefix cache. Region IDs stay
                // unchanged in `orderedRegions` and are mapped back downstream.
                groups[source] = TranslationBatchEntry(
                    item: TranslationItem(id: PromptStableIdentifier.id(for: source), sourceText: source),
                    sourceText: source,
                    regions: [region]
                )
                order.append(source)
            }
        }

        let entries = order.compactMap { groups[$0] }
        let orderedRegions = entries.flatMap(\.regions)
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
        targetLanguage: String? = nil
    ) -> [TranslationBatch] {
        var batches: [TranslationBatch] = []
        var current: [TranslationBatchEntry] = []
        var currentCharacters = 0

        for entry in entries {
            let wouldExceedCount = current.count >= maximumItems
            let wouldExceedCharacters = currentCharacters + entry.sourceText.count > maximumSourceCharacters
            if !current.isEmpty && (wouldExceedCount || wouldExceedCharacters) {
                batches.append(TranslationBatch(
                    entries: current,
                    windowRevision: windowRevision,
                    copiedSourcePolicy: copiedSourcePolicy,
                    targetLanguage: targetLanguage
                ))
                current.removeAll(keepingCapacity: true)
                currentCharacters = 0
            }
            current.append(entry)
            currentCharacters += entry.sourceText.count
        }
        if !current.isEmpty {
            batches.append(TranslationBatch(
                entries: current,
                windowRevision: windowRevision,
                copiedSourcePolicy: copiedSourcePolicy,
                targetLanguage: targetLanguage
            ))
        }
        return batches
    }

    public func makeBatches(
        from regions: [TextRegion],
        windowRevision: UInt64,
        copiedSourcePolicy: CopiedSourcePolicy = .reject,
        targetLanguage: String? = nil
    ) -> [TranslationBatch] {
        let plan = plan(regions: regions)
        return makeBatches(
            from: plan.entries,
            windowRevision: windowRevision,
            copiedSourcePolicy: copiedSourcePolicy,
            targetLanguage: targetLanguage
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
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
