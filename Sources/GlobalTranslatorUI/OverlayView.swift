import SwiftUI
import GlobalTranslatorCore
import GlobalTranslatorEngine

/// Click-through translation patch. Plain `Text` only — no HTML/Markdown.
/// Draws a solid system background so the source text underneath is covered.
public struct OverlayView: View {
    private let text: String

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
            .padding(.horizontal, GTOverlayMetrics.horizontalPadding)
            .padding(.vertical, GTOverlayMetrics.verticalPadding)
            // Fill the whole panel so wide source regions do not leave empty gaps
            // and the patch covers the original text underneath.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            // Solid fill, not a translucent material: a material still lets the
            // English source show through, which defeats the in-place patch.
            .background(GTColor.overlaySolidFallback)
            .clipShape(RoundedRectangle(cornerRadius: GTOverlayMetrics.patchCornerRadius, style: .continuous))
            .accessibilityLabel("翻译结果")
            .accessibilityValue(text)
    }
}
