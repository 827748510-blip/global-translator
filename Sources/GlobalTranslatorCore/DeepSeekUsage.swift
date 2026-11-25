import Foundation

/// Token counts returned by the DeepSeek Responses API `usage` object.
public struct DeepSeekTokenUsage: Equatable, Sendable {
    public let inputTokens: Int
    public let cachedInputTokens: Int
    public let outputTokens: Int
    public let totalTokens: Int

    public init(
        inputTokens: Int,
        cachedInputTokens: Int = 0,
        outputTokens: Int,
        totalTokens: Int? = nil
    ) {
        let input = max(0, inputTokens)
        self.inputTokens = input
        // `cached_tokens` is a subset of `input_tokens`; clamp so a malformed
        // response can never produce a hit rate above 100%.
        self.cachedInputTokens = min(max(0, cachedInputTokens), input)
        self.outputTokens = max(0, outputTokens)
        self.totalTokens = max(0, totalTokens ?? input + self.outputTokens)
    }

    /// Every input token participates in DeepSeek's automatic prefix cache.
    public var cacheableInputTokens: Int { inputTokens }

    /// Cache hits are counted against the cacheable input tokens, not against
    /// the full prompt plus completion.
    public var cacheHitRate: Double {
        guard cacheableInputTokens > 0 else { return 0 }
        return Double(cachedInputTokens) / Double(cacheableInputTokens)
    }
}

/// Aggregated usage for this app session. Statistics are in-memory only: no
/// source text, prompts, or credentials are stored.
public struct DeepSeekUsageSnapshot: Equatable, Sendable {
    public let requestCount: Int
    public let inputTokens: Int
    public let cachedInputTokens: Int
    public let outputTokens: Int
    public let generationSeconds: Double
    public let estimatedCostUSD: Double
    public let lastModel: String
    public let lastUpdatedAt: Date?

    public init(
        requestCount: Int = 0,
        inputTokens: Int = 0,
        cachedInputTokens: Int = 0,
        outputTokens: Int = 0,
        generationSeconds: Double = 0,
        estimatedCostUSD: Double = 0,
        lastModel: String = AppConfiguration.defaultDeepSeekModel,
        lastUpdatedAt: Date? = nil
    ) {
        self.requestCount = requestCount
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.generationSeconds = generationSeconds
        self.estimatedCostUSD = estimatedCostUSD
        self.lastModel = lastModel
        self.lastUpdatedAt = lastUpdatedAt
    }

    public var cacheHitRate: Double {
        guard inputTokens > 0 else { return 0 }
        return Double(cachedInputTokens) / Double(inputTokens)
    }

    /// Output tokens divided by the measured request duration (generation plus
    /// network round-trip; the non-streaming API exposes no separate timer).
    public var outputTokensPerSecond: Double {
        guard generationSeconds > 0 else { return 0 }
        return Double(outputTokens) / generationSeconds
    }

    /// Display-only RMB estimate. DeepSeek bills in USD; the actual card
    /// settlement uses the issuer's exchange rate.
    public var estimatedCostCNY: Double {
        estimatedCostUSD * DeepSeekPricing.usdToCNY
    }
}

public extension Notification.Name {
    static let deepSeekUsageDidChange = Notification.Name("GlobalTranslator.DeepSeekUsageDidChange")
}

/// Thread-safe accumulator shared by every DeepSeek backend instance in the
/// process, so configuration rebuilds do not reset the running totals.
public final class DeepSeekUsageStore: @unchecked Sendable {
    public static let shared = DeepSeekUsageStore()

    private let lock = NSLock()
    private var requestCount = 0
    private var inputTokens = 0
    private var cachedInputTokens = 0
    private var outputTokens = 0
    private var generationSeconds: Double = 0
    private var estimatedCostUSD: Double = 0
    private var lastModel = AppConfiguration.defaultDeepSeekModel
    private var lastUpdatedAt: Date?

    public init() {}

