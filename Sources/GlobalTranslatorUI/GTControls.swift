import SwiftUI
import GlobalTranslatorCore

/// Shared frosted-glass surface with an opaque fallback for Reduce Transparency.
/// Kept separate from layout so cards can change material without changing size.
struct GTGlassBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var material: Material = .regularMaterial
    var fallback: Color = GTColor.panelBackground

    static func usesMaterial(reduceTransparency: Bool) -> Bool {
        !reduceTransparency
    }

    var body: some View {
        if Self.usesMaterial(reduceTransparency: reduceTransparency) {
            Rectangle().fill(material)
        } else {
            fallback
        }
    }
}

/// The production settings-panel chrome, shared with render tests so previews
/// exercise the exact same material/gradient/stroke composition as the app.
struct GTSettingsPanelChrome: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background {
                GTGlassBackground(material: .regularMaterial)
                LinearGradient(
                    colors: [Color.white.opacity(0.10), GTColor.accent.opacity(0.025)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.22), GTColor.hairline],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: GTControlMetrics.fieldStrokeWidth
                    )
            }
    }
}

/// Grouped settings block: fill, radius, and inner padding from DesignTokens.
struct GTSettingsCard<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: GTSpacing.small) {
            content()
        }
        .padding(GTSpacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            GTGlassBackground(material: .thinMaterial, fallback: GTColor.sectionFill)
        }
        .clipShape(RoundedRectangle(cornerRadius: GTRadius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: GTRadius.card, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(isHovered ? 0.32 : 0.20),
                            GTColor.hairline
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: GTControlMetrics.fieldStrokeWidth
                )
        }
        .shadow(
            color: Color.black.opacity(isHovered ? 0.16 : 0.08),
            radius: isHovered ? 12 : 7,
            x: 0,
            y: isHovered ? 6 : 3
        )
        .offset(y: reduceMotion || !isHovered ? 0 : -1)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isHovered)
        .onHover { isHovered = $0 }
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

/// Bordered action that fills the width proposed by `GTEqualWidthHStack`.
struct GTEqualFillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(GTType.body)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(GTColor.primaryText)
            .background(GTColor.fieldFill)
            .clipShape(RoundedRectangle(cornerRadius: GTRadius.row, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: GTRadius.row, style: .continuous)
                    .strokeBorder(GTColor.hairline, lineWidth: GTControlMetrics.fieldStrokeWidth)
            )
            .opacity(configuration.isPressed ? 0.82 : 1)
    }
}

/// Equal-width segmented control; selected fill uses accent so dark mode stays readable.
struct GTEqualWidthSegmentedPicker<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    var title: (Value) -> String
    var isEnabled: Bool = true
    var accessibilityLabelText: String = ""

    var body: some View {
        GTEqualWidthHStack(spacing: 1) {
            ForEach(options, id: \.self) { option in
                let isSelected = option == selection
                Button {
                    selection = option
                } label: {
                    Text(title(option))
                        .font(GTType.secondary.weight(.medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .foregroundStyle(isSelected ? GTColor.selectedSegmentText : GTColor.primaryText)
                        .background(isSelected ? GTColor.accent : Color.clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!isEnabled)
                .accessibilityAddTraits(isSelected ? .isSelected : AccessibilityTraits())
                .accessibilityValue(title(option))
            }
        }
        .frame(height: GTSelectionMetrics.modePickerHeight)
        .frame(maxWidth: .infinity)
        .background(GTColor.segmentTrack)
        .clipShape(RoundedRectangle(cornerRadius: GTRadius.row, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: GTRadius.row, style: .continuous)
                .strokeBorder(GTColor.hairline, lineWidth: GTControlMetrics.fieldStrokeWidth)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabelText)
    }
}

/// Three-scene control used in settings and the selection popover.
struct GTOptimizeModePicker: View {
    @Binding var selection: PromptOptimizeMode
    var isEnabled: Bool = true

    var body: some View {
        GTEqualWidthSegmentedPicker(
            options: PromptOptimizeMode.allCases,
            selection: $selection,
            title: { $0.title },
            isEnabled: isEnabled,
            accessibilityLabelText: "优化场景"
        )
        .accessibilityValue(selection.title)
        .accessibilityHint(selection.optimizeAccessibilityHint)
    }
}
