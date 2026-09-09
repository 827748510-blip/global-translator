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
        VStack(alignment: .leading, spacing: GTSpacing.xSmall) {
            if !content.originalPreview.isEmpty {
                Text(content.originalPreview)
                    .font(GTType.caption)
                    .foregroundStyle(GTColor.secondaryText)
                    .lineLimit(GTSelectionMetrics.maxOriginalLines)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("原文")
                    .accessibilityValue(content.originalPreview)
            }
            Text(content.displayTranslation)
                .font(GTType.body)
                .foregroundStyle(content.status == .failed || content.status == .unavailable ? GTColor.destructive : GTColor.primaryText)
                .lineLimit(GTSelectionMetrics.maxTranslationLines)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityLabel(resultAccessibilityLabel)
                .accessibilityValue(content.displayTranslation)
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
                            .accessibilityHint("把选区译成简体中文")
                    }
                    if content.showsOptimizeAction {
                        Button("优化提示词", action: onOptimize)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
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
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityLabel(chrome.copyFeedback.title)
                        .accessibilityHint(chrome.copyFeedback == .idle ? "将结果复制到剪贴板" : chrome.copyFeedback.title)
                    }
                }
            }
        }
        .padding(.horizontal, GTOverlayMetrics.horizontalPadding)
        .padding(.vertical, GTOverlayMetrics.verticalPadding)
        .frame(width: GTSelectionMetrics.width, alignment: .leading)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: GTRadius.overlay, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private var modeBinding: Binding<PromptOptimizeMode> {
        Binding(
            get: { chrome.optimizeMode },
            set: { onOptimizeModeChange($0) }
        )
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
