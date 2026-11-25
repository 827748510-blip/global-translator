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

    /// Fast TextKit text measurement for panel sizing. Long CJK text wraps at
    /// `maxWidth`; height is capped at `maxLines` (the view truncates with an
    /// ellipsis at the same limit).
    public static func estimatedTextSize(
        for text: String,
        maxWidth: CGFloat,
        maxLines: Int,
        font: NSFont = NSFont.preferredFont(forTextStyle: .callout)
    ) -> CGSize {
        let lineHeight = estimatedLineHeight(for: font)
        guard !text.isEmpty, maxWidth > 0 else {
            return CGSize(width: 0, height: lineHeight)
        }
        let storage = NSTextStorage(string: text, attributes: [.font: font])
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: maxWidth, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        container.maximumNumberOfLines = max(1, maxLines)
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container)
        let cappedHeight = min(ceil(used.height), lineHeight * CGFloat(maxLines))
        return CGSize(
            width: min(ceil(used.width), maxWidth),
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

    /// Places the patch over the original region so the source text is hidden
    /// behind the translation. The frame grows just enough for longer
    /// translations, then clamps inside the owning screen's visible frame.
    /// Works with negative-coordinate secondary displays.
    public static func placementFrame(
        originalFrame: CGRect,
        contentSize: CGSize,
        screenVisibleFrame: CGRect
    ) -> CGRect {
        let padding = GTOverlayMetrics.coverPadding
        let desiredWidth = max(originalFrame.width + padding * 2, contentSize.width)
        let desiredHeight = max(originalFrame.height + padding * 2, contentSize.height)
        let width = min(desiredWidth, screenVisibleFrame.width)
        let height = min(desiredHeight, screenVisibleFrame.height)

        var x = originalFrame.minX - padding
        var y = originalFrame.minY - padding
        x = min(max(x, screenVisibleFrame.minX), screenVisibleFrame.maxX - width)
        y = min(max(y, screenVisibleFrame.minY), screenVisibleFrame.maxY - height)
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
    nonisolated(unsafe) private var mouseMonitors: [Any] = []
    private var lastHoverSampleTime: TimeInterval = 0
    private var invalidatedThroughRevision: UInt64?
    private let visibleFramesProvider: () -> [CGRect]
    public var shouldSuppressHoverRaise: () -> Bool

    public var panelCount: Int {
        panels.count
    }

    /// Test seam: the text currently rendered by the panel for a region ID.
    public func panelText(for id: UUID) -> String? {
        panelContents[id]
    }

    public init(
        visibleFramesProvider: @escaping () -> [CGRect] = { NSScreen.screens.map(\.visibleFrame) },
        shouldSuppressHoverRaise: @escaping () -> Bool = { false }
    ) {
        self.visibleFramesProvider = visibleFramesProvider
        self.shouldSuppressHoverRaise = shouldSuppressHoverRaise
    }

    deinit {
        for monitor in mouseMonitors { NSEvent.removeMonitor(monitor) }
    }

    func panelLevel(for id: UUID) -> NSWindow.Level? { panels[id]?.level }

    func updateHover(at point: CGPoint) {
        let suppressed = shouldSuppressHoverRaise()
        for (id, panel) in panels {
            let area = panel.frame.union(sourceFrames[id] ?? panel.frame).insetBy(dx: -4, dy: -4)
            let level: NSWindow.Level = (!suppressed && area.contains(point)) ? .screenSaver : .floating
            if panel.level != level {
                panel.level = level
                if level == .screenSaver { panel.orderFrontRegardless() }
            }
        }
    }

    private func trackHover() {
        guard !panels.isEmpty else {
            stopMouseMonitors()
            return
        }
        updateHover(at: NSEvent.mouseLocation)
        guard mouseMonitors.isEmpty else { return }
        var monitors: [Any] = []
        let handler: (NSEvent) -> Void = { [weak self] _ in
            guard let self else { return }
            assert(Thread.isMainThread)
            MainActor.assumeIsolated {
                guard !self.panels.isEmpty else { return }
                let now = ProcessInfo.processInfo.systemUptime
                guard now - self.lastHoverSampleTime >= 0.05 else { return }
                self.lastHoverSampleTime = now
                self.updateHover(at: NSEvent.mouseLocation)
            }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: handler) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { event in
            handler(event)
            return event
        }) {
            monitors.append(local)
        }
        mouseMonitors = monitors
    }

    private func stopMouseMonitors() {
        for monitor in mouseMonitors { NSEvent.removeMonitor(monitor) }
        mouseMonitors = []
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
            let screenFrame = translation.region.screenFrame
            let center = CGPoint(x: screenFrame.midX, y: screenFrame.midY)
            guard let visibleFrame = OverlayLayout.owningVisibleFrame(for: center, in: visibleFrames)
                ?? OverlayLayout.owningVisibleFrame(for: screenFrame.origin, in: visibleFrames) else {
                continue
            }

            seen.insert(translation.id)
            sourceFrames[translation.id] = screenFrame
            let contentSize = OverlayLayout.contentSize(forText: translation.text)
            let frame = OverlayLayout.placementFrame(
                originalFrame: screenFrame,
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
        stopMouseMonitors()
    }
}
