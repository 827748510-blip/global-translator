import AppKit
import SwiftUI
import Combine
import GlobalTranslatorCore

/// Live chrome for the selection popover (scene + copy button). Observed so
/// copy feedback can update without rebuilding the hosting view — replacing
/// `NSHostingView` on copy was resetting feedback to idle on Mac.
@MainActor
public final class SelectionPopoverChrome: ObservableObject {
    @Published public var optimizeMode: PromptOptimizeMode = .communicationPolish
    @Published public var copyFeedback: SelectionCopyFeedback = .idle

    public init(
        optimizeMode: PromptOptimizeMode = .communicationPolish,
        copyFeedback: SelectionCopyFeedback = .idle
    ) {
        self.optimizeMode = optimizeMode
        self.copyFeedback = copyFeedback
    }
}

/// Interactive selection popover: truncated original, result, 翻译 / 优化提示词 / 拷贝.
public struct SelectionTranslatePopoverView: View {
    let content: SelectionPopoverContent
    @ObservedObject var chrome: SelectionPopoverChrome
    var resultHeight: CGFloat? = nil
    var isResultScrollable: Bool = false
    var onCopy: () -> Void = {}
    var onTranslate: () -> Void = {}
    var onOptimize: () -> Void = {}
    var onOptimizeModeChange: (PromptOptimizeMode) -> Void = { _ in }

    public init(
        content: SelectionPopoverContent,
        chrome: SelectionPopoverChrome,
        resultHeight: CGFloat? = nil,
        isResultScrollable: Bool = false,
        onCopy: @escaping () -> Void = {},
        onTranslate: @escaping () -> Void = {},
        onOptimize: @escaping () -> Void = {},
        onOptimizeModeChange: @escaping (PromptOptimizeMode) -> Void = { _ in }
    ) {
        self.content = content
        self.chrome = chrome
        self.resultHeight = resultHeight
        self.isResultScrollable = isResultScrollable
        self.onCopy = onCopy
        self.onTranslate = onTranslate
        self.onOptimize = onOptimize
        self.onOptimizeModeChange = onOptimizeModeChange
    }

    public var body: some View {
        contentLayout
            .glassEffect(
                .regular.interactive(),
                in: RoundedRectangle(cornerRadius: GTRadius.overlay, style: .continuous)
            )
            .accessibilityElement(children: .contain)
    }

    private var contentLayout: some View {
        VStack(alignment: .leading, spacing: GTSelectionMetrics.sectionSpacing) {
            textBlock
            if let savedHint = content.savedImageHint {
                Text(savedHint)
                    .font(GTType.caption)
                    .foregroundStyle(GTColor.secondaryText)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("截图保存位置")
                    .accessibilityValue(savedHint)
            }
            if content.showsOptimizeAction || content.showsActionButtons {
                actionsGroup
            }
        }
        .padding(.horizontal, GTSelectionMetrics.horizontalPadding)
        .padding(.vertical, GTSelectionMetrics.verticalPadding)
        .frame(width: GTSelectionMetrics.width, alignment: .leading)
    }

    private var textBlock: some View {
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
            resultBlock
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var resultBlock: some View {
        if isResultScrollable, let resultHeight {
            ScrollView(.vertical) {
                resultText
                    .frame(width: textWidth, alignment: .leading)
            }
            .frame(width: textWidth, height: resultHeight, alignment: .leading)
            .scrollIndicators(.automatic)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(resultAccessibilityLabel)
            .accessibilityValue(content.displayTranslation)
            .accessibilityHint("内容较长，可上下滚动查看完整译文")
        } else {
            resultText
        }
    }

    private var resultText: some View {
        Text(content.displayTranslation)
            .font(resultFont)
            .foregroundStyle(resultColor)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .accessibilityLabel(resultAccessibilityLabel)
            .accessibilityValue(content.displayTranslation)
    }

    private var textWidth: CGFloat {
        GTSelectionMetrics.width - GTSelectionMetrics.horizontalPadding * 2
    }

    private var actionsGroup: some View {
        VStack(alignment: .leading, spacing: GTSelectionMetrics.actionsSpacing) {
            if content.showsOptimizeAction {
                GTOptimizeModePicker(
                    selection: modeBinding,
                    isEnabled: content.status != .optimizing
                )
            }
            if content.showsActionButtons {
                // Plain style is required: the default macOS button bezel sits
                // underneath `.glassEffect`, producing a visible double fill.
                HStack(spacing: GTSpacing.xSmall) {
                    if content.showsTranslateAction {
                        Button(action: onTranslate) {
                            Text("翻译")
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                                .foregroundStyle(
                                    content.status == .loading ? GTColor.secondaryText : GTColor.primaryText
                                )
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .selectionActionGlassSurface("translate")
                        .disabled(content.status == .loading)
                        .accessibilityHint(
                            content.isCodeSnippet
                                ? "自动翻译代码中的注释和字符串，并解释代码"
                                : "按内容自动翻译选区：中文译成英文，其他译成简体中文"
                        )
                    }
                    if content.showsOptimizeAction {
                        Button(action: onOptimize) {
                            Text("优化提示词")
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                                .foregroundStyle(
                                    content.status == .optimizing ? GTColor.secondaryText : GTColor.primaryText
                                )
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .selectionActionGlassSurface("optimize")
                        .disabled(content.status == .optimizing)
                        .accessibilityHint(chrome.optimizeMode.optimizeAccessibilityHint)
                    }
                    if content.allowsCopy {
                        Button(action: onCopy) {
                            HStack(spacing: GTSpacing.xxSmall) {
                                if chrome.copyFeedback == .copied {
                                    Image(systemName: "checkmark")
                                        .accessibilityHidden(true)
                                }
                                Text(chrome.copyFeedback.title)
                            }
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .selectionActionGlassSurface("copy")
                        .accessibilityLabel(chrome.copyFeedback.title)
                        .accessibilityHint(chrome.copyFeedback == .idle ? "将结果复制到剪贴板" : chrome.copyFeedback.title)
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

    private var resultFont: Font {
        SelectionPopoverLayout.resultFont(for: content.status)
    }

    private var resultColor: Color {
        switch content.status {
        case .failed, .unavailable:
            return GTColor.destructive
        default:
            return GTColor.primaryText
        }
    }

    private var resultAccessibilityLabel: String {
        if content.isCodeSnippet { return "代码翻译结果" }
        switch content.status {
        case .optimized, .optimizing:
            return "优化后的提示词"
        default:
            return "翻译结果"
        }
    }

}

extension View {
    /// Glass for one action. The marker is part of this surface, after the
    /// expanding frame and with the glass, so a full-width row ancestor or an
    /// intrinsic focus ring is not what gets measured.
    func selectionActionGlassSurface(_ name: String) -> some View {
        glassEffect(
            .regular.interactive(),
            in: RoundedRectangle(cornerRadius: GTRadius.row, style: .continuous)
        )
        .background {
            SelectionActionSurfaceMarker(name: name)
                .allowsHitTesting(false)
        }
    }
}

enum SelectionActionSurface {
    static let identifierPrefix = "selection-action-surface."

    static func identifier(_ name: String) -> String {
        identifierPrefix + name
    }
}

/// Invisible layout probe sized to the glass surface it decorates.
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
