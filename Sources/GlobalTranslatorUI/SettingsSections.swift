import SwiftUI
import GlobalTranslatorCore
import GlobalTranslatorCapture

/// Popover sections, split out so each stays small and reviewable.
/// All state flows through `SettingsViewModel`; these views hold no logic
/// beyond bindings and labels.

// MARK: - Header & Setup Banner

struct SettingsHeaderSection: View {
    var viewModel: SettingsViewModel

    var body: some View {
        HStack(alignment: .center, spacing: GTSpacing.xSmall) {
            Image(systemName: viewModel.status.symbolName)
                .font(.title3.weight(.semibold))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(GTColor.primaryText)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: GTSpacing.xxSmall / 2) {
                Text(viewModel.status.accessibilityLabel)
                    .font(GTType.stateLine)
                    .lineLimit(1)
                if let message = viewModel.visibleAutomaticEnableBlockedReason ?? viewModel.healthMessage,
                   !message.isEmpty {
                    Text(message)
                        .font(GTType.caption)
                        .foregroundStyle(GTColor.secondaryText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: GTSpacing.xSmall)
            Toggle(
                "自动翻译",
                isOn: Binding(
                    get: { viewModel.isAutomaticTranslationEnabled },
                    set: { viewModel.setAutomaticTranslation($0) }
                )
            )
            .toggleStyle(.switch)
            .controlSize(.small)
            .font(GTType.body)
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
    }
}

struct SettingsSetupBanner: View {
    var viewModel: SettingsViewModel

    private var needsBackendSetup: Bool {
        !viewModel.canEnableAutomaticTranslation
    }

    private var needsPermissions: Bool {
        !viewModel.permissionSnapshot.accessibilityTrusted
            || !viewModel.permissionSnapshot.screenCaptureAuthorized
    }

    var body: some View {
        if needsBackendSetup || needsPermissions {
            let shape = RoundedRectangle(cornerRadius: GTRadius.row, style: .continuous)
            HStack(spacing: GTSpacing.xSmall) {
                Image(systemName: "info.circle")
                    .font(GTType.secondary)
                    .foregroundStyle(GTColor.accent)
                    .accessibilityHidden(true)
                Text(bannerMessage)
                    .font(GTType.caption)
                    .foregroundStyle(GTColor.primaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: GTSpacing.xSmall)
                Button(actionTitle) {
                    viewModel.selectedTab = needsBackendSetup ? .backend : .advanced
                }
                .buttonStyle(GTPrimaryPillButtonStyle())
            }
            .padding(.horizontal, GTSpacing.small)
            .padding(.vertical, GTSpacing.xSmall)
            .background(GTColor.cardSurface)
            .clipShape(shape)
            .overlay(
                shape.strokeBorder(GTColor.hairline, lineWidth: GTControlMetrics.fieldStrokeWidth)
            )
        }
    }

    private var bannerMessage: String {
        if let reason = viewModel.automaticEnableBlockedReason {
            return reason
        }
        return "部分系统权限未开启，窗口或截图翻译可能无法使用"
    }

    private var actionTitle: String {
        needsBackendSetup ? "去配置" : "去授权"
    }
}

// MARK: - Translation Core

struct TranslationCoreSection: View {
    var viewModel: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: GTControlMetrics.sectionSpacing) {
            Text("划词与网页")
                .font(GTType.cardTitle)
                .foregroundStyle(GTColor.secondaryText)

            GTSettingsToggleRow(
                title: "划词翻译",
                isOn: Binding(
                    get: { viewModel.isSelectionTranslateEnabled },
                    set: { viewModel.setSelectionTranslate($0) }
                ),
                hint: "选中文本后自动弹出译文，并可按场景优化表达"
            )

            if viewModel.isSelectionTranslateEnabled && !viewModel.permissionSnapshot.accessibilityTrusted {
                HStack(spacing: GTSpacing.xSmall) {
                    Text("划词翻译需要“辅助功能”权限才能读取选中文本")
                        .font(GTType.caption)
                        .foregroundStyle(GTColor.destructive)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: GTSpacing.xxSmall)
                    Button("去授权") {
                        viewModel.selectedTab = .advanced
                    }
                    .buttonStyle(GTSecondaryPillButtonStyle(compact: true))
                }
            }

            if viewModel.isSelectionTranslateEnabled {
                GTLabeledControl(title: "优化场景") {
                    GTOptimizeModePicker(
                        selection: Binding(
                            get: { viewModel.promptOptimizeMode },
                            set: { viewModel.setPromptOptimizeMode($0) }
                        ),
                        height: GTControlMetrics.segmentHeight
                    )
                }
                Text(viewModel.promptOptimizeMode.optimizeAccessibilityHint)
                    .font(GTType.caption)
                    .foregroundStyle(GTColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            GTSettingsToggleRow(
                title: "视频翻译",
                isOn: Binding(
                    get: { viewModel.isVideoTranslateEnabled },
                    set: { viewModel.setVideoTranslate($0) }
                ),
                hint: "在网页视频底部叠加简体中文字幕；无字幕时使用本机音频转写"
            )
        }
    }
}

// MARK: - Screenshot translate

struct ScreenshotTranslateSection: View {
    var viewModel: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: GTControlMetrics.sectionSpacing) {
            Text("截图翻译")
                .font(GTType.cardTitle)
                .foregroundStyle(GTColor.secondaryText)

            GTLabeledControl(title: "快捷键") {
                HStack(spacing: GTSpacing.xSmall) {
                    Text(viewModel.screenshotTranslateHotkey.displayString)
                        .font(GTType.body)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, GTSpacing.xSmall)
                        .padding(.vertical, GTSpacing.xxSmall)
                        .frame(minHeight: GTControlMetrics.fieldHeight)
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
                    .buttonStyle(GTSecondaryPillButtonStyle())
                    .accessibilityHint("录制新的截图翻译快捷键，按下带修饰键的组合即可保存")
                }
            }

