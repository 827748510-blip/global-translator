import SwiftUI
import GlobalTranslatorCore
import GlobalTranslatorEngine

/// Click-through translation bubble. Plain `Text` only — no HTML/Markdown.
/// Uses a system material with a solid fallback when Reduce Transparency is on.
public struct OverlayView: View {
    private let text: String

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public init(text: String) {
        self.text = text
    }

    public init(rendered: RenderedTranslation) {
        self.init(text: rendered.text)
    }

    public var body: some View {
        Text(text)
            .font(GTType.overlay)
            .foregroundStyle(GTColor.primaryText)
            .multilineTextAlignment(.leading)
            .lineLimit(GTOverlayMetrics.maxLines)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)
            .frame(
                maxWidth: GTOverlayMetrics.maxTextWidth,
                alignment: .leading
            )
            .padding(.horizontal, GTOverlayMetrics.horizontalPadding)
            .padding(.vertical, GTOverlayMetrics.verticalPadding)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: GTRadius.overlay, style: .continuous))
            .accessibilityLabel("翻译结果")
            .accessibilityValue(text)
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
