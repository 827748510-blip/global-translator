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
        VStack(alignment: .leading, spacing: GTSpacing.small) {
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

            Divider()

            HStack(alignment: .center, spacing: GTSpacing.medium) {
                Toggle(
                    "滑词翻译",
                    isOn: Binding(
                        get: { viewModel.isSelectionTranslateEnabled },
                        set: { viewModel.setSelectionTranslate($0) }
                    )
                )
                .toggleStyle(.switch)
                .accessibilityHint("划选后显示译文，并可按场景优化措辞，默认开启")

                Spacer(minLength: GTSpacing.small)

                Toggle(
                    "视频翻译",
                    isOn: Binding(
                        get: { viewModel.isVideoTranslateEnabled },
                        set: { viewModel.setVideoTranslate($0) }
                    )
                )
                .toggleStyle(.switch)
                .accessibilityHint("启用后对网页视频字幕叠简体中文；无外语字幕时用本机系统/窗口音频转写。默认关闭，不单独占一行")
            }
            .frame(minHeight: GTPopoverMetrics.minRowHitHeight)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .contain)

            if viewModel.isSelectionTranslateEnabled {
                GTLabeledControl(title: "优化场景") {
                    GTOptimizeModePicker(
                        selection: Binding(
                            get: { viewModel.promptOptimizeMode },
                            set: { viewModel.setPromptOptimizeMode($0) }
                        )
                    )
                }
            }
        }
    }
}

// MARK: - Screenshot translate

struct ScreenshotTranslateSection: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: GTSpacing.small) {
            Text("截图翻译")
                .font(GTType.sectionTitle)

            GTLabeledControl(title: "快捷键") {
                HStack(spacing: GTSpacing.xSmall) {
                    Text(viewModel.screenshotTranslateHotkey.displayString)
                        .font(GTType.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, GTSpacing.small)
                        .frame(height: GTControlMetrics.fieldHeight)
                        .background(GTColor.fieldFill)
                        .clipShape(RoundedRectangle(cornerRadius: GTRadius.row, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: GTRadius.row, style: .continuous)
                                .strokeBorder(GTColor.hairline, lineWidth: GTControlMetrics.fieldStrokeWidth)
                        )
                        .accessibilityLabel("截图翻译快捷键")
                        .accessibilityValue(viewModel.screenshotTranslateHotkey.displayString)
                    Button(viewModel.isRecordingScreenshotHotkey
                           ? KeyboardShortcutSupport.recordingPromptCopy
                           : "录制") {
                        if viewModel.isRecordingScreenshotHotkey {
                            viewModel.cancelRecordingScreenshotHotkey()
                        } else {
                            viewModel.beginRecordingScreenshotHotkey()
                        }
                    }
                    .buttonStyle(.glass)
                    .accessibilityHint("录制新的截图翻译快捷键，按下带修饰键的组合即可保存")
                }
            }

            if let message = viewModel.screenshotHotkeyConflictMessage, !message.isEmpty {
                Text(message)
                    .font(GTType.secondary)
                    .foregroundStyle(GTColor.destructive)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("快捷键冲突")
                    .accessibilityValue(message)
            }

            Toggle(
                "自动复制译文",
                isOn: Binding(
                    get: { viewModel.autoCopyScreenshotTranslation },
                    set: { viewModel.setAutoCopyScreenshotTranslation($0) }
                )
            )
            .toggleStyle(.switch)
            .frame(minHeight: GTPopoverMetrics.minRowHitHeight)
            .accessibilityHint("翻译成功后自动把简体中文译文写入剪贴板，默认关闭")

            HStack(alignment: .center, spacing: GTSpacing.medium) {
                Toggle(
                    "保存截图",
                    isOn: Binding(
                        get: { viewModel.saveScreenshotImage },
                        set: { viewModel.setSaveScreenshotImage($0) }
                    )
                )
                .toggleStyle(.switch)
                .accessibilityHint("截图后把拖选区域存成 PNG 文件，默认关闭")

                Spacer(minLength: GTSpacing.small)

                Toggle(
                    "复制截图",
                    isOn: Binding(
                        get: { viewModel.copyScreenshotImage },
                        set: { viewModel.setCopyScreenshotImage($0) }
                    )
                )
                .toggleStyle(.switch)
                .accessibilityHint("截图后把拖选区域复制到剪贴板，默认关闭")
            }
            .frame(minHeight: GTPopoverMetrics.minRowHitHeight)

