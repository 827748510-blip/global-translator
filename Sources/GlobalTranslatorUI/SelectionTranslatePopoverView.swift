import AppKit
import Observation
import SwiftUI
import GlobalTranslatorCore

/// Live observable chrome and content state for the selection popover.
/// Updating properties in place avoids destroying/rebuilding `NSHostingView`.
@MainActor
@Observable
public final class SelectionPopoverChrome {
    public var optimizeMode: PromptOptimizeMode = .communicationPolish
    public var copyFeedback: SelectionCopyFeedback = .idle
    public var content: SelectionPopoverContent?
    public var resultHeight: CGFloat?
    public var isResultScrollable: Bool = false

    public init(
        optimizeMode: PromptOptimizeMode = .communicationPolish,
        copyFeedback: SelectionCopyFeedback = .idle,
        content: SelectionPopoverContent? = nil,
        resultHeight: CGFloat? = nil,
        isResultScrollable: Bool = false
    ) {
        self.optimizeMode = optimizeMode
        self.copyFeedback = copyFeedback
        self.content = content
        self.resultHeight = resultHeight
        self.isResultScrollable = isResultScrollable
    }
}

/// Interactive selection popover: truncated original, result, 翻译 / 优化提示词 / 拷贝 / 打开设置.
public struct SelectionTranslatePopoverView: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private let explicitContent: SelectionPopoverContent?
    private let chrome: SelectionPopoverChrome
    private let explicitResultHeight: CGFloat?
    private let explicitIsResultScrollable: Bool?
    var onCopy: () -> Void = {}
    var onTranslate: () -> Void = {}
    var onOptimize: () -> Void = {}
    var onOpenSettings: () -> Void = {}
    var onOptimizeModeChange: (PromptOptimizeMode) -> Void = { _ in }

    public init(
        content: SelectionPopoverContent,
        chrome: SelectionPopoverChrome,
        resultHeight: CGFloat? = nil,
        isResultScrollable: Bool = false,
        onCopy: @escaping () -> Void = {},
        onTranslate: @escaping () -> Void = {},
        onOptimize: @escaping () -> Void = {},
        onOpenSettings: @escaping () -> Void = {},
        onOptimizeModeChange: @escaping (PromptOptimizeMode) -> Void = { _ in }
    ) {
        self.explicitContent = content
        self.chrome = chrome
        self.explicitResultHeight = resultHeight
        self.explicitIsResultScrollable = isResultScrollable
        self.onCopy = onCopy
        self.onTranslate = onTranslate
        self.onOptimize = onOptimize
        self.onOpenSettings = onOpenSettings
        self.onOptimizeModeChange = onOptimizeModeChange
    }

    init(
        chrome: SelectionPopoverChrome,
        onCopy: @escaping () -> Void = {},
        onTranslate: @escaping () -> Void = {},
        onOptimize: @escaping () -> Void = {},
        onOpenSettings: @escaping () -> Void = {},
        onOptimizeModeChange: @escaping (PromptOptimizeMode) -> Void = { _ in }
    ) {
        self.explicitContent = nil
        self.chrome = chrome
        self.explicitResultHeight = nil
        self.explicitIsResultScrollable = nil
        self.onCopy = onCopy
        self.onTranslate = onTranslate
        self.onOptimize = onOptimize
        self.onOpenSettings = onOpenSettings
        self.onOptimizeModeChange = onOptimizeModeChange
    }

    private var activeContent: SelectionPopoverContent {
        explicitContent ?? chrome.content ?? .unavailable(screenFrame: .zero)
    }

    private var activeResultHeight: CGFloat? {
        explicitResultHeight ?? chrome.resultHeight
    }

    private var activeIsResultScrollable: Bool {
        explicitIsResultScrollable ?? chrome.isResultScrollable
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: GTRadius.overlay, style: .continuous)
        Group {
            if reduceTransparency {
                contentLayout
                    .background(GTColor.panelBackground)
                    .clipShape(shape)
                    .overlay(shape.strokeBorder(GTColor.hairline, lineWidth: GTControlMetrics.fieldStrokeWidth))
            } else {
                contentLayout
                    .glassEffect(.regular, in: shape)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var contentLayout: some View {
        let content = activeContent
        return VStack(alignment: .leading, spacing: GTSelectionMetrics.sectionSpacing) {
            textBlock(for: content)
            // 保存路径 / 剪贴板提示：一条一行，行数上限与高度测量共用常量。
            ForEach(Array(content.secondaryHints.enumerated()), id: \.offset) { _, hint in
                Text(hint)
                    .font(GTType.caption)
                    .foregroundStyle(GTColor.secondaryText)
                    .lineLimit(GTSelectionMetrics.secondaryHintMaxLines)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("截图提示")
                    .accessibilityValue(hint)
            }
            if content.showsOptimizeAction || content.showsActionButtons {
                actionsGroup(for: content)
            }
        }
        .padding(.horizontal, GTSelectionMetrics.horizontalPadding)
        .padding(.vertical, GTSelectionMetrics.verticalPadding)
        .frame(width: GTSelectionMetrics.width, alignment: .leading)
    }

    private func textBlock(for content: SelectionPopoverContent) -> some View {
        VStack(alignment: .leading, spacing: GTSelectionMetrics.textBlockSpacing) {
            if !content.originalPreview.isEmpty {
                Text(content.originalPreview)
                    .font(GTType.caption)
                    .foregroundStyle(GTColor.secondaryText)
                    .lineLimit(GTSelectionMetrics.maxOriginalLines)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("原文")
                    .accessibilityValue(content.originalPreview)
            }
            resultBlock(for: content)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func resultBlock(for content: SelectionPopoverContent) -> some View {
        if activeIsResultScrollable, let resultHeight = activeResultHeight {
            ScrollView(.vertical) {
                resultText(for: content)
                    .frame(width: textWidth, alignment: .leading)
            }
            .frame(width: textWidth, height: resultHeight, alignment: .leading)
            .scrollIndicators(.automatic)
        } else {
            resultText(for: content)
        }
    }

    private func resultText(for content: SelectionPopoverContent) -> some View {
        Text(content.displayTranslation)
            .font(resultFont(for: content))
            .foregroundStyle(resultColor(for: content))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .accessibilityLabel(resultAccessibilityLabel(for: content))
            .accessibilityValue(content.displayTranslation)
    }

    private var textWidth: CGFloat {
        GTSelectionMetrics.width - GTSelectionMetrics.horizontalPadding * 2
    }

    private func actionsGroup(for content: SelectionPopoverContent) -> some View {
        VStack(alignment: .leading, spacing: GTSelectionMetrics.actionsSpacing) {
            if content.showsOptimizeAction {
                GTOptimizeModePicker(
                    selection: modeBinding,
                    isEnabled: content.status != .optimizing
                )
            }
            if content.showsActionButtons {
                HStack(spacing: GTSpacing.xSmall) {
                    if content.showsTranslateAction {
                        let translateTitle = content.status == .translated ? "重试" : "翻译"
                        SelectionPopoverActionButton(
                            title: translateTitle,
                            systemImage: nil,
                            isPrimary: false,
                            isDisabled: content.status == .loading,
                            markerName: "translate",
                            action: onTranslate
                        )
                        .accessibilityHint(
                            content.isCodeSnippet
                                ? "自动翻译代码中的注释和字符串，并解释代码"
                                : "按内容自动翻译选区：中文译成英文，其他译成简体中文"
                        )
                    }
                    if content.showsOptimizeAction {
                        SelectionPopoverActionButton(
                            title: "优化提示词",
                            systemImage: nil,
                            isPrimary: false,
                            isDisabled: content.status == .optimizing,
                            markerName: "optimize",
                            action: onOptimize
                        )
                        .accessibilityHint(chrome.optimizeMode.optimizeAccessibilityHint)
                    }
                    if content.allowsCopy {
                        SelectionPopoverActionButton(
                            title: chrome.copyFeedback.title,
                            systemImage: chrome.copyFeedback == .copied ? "checkmark" : nil,
                            isPrimary: !content.showsOpenSettingsAction,
                            isDisabled: false,
                            markerName: "copy",
                            action: onCopy
                        )
                        .accessibilityLabel(chrome.copyFeedback.title)
                        .accessibilityHint(chrome.copyFeedback == .idle ? "将结果复制到剪贴板 (⌘C)" : chrome.copyFeedback.title)
                    }
                    if content.showsOpenSettingsAction {
                        SelectionPopoverActionButton(
                            title: "打开设置",
                            systemImage: nil,
                            isPrimary: true,
                            isDisabled: false,
                            markerName: "settings",
                            action: onOpenSettings
                        )
                        .accessibilityHint("打开设置完成权限或后端配置")
                    }
                }
                .frame(
                    width: GTSelectionMetrics.width - GTSelectionMetrics.horizontalPadding * 2,
                    height: GTSelectionMetrics.actionRowHeight
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var modeBinding: Binding<PromptOptimizeMode> {
        Binding(
            get: { chrome.optimizeMode },
            set: { onOptimizeModeChange($0) }
        )
    }

    private func resultFont(for content: SelectionPopoverContent) -> Font {
        SelectionPopoverLayout.resultFont(for: content.status)
    }

    private func resultColor(for content: SelectionPopoverContent) -> Color {
        switch content.status {
        case .failed, .unavailable:
            return GTColor.destructive
        default:
            return GTColor.primaryText
        }
    }

    private func resultAccessibilityLabel(for content: SelectionPopoverContent) -> String {
        if content.isCodeSnippet { return "代码翻译结果" }
        switch content.status {
        case .optimized, .optimizing:
            return "优化后的提示词"
        default:
            return "翻译结果"
        }
    }
}

private struct SelectionPopoverActionButton: View {
    let title: String
    let systemImage: String?
    let isPrimary: Bool
    let isDisabled: Bool
    let markerName: String
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: GTSpacing.xxSmall) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .accessibilityHidden(true)
                }
                Text(title)
            }
            .font(GTType.secondary.weight(isPrimary ? .semibold : .medium))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .foregroundStyle(foregroundColor)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: GTRadius.row, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: GTRadius.row, style: .continuous)
                .strokeBorder(isPrimary ? Color.clear : GTColor.hairline, lineWidth: GTControlMetrics.fieldStrokeWidth)
        )
        .scaleEffect(isPressed && !reduceMotion ? 0.97 : 1)
        .animation(reduceMotion ? nil : .timingCurve(0.23, 1, 0.32, 1, duration: 0.12), value: isPressed)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovered)
        .onHover { isHovered = $0 }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in if !isDisabled { isPressed = true } }
                .onEnded { _ in isPressed = false }
        )
        .selectionActionSurfaceMarker(markerName)
        .disabled(isDisabled)
    }

    private var foregroundColor: Color {
        if isDisabled { return GTColor.secondaryText }
        return isPrimary ? GTColor.selectedSegmentText : GTColor.primaryText
    }

    private var backgroundColor: Color {
        if isPrimary {
            return isHovered && !isDisabled ? GTColor.accent.opacity(0.88) : GTColor.accent
        }
        return isHovered && !isDisabled ? GTColor.hoverFill : GTColor.cardSurface
    }
}