    public func record(
        usage: DeepSeekTokenUsage,
        model: String,
        durationSeconds: Double,
        requestedAt: Date
    ) {
        let seconds = max(0, durationSeconds)
        let cost = DeepSeekPricing.estimatedCostUSD(usage: usage, at: requestedAt)

        lock.lock()
        requestCount += 1
        inputTokens += usage.inputTokens
        cachedInputTokens += usage.cachedInputTokens
        outputTokens += usage.outputTokens
        generationSeconds += seconds
        estimatedCostUSD += cost
        lastModel = model
        lastUpdatedAt = Date()
        lock.unlock()

        NotificationCenter.default.post(name: .deepSeekUsageDidChange, object: nil)
    }

    public func snapshot() -> DeepSeekUsageSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return DeepSeekUsageSnapshot(
            requestCount: requestCount,
            inputTokens: inputTokens,
            cachedInputTokens: cachedInputTokens,
            outputTokens: outputTokens,
            generationSeconds: generationSeconds,
            estimatedCostUSD: estimatedCostUSD,
            lastModel: lastModel,
            lastUpdatedAt: lastUpdatedAt
        )
    }

    public func reset() {
        lock.lock()
        requestCount = 0
        inputTokens = 0
        cachedInputTokens = 0
        outputTokens = 0
        generationSeconds = 0
        estimatedCostUSD = 0
        lastModel = AppConfiguration.defaultDeepSeekModel
        lastUpdatedAt = nil
        lock.unlock()

        NotificationCenter.default.post(name: .deepSeekUsageDidChange, object: nil)
    }
}

/// Published deepseek-flash prices, USD per 1M tokens.
/// https://api-docs.deepseek.com/quick_start/pricing/
public enum DeepSeekPricing {
    /// Fixed display rate for the in-app RMB estimate, not a billing rate.
    public static let usdToCNY: Double = 7.2

    private struct Rates {
        let cacheHit: Double
        let cacheMiss: Double
        let output: Double
    }

    private static let peak = Rates(cacheHit: 0.006, cacheMiss: 0.3, output: 1.2)
    private static let offPeak = Rates(cacheHit: 0.003, cacheMiss: 0.15, output: 0.6)

    /// Peak is 01:00-04:00 and 06:00-10:00 UTC on weekdays. DeepSeek excludes
    /// Chinese public holidays from peak pricing; this estimate has no holiday
    /// calendar, so holiday peak hours are billed here at the peak rate.
    public static func isPeak(at date: Date) -> Bool {
        let unixSeconds = Int64(floor(date.timeIntervalSince1970))
        let days = unixSeconds >= 0 ? unixSeconds / 86_400 : (unixSeconds - 86_399) / 86_400
        let secondsOfDay = Int(unixSeconds - days * 86_400)
        let hour = secondsOfDay / 3_600
        // 1970-01-01 was Thursday (offset 3 when Monday == 0).
        let weekdayZeroMon = ((days + 3) % 7 + 7) % 7
        guard (0...4).contains(weekdayZeroMon) else {
            return false
        }
        return (1..<4).contains(hour) || (6..<10).contains(hour)
    }

    public static func estimatedCostUSD(usage: DeepSeekTokenUsage, at date: Date) -> Double {
        let rates = isPeak(at: date) ? peak : offPeak
        let hitTokens = usage.cachedInputTokens
        let missTokens = max(0, usage.inputTokens - hitTokens)
        return (Double(hitTokens) * rates.cacheHit
            + Double(missTokens) * rates.cacheMiss
            + Double(usage.outputTokens) * rates.output)
            / 1_000_000
    }
}

enum DeepSeekUsageParser {
    static func parse(_ data: Data) -> DeepSeekTokenUsage? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usage = root["usage"] as? [String: Any],
              let inputTokens = intValue(usage["input_tokens"]),
              let outputTokens = intValue(usage["output_tokens"]) else {
            return nil
        }
        let details = usage["input_tokens_details"] as? [String: Any]
        let cachedTokens = intValue(details?["cached_tokens"]) ?? 0
        let totalTokens = intValue(usage["total_tokens"]) ?? inputTokens + outputTokens
        return DeepSeekTokenUsage(
            inputTokens: inputTokens,
            cachedInputTokens: cachedTokens,
            outputTokens: outputTokens,
            totalTokens: totalTokens
        )
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let text = value as? String {
            return Int(text)
        }
        return nil
    }
}