            HStack(alignment: .center, spacing: GTSpacing.xSmall) {
                Text("保存位置")
                    .font(GTType.body)
                    .foregroundStyle(GTColor.secondaryText)
                Text(SelectionTranslateSupport.displayPath(viewModel.screenshotSaveDirectory))
                    .font(GTType.caption)
                    .foregroundStyle(GTColor.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .accessibilityLabel("截图保存位置")
                    .accessibilityValue(SelectionTranslateSupport.displayPath(viewModel.screenshotSaveDirectory))
                Button("选择…") {
                    viewModel.chooseScreenshotSaveDirectory()
                }
                .buttonStyle(.glass)
                .accessibilityHint("选择截图保存文件夹")
            }
            .accessibilityElement(children: .contain)

            Text("按快捷键后拖选区域。文字由本机 Vision 识别（中/英），再走当前翻译后端。需要屏幕录制权限。")
                .font(GTType.caption)
                .foregroundStyle(GTColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Backend picker + fixed target

struct BackendPickerSection: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: GTSpacing.small) {
            Text("翻译后端")
                .font(GTType.sectionTitle)
            GTEqualWidthSegmentedPicker(
                options: [BackendKind.deepSeekCloud, .local],
                selection: Binding(
                    get: { viewModel.selectedBackend },
                    set: { viewModel.selectBackend($0) }
                ),
                title: { $0.displayTitle },
                accessibilityLabelText: "翻译后端"
            )

            Text("默认 Ollama 地址且由 Homebrew 管理时：切到 DeepSeek 云端会停止 Ollama 服务（进行中的本地翻译会中断），切回本地模型会自动启动并等接口就绪。其他本地服务不受影响。")
                .font(GTType.caption)
                .foregroundStyle(GTColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            GTLabeledControl(title: "窗口/网页目标语言") {
                GTReadOnlyField(value: viewModel.targetLanguageDisplayName)
                    .accessibilityLabel("窗口覆盖层与网页整页翻译固定为简体中文；划词与截图自动判断中英互译方向")
            }
        }
    }
}

// MARK: - Cloud backend

struct CloudBackendSection: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: GTSpacing.small) {
            HStack {
                Text("API Key")
                    .font(GTType.body)
                Spacer()
                Text(viewModel.keyConfigured ? "已配置 · 钥匙串保存" : "未配置")
                    .font(GTType.secondary)
                    .foregroundStyle(viewModel.keyConfigured ? GTColor.secondaryText : GTColor.destructive)
            }

            if viewModel.showsKeyEntry {
                SecureField("输入新的 API Key", text: $viewModel.keyDraft)
                    .textFieldStyle(GTFieldTextStyle())
                    .accessibilityLabel("DeepSeek API Key")
                    .accessibilityHint("出于安全考虑，已保存的密钥不会显示或预填")
            }

