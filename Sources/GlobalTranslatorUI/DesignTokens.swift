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
    public static let sectionTitle = Font.subheadline.weight(.semibold)
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
    /// Solid fallback for overlay backgrounds when Reduce Transparency is enabled.
    public static let overlaySolidFallback = Color(nsColor: .windowBackgroundColor)
}

/// Overlay layout metrics (see DESIGN.md §3/§5).
public enum GTOverlayMetrics {
    /// Maximum width of the translation text block.
    public static let maxTextWidth: CGFloat = 320
    /// Maximum visible text lines before truncation.
    public static let maxLines = 3
    public static let horizontalPadding: CGFloat = 10
    public static let verticalPadding: CGFloat = 6
    /// Vertical gap between the original text region and the overlay panel.
    public static let gap: CGFloat = 6
}

/// Popover chrome metrics (see DESIGN.md §0/§5).
public enum GTPopoverMetrics {
    public static let width: CGFloat = 380
    /// Fallback max height when no screen is available; the controller recomputes
    /// the real limit from the visible frame at show time.
    public static let defaultMaxHeight: CGFloat = 640
    /// Minimum practical vertical hit area for interactive rows.
    public static let minRowHitHeight: CGFloat = 44
}
