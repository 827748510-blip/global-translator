import SwiftUI
import GlobalTranslatorCore

/// The production settings-panel chrome, shared with render tests so previews
/// exercise the exact same material/gradient/stroke composition as the app.
struct GTSettingsPanelChrome: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if reduceTransparency {
            content
                .background(GTColor.panelBackground)
                .clipShape(shape)
                .overlay(
                    shape.strokeBorder(GTColor.hairline, lineWidth: GTControlMetrics.fieldStrokeWidth)
                )
        } else {
            // 单层外框 Liquid Glass；静态容器不加 `.interactive()`，避免整块背景误响应悬停。
            content
                .glassEffect(.regular, in: shape)
        }
    }
}

/// Grouped settings block: tonal fill, radius, and inner padding from DesignTokens.
struct GTSettingsCard<Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ViewBuilder var content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: GTRadius.card, style: .continuous)
        VStack(alignment: .leading, spacing: GTControlMetrics.sectionSpacing) {
            content()
        }
        .padding(.horizontal, GTControlMetrics.cardHorizontalPadding)
        .padding(.vertical, GTControlMetrics.cardVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(reduceTransparency ? GTColor.sectionFill : GTColor.cardSurface)
        .clipShape(shape)
        .overlay(
            shape.strokeBorder(GTColor.hairline, lineWidth: GTControlMetrics.fieldStrokeWidth)
        )
    }
}

/// One compact card header, optionally with a trailing action (选择应用 / 重新检查).
struct GTSettingsSectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: GTSpacing.xSmall) {
            Text(title)
                .font(GTType.cardTitle)
                .foregroundStyle(GTColor.secondaryText)
            Spacer(minLength: GTSpacing.xSmall)
            trailing()
        }
        .frame(minHeight: GTControlMetrics.settingRowHeight)
        .accessibilityElement(children: .contain)
    }
}

extension GTSettingsSectionHeader where Trailing == EmptyView {
    init(title: String) {
        self.init(title: title) { EmptyView() }
    }
}

/// Compact settings toggle: label on the left, switch pinned to the right.
/// The expanding label keeps every switch in one aligned column.
struct GTSettingsToggleRow: View {
    let title: String
    @Binding var isOn: Bool
    var hint: String = ""

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(title)
                .font(GTType.body)
                .foregroundStyle(GTColor.primaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .frame(minHeight: GTControlMetrics.settingRowHeight)
        .accessibilityHint(hint)
    }
}

/// A label on the left and a control on the right. Keeping one label column
/// across the page is what makes the compact settings layout scan cleanly.
struct GTLabeledControl<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .center, spacing: GTSpacing.xSmall) {
            Text(title)
                .font(GTType.secondary)
                .foregroundStyle(GTColor.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(minWidth: GTControlMetrics.settingLabelWidth, alignment: .leading)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: GTControlMetrics.settingRowHeight)
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
            .padding(.vertical, GTSpacing.xxSmall)
            .frame(minHeight: GTControlMetrics.fieldHeight)
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
            .padding(.vertical, GTSpacing.xxSmall)
            .frame(minHeight: GTControlMetrics.fieldHeight)
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
        .frame(minHeight: GTControlMetrics.settingRowHeight)
        .frame(maxWidth: .infinity)
    }
}

extension GTActionRow where Secondary == EmptyView {
    init(@ViewBuilder primary: @escaping () -> Primary) {
        self.primary = primary
        self.secondary = nil
    }
}

/// Custom select: DesignToken-styled trigger and list with keyboard navigation.
struct GTSelectField: View {
    let options: [String]
    @Binding var selection: String
    var placeholder: String = "请选择"
    var isEnabled: Bool = true
    var onChange: (() -> Void)?

    @State private var isExpanded = false
    @State private var isTriggerHovered = false
    @State private var hoveredOption: String?

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
        .onKeyPress(.escape) {
            guard isExpanded else { return .ignored }
            isExpanded = false
            return .handled
        }
        .onKeyPress(.downArrow) {
            guard isEnabled, !options.isEmpty else { return .ignored }
            stepSelection(by: 1)
            return .handled
        }
        .onKeyPress(.upArrow) {
            guard isEnabled, !options.isEmpty else { return .ignored }
            stepSelection(by: -1)
            return .handled
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
            .padding(.vertical, GTSpacing.xxSmall)
            .frame(minHeight: GTControlMetrics.fieldHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isTriggerHovered ? GTColor.hoverFill : GTColor.fieldFill)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || options.isEmpty)
        .onHover { hovered in
            isTriggerHovered = hovered
        }
        .clipShape(RoundedRectangle(cornerRadius: GTRadius.row, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: GTRadius.row, style: .continuous)
                .strokeBorder(GTColor.hairline, lineWidth: GTControlMetrics.fieldStrokeWidth)
        )
        .accessibilityValue(displayedValue)
        .accessibilityHint(options.isEmpty ? "请先测试连接以获取模型列表" : "打开或使用上下方向键切换模型")
    }

    private var optionList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(options, id: \.self) { option in
                    let isSelected = option == selection
                    let isHovered = option == hoveredOption
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
                            if isSelected {
                                Image(systemName: "checkmark")
                                    .font(GTType.caption.weight(.semibold))
                                    .foregroundStyle(GTColor.accent)
                                    .accessibilityHidden(true)
                            }
                        }
                        .padding(.horizontal, GTSpacing.small)
                        .frame(minHeight: GTControlMetrics.menuRowHeight)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            isSelected
                                ? GTColor.accent.opacity(0.12)
                                : (isHovered ? GTColor.hoverFill : Color.clear)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        hoveredOption = hovering ? option : (hoveredOption == option ? nil : hoveredOption)
                    }
                    .accessibilityAddTraits(isSelected ? .isSelected : AccessibilityTraits())
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

    private func stepSelection(by delta: Int) {
        guard !options.isEmpty else { return }
        if let currentIndex = options.firstIndex(of: selection) {
            let nextIndex = (currentIndex + delta + options.count) % options.count
            selection = options[nextIndex]
        } else if let first = options.first {
            selection = first
        }
        onChange?()
    }

    private var hasValue: Bool {
        !selection.isEmpty
    }

    private var displayedValue: String {
        if !selection.isEmpty { return selection }
        return placeholder
    }
}

