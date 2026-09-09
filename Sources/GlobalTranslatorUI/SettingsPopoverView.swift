import SwiftUI

/// Root view of the menu-bar settings popover. ~380px wide, scrolls
/// vertically within the usable screen height (see DESIGN.md §5).
public struct SettingsPopoverView: View {
    @ObservedObject private var viewModel: SettingsViewModel

    /// Height ceiling, recomputed from the screen's visible frame at show time.
    private let maxHeight: CGFloat

    public init(
        viewModel: SettingsViewModel,
        maxHeight: CGFloat = GTPopoverMetrics.defaultMaxHeight
    ) {
        self.viewModel = viewModel
        self.maxHeight = maxHeight
    }

    public var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: GTSpacing.small) {
                GTSettingsCard {
                    SettingsHeaderSection(viewModel: viewModel)
                }
                GTSettingsCard {
                    TranslatedApplicationsSection(viewModel: viewModel)
                }
                GTSettingsCard {
                    BackendPickerSection(viewModel: viewModel)
                    Divider()
                    Group {
                        switch viewModel.selectedBackend {
                        case .deepSeekCloud:
                            CloudBackendSection(viewModel: viewModel)
                        case .local:
                            LocalBackendSection(viewModel: viewModel)
                        }
                    }
                }
                GTSettingsCard {
                    PermissionsSection(viewModel: viewModel)
                }
                SettingsFooterSection(viewModel: viewModel)
            }
            .padding(GTSpacing.medium)
        }
        .frame(width: GTPopoverMetrics.width)
        .frame(maxHeight: maxHeight)
        .background(GTColor.panelBackground)
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
        .alert(
            "开启视觉兜底？",
            isPresented: Binding(
                get: { viewModel.isVisionConsentPresented },
                set: { if !$0 { viewModel.cancelVisionConsent() } }
            )
        ) {
            Button("开启", action: viewModel.confirmVisionConsent)
            Button("取消", role: .cancel, action: viewModel.cancelVisionConsent)
        } message: {
            Text(viewModel.visionConsentText)
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