            if let message = viewModel.screenshotHotkeyConflictMessage, !message.isEmpty {
                Text(message)
                    .font(GTType.caption)
                    .foregroundStyle(GTColor.destructive)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("快捷键冲突")
                    .accessibilityValue(message)
            }

            VStack(alignment: .leading, spacing: GTSpacing.xxSmall) {
                GTSettingsToggleRow(
                    title: "自动复制译文",
                    isOn: Binding(
                        get: { viewModel.autoCopyScreenshotTranslation },
                        set: { viewModel.setAutoCopyScreenshotTranslation($0) }
                    ),
                    hint: "翻译成功后自动将译文写入剪贴板，默认关闭"
                )
                GTSettingsToggleRow(
                    title: "保存截图",
                    isOn: Binding(
                        get: { viewModel.saveScreenshotImage },
                        set: { viewModel.setSaveScreenshotImage($0) }
                    ),
                    hint: "截图后把拖选区域存成 PNG 文件，默认关闭"
                )
                GTSettingsToggleRow(
                    title: "复制截图",
                    isOn: Binding(
                        get: { viewModel.copyScreenshotImage },
                        set: { viewModel.setCopyScreenshotImage($0) }
                    ),
                    hint: "截图后把拖选区域复制到剪贴板，默认关闭"
                )
            }