extension View {
    @ViewBuilder
    func selectionActionSurfaceMarker(_ name: String) -> some View {
        #if DEBUG
        background {
            SelectionActionSurfaceMarker(name: name)
                .allowsHitTesting(false)
        }
        #else
        self
        #endif
    }
}

#if DEBUG
enum SelectionActionSurface {
    static let identifierPrefix = "selection-action-surface."

    static func identifier(_ name: String) -> String {
        identifierPrefix + name
    }
}

/// Invisible layout probe sized to the action surface it decorates.
struct SelectionActionSurfaceMarker: NSViewRepresentable {
    var name: String

    func makeNSView(context _: Context) -> NSView {
        let view = SelectionActionSurfaceNSView()
        configure(view)
        return view
    }

    func updateNSView(_ nsView: NSView, context _: Context) {
        configure(nsView)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView _: NSView, context _: Context) -> CGSize? {
        guard proposal.width != nil, proposal.height != nil else { return nil }
        return proposal.replacingUnspecifiedDimensions()
    }

    private func configure(_ view: NSView) {
        view.identifier = NSUserInterfaceItemIdentifier(SelectionActionSurface.identifier(name))
        view.setAccessibilityElement(false)
        view.alphaValue = 0
    }
}

final class SelectionActionSurfaceNSView: NSView {
    override func hitTest(_: NSPoint) -> NSView? { nil }
}
#endif

