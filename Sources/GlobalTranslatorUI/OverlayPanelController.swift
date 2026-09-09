import AppKit
import SwiftUI
import GlobalTranslatorCore
import GlobalTranslatorEngine

/// Borderless, nonactivating, click-through panel used for translation bubbles.
/// The panel never takes key/main status and never captures input.
public final class OverlayPanel: NSPanel {
    public override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask = [.borderless, .nonactivatingPanel],
        backing bufferingType: NSWindow.BackingStoreType = .buffered,
        defer flag: Bool = false
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: bufferingType,
            defer: flag
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        // Hovering raises the panel without activating it or capturing input.
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
    }

    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }
}

/// Pure geometry helpers for overlay placement. `TextRegion.screenFrame` uses
/// AppKit global lower-left coordinates, matching `NSWindow.frame` directly.
public enum OverlayLayout {
    /// Height of one line of overlay text, used for size capping.
    public static var estimatedLineHeight: CGFloat {
        estimatedLineHeight(for: NSFont.preferredFont(forTextStyle: .callout))
    }

    public static func estimatedLineHeight(for font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading)
    }

    /// Conservative text measurement for panel sizing. Long CJK text wraps at
    /// `maxWidth`; height is capped at `maxLines` (the view truncates with an
    /// ellipsis at the same limit).
    public static func estimatedTextSize(
        for text: String,
        maxWidth: CGFloat,
        maxLines: Int,
        font: NSFont = NSFont.preferredFont(forTextStyle: .callout)
    ) -> CGSize {
        let lineHeight = estimatedLineHeight(for: font)
        let constrained = CGSize(width: maxWidth, height: .greatestFiniteMagnitude)
        let measured = (text as NSString).boundingRect(
            with: constrained,
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        let cappedHeight = min(ceil(measured.height), lineHeight * CGFloat(maxLines))
        return CGSize(
            width: min(ceil(measured.width), maxWidth),
            height: max(cappedHeight, lineHeight)
        )
    }

    /// Full panel content size including padding for a given text.
    public static func contentSize(forText text: String) -> CGSize {
        let textSize = estimatedTextSize(
            for: text,
            maxWidth: GTOverlayMetrics.maxTextWidth,
            maxLines: GTOverlayMetrics.maxLines
        )
        return CGSize(
            width: textSize.width + GTOverlayMetrics.horizontalPadding * 2,
            height: textSize.height + GTOverlayMetrics.verticalPadding * 2
        )
    }

    /// Places the panel adjacent to the original region: above when there is
    /// room, below as a fallback, clamped inside the owning screen's visible
    /// frame either way. Works with negative-coordinate secondary displays.
    public static func placementFrame(
        originalFrame: CGRect,
        contentSize: CGSize,
        screenVisibleFrame: CGRect,
        gap: CGFloat = GTOverlayMetrics.gap
    ) -> CGRect {
        let width = min(contentSize.width, screenVisibleFrame.width)
        let height = min(contentSize.height, screenVisibleFrame.height)

        var x = originalFrame.minX
        x = min(max(x, screenVisibleFrame.minX), screenVisibleFrame.maxX - width)

        var y: CGFloat
        let aboveY = originalFrame.maxY + gap
        if aboveY + height <= screenVisibleFrame.maxY {
            y = aboveY
        } else {
            let belowY = originalFrame.minY - gap - height
            if belowY >= screenVisibleFrame.minY {
                y = belowY
            } else {
                // Neither side fits; clamp inside the visible frame.
                y = min(max(aboveY, screenVisibleFrame.minY), screenVisibleFrame.maxY - height)
            }
        }

        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// The screen whose visible frame contains (or nearly contains) a point.
    /// A tolerance covers regions overlapping the menu bar or dragged slightly
    /// past a display edge; points far outside every screen are treated as
    /// stale and return nil so no panel is shown on the wrong display.
    public static func owningVisibleFrame(
        for point: CGPoint,
        in visibleFrames: [CGRect],
        containmentTolerance: CGFloat = 200
    ) -> CGRect? {
        if let containing = visibleFrames.first(where: { $0.contains(point) }) {
            return containing
        }
        return visibleFrames.first(where: {
            $0.insetBy(dx: -containmentTolerance, dy: -containmentTolerance).contains(point)
        })
    }
}

/// Owns one `OverlayPanel` per rendered translation. Panels only ever reflect
/// the current window revision; stale updates are dropped and `hideAll()`
/// tears everything down immediately.
@MainActor
public final class OverlayPanelController {
    public private(set) var currentRevision: UInt64 = 0

    private var panels: [UUID: OverlayPanel] = [:]
    /// Last text rendered into each panel's hosting view; also the test seam
    /// for verifying root-content updates without introspecting SwiftUI.
    private var panelContents: [UUID: String] = [:]
    private var sourceFrames: [UUID: CGRect] = [:]
    private var hoverTask: Task<Void, Never>?
    private var invalidatedThroughRevision: UInt64?
    private let visibleFramesProvider: () -> [CGRect]

    public var panelCount: Int {
        panels.count
    }

    /// Test seam: the text currently rendered by the panel for a region ID.
    public func panelText(for id: UUID) -> String? {
        panelContents[id]
    }

    public init() {
        self.visibleFramesProvider = { NSScreen.screens.map(\.visibleFrame) }
    }

    /// Test seam: inject screen visible frames without touching real displays.
    public init(visibleFramesProvider: @escaping () -> [CGRect]) {
        self.visibleFramesProvider = visibleFramesProvider
    }

    deinit { hoverTask?.cancel() }

    func panelLevel(for id: UUID) -> NSWindow.Level? { panels[id]?.level }

    func updateHover(at point: CGPoint) {
        for (id, panel) in panels {
            let area = panel.frame.union(sourceFrames[id] ?? panel.frame).insetBy(dx: -4, dy: -4)
            let level: NSWindow.Level = area.contains(point) ? .screenSaver : .floating
            if panel.level != level {
                panel.level = level
                if level == .screenSaver { panel.orderFrontRegardless() }
            }
        }
    }

    private func trackHover() {
        guard !panels.isEmpty else {
            hoverTask?.cancel()
            hoverTask = nil
            return
        }
        updateHover(at: NSEvent.mouseLocation)
        guard hoverTask == nil else { return }
        hoverTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                guard let self, !self.panels.isEmpty else { return }
                self.updateHover(at: NSEvent.mouseLocation)
            }
        }
    }

    /// Replaces the overlay set with the given translations for `revision`.
    /// Older revisions are ignored so stale translations never appear.
    public func update(translations: [RenderedTranslation], revision: UInt64) {
        if let invalidatedThroughRevision, revision <= invalidatedThroughRevision { return }
        guard revision >= currentRevision else { return }
        currentRevision = revision

        let visibleFrames = visibleFramesProvider()
        var seen: Set<UUID> = []

        for translation in translations {
            guard !translation.text.isEmpty else { continue }
            let origin = translation.region.screenFrame.origin
            guard let visibleFrame = OverlayLayout.owningVisibleFrame(
                for: origin,
                in: visibleFrames
            ) else { continue }

            seen.insert(translation.id)
            sourceFrames[translation.id] = translation.region.screenFrame
            let contentSize = OverlayLayout.contentSize(forText: translation.text)
            let frame = OverlayLayout.placementFrame(
                originalFrame: translation.region.screenFrame,
                contentSize: contentSize,
                screenVisibleFrame: visibleFrame
            )

            if let panel = panels[translation.id] {
                if panel.frame != frame { panel.setFrame(frame, display: true) }
                if panelContents[translation.id] != translation.text {
                    // Reuse the panel but refresh the rendered translation.
                    (panel.contentView as? NSHostingView<OverlayView>)?.rootView = OverlayView(rendered: translation)
                    panelContents[translation.id] = translation.text
                }
            } else {
                let panel = OverlayPanel(contentRect: frame)
                panel.contentView = NSHostingView(rootView: OverlayView(rendered: translation))
                panels[translation.id] = panel
                panelContents[translation.id] = translation.text
            }
            if let panel = panels[translation.id], !panel.isVisible { panel.orderFrontRegardless() }
        }

        // Collect stale IDs first; never mutate `panels` while iterating it.
        let staleIDs = panels.keys.filter { !seen.contains($0) }
        for id in staleIDs {
            panels[id]?.orderOut(nil)
            panels.removeValue(forKey: id)
            panelContents.removeValue(forKey: id)
            sourceFrames.removeValue(forKey: id)
        }
        trackHover()
    }

    /// Hides and drops every panel immediately and invalidates in-flight work:
    /// an update carrying the pre-hide (equal) or an older revision cannot
    /// recreate panels; only a genuinely newer capture may.
    public func hideAll() {
        invalidatedThroughRevision = max(invalidatedThroughRevision ?? 0, currentRevision)
        for panel in panels.values {
            panel.orderOut(nil)
        }
        panels.removeAll()
        panelContents.removeAll()
        sourceFrames.removeAll()
        hoverTask?.cancel()
        hoverTask = nil
    }
}