/// Divides the proposed width equally across children, matching left/right
/// edges of the row above (scene segments ↔ action buttons).
struct GTEqualWidthHStack: Layout {
    var spacing: CGFloat = GTSpacing.xSmall

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let count = subviews.count
        guard count > 0 else { return .zero }
        let proposedWidth = proposal.width ?? subviews.reduce(CGFloat.zero) { $0 + $1.sizeThatFits(.unspecified).width }
        let itemWidth = GTEqualWidthMetrics.itemWidth(total: proposedWidth, count: count, spacing: spacing)
        let height = subviews.map {
            $0.sizeThatFits(ProposedViewSize(width: itemWidth, height: proposal.height)).height
        }.max() ?? 0
        return CGSize(width: proposedWidth, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let count = subviews.count
        guard count > 0 else { return }
        let itemWidth = GTEqualWidthMetrics.itemWidth(total: bounds.width, count: count, spacing: spacing)
        var x = bounds.minX
        for subview in subviews {
            subview.place(
                at: CGPoint(x: x, y: bounds.minY),
                proposal: ProposedViewSize(width: itemWidth, height: bounds.height)
            )
            x += itemWidth + spacing
        }
    }
}

/// Equal-width segmented control; selected fill uses accent with subtle spring/ease-out slide
/// and arrow-key navigation.
struct GTEqualWidthSegmentedPicker<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    var title: (Value) -> String
    var isEnabled: Bool = true
    var height: CGFloat = GTSelectionMetrics.modePickerHeight
    var accessibilityLabelText: String = ""

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoveredOption: Value?
    @Namespace private var segmentNamespace

    var body: some View {
        GTEqualWidthHStack(spacing: 1) {
            ForEach(options, id: \.self) { option in
                let isSelected = option == selection
                let isHovered = option == hoveredOption
                Button {
                    select(option)
                } label: {
                    Text(title(option))
                        .font(GTType.secondary.weight(.medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .padding(.horizontal, GTSpacing.xxSmall)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .foregroundStyle(isSelected ? GTColor.selectedSegmentText : GTColor.primaryText)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: GTRadius.row - 1, style: .continuous)
                                    .fill(GTColor.accent)
                                    .matchedGeometryEffect(id: "activeSegment", in: segmentNamespace)
                            } else if isHovered && isEnabled {
                                RoundedRectangle(cornerRadius: GTRadius.row - 1, style: .continuous)
                                    .fill(GTColor.hoverFill)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!isEnabled)
                .onHover { hovering in
                    hoveredOption = hovering ? option : (hoveredOption == option ? nil : hoveredOption)
                }
                .accessibilityAddTraits(isSelected ? .isSelected : AccessibilityTraits())
            }
        }
        .padding(1)
        .frame(minHeight: height)
        .frame(maxWidth: .infinity)
        .background(GTColor.segmentTrack)
        .clipShape(RoundedRectangle(cornerRadius: GTRadius.row, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: GTRadius.row, style: .continuous)
                .strokeBorder(GTColor.hairline, lineWidth: GTControlMetrics.fieldStrokeWidth)
        )
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: selection)
        .onKeyPress(.leftArrow) {
            stepSelection(by: -1)
        }
        .onKeyPress(.rightArrow) {
            stepSelection(by: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabelText)
    }

    private func select(_ option: Value) {
        guard isEnabled, selection != option else { return }
        if reduceMotion {
            selection = option
        } else {
            withAnimation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.18)) {
                selection = option
            }
        }
    }

    private func stepSelection(by delta: Int) -> KeyPress.Result {
        guard isEnabled, let index = options.firstIndex(of: selection), !options.isEmpty else {
            return .ignored
        }
        let nextIndex = (index + delta + options.count) % options.count
        select(options[nextIndex])
        return .handled
    }
}

/// Three-scene control used in settings and the selection popover.
struct GTOptimizeModePicker: View {
    @Binding var selection: PromptOptimizeMode
    var isEnabled: Bool = true
    var height: CGFloat = GTSelectionMetrics.modePickerHeight

    var body: some View {
        GTEqualWidthSegmentedPicker(
            options: PromptOptimizeMode.allCases,
            selection: $selection,
            title: { $0.title },
            isEnabled: isEnabled,
            height: height,
            accessibilityLabelText: "优化场景"
        )
        .accessibilityValue(selection.title)
        .accessibilityHint(selection.optimizeAccessibilityHint)
    }
}
