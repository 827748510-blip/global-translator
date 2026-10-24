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
    var onCopy: () -> Void = {}
    var onTranslate: () -> Void = {}
    var onOptimize: () -> Void = {}
    var onOptimizeModeChange: (PromptOptimizeMode) -> Void = { _ in }

    public init(
        content: SelectionPopoverContent,
        chrome: SelectionPopoverChrome,
        onCopy: @escaping () -> Void = {},
        onTranslate: @escaping () -> Void = {},
        onOptimize: @escaping () -> Void = {},
        onOptimizeModeChange: @escaping (PromptOptimizeMode) -> Void = { _ in }
    ) {
        self.content = content
        self.chrome = chrome
        self.onCopy = onCopy
        self.onTranslate = onTranslate
        self.onOptimize = onOptimize
        self.onOptimizeModeChange = onOptimizeModeChange
    }

    public var body: some View {
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
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: GTRadius.overlay, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: GTRadius.overlay, style: .continuous)
                .strokeBorder(
                    GTGlassOptics.refractionStroke,
                    lineWidth: GTControlMetrics.fieldStrokeWidth
                )
        }
        .accessibilityElement(children: .contain)
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
            Text(content.displayTranslation)
                .font(resultFont)
                .foregroundStyle(resultColor)
                .lineLimit(GTSelectionMetrics.maxTranslationLines)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .accessibilityLabel(resultAccessibilityLabel)
                .accessibilityValue(content.displayTranslation)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                GTEqualWidthHStack(spacing: GTSpacing.xSmall) {
                    if content.showsTranslateAction {
                        Button("翻译", action: onTranslate)
                            .buttonStyle(GTEqualFillButtonStyle())
                            .disabled(content.status == .loading)
                            .accessibilityHint("按内容自动翻译选区：中文译成英文，其他译成简体中文")
                    }
                    if content.showsOptimizeAction {
                        Button("优化提示词", action: onOptimize)
                            .buttonStyle(GTEqualFillButtonStyle())
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
                        }
                        .buttonStyle(GTEqualFillButtonStyle())
                        .accessibilityLabel(chrome.copyFeedback.title)
                        .accessibilityHint(chrome.copyFeedback == .idle ? "将结果复制到剪贴板" : chrome.copyFeedback.title)
                    }
                }
                .frame(height: GTSelectionMetrics.actionRowHeight)
                .frame(maxWidth: .infinity)
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
        switch content.status {
        case .optimized, .optimizing:
            return "优化后的提示词"
        default:
            return "翻译结果"
        }
    }

    private var background: some View {
        ZStack {
            GTGlassBackground(
                material: GTGlassOptics.selectionMaterial,
                fallback: GTColor.overlaySolidFallback,
                transmission: GTGlassOptics.selectionTransmission
            )
            GTRefractionSheen()
        }
    }
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
}
