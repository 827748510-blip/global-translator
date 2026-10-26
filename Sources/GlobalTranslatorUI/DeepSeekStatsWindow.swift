import AppKit
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

public struct DeepSeekStatsView: View {
    @ObservedObject private var viewModel: DeepSeekStatsViewModel

    public init(viewModel: DeepSeekStatsViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: GTSpacing.small) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("DeepSeek 用量统计")
                        .font(.title3.weight(.semibold))
                    Text("本次会话累计 · \(viewModel.snapshot.lastModel)")
                        .font(GTType.caption)
                        .foregroundStyle(GTColor.secondaryText)
                }

                if viewModel.snapshot.requestCount == 0 {
                    GTSettingsCard {
                        Text("尚无请求记录")
                            .font(GTType.body)
                            .foregroundStyle(GTColor.primaryText)
                        Text("完成一次翻译、划词或优化提示词后，这里会显示 token、缓存命中率和预估费用。")
                            .font(GTType.caption)
                            .foregroundStyle(GTColor.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    GTSettingsCard {
                        metricRow("预估费用", costText(viewModel.snapshot.estimatedCostUSD))
                        Divider()
                        metricRow("请求次数", viewModel.snapshot.requestCount.formatted())
                        metricRow("输入 tokens", viewModel.snapshot.inputTokens.formatted())
                        metricRow("缓存命中 tokens", viewModel.snapshot.cachedInputTokens.formatted())
                        metricRow("输出 tokens", viewModel.snapshot.outputTokens.formatted())
                        Divider()
                        metricRow("缓存命中率", percentText(viewModel.snapshot.cacheHitRate))
                        metricRow("输出速度", speedText(viewModel.snapshot.outputTokensPerSecond))
                    }

                    GTSettingsCard {
                        Text("计算口径")
                            .font(GTType.cardTitle)
                            .foregroundStyle(GTColor.secondaryText)
                        Text("缓存命中率 = 缓存命中 tokens ÷ 输入 tokens。DeepSeek 的全部输入 tokens 都参与自动前缀缓存。")
                            .font(GTType.caption)
                            .foregroundStyle(GTColor.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("输出速度 = 输出 tokens ÷ 请求耗时。耗时按非流式请求的往返时间统计，包含网络时间。")
                            .font(GTType.caption)
                            .foregroundStyle(GTColor.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Text("费用按 deepseek-flash 官网峰谷价估算（USD/1M tokens）；未扣除中国法定节假日，节假日峰值时段可能高估。统计只保存在内存，退出应用后清零。")
                    .font(GTType.caption)
                    .foregroundStyle(GTColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                if let updatedAt = viewModel.snapshot.lastUpdatedAt {
                    Text("最近更新 \(updatedAt.formatted(date: .omitted, time: .standard))")
                        .font(GTType.caption)
                        .foregroundStyle(GTColor.secondaryText)
                }
            }
            .padding(GTSpacing.large)
        }
        .scrollIndicators(.hidden)
        .frame(width: 420)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(GTColor.panelBackground)
    }

    private func metricRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: GTSpacing.small) {
            Text(title)
                .font(GTType.body)
                .foregroundStyle(GTColor.secondaryText)
            Spacer(minLength: GTSpacing.small)
            Text(value)
                .font(GTType.body)
                .monospacedDigit()
                .foregroundStyle(GTColor.primaryText)
                .textSelection(.enabled)
                .accessibilityLabel(title)
                .accessibilityValue(value)
        }
        .frame(minHeight: GTControlMetrics.settingRowHeight)
    }

    private func costText(_ value: Double) -> String {
        if value == 0 { return "$0.00" }
        if value >= 0.01 { return String(format: "$%.4f", value) }
        return String(format: "$%.6f", value)
    }

    private func percentText(_ value: Double) -> String {
        String(format: "%.1f%%", value * 100)
    }

    private func speedText(_ value: Double) -> String {
        String(format: "%.1f token/s", value)
    }
}

/// Standard desktop window for the statistics view. It is retained by the
/// application controller so opening it twice reuses the same window.
@MainActor
public final class DeepSeekStatsWindowController: NSWindowController {
    public init(store: DeepSeekUsageStore = .shared) {
        let view = DeepSeekStatsView(viewModel: DeepSeekStatsViewModel(store: store))
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "DeepSeek 用量统计"
        window.setContentSize(NSSize(width: 420, height: 520))
        window.minSize = NSSize(width: 420, height: 420)
        window.isReleasedWhenClosed = false
        _ = window.setFrameAutosaveName("DeepSeekUsageStatsWindow")
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    public func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate()
    }
}
