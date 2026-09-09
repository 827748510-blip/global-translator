import AppKit
import SwiftUI
import Combine
import GlobalTranslatorCore

/// Live chrome for the selection popover (scene + copy button). Observed so
/// copy feedback can update without rebuilding the hosting view — replacing
/// `NSHostingView` on copy was resetting feedback to idle on Mac.
@MainActor
public final class SelectionPopoverChrome: ObservableObject {
    @Published public var optimizeMode: PromptOptimizeMode = .generativePrompt
    @Published public var copyFeedback: SelectionCopyFeedback = .idle

    public init(
        optimizeMode: PromptOptimizeMode = .generativePrompt,
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

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

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
            if content.showsOptimizeAction || content.showsActionButtons {
                actionsGroup
            }
        }
        .padding(.horizontal, GTSelectionMetrics.horizontalPadding)
        .padding(.vertical, GTSelectionMetrics.verticalPadding)
        .frame(width: GTSelectionMetrics.width, alignment: .leading)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: GTRadius.overlay, style: .continuous))
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
                Picker("优化场景", selection: modeBinding) {
                    ForEach(PromptOptimizeMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .labelsHidden()
                .disabled(content.status == .optimizing)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("优化场景")
                .accessibilityValue(chrome.optimizeMode.title)
            }
            if content.showsActionButtons {
                HStack(spacing: GTSpacing.xSmall) {
                    if content.showsTranslateAction {
                        Button("翻译", action: onTranslate)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(content.status == .loading)
                            .frame(maxWidth: .infinity)
                            .accessibilityHint("把选区译成简体中文")
                    }
                    if content.showsOptimizeAction {
                        Button("优化提示词", action: onOptimize)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(content.status == .optimizing)
                            .frame(maxWidth: .infinity)
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
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel(chrome.copyFeedback.title)
                        .accessibilityHint(chrome.copyFeedback == .idle ? "将结果复制到剪贴板" : chrome.copyFeedback.title)
                    }
                }
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

    @ViewBuilder
    private var background: some View {
        if reduceTransparency {
            GTColor.overlaySolidFallback
        } else {
            Rectangle().fill(.regularMaterial)
        }
    }
}

enum SelectionPopoverLayout {
    static func resultFont(for status: SelectionPopoverStatus) -> Font {
        switch status {
        case .translated, .optimized:
            return GTType.body
        default:
            return GTType.stateLine
        }
    }

    static func resultMeasuringFont(for status: SelectionPopoverStatus) -> NSFont {
        switch status {
        case .translated, .optimized:
            return NSFont.preferredFont(forTextStyle: .body)
        default:
            return NSFont.preferredFont(forTextStyle: .headline)
        }
    }
}
