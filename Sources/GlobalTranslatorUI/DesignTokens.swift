import SwiftUI
import AppKit

/// 4px spacing grid (see DESIGN.md §3).
public enum GTSpacing {
    public static let xxSmall: CGFloat = 4
    public static let xSmall: CGFloat = 8
    public static let small: CGFloat = 12
    public static let medium: CGFloat = 16
    public static let large: CGFloat = 20
    public static let xLarge: CGFloat = 24
}

/// Corner radii (see DESIGN.md §3).
public enum GTRadius {
    public static let row: CGFloat = 6
    public static let card: CGFloat = 10
    public static let overlay: CGFloat = 8
}

/// System text styles (SF Pro / PingFang fallback chain). Dynamic Type safe.
public enum GTType {
    public static let stateLine = Font.headline
    public static let cardTitle = Font.system(size: 12, weight: .semibold)
    public static let sectionTitle = Font.system(size: 12, weight: .semibold)
    public static let body = Font.body
    public static let secondary = Font.footnote
    public static let caption = Font.caption
    public static let overlay = Font.callout
}

/// Semantic colors only — no raw hex (see DESIGN.md §3).
public enum GTColor {
    public static let primaryText = Color.primary
    public static let secondaryText = Color.secondary
    public static let accent = Color.accentColor
    public static let destructive = Color(nsColor: .systemRed)
    public static let sectionFill = Color(nsColor: .controlBackgroundColor)
    public static let fieldFill = Color(nsColor: .textBackgroundColor)
    public static let hairline = Color.primary.opacity(0.12)
    /// Solid popup fill: pure white in light mode, system window background in dark.
    public static let panelBackground = Color(nsColor: NSColor(name: "GTPanelBackground", dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.windowBackgroundColor
            : NSColor.white
    }))
    /// Track behind equal-width segmented controls; readable on white and dark panels.
    public static let segmentTrack = Color.primary.opacity(0.08)
    /// Selected segment label sits on `accent`; keep it light in both appearances.
    public static let selectedSegmentText = Color.white
    /// Solid fallback for overlay backgrounds when Reduce Transparency is enabled.
    public static let overlaySolidFallback = panelBackground
}

/// Shared math for equal-width button / segment rows.
public enum GTEqualWidthMetrics {
    public static func itemWidth(total: CGFloat, count: Int, spacing: CGFloat) -> CGFloat {
        guard count > 0 else { return 0 }
        return max(0, (total - spacing * CGFloat(count - 1)) / CGFloat(count))
    }
}

/// Shared form controls (settings cards, text fields, custom menus).
public enum GTControlMetrics {
    /// Compact settings field / menu trigger height.
    public static let fieldHeight: CGFloat = 30
    public static let menuRowHeight: CGFloat = 28
    public static let menuListMaxHeight: CGFloat = 144
    public static let fieldStrokeWidth: CGFloat = 1
    /// Compact settings rows keep the whole page dense without shrinking labels.
    public static let settingRowHeight: CGFloat = 30
    public static let settingLabelWidth: CGFloat = 72
    public static let sectionSpacing: CGFloat = 8
    public static let cardHorizontalPadding: CGFloat = 12
    public static let cardVerticalPadding: CGFloat = 10
    public static let segmentHeight: CGFloat = 28
}

/// Overlay layout metrics (see DESIGN.md §3/§5).
public enum GTOverlayMetrics {
    /// Maximum width of the translation text block.
    public static let maxTextWidth: CGFloat = 320
    /// Maximum visible text lines before truncation.
    public static let maxLines = 3
    /// Tight padding so the translation reads as a patch over the source text.
    public static let horizontalPadding: CGFloat = 6
    public static let verticalPadding: CGFloat = 3
    /// The patch extends slightly beyond the source region so its edges are covered.
    public static let coverPadding: CGFloat = 2
    public static let patchCornerRadius: CGFloat = 4
}

/// Popover chrome metrics (see DESIGN.md §0/§5).
public enum GTPopoverMetrics {
    public static let width: CGFloat = 360
    /// Fallback max height when no screen is available; the controller recomputes
    /// the real limit from the visible frame at show time.
    public static let defaultMaxHeight: CGFloat = 600
    /// Keeps a floating panel clear of the menu bar and screen edges.
    public static let screenMargin: CGFloat = 8
    public static let contentPadding: CGFloat = 12
    public static let cardSpacing: CGFloat = 8
    /// Minimum practical vertical hit area for interactive rows.
    public static let minRowHitHeight: CGFloat = 44
}

/// Floating selection-translate popover (not the click-through overlay).
public enum GTSelectionMetrics {
    public static let width: CGFloat = 312
    public static let maxOriginalLines = 2
    public static let modePickerHeight: CGFloat = 32
    public static let actionRowHeight: CGFloat = 28
    public static let horizontalPadding: CGFloat = 14
    public static let verticalPadding: CGFloat = 12
    /// Original ↔ result. Tighter than the section gap so the pair reads as one block.
    public static let textBlockSpacing: CGFloat = GTSpacing.xxSmall
    /// Text block ↔ actions group.
    public static let sectionSpacing: CGFloat = GTSpacing.small
    /// Scene picker ↔ action buttons inside the actions group.
    public static let actionsSpacing: CGFloat = GTSpacing.xSmall
}
