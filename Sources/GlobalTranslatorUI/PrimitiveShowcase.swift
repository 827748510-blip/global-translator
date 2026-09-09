#if DEBUG
import SwiftUI
import GlobalTranslatorCore
import GlobalTranslatorCapture
import GlobalTranslatorEngine

/// Debug-only primitive and state showcase. Renders every core primitive and
/// state before product composition, and serves as the screenshot surface for
/// integration visual QA. Not compiled into release builds; no app bundle or
/// preview dependency.
public struct PrimitiveShowcase: View {
    @StateObject private var viewModel: SettingsViewModel

    public init() {
        _viewModel = StateObject(wrappedValue: SettingsViewModel(actions: ShowcaseActions()))
    }

    public var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: GTSpacing.large) {
                statusRowShowcase
                backendPickerShowcase
                permissionRowShowcase
                keyFieldStatesShowcase
                buttonStatesShowcase
                overlaySamplesShowcase
            }
            .padding(GTSpacing.large)
        }
        .frame(width: 420, height: 760)
    }

    // MARK: - Status rows (every state, text always present)

    private var statusRowShowcase: some View {
        showcaseGroup("状态行 / MenuBarStatus") {
            ForEach(MenuBarStatus.allCases, id: \.self) { status in
                HStack(spacing: GTSpacing.xSmall) {
                    Image(systemName: status.symbolName)
                        .symbolRenderingMode(.monochrome)
                        .accessibilityHidden(true)
                    Text(status.accessibilityLabel)
                        .font(GTType.body)
                    Spacer()
                    Text(status.symbolName)
                        .font(GTType.caption)
                        .foregroundStyle(GTColor.secondaryText)
                }
            }
        }
    }

    // MARK: - Backend picker

    private var backendPickerShowcase: some View {
        showcaseGroup("后端选择") {
            BackendPickerSection(viewModel: viewModel)
        }
    }

    // MARK: - Permission rows

    private var permissionRowShowcase: some View {
        showcaseGroup("权限行") {
            PermissionsSection(viewModel: viewModel)
        }
    }

    // MARK: - Secure key field states

    private var keyFieldStatesShowcase: some View {
        showcaseGroup("密钥输入状态") {
            CloudBackendSection(viewModel: viewModel)
            Divider()
            Text("错误状态示例")
                .font(GTType.caption)
                .foregroundStyle(GTColor.secondaryText)
            errorStateExample
        }
    }

    private var errorStateExample: some View {
        VStack(alignment: .leading, spacing: GTSpacing.xxSmall) {
            // Never render a key-shaped value, even a fake one; a disabled
            // empty field plus caption conveys the error state.
            SecureField("已保存的密钥不会显示", text: .constant(""))
                .textFieldStyle(GTFieldTextStyle())
                .disabled(true)
            Text("密钥存储失败，请重试")
                .font(GTType.secondary)
                .foregroundStyle(GTColor.destructive)
        }
    }

    // MARK: - Button states

    private var buttonStatesShowcase: some View {
        showcaseGroup("按钮状态") {
            HStack(spacing: GTSpacing.xSmall) {
                Button("主要操作") {}.buttonStyle(.borderedProminent)
                Button("次要操作") {}.buttonStyle(.bordered)
                Button("禁用") {}.buttonStyle(.bordered).disabled(true)
            }
            HStack(spacing: GTSpacing.xSmall) {
                Button(action: {}) {
                    ProgressView().controlSize(.small)
                }
                .buttonStyle(.bordered)
                .disabled(true)
                .accessibilityLabel("加载中")
                Button("删除", role: .destructive) {}.buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Overlay samples

    private var overlaySamplesShowcase: some View {
        showcaseGroup("译文气泡") {
            VStack(alignment: .leading, spacing: GTSpacing.xSmall) {
                OverlayView(text: "你好，世界")
                OverlayView(
                    text: "这是一段较长的中文翻译结果，用于验证气泡在 320 点宽度内的换行与截断行为，超过三行时末尾显示省略号而不是溢出或裁剪中文字符。"
                )
            }
        }
    }

    // MARK: - Helpers

    private func showcaseGroup<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: GTSpacing.xSmall) {
            Text(title)
                .font(GTType.sectionTitle)
            content()
        }
        .padding(GTSpacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GTColor.sectionFill)
        .clipShape(RoundedRectangle(cornerRadius: GTRadius.card, style: .continuous))
    }
}

/// No-op actions for the showcase; records nothing, touches nothing.
@MainActor
private final class ShowcaseActions: SettingsActions {
    func setAutomaticTranslation(_ enabled: Bool) {}
    func setSelectionTranslate(_ enabled: Bool) {}
    func setVideoTranslate(_ enabled: Bool) {}
    func setPromptOptimizeMode(_ mode: PromptOptimizeMode) {}
    func selectBackend(_ kind: BackendKind) {}
    func saveAPIKey(_ draft: String) async throws {}
    func deleteAPIKey() async throws {}
    func testConnection() async throws -> BackendHealth {
        BackendHealth(status: .healthy, message: "示例：连接正常", availableModels: ["deepseek-chat"])
    }
    func setVisionFallback(_ enabled: Bool) {}
    func setLocalConfiguration(baseURL: String, model: String) {}
    func setDeepSeekModel(_ model: String) {}
    func requestPermission(_ kind: PermissionKind) {}
    func refreshPermissions() {}
    func openSystemSettings(_ kind: PermissionKind) {}
    func addCurrentAppTranslation() {}
    func chooseTranslatedApplications() {}
    func removeTranslationApplication(bundleIdentifier: String) {}
    func clearCache() async throws {}
    func openLogs() {}
    func quit() {}
}
#endif
