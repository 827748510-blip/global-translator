import SwiftUI

/// Root view of the menu-bar settings popover. 360px wide, 3-tab structure
/// (翻译 / 后端 / 高级) with pinned status header, setup guidance banner,
/// scrollable tab content, and pinned footer.
public struct SettingsPopoverView: View {
    private var viewModel: SettingsViewModel

    /// Height ceiling, recomputed from the screen's visible frame at show time.
    private let maxHeight: CGFloat
    private let onPreferredHeightChange: ((CGFloat) -> Void)?

    public init(
        viewModel: SettingsViewModel,
        maxHeight: CGFloat = GTPopoverMetrics.defaultMaxHeight,
        onPreferredHeightChange: ((CGFloat) -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.maxHeight = maxHeight
        self.onPreferredHeightChange = onPreferredHeightChange
    }

    public var body: some View {
        @Bindable var bindable = viewModel

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
                    height: GTControlMetrics.segmentHeight,
                    accessibilityLabelText: "设置分区"
                )
            }
            .padding(.horizontal, GTPopoverMetrics.contentPadding)
            .padding(.top, GTPopoverMetrics.contentPadding)

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
            }
            .scrollIndicators(.automatic)

            SettingsFooterSection(viewModel: viewModel)
                .padding(.horizontal, GTPopoverMetrics.contentPadding)
                .padding(.bottom, GTPopoverMetrics.contentPadding)
        }
        .frame(width: GTPopoverMetrics.width)
        .frame(maxHeight: maxHeight)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { _, newHeight in
            onPreferredHeightChange?(newHeight)
        }
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
}