enum SelectionPopoverLayout {
    /// Short terminal status (已是中文 / 无需翻译 / 失败 / 无法读取). Process
    /// and long body copy stay on `.body` so loading is not taller than translated.
    static let statusResultFont: Font = .title3.weight(.semibold)

    static func resultFont(for status: SelectionPopoverStatus) -> Font {
        usesStatusResultFont(status) ? statusResultFont : GTType.body
    }

    static func resultMeasuringFont(for status: SelectionPopoverStatus) -> NSFont {
        usesStatusResultFont(status)
            ? statusResultMeasuringFont
            : NSFont.preferredFont(forTextStyle: .body)
    }

    static func usesStatusResultFont(_ status: SelectionPopoverStatus) -> Bool {
        switch status {
        case .alreadyChinese, .noTranslationNeeded, .failed, .unavailable:
            return true
        case .loading, .optimizing, .translated, .optimized:
            return false
        }
    }

    static var statusResultMeasuringFont: NSFont {
        let size = NSFont.preferredFont(forTextStyle: .title3).pointSize
        return NSFont.systemFont(ofSize: size, weight: .semibold)
    }

    /// Places the selection popover below (or above if space below is tight)
    /// `originalFrame` so it does not cover the text the user just selected.
    static func placementFrame(
        around originalFrame: CGRect,
        contentSize: CGSize,
        screenVisibleFrame: CGRect
    ) -> CGRect {
        let gap: CGFloat = GTSpacing.xSmall
        let width = min(contentSize.width, screenVisibleFrame.width)
        let height = min(contentSize.height, screenVisibleFrame.height)
        let x = min(
            max(originalFrame.minX, screenVisibleFrame.minX + GTPopoverMetrics.screenMargin),
            max(screenVisibleFrame.minX + GTPopoverMetrics.screenMargin, screenVisibleFrame.maxX - width - GTPopoverMetrics.screenMargin)
        )
        guard originalFrame.width > 0 || originalFrame.height > 0 else {
            return OverlayLayout.placementFrame(
                originalFrame: originalFrame,
                contentSize: CGSize(width: width, height: height),
                screenVisibleFrame: screenVisibleFrame
            )
        }
        let belowY = originalFrame.minY - gap - height
        let aboveY = originalFrame.maxY + gap
        let minY = screenVisibleFrame.minY + GTPopoverMetrics.screenMargin
        let maxY = screenVisibleFrame.maxY - GTPopoverMetrics.screenMargin - height
        let y: CGFloat
        if belowY >= minY {
            y = min(belowY, max(minY, maxY))
        } else if aboveY <= maxY {
            y = max(aboveY, minY)
        } else {
            y = min(max(belowY, minY), max(minY, maxY))
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// `NSString.boundingRect` is pathologically slow for a few thousand CJK
    /// characters (measured ~1.6s for 120 lines), which would freeze the panel
    /// after a long code explanation. TextKit gives the same wrapped height in
    /// tens of milliseconds.
    static func measuredWrappedHeight(
        for text: String,
        width: CGFloat,
        font: NSFont
    ) -> CGFloat {
        let lineHeight = OverlayLayout.estimatedLineHeight(for: font)
        guard !text.isEmpty else { return lineHeight }
        let storage = NSTextStorage(
            string: text,
            attributes: [.font: font]
        )
        let manager = NSLayoutManager()
        let container = NSTextContainer(
            size: CGSize(width: width, height: .greatestFiniteMagnitude)
        )
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        return max(lineHeight, ceil(manager.usedRect(for: container).height))
    }
}