            if viewModel.autoCopyScreenshotTranslation && viewModel.copyScreenshotImage {
                Text("同时开启“自动复制译文”和“复制截图”时，系统剪贴板会保留截图，译文可在结果浮窗中点击复制。")
                    .font(GTType.caption)
                    .foregroundStyle(GTColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if viewModel.saveScreenshotImage {
                GTLabeledControl(title: "保存位置") {
                    HStack(spacing: GTSpacing.xSmall) {
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
                        .buttonStyle(GTSecondaryPillButtonStyle())
                        .accessibilityHint("选择截图保存文件夹")
                    }
                }
            }

            Text("拖选屏幕区域后在本机识别文字并翻译；需要屏幕录制权限。")
                .font(GTType.caption)
                .foregroundStyle(GTColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Backend picker + fixed target

struct BackendPickerSection: View {
    var viewModel: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: GTControlMetrics.sectionSpacing) {
            Text("翻译后端")
                .font(GTType.cardTitle)
                .foregroundStyle(GTColor.secondaryText)
            GTEqualWidthSegmentedPicker(
                options: [BackendKind.deepSeekCloud, .local],
                selection: Binding(
                    get: { viewModel.selectedBackend },
                    set: { viewModel.selectBackend($0) }
                ),
                title: { $0.displayTitle },
                height: GTControlMetrics.segmentHeight,
                accessibilityLabelText: "翻译后端"
            )

            Text("切到云端会暂停本机 Ollama 服务；切回本地时会自动唤醒。")
                .font(GTType.caption)
                .foregroundStyle(GTColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: GTSpacing.xxSmall) {
                GTLabeledControl(title: "目标语言") {
                    Text(viewModel.targetLanguageDisplayName)
                        .font(GTType.body)
                        .foregroundStyle(GTColor.primaryText)
                }
                Text("窗口覆盖层与网页整页固定译为简体中文；划词与截图自动判断中英互译方向。")
                    .font(GTType.caption)
                    .foregroundStyle(GTColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Cloud backend

struct CloudBackendSection: View {
    var viewModel: SettingsViewModel

    var body: some View {
        @Bindable var bindable = viewModel

        VStack(alignment: .leading, spacing: GTControlMetrics.sectionSpacing) {
            HStack(spacing: GTSpacing.xSmall) {
                Text("API Key")
                    .font(GTType.secondary)
                    .foregroundStyle(GTColor.secondaryText)
                    .frame(minWidth: GTControlMetrics.settingLabelWidth, alignment: .leading)
                Text(viewModel.keyConfigured ? "已保存在系统钥匙串" : "未配置")
                    .font(GTType.body)
                    .foregroundStyle(viewModel.keyConfigured ? GTColor.secondaryText : GTColor.destructive)
                    .lineLimit(1)
                Spacer(minLength: GTSpacing.xSmall)
                if viewModel.keyConfigured, !viewModel.showsKeyEntry {
                    Button("替换") {
                        viewModel.beginReplaceKey()
                    }
                    .buttonStyle(GTSecondaryPillButtonStyle())
                    .disabled(viewModel.isKeyOperationInProgress)
                    .accessibilityHint("仅在替换时显示输入框，已保存的密钥不会回填")

                    Button("删除", role: .destructive) {
                        viewModel.requestDeleteKey()
                    }
                    .buttonStyle(GTDestructivePillButtonStyle())
                    .disabled(viewModel.isKeyOperationInProgress)
                    .accessibilityHint("删除保存在钥匙串中的 API Key")
                }
            }
            .frame(minHeight: GTControlMetrics.settingRowHeight)
            .accessibilityElement(children: .contain)

            if viewModel.showsKeyEntry {
                HStack(spacing: GTSpacing.xSmall) {
                    SecureField("输入新的 API Key", text: $bindable.keyDraft)
                        .textFieldStyle(GTFieldTextStyle())
                        .accessibilityLabel("DeepSeek API Key")
                        .accessibilityHint("出于安全考虑，已保存的密钥不会显示或预填")
                        .onSubmit {
                            Task { await viewModel.saveKey() }
                        }
                    Button(action: { Task { await viewModel.saveKey() } }) {
                        if viewModel.isKeyOperationInProgress {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("保存")
                        }
                    }
                    .buttonStyle(GTPrimaryPillButtonStyle())
                    .disabled(!viewModel.canSaveKey)
                    .accessibilityLabel(viewModel.isKeyOperationInProgress ? "正在保存 API Key" : "保存 API Key")
                    .accessibilityHint("保存后输入框将清空，密钥只写入系统钥匙串")

                    if viewModel.isReplacingKey {
                        Button("取消") {
                            viewModel.cancelReplaceKey()
                        }
                        .buttonStyle(GTSecondaryPillButtonStyle())
                        .disabled(viewModel.isKeyOperationInProgress)
                    }
                }
                .frame(minHeight: GTControlMetrics.settingRowHeight)
            }

            if case .failure(let message) = viewModel.keyOperation {
                Text(message)
                    .font(GTType.caption)
                    .foregroundStyle(GTColor.destructive)
                    .fixedSize(horizontal: false, vertical: true)
            }

            GTLabeledControl(title: "模型") {
                if viewModel.availableModels.isEmpty {
                    GTReadOnlyField(value: viewModel.keyConfigured
                        ? "请先测试连接"
                        : "请先配置 API Key")
                        .accessibilityLabel("模型")
                        .accessibilityValue(viewModel.keyConfigured
                            ? "尚未获取模型列表"
                            : "可测试连接或保存 API Key")
                } else {
                    GTModelMenuPicker(
                        options: viewModel.availableModels,
                        selection: $bindable.deepSeekModel,
                        onChange: { viewModel.commitDeepSeekModel() }
                    )
                    .accessibilityLabel("模型")
                    .accessibilityValue(viewModel.deepSeekModel)
                    .accessibilityHint("选择云端翻译使用的模型")
                }
            }

            ConnectionTestRow(viewModel: viewModel)
        }
    }
}

// MARK: - Local backend

struct LocalBackendSection: View {
    var viewModel: SettingsViewModel

    var body: some View {
        @Bindable var bindable = viewModel

        VStack(alignment: .leading, spacing: GTControlMetrics.sectionSpacing) {
            GTLabeledControl(title: "服务地址") {
                TextField("http://127.0.0.1:11434/v1", text: $bindable.localBaseURL)
                    .textFieldStyle(GTFieldTextStyle())
                    .accessibilityLabel("本地服务地址")
                    .accessibilityHint("仅限本机地址，例如 http://127.0.0.1:11434/v1")
                    .onSubmit { viewModel.commitLocalConfiguration() }
            }

            GTLabeledControl(title: "模型") {
                if viewModel.availableModels.isEmpty {
                    GTReadOnlyField(value: "请先测试连接")
                        .accessibilityLabel("模型")
                        .accessibilityValue("尚未获取模型列表")
                } else {
                    GTModelMenuPicker(
                        options: viewModel.availableModels,
                        selection: $bindable.localModel,
                        placeholder: "请选择本地模型",
                        onChange: { viewModel.commitLocalConfiguration() }
                    )
                    .accessibilityLabel("模型")
                    .accessibilityValue(viewModel.localModel.isEmpty ? "请选择本地模型" : viewModel.localModel)
                    .accessibilityHint("选择本地翻译使用的模型")
                }
            }

            GTActionRow {
                testConnectionButton
            } secondary: {
                Button {
                    viewModel.commitLocalConfiguration()
                } label: {
                    Text("应用设置")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(GTSecondaryPillButtonStyle())
                .disabled(viewModel.localBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            ConnectionTestStatus(viewModel: viewModel)

            Text("仅连接本机本地服务，数据不会上传到云端；首次加载模型可能较慢。")
                .font(GTType.caption)
                .foregroundStyle(GTColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var testConnectionButton: some View {
        let button = Button(action: { Task { await viewModel.testConnection() } }) {
            Group {
                if viewModel.connectionTest == .testing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text("测试连接")
                }
            }
            .frame(maxWidth: .infinity)
        }
        .disabled(!viewModel.canTestConnection)
        .accessibilityLabel(viewModel.connectionTest == .testing ? "正在测试连接" : "测试连接")
        .accessibilityHint(ConnectionTestRow.testHint(for: viewModel))

        if viewModel.backendReady {
            button.buttonStyle(GTSecondaryPillButtonStyle())
        } else {
            button.buttonStyle(GTPrimaryPillButtonStyle())
        }
    }
}

// MARK: - Shared connection test row

struct ConnectionTestRow: View {
    var viewModel: SettingsViewModel

    var body: some View {
        HStack(alignment: .center, spacing: GTSpacing.xSmall) {
            testButton
            ConnectionTestStatus(viewModel: viewModel)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var testButton: some View {
        let button = Button(action: { Task { await viewModel.testConnection() } }) {
            if viewModel.connectionTest == .testing {
                ProgressView()
                    .controlSize(.small)
            } else {
                Text("测试连接")
            }
        }
        .disabled(!viewModel.canTestConnection)
        .accessibilityLabel(viewModel.connectionTest == .testing ? "正在测试连接" : "测试连接")
        .accessibilityHint(Self.testHint(for: viewModel))

        if viewModel.backendReady {
            button.buttonStyle(GTSecondaryPillButtonStyle())
        } else {
            button.buttonStyle(GTPrimaryPillButtonStyle())
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
    var viewModel: SettingsViewModel

    var body: some View {
        switch viewModel.connectionTest {
        case .healthy(let message):
            Text(message)
                .font(GTType.caption)
                .foregroundStyle(GTColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        case .failed(let message):
            Text(message)
                .font(GTType.caption)
                .foregroundStyle(GTColor.destructive)
                .fixedSize(horizontal: false, vertical: true)
        case .idle, .testing:
            EmptyView()
        }
    }
}

// MARK: - Permissions

struct PermissionsSection: View {
    var viewModel: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: GTControlMetrics.sectionSpacing) {
            GTSettingsSectionHeader(title: "系统权限") {
                Button("重新检查", action: viewModel.refreshPermissions)
                    .buttonStyle(GTSecondaryPillButtonStyle())
                    .accessibilityLabel("重新检查系统权限")
            }
            PermissionRow(
                title: "辅助功能",
                purpose: "用于读取选中文字和窗口文本结构",
                granted: viewModel.permissionSnapshot.accessibilityTrusted,
                kind: .accessibility,
                viewModel: viewModel
            )
            PermissionRow(
                title: "屏幕录制",
                purpose: "用于截图文字识别、画面内容提取及视频音频转写",
                granted: viewModel.permissionSnapshot.screenCaptureAuthorized,
                kind: .screenCapture,
                viewModel: viewModel
            )
            if !viewModel.permissionSnapshot.accessibilityTrusted
                || !viewModel.permissionSnapshot.screenCaptureAuthorized {
                Text("点击“授权”触发系统弹窗，或在“打开系统设置”中手动勾选；更新版本后若仍显示未授权，请重新勾选一次。")
                    .font(GTType.caption)
                    .foregroundStyle(GTColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let purpose: String
    let granted: Bool
    let kind: PermissionKind
    var viewModel: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: GTSpacing.xxSmall) {
            HStack(spacing: GTSpacing.xSmall) {
                Text(title)
                    .font(GTType.body)
                Text(granted ? "已授权" : "未授权")
                    .font(GTType.caption)
                    .foregroundStyle(granted ? GTColor.secondaryText : GTColor.destructive)
                Spacer()
                if !granted {
                    Button("授权") {
                        viewModel.requestPermission(kind)
                    }
                    .buttonStyle(GTSecondaryPillButtonStyle())
                    .accessibilityLabel("授权\(title)")

                    Button("打开系统设置") {
                        viewModel.openSystemSettings(kind)
                    }
                    .buttonStyle(GTSecondaryPillButtonStyle())
                    .accessibilityLabel("打开\(title)系统设置")
                }
            }
            .frame(minHeight: GTControlMetrics.settingRowHeight)
            Text(purpose)
                .font(GTType.caption)
                .foregroundStyle(GTColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Translated applications

struct TranslatedApplicationsSection: View {
    var viewModel: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: GTControlMetrics.sectionSpacing) {
            GTSettingsSectionHeader(title: "要翻译的应用") {
                HStack(spacing: GTSpacing.xxSmall) {
                    Button("添加当前") {
                        viewModel.addCurrentAppTranslation()
                    }
                    .buttonStyle(GTSecondaryPillButtonStyle())
                    .accessibilityHint("把当前正在使用的应用加入自动翻译列表")

                    Button("选择应用…") {
                        viewModel.chooseTranslatedApplications()
                    }
                    .buttonStyle(GTSecondaryPillButtonStyle())
                    .accessibilityHint("选择一个或多个要翻译的应用，可按住 Command 多选")
                }
            }

            if viewModel.translatedApplications.isEmpty {
                Text("未选择要翻译的应用")
                    .font(GTType.caption)
                    .foregroundStyle(GTColor.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, GTSpacing.xSmall)
                    .padding(.vertical, GTSpacing.xxSmall)
                    .frame(minHeight: GTControlMetrics.fieldHeight)
                    .background(GTColor.fieldFill)
                    .clipShape(RoundedRectangle(cornerRadius: GTRadius.row, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: GTRadius.row, style: .continuous)
                            .strokeBorder(GTColor.hairline, lineWidth: GTControlMetrics.fieldStrokeWidth)
                    )
            } else if viewModel.translatedApplications.count <= 3 {
                applicationRows
                    .background(GTColor.fieldFill)
                    .clipShape(RoundedRectangle(cornerRadius: GTRadius.row, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: GTRadius.row, style: .continuous)
                            .strokeBorder(GTColor.hairline, lineWidth: GTControlMetrics.fieldStrokeWidth)
                    )
            } else {
                ScrollView(.vertical) {
                    applicationRows
                }
                .frame(height: 144)
                .background(GTColor.fieldFill)
                .clipShape(RoundedRectangle(cornerRadius: GTRadius.row, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: GTRadius.row, style: .continuous)
                        .strokeBorder(GTColor.hairline, lineWidth: GTControlMetrics.fieldStrokeWidth)
                )
            }

            Text("开启“自动翻译”后，仅对列表中的应用显示窗口译文贴片；未选择时不覆盖任何桌面应用。")
                .font(GTType.caption)
                .foregroundStyle(GTColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var applicationRows: some View {
        VStack(spacing: 0) {
            ForEach(Array(viewModel.translatedApplications.enumerated()), id: \.element.id) { index, app in
                if index > 0 {
                    Divider()
                }
                HStack(spacing: GTSpacing.xSmall) {
                    VStack(alignment: .leading, spacing: GTSpacing.xxSmall / 2) {
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
                            .padding(GTSpacing.xxSmall + 2)
                            .contentShape(Rectangle())
                            .accessibilityHidden(true)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("移除 \(app.displayName)")
                }
                .padding(.horizontal, GTSpacing.xSmall)
                .padding(.vertical, GTSpacing.xxSmall)
            }
        }
    }
}

// MARK: - Maintenance & Footer

struct MaintenanceSection: View {
    var viewModel: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: GTControlMetrics.sectionSpacing) {
            Text("维护与诊断")
                .font(GTType.cardTitle)
                .foregroundStyle(GTColor.secondaryText)

            GTActionRow {
                Button {
                    viewModel.requestClearCache()
                } label: {
                    Text("清除缓存")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(GTSecondaryPillButtonStyle())
                .accessibilityHint("删除本地翻译缓存，需确认")
            } secondary: {
                Button {
                    viewModel.openLogs()
                } label: {
                    Text("打开日志")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(GTSecondaryPillButtonStyle())
                .accessibilityLabel("打开诊断日志文件夹")
            }

            Text("只保存最近会话缓存；API 密钥仅保存在系统钥匙串，不写入日志。")
                .font(GTType.caption)
                .foregroundStyle(GTColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct SettingsFooterSection: View {
    var viewModel: SettingsViewModel

    var body: some View {
        HStack(spacing: GTSpacing.xSmall) {
            if let feedback = viewModel.actionFeedbackMessage, !feedback.isEmpty {
                HStack(spacing: GTSpacing.xxSmall) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(GTType.caption)
                        .foregroundStyle(GTColor.accent)
                        .accessibilityHidden(true)
                    Text(feedback)
                        .font(GTType.caption)
                        .foregroundStyle(GTColor.primaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .accessibilityLabel(feedback)
            } else {
                Text("Global Translator")
                    .font(GTType.caption)
                    .foregroundStyle(GTColor.secondaryText)
            }

            Spacer()

            Button("退出应用", role: .destructive) {
                viewModel.quit()
            }
            .buttonStyle(GTDestructivePillButtonStyle())
            .keyboardShortcut("q", modifiers: .command)
            .accessibilityLabel("退出 Global Translator")
            .accessibilityHint("停止翻译并退出程序")
        }
        .frame(minHeight: GTControlMetrics.settingRowHeight)
    }
}
