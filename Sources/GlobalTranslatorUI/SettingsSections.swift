import SwiftUI
import GlobalTranslatorCore
import GlobalTranslatorCapture

/// Popover sections, split out so each stays small and reviewable.
/// All state flows through `SettingsViewModel`; these views hold no logic
/// beyond bindings and labels.

// MARK: - Header

struct SettingsHeaderSection: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: GTSpacing.xSmall) {
            HStack(alignment: .center, spacing: GTSpacing.small) {
                Image(systemName: viewModel.status.symbolName)
                    .font(.title3)
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(GTColor.primaryText)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: GTSpacing.xxSmall) {
                    Text(viewModel.status.accessibilityLabel)
                        .font(GTType.stateLine)
                    if let message = viewModel.visibleAutomaticEnableBlockedReason ?? viewModel.healthMessage,
                       !message.isEmpty {
                        Text(message)
                            .font(GTType.secondary)
                            .foregroundStyle(GTColor.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: GTSpacing.small)
                Toggle(
                    "自动翻译",
                    isOn: Binding(
                        get: { viewModel.isAutomaticTranslationEnabled },
                        set: { viewModel.setAutomaticTranslation($0) }
                    )
                )
                .toggleStyle(.switch)
                // Disabled only for OFF→ON when the gate fails; turning OFF is
                // always possible.
                .disabled(!viewModel.isAutomaticTranslationEnabled && !viewModel.canEnableAutomaticTranslation)
                .accessibilityHint(
                    viewModel.isAutomaticTranslationEnabled
                        ? "关闭自动翻译"
                        : (viewModel.automaticEnableBlockedReason ?? "开启后自动翻译活动窗口文本")
                )
            }
            .accessibilityElement(children: .contain)
            Toggle(
                "滑词翻译",
                isOn: Binding(
                    get: { viewModel.isSelectionTranslateEnabled },
                    set: { viewModel.setSelectionTranslate($0) }
                )
            )
            .toggleStyle(.switch)
            .accessibilityHint("划选文字后在附近显示译文，默认开启")
        }
    }
}

// MARK: - Backend picker + fixed target

struct BackendPickerSection: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: GTSpacing.xSmall) {
            Text("翻译后端")
                .font(GTType.sectionTitle)
            Picker("翻译后端", selection: Binding(
                get: { viewModel.selectedBackend },
                set: { viewModel.selectBackend($0) }
            )) {
                Text("DeepSeek 云端").tag(BackendKind.deepSeekCloud)
                Text("本地模型").tag(BackendKind.local)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("翻译后端")

            HStack {
                Text("目标语言")
                    .font(GTType.body)
                Spacer()
                Text(viewModel.targetLanguageDisplayName)
                    .font(GTType.body)
                    .foregroundStyle(GTColor.secondaryText)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("目标语言，固定为简体中文")
        }
    }
}

// MARK: - Cloud backend

struct CloudBackendSection: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: GTSpacing.xSmall) {
            HStack {
                Text("API Key")
                    .font(GTType.body)
                Spacer()
                Text(viewModel.keyConfigured ? "已配置 · 不会显示" : "未配置")
                    .font(GTType.secondary)
                    .foregroundStyle(viewModel.keyConfigured ? GTColor.secondaryText : GTColor.destructive)
            }

            SecureField("输入新的 API Key", text: $viewModel.keyDraft)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("DeepSeek API Key")
                .accessibilityHint("出于安全考虑，已保存的密钥不会显示或预填")

            if case .failure(let message) = viewModel.keyOperation {
                Text(message)
                    .font(GTType.secondary)
                    .foregroundStyle(GTColor.destructive)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: GTSpacing.xSmall) {
                Button(action: { Task { await viewModel.saveKey() } }) {
                    if viewModel.isKeyOperationInProgress {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(viewModel.keyConfigured ? "替换密钥" : "保存密钥")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canSaveKey)
                .accessibilityHint("保存后输入框将清空")

                if viewModel.keyConfigured {
                    Button("删除密钥", role: .destructive) {
                        viewModel.requestDeleteKey()
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.isKeyOperationInProgress)
                }
            }
            .frame(minHeight: GTPopoverMetrics.minRowHitHeight)

            Divider()

            Toggle(
                "视觉兜底（截图识别）",
                isOn: Binding(
                    get: { viewModel.visionFallbackEnabled },
                    set: { viewModel.setVisionFallbackEnabled($0) }
                )
            )
            .toggleStyle(.switch)
            .accessibilityHint("辅助功能无法读取文本时，将局部截图上传 DeepSeek 识别，开启前需确认")

            ConnectionTestRow(viewModel: viewModel)
        }
    }
}

// MARK: - Local backend

struct LocalBackendSection: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: GTSpacing.xSmall) {
            Text("本地服务地址")
                .font(GTType.body)
            TextField("http://127.0.0.1:11434/v1", text: $viewModel.localBaseURL)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("本地服务地址")
                .accessibilityHint("仅限本机回环地址，例如 http://127.0.0.1:11434/v1")
                .onSubmit { viewModel.commitLocalConfiguration() }

