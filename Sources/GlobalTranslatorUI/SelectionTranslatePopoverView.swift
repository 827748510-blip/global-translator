import SwiftUI
import GlobalTranslatorCore

/// Interactive selection popover: truncated original, translation, Copy.
public struct SelectionTranslatePopoverView: View {
    let content: SelectionPopoverContent
    var onCopy: () -> Void = {}

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public init(content: SelectionPopoverContent, onCopy: @escaping () -> Void = {}) {
        self.content = content
        self.onCopy = onCopy
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
                .accessibilityLabel("翻译结果")
                .accessibilityValue(content.displayTranslation)
            if content.allowsCopy {
                Button("拷贝", action: onCopy)
                    .buttonStyle(.bordered)
                    .accessibilityHint("将译文复制到剪贴板")
            }
        }
        .padding(.horizontal, GTOverlayMetrics.horizontalPadding)
        .padding(.vertical, GTOverlayMetrics.verticalPadding)
        .frame(width: GTSelectionMetrics.width, alignment: .leading)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: GTRadius.overlay, style: .continuous))
        .accessibilityElement(children: .contain)
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
