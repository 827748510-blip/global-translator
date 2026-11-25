import Combine
import GlobalTranslatorCore
import SwiftUI

/// Live view of the in-memory DeepSeek usage totals.
@MainActor
public final class DeepSeekStatsViewModel: ObservableObject {
    @Published public private(set) var snapshot: DeepSeekUsageSnapshot

    private let store: DeepSeekUsageStore
    private var usageCancellable: AnyCancellable?

    public init(store: DeepSeekUsageStore = .shared) {
        self.store = store
        self.snapshot = store.snapshot()
        usageCancellable = NotificationCenter.default
            .publisher(for: .deepSeekUsageDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.snapshot = self.store.snapshot()
            }
    }
}

/// Compact statistics block embedded directly in the cloud backend tab.
/// Collapsed by default behind a single-line summary so settings stay scannable.
struct DeepSeekStatsSection: View {
    @StateObject private var viewModel: DeepSeekStatsViewModel
    @State private var isExpanded = false

    init(store: DeepSeekUsageStore = .shared) {
        _viewModel = StateObject(wrappedValue: DeepSeekStatsViewModel(store: store))
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: GTSpacing.xSmall) {
                if viewModel.snapshot.requestCount == 0 {
                    Text("尚无请求记录，完成一次翻译后自动更新。")
                        .font(GTType.caption)
                        .foregroundStyle(GTColor.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, GTSpacing.xxSmall)
                } else {
                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(), spacing: GTSpacing.small, alignment: .leading),
                            GridItem(.flexible(), spacing: GTSpacing.small, alignment: .leading)
                        ],
                        alignment: .leading,
                        spacing: GTSpacing.xSmall
                    ) {
                        metric("预估费用", costText(viewModel.snapshot.estimatedCostCNY))
                        metric("请求次数", viewModel.snapshot.requestCount.formatted())
                        metric("输入 tokens", viewModel.snapshot.inputTokens.formatted())
                        metric("缓存命中 tokens", viewModel.snapshot.cachedInputTokens.formatted())
                        metric("输出 tokens", viewModel.snapshot.outputTokens.formatted())
                        metric("缓存命中率", percentText(viewModel.snapshot.cacheHitRate))
                        metric("输出速度", speedText(viewModel.snapshot.outputTokensPerSecond))
                        metric("平均耗时", durationText(viewModel.snapshot))
                    }
                    .padding(.top, GTSpacing.xxSmall)

                    Text("命中率 = 缓存命中 ÷ 输入 tokens；速度 = 输出 tokens ÷ 请求耗时（含网络）；费用按官网美元峰谷价、1 美元 ≈ 7.2 元估算。")
                        .font(GTType.caption)
                        .foregroundStyle(GTColor.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: GTSpacing.xSmall) {
                Text("用量统计")
                    .font(GTType.cardTitle)
                    .foregroundStyle(GTColor.secondaryText)
                Spacer(minLength: GTSpacing.xSmall)
                Text(summaryText)
                    .font(GTType.caption)
                    .monospacedDigit()
                    .foregroundStyle(GTColor.secondaryText)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var summaryText: String {
        let count = viewModel.snapshot.requestCount
        guard count > 0 else { return "本次会话 · 尚无记录" }
        return "本次 \(count) 次 · \(costText(viewModel.snapshot.estimatedCostCNY))"
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: GTSpacing.xxSmall / 2) {
            Text(title)
                .font(GTType.caption)
                .foregroundStyle(GTColor.secondaryText)
                .lineLimit(1)
            Text(value)
                .font(GTType.secondary)
                .monospacedDigit()
                .foregroundStyle(GTColor.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }

    private func costText(_ value: Double) -> String {
        if value == 0 { return "0 元" }
        if value >= 0.01 { return String(format: "%.4f 元", value) }
        return String(format: "%.6f 元", value)
    }

    private func percentText(_ value: Double) -> String {
        String(format: "%.1f%%", value * 100)
    }

    private func speedText(_ value: Double) -> String {
        String(format: "%.1f token/s", value)
    }

    private func durationText(_ snapshot: DeepSeekUsageSnapshot) -> String {
        guard snapshot.requestCount > 0, snapshot.outputTokens > 0, snapshot.outputTokensPerSecond > 0 else {
            return "--"
        }
        let totalSeconds = Double(snapshot.outputTokens) / snapshot.outputTokensPerSecond
        let average = totalSeconds / Double(snapshot.requestCount)
        return String(format: "%.2f s", average)
    }
}
