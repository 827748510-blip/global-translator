import SwiftUI
import GlobalTranslatorCore

/// Grouped settings block: fill, radius, and inner padding from DesignTokens.
struct GTSettingsCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: GTSpacing.small) {
            content()
        }
        .padding(GTSpacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GTColor.sectionFill)
        .clipShape(RoundedRectangle(cornerRadius: GTRadius.card, style: .continuous))
    }
}

/// Caption above a full-width control so address, model, and language rows share rhythm.
struct GTLabeledControl<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: GTSpacing.xxSmall) {
            Text(title)
                .font(GTType.secondary)
                .foregroundStyle(GTColor.secondaryText)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

/// Text field chrome matching the custom menu trigger (not the short grey system bezel).
struct GTFieldTextStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .font(GTType.body)
            .padding(.horizontal, GTSpacing.small)
            .frame(height: GTControlMetrics.fieldHeight)
            .background(GTColor.fieldFill)
            .clipShape(RoundedRectangle(cornerRadius: GTRadius.row, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: GTRadius.row, style: .continuous)
                    .strokeBorder(GTColor.hairline, lineWidth: GTControlMetrics.fieldStrokeWidth)
            )
    }
}

/// Read-only value row with the same height and stroke as editable fields.
struct GTReadOnlyField: View {
    let value: String

    var body: some View {
        Text(value)
            .font(GTType.body)
            .foregroundStyle(GTColor.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, GTSpacing.small)
            .frame(height: GTControlMetrics.fieldHeight)
            .background(GTColor.fieldFill)
            .clipShape(RoundedRectangle(cornerRadius: GTRadius.row, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: GTRadius.row, style: .continuous)
                    .strokeBorder(GTColor.hairline, lineWidth: GTControlMetrics.fieldStrokeWidth)
            )
    }
}

/// Full-width primary / secondary action pair (or a single primary).
struct GTActionRow<Primary: View, Secondary: View>: View {
    var primary: () -> Primary
    var secondary: (() -> Secondary)?

    init(
        @ViewBuilder primary: @escaping () -> Primary,
        @ViewBuilder secondary: @escaping () -> Secondary
    ) {
        self.primary = primary
        self.secondary = secondary
    }

    var body: some View {
        HStack(spacing: GTSpacing.xSmall) {
            if let secondary {
                secondary()
                    .frame(maxWidth: .infinity)
            }
            primary()
                .frame(maxWidth: .infinity)
        }
        .frame(minHeight: GTPopoverMetrics.minRowHitHeight)
        .frame(maxWidth: .infinity)
    }
}

extension GTActionRow where Secondary == EmptyView {
    init(@ViewBuilder primary: @escaping () -> Primary) {
        self.primary = primary
        self.secondary = nil
    }
}

/// Custom select: DesignToken-styled trigger and list, replacing the short grey system Picker.
struct GTSelectField: View {
    let options: [String]
    @Binding var selection: String
    var placeholder: String = "请选择"
    var isEnabled: Bool = true
    var onChange: (() -> Void)?

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: GTSpacing.xxSmall) {
            trigger
            if isExpanded, isEnabled, !options.isEmpty {
                optionList
            }
        }
        .onChange(of: options) { _, _ in
            if !options.contains(selection) {
                isExpanded = false
            }
        }
    }

    private var trigger: some View {
        Button {
            guard isEnabled, !options.isEmpty else { return }
            isExpanded.toggle()
        } label: {
            HStack(spacing: GTSpacing.xSmall) {
                Text(displayedValue)
                    .font(GTType.body)
                    .foregroundStyle(hasValue ? GTColor.primaryText : GTColor.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: GTSpacing.xSmall)
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(GTType.caption)
                    .foregroundStyle(GTColor.secondaryText)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, GTSpacing.small)
            .frame(height: GTControlMetrics.fieldHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || options.isEmpty)
        .background(GTColor.fieldFill)
        .clipShape(RoundedRectangle(cornerRadius: GTRadius.row, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: GTRadius.row, style: .continuous)
                .strokeBorder(GTColor.hairline, lineWidth: GTControlMetrics.fieldStrokeWidth)
        )
        .accessibilityHint(options.isEmpty ? "请先测试连接以获取模型列表" : "打开模型列表")
    }

    private var optionList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(options, id: \.self) { option in
                    Button {
                        if selection != option {
                            selection = option
                            onChange?()
                        }
                        isExpanded = false
                    } label: {
                        HStack(spacing: GTSpacing.xSmall) {
                            Text(option)
                                .font(GTType.body)
                                .foregroundStyle(GTColor.primaryText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: GTSpacing.xSmall)
                            if option == selection {
                                Image(systemName: "checkmark")
                                    .font(GTType.caption.weight(.semibold))
                                    .foregroundStyle(GTColor.accent)
                                    .accessibilityHidden(true)
                            }
                        }
                        .padding(.horizontal, GTSpacing.small)
                        .frame(height: GTControlMetrics.menuRowHeight)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(option == selection ? GTColor.accent.opacity(0.12) : Color.clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(option == selection ? .isSelected : AccessibilityTraits())
                }
            }
        }
        .frame(maxHeight: min(CGFloat(options.count) * GTControlMetrics.menuRowHeight, GTControlMetrics.menuListMaxHeight))
        .background(GTColor.fieldFill)
        .clipShape(RoundedRectangle(cornerRadius: GTRadius.row, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: GTRadius.row, style: .continuous)
                .strokeBorder(GTColor.hairline, lineWidth: GTControlMetrics.fieldStrokeWidth)
        )
        .accessibilityLabel("模型列表")
    }

    private var hasValue: Bool {
        !selection.isEmpty
    }

    private var displayedValue: String {
        if !selection.isEmpty { return selection }
        return placeholder
    }
}

/// Three-scene control used in settings and the selection popover.
struct GTOptimizeModePicker: View {
    @Binding var selection: PromptOptimizeMode
    var isEnabled: Bool = true

    var body: some View {
        Picker("优化场景", selection: $selection) {
            ForEach(PromptOptimizeMode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .disabled(!isEnabled)
        .frame(height: GTSelectionMetrics.modePickerHeight)
        .frame(maxWidth: .infinity)
        .accessibilityLabel("优化场景")
        .accessibilityValue(selection.title)
        .accessibilityHint(selection.optimizeAccessibilityHint)
    }
}