            if case .failure(let message) = viewModel.keyOperation {
                Text(message)
                    .font(GTType.secondary)
                    .foregroundStyle(GTColor.destructive)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: GTSpacing.xSmall) {
                if viewModel.showsKeyEntry {
                    Button(action: { Task { await viewModel.saveKey() } }) {
                        if viewModel.isKeyOperationInProgress {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("保存密钥")
                        }
                    }
                    .buttonStyle(.glass)
                    .frame(maxWidth: .infinity)
                    .disabled(!viewModel.canSaveKey)
                    .accessibilityHint("保存后输入框将清空，密钥只写入钥匙串")

                    if viewModel.isReplacingKey {
                        Button("取消") {
                            viewModel.cancelReplaceKey()
                        }
                        .buttonStyle(.glass)
                        .frame(maxWidth: .infinity)
                        .disabled(viewModel.isKeyOperationInProgress)
                    }
                } else {
                    Button("替换密钥") {
                        viewModel.beginReplaceKey()
                    }
                    .buttonStyle(.glass)
                    .frame(maxWidth: .infinity)
                    .disabled(viewModel.isKeyOperationInProgress)
                    .accessibilityHint("仅在替换时显示输入框，已保存的密钥不会回填")
                }

                if viewModel.keyConfigured {
                    Button("删除密钥", role: .destructive) {
                        viewModel.requestDeleteKey()
                    }
                    .buttonStyle(.glass)
                    .frame(maxWidth: .infinity)
                    .disabled(viewModel.isKeyOperationInProgress)
                }
            }
            .frame(minHeight: GTPopoverMetrics.minRowHitHeight)

            GTLabeledControl(title: "模型") {
                if viewModel.availableModels.isEmpty {
                    GTReadOnlyField(value: viewModel.keyConfigured
                        ? "尚未获取模型列表，请先测试连接"
                        : "可测试连接验证已有钥匙串密钥，或保存 API Key")
                        .accessibilityLabel("模型")
                        .accessibilityValue(viewModel.keyConfigured
                            ? "尚未获取模型列表"
                            : "可测试连接或保存 API Key")
                } else {
                    GTSelectField(
                        options: viewModel.availableModels,
                        selection: $viewModel.deepSeekModel,
                        placeholder: "选择 DeepSeek 模型",
                        onChange: { viewModel.commitDeepSeekModel() }
                    )
                    .accessibilityLabel("模型")
                    .accessibilityHint("选择云端翻译使用的模型")
                }
            }

            Toggle(
                "视觉兜底（截图识别）",
                isOn: Binding(
                    get: { viewModel.visionFallbackEnabled },
                    set: { viewModel.setVisionFallbackEnabled($0) }
                )
            )
            .toggleStyle(.switch)
            .frame(minHeight: GTPopoverMetrics.minRowHitHeight)
            .accessibilityHint("辅助功能无法读取文本时，将局部截图上传 DeepSeek 识别，开启前需确认")

            ConnectionTestRow(viewModel: viewModel, fillsWidth: true)
        }
    }
}

// MARK: - Local backend

struct LocalBackendSection: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: GTSpacing.small) {
            GTLabeledControl(title: "本地服务地址") {
                TextField("http://127.0.0.1:11434/v1", text: $viewModel.localBaseURL)
                    .textFieldStyle(GTFieldTextStyle())
                    .accessibilityLabel("本地服务地址")
                    .accessibilityHint("仅限本机回环地址，例如 http://127.0.0.1:11434/v1")
                    .onSubmit { viewModel.commitLocalConfiguration() }
            }

            GTLabeledControl(title: "模型") {
                if viewModel.availableModels.isEmpty {
                    GTReadOnlyField(value: "尚未获取模型列表，请先测试连接")
                        .accessibilityLabel("模型")
                        .accessibilityValue("尚未获取模型列表")
                } else {
                    GTSelectField(
                        options: viewModel.availableModels,
                        selection: $viewModel.localModel,
                        placeholder: "选择本地模型",
                        onChange: { viewModel.commitLocalConfiguration() }
                    )
                    .accessibilityLabel("模型")
                    .accessibilityHint("选择本地翻译使用的模型")
                }
            }

