import SwiftUI

/// Root view of the menu-bar settings popover. 360px wide, 3-tab structure
/// (翻译 / 后端 / 高级) with pinned status header, setup guidance banner,
/// scrollable tab content, and pinned footer.
public struct SettingsPopoverView: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private var viewModel: SettingsViewModel

    /// Height ceiling, recomputed from the screen's visible frame at show time.
    private let maxHeight: CGFloat
    private let onPreferredHeightChange: ((CGFloat) -> Void)?

    @State private var headerHeight: CGFloat = 0
    @State private var scrollContentHeight: CGFloat = 0
    @State private var footerHeight: CGFloat = 0

    public init(
        viewModel: SettingsViewModel,
        maxHeight: CGFloat = GTPopoverMetrics.defaultMaxHeight,
        onPreferredHeightChange: ((CGFloat) -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.maxHeight = maxHeight
        self.onPreferredHeightChange = onPreferredHeightChange
    }

    private var measuredIdealHeight: CGFloat {
        guard headerHeight > 0, footerHeight > 0 else { return maxHeight }
        return headerHeight + scrollContentHeight + footerHeight + GTSpacing.xSmall * 2
    }

    private var resolvedScrollHeight: CGFloat? {
        guard scrollContentHeight > 0, headerHeight > 0, footerHeight > 0 else { return nil }
        let available = max(80, maxHeight - headerHeight - footerHeight - GTSpacing.xSmall * 2)
        return min(scrollContentHeight, available)
    }

    public var body: some View {
        @Bindable var bindable = viewModel
        let footerShape = RoundedRectangle(cornerRadius: GTRadius.card, style: .continuous)

        VStack(alignment: .leading, spacing: GTSpacing.xSmall) {
            VStack(alignment: .leading, spacing: GTSpacing.xSmall) {
                GTSettingsCard {
                    SettingsHeaderSection(viewModel: viewModel)
                }

                SettingsSetupBanner(viewModel: viewModel)

                GTEqualWidthSegmentedPicker(
                    options: SettingsTab.allCases,
                    selection: $bindable.selectedTab,
                    title: { $0.title },
                    height: 32,
                    usesCardSurfaceTrack: true,
                    accessibilityLabelText: "设置分区"
                )
            }
            .padding(.horizontal, GTPopoverMetrics.contentPadding)
            .padding(.top, GTPopoverMetrics.contentPadding)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { _, newHeight in
                headerHeight = newHeight
                reportPreferredHeight()
            }

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: GTPopoverMetrics.cardSpacing) {
                    switch viewModel.selectedTab {
                    case .translation:
                        GTSettingsCard {
                            TranslationCoreSection(viewModel: viewModel)
                        }
                        GTSettingsCard {
                            TranslatedApplicationsSection(viewModel: viewModel)
                        }
                        GTSettingsCard {
                            ScreenshotTranslateSection(viewModel: viewModel)
                        }
                    case .backend:
                        GTSettingsCard {
                            BackendPickerSection(viewModel: viewModel)
                            Divider()
                            switch viewModel.selectedBackend {
                            case .deepSeekCloud:
                                CloudBackendSection(viewModel: viewModel)
                            case .local:
                                LocalBackendSection(viewModel: viewModel)
                            }
                        }
                        if viewModel.selectedBackend == .deepSeekCloud {
                            GTSettingsCard {
                                DeepSeekStatsSection()
                            }
                        }
                    case .advanced:
                        GTSettingsCard {
                            PermissionsSection(viewModel: viewModel)
                        }
                        GTSettingsCard {
                            MaintenanceSection(viewModel: viewModel)
                        }
                    }
                }
                .padding(.horizontal, GTPopoverMetrics.contentPadding)
                .padding(.vertical, GTSpacing.xxSmall)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { _, newHeight in
                    scrollContentHeight = newHeight
                    reportPreferredHeight()
                }
            }
            .frame(height: resolvedScrollHeight)
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.hidden)

            SettingsFooterSection(viewModel: viewModel)
                .padding(.horizontal, GTControlMetrics.cardHorizontalPadding)
                .padding(.vertical, GTSpacing.xSmall)
                .background(reduceTransparency ? GTColor.sectionFill : GTColor.cardSurface)
                .clipShape(footerShape)
                .overlay(
                    footerShape.strokeBorder(GTColor.hairline, lineWidth: GTControlMetrics.fieldStrokeWidth)
                )
                .padding(.horizontal, GTPopoverMetrics.contentPadding)
                .padding(.bottom, GTPopoverMetrics.contentPadding)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { _, newHeight in
                    footerHeight = newHeight
                    reportPreferredHeight()
                }
        }
        .frame(width: GTPopoverMetrics.width)
        .frame(maxHeight: maxHeight)
        .foregroundStyle(GTColor.primaryText)
        // The rounded glass surface is owned by StatusItemController's root.
        .background(Color.clear)
        .confirmationDialog(
            "删除已保存的 API Key？",
            isPresented: Binding(
                get: { viewModel.isDeleteKeyConfirmationPresented },
                set: { if !$0 { viewModel.cancelDeleteKey() } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除密钥", role: .destructive) {
                Task { await viewModel.confirmDeleteKey() }
            }
            Button("取消", role: .cancel) {
                viewModel.cancelDeleteKey()
            }
        } message: {
            Text("删除后需要重新输入密钥才能使用云端翻译。此操作不会影响其他设置。")
        }
        .confirmationDialog(
            "清除本地翻译缓存？",
            isPresented: Binding(
                get: { viewModel.isClearCacheConfirmationPresented },
                set: { if !$0 { viewModel.cancelClearCache() } }
            ),
            titleVisibility: .visible
        ) {
            Button("清除缓存", role: .destructive) {
                Task { await viewModel.confirmClearCache() }
            }
            Button("取消", role: .cancel) {
                viewModel.cancelClearCache()
            }
        } message: {
            Text("清除后已翻译内容需要重新请求后端。")
        }
    }

    private func reportPreferredHeight() {
        guard headerHeight > 0, scrollContentHeight > 0, footerHeight > 0 else { return }
        onPreferredHeightChange?(min(maxHeight, max(240, measuredIdealHeight)))
    }
}