            if viewModel.availableModels.isEmpty {
                Text("尚未获取模型列表，请先测试连接")
                    .font(GTType.secondary)
                    .foregroundStyle(GTColor.secondaryText)
            } else {
                Picker("模型", selection: $viewModel.localModel) {
                    ForEach(viewModel.availableModels, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
                .accessibilityHint("选择本地翻译使用的模型")
                .onChange(of: viewModel.localModel) { _, _ in
                    viewModel.commitLocalConfiguration()
                }
            }

            HStack(spacing: GTSpacing.xSmall) {
                Button("应用设置") {
                    viewModel.commitLocalConfiguration()
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.localBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .frame(minHeight: GTPopoverMetrics.minRowHitHeight)

            ConnectionTestRow(viewModel: viewModel)

            Text("本工具只连接本机回环服务；模型服务是否联网由其自身配置决定。首次翻译可能较慢。")
                .font(GTType.caption)
                .foregroundStyle(GTColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Shared connection test row

struct ConnectionTestRow: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: GTSpacing.xxSmall) {
            HStack(spacing: GTSpacing.xSmall) {
                Button(action: { Task { await viewModel.testConnection() } }) {
                    if viewModel.connectionTest == .testing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("测试连接")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(!viewModel.canTestConnection)
                .accessibilityHint(testHint)
            }
            .frame(minHeight: GTPopoverMetrics.minRowHitHeight)

            switch viewModel.connectionTest {
            case .healthy(let message):
                Text(message)
                    .font(GTType.secondary)
                    .foregroundStyle(GTColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            case .failed(let message):
                Text(message)
                    .font(GTType.secondary)
                    .foregroundStyle(GTColor.destructive)
                    .fixedSize(horizontal: false, vertical: true)
            case .idle, .testing:
                EmptyView()
            }
        }
    }

    private var testHint: String {
        viewModel.canTestConnection
            ? "向当前后端发送一次健康检查"
            : (viewModel.selectedBackend == .deepSeekCloud ? "请先配置 API Key" : "请先填写本地服务地址")
    }
}

// MARK: - Permissions

struct PermissionsSection: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: GTSpacing.xSmall) {
            HStack {
                Text("系统权限")
                    .font(GTType.sectionTitle)
                Spacer()
                Button("重新检查", action: viewModel.refreshPermissions)
                    .accessibilityLabel("重新检查系统权限")
            }
            PermissionRow(
                title: "辅助功能",
                granted: viewModel.permissionSnapshot.accessibilityTrusted,
                kind: .accessibility,
                viewModel: viewModel
            )
            PermissionRow(
                title: "屏幕录制",
                granted: viewModel.permissionSnapshot.screenCaptureAuthorized,
                kind: .screenCapture,
                viewModel: viewModel
            )
            if !viewModel.permissionSnapshot.accessibilityTrusted
                || !viewModel.permissionSnapshot.screenCaptureAuthorized {
                Text("授权后返回此窗口会自动检查。若更新应用后仍显示未授权，请在系统设置中重新授权当前版本，再退出并重新打开应用。")
                    .font(GTType.secondary)
                    .foregroundStyle(GTColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let granted: Bool
    let kind: PermissionKind
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        HStack(spacing: GTSpacing.xSmall) {
            Text(title)
                .font(GTType.body)
            Text(granted ? "已授权" : "未授权")
                .font(GTType.secondary)
                .foregroundStyle(granted ? GTColor.secondaryText : GTColor.destructive)
            Spacer()
            if !granted {
                Button("授权") {
                    viewModel.requestPermission(kind)
                }
                .buttonStyle(.bordered)
                Button("打开系统设置") {
                    viewModel.openSystemSettings(kind)
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(minHeight: GTPopoverMetrics.minRowHitHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title)，\(granted ? "已授权" : "未授权")")
    }
}

// MARK: - Translated applications

struct TranslatedApplicationsSection: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: GTSpacing.xSmall) {
            Text("要翻译的应用")
                .font(GTType.sectionTitle)

            if viewModel.translatedApplications.isEmpty {
                Text("未选择要翻译的应用")
                    .font(GTType.secondary)
                    .foregroundStyle(GTColor.secondaryText)
            } else {
                ForEach(viewModel.translatedApplications) { app in
                    HStack(spacing: GTSpacing.xSmall) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(app.displayName)
                                .font(GTType.body)
                                .lineLimit(1)
                            Text(app.bundleIdentifier)
                                .font(GTType.caption)
                                .foregroundStyle(GTColor.secondaryText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Button(action: {
                            viewModel.removeTranslationApplication(bundleIdentifier: app.bundleIdentifier)
                        }) {
                            Image(systemName: "minus.circle")
                                .accessibilityHidden(true)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("移除 \(app.displayName)")
                    }
                    .frame(minHeight: GTPopoverMetrics.minRowHitHeight)
                }
            }

            Text("只有所选应用会被采集并翻译；未选择时不翻译任何应用。修改立即生效。")
                .font(GTType.secondary)
                .foregroundStyle(GTColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            Button("选择应用…") {
                viewModel.chooseTranslatedApplications()
            }
            .buttonStyle(.bordered)
            .accessibilityHint("选择一个或多个要翻译的应用，可按住 Command 多选")
        }
    }
}

// MARK: - Footer

struct SettingsFooterSection: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        HStack(spacing: GTSpacing.xSmall) {
            Button("清除缓存") {
                viewModel.requestClearCache()
            }
            .buttonStyle(.bordered)
            .accessibilityHint("删除本地翻译缓存，需确认")

            Button("打开日志") {
                viewModel.openLogs()
            }
            .buttonStyle(.bordered)

            Spacer()

            Button("退出 Global Translator") {
                viewModel.quit()
            }
            .buttonStyle(.bordered)
            .foregroundStyle(GTColor.destructive)
            .accessibilityHint("停止翻译并退出程序")
        }
        .frame(minHeight: GTPopoverMetrics.minRowHitHeight)
    }
}