            GTActionRow {
                Button(action: { Task { await viewModel.testConnection() } }) {
                    if viewModel.connectionTest == .testing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("测试连接")
                    }
                }
                .buttonStyle(.glass)
                .disabled(!viewModel.canTestConnection)
                .accessibilityHint(ConnectionTestRow.testHint(for: viewModel))
            } secondary: {
                Button("应用设置") {
                    viewModel.commitLocalConfiguration()
                }
                .buttonStyle(.glass)
                .disabled(viewModel.localBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            ConnectionTestStatus(viewModel: viewModel)

            Text("只连接本机回环服务；首次翻译可能较慢。")
                .font(GTType.caption)
                .foregroundStyle(GTColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Shared connection test row

struct ConnectionTestRow: View {
    @ObservedObject var viewModel: SettingsViewModel
    var fillsWidth: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: GTSpacing.xxSmall) {
            Button(action: { Task { await viewModel.testConnection() } }) {
                if viewModel.connectionTest == .testing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text("测试连接")
                }
            }
            .buttonStyle(.glass)
            .frame(maxWidth: fillsWidth ? .infinity : nil)
            .disabled(!viewModel.canTestConnection)
            .accessibilityHint(Self.testHint(for: viewModel))
            .frame(minHeight: GTPopoverMetrics.minRowHitHeight)

            ConnectionTestStatus(viewModel: viewModel)
        }
    }

    static func testHint(for viewModel: SettingsViewModel) -> String {
        if viewModel.canTestConnection {
            if viewModel.selectedBackend == .deepSeekCloud, !viewModel.keyConfigured {
                return "向当前后端发送一次健康检查，可验证已保存在钥匙串中的密钥"
            }
            return "向当前后端发送一次健康检查"
        }
        return viewModel.selectedBackend == .deepSeekCloud
            ? "请先配置 API Key"
            : "请先填写本地服务地址"
    }
}

struct ConnectionTestStatus: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
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

// MARK: - Permissions

struct PermissionsSection: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: GTSpacing.small) {
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
                Text("授权后返回此窗口会自动检查。更新后若仍显示未授权，请在系统设置中重新授权当前版本。")
                    .font(GTType.caption)
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
                .buttonStyle(.glass)
                Button("打开系统设置") {
                    viewModel.openSystemSettings(kind)
                }
                .buttonStyle(.glass)
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
        VStack(alignment: .leading, spacing: GTSpacing.small) {
            HStack(alignment: .firstTextBaseline) {
                Text("要翻译的应用")
                    .font(GTType.sectionTitle)
                Spacer(minLength: GTSpacing.small)
                Button("选择应用…") {
                    viewModel.chooseTranslatedApplications()
                }
                .buttonStyle(.glass)
                .controlSize(.regular)
                .accessibilityHint("选择一个或多个要翻译的应用，可按住 Command 多选")
            }

            if viewModel.translatedApplications.isEmpty {
                Text("未选择要翻译的应用")
                    .font(GTType.secondary)
                    .foregroundStyle(GTColor.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(GTSpacing.small)
                    .frame(minHeight: GTPopoverMetrics.minRowHitHeight)
                    .background(GTColor.fieldFill)
                    .clipShape(RoundedRectangle(cornerRadius: GTRadius.row, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: GTRadius.row, style: .continuous)
                            .strokeBorder(GTColor.hairline, lineWidth: GTControlMetrics.fieldStrokeWidth)
                    )
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(viewModel.translatedApplications.enumerated()), id: \.element.id) { index, app in
                        if index > 0 {
                            Divider()
                        }
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
                        .padding(.horizontal, GTSpacing.small)
                        .frame(minHeight: GTPopoverMetrics.minRowHitHeight)
                    }
                }
                .background(GTColor.fieldFill)
                .clipShape(RoundedRectangle(cornerRadius: GTRadius.row, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: GTRadius.row, style: .continuous)
                        .strokeBorder(GTColor.hairline, lineWidth: GTControlMetrics.fieldStrokeWidth)
                )
            }

            Text("只有所选应用会被翻译；未选择时不翻译任何应用。")
                .font(GTType.caption)
                .foregroundStyle(GTColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
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
            .buttonStyle(.glass)
            .accessibilityHint("删除本地翻译缓存，需确认")

            Button("打开日志") {
                viewModel.openLogs()
            }
            .buttonStyle(.glass)

            Spacer()

            Button("退出 Global Translator") {
                viewModel.quit()
            }
            .buttonStyle(.glass)
            .foregroundStyle(GTColor.destructive)
            .accessibilityHint("停止翻译并退出程序")
        }
        .frame(minHeight: GTPopoverMetrics.minRowHitHeight)
    }
}
