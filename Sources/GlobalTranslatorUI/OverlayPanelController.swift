import AppKit
import GlobalTranslatorCore
import GlobalTranslatorEngine
import os
import SwiftUI

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
    private struct FontBox: @unchecked Sendable {
        let font: NSFont
    }

    private struct CacheKey: Hashable, Sendable {
        let text: String
        let widthHundredths: Int
        let maxLines: Int
        let fontName: String
        let fontSizeHundredths: Int
    }

    private final class SizeCacheState: @unchecked Sendable {
        static let maxEntries = 1_024
        static let maxCachedTextLength = 2_000

        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 320, height: CGFloat.greatestFiniteMagnitude))
        var entries: [CacheKey: (size: CGSize, stamp: UInt64)] = [:]
        var stamp: UInt64 = 0

        init() {
            container.lineFragmentPadding = 0
            container.widthTracksTextView = false
            manager.addTextContainer(container)
            storage.addLayoutManager(manager)
        }
    }

    private static let sizeCache = OSAllocatedUnfairLock(initialState: SizeCacheState())

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
        let clampedLines = max(1, maxLines)
        let cacheKey: CacheKey? = text.count <= SizeCacheState.maxCachedTextLength
            ? CacheKey(
                text: text,
                widthHundredths: Int((maxWidth * 100).rounded()),
                maxLines: clampedLines,
                fontName: font.fontName,
                fontSizeHundredths: Int((font.pointSize * 100).rounded())
            )
            : nil

        let fontBox = FontBox(font: font)
        return sizeCache.withLock { state in
            if let cacheKey, var hit = state.entries[cacheKey] {
                state.stamp &+= 1
                hit.stamp = state.stamp
                state.entries[cacheKey] = hit
                return hit.size
            }

            state.container.size = CGSize(width: maxWidth, height: CGFloat.greatestFiniteMagnitude)
            state.container.maximumNumberOfLines = clampedLines
            state.storage.beginEditing()
            state.storage.setAttributedString(NSAttributedString(string: text, attributes: [.font: fontBox.font]))
            state.storage.endEditing()
            state.manager.ensureLayout(for: state.container)
            let used = state.manager.usedRect(for: state.container)
            let cappedHeight = min(ceil(used.height), lineHeight * CGFloat(clampedLines))
            let measured = CGSize(
                width: min(ceil(used.width), maxWidth),
                height: max(cappedHeight, lineHeight)
            )
            if let cacheKey {
                if state.entries.count >= SizeCacheState.maxEntries,
                   let victim = state.entries.min(by: { $0.value.stamp < $1.value.stamp })?.key {
                    state.entries.removeValue(forKey: victim)
                }
                state.stamp &+= 1
                state.entries[cacheKey] = (measured, state.stamp)
            }
            return measured
        }
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

/// Renders all overlay patches via one reusable click-through container
/// `OverlayPanel` per active display (using a `CALayer` + `CATextLayer` pool)
/// plus at most one reusable `.screenSaver` hover `OverlayPanel`.
@MainActor
public final class OverlayPanelController {
    public private(set) var currentRevision: UInt64 = 0

    private struct ScreenKey: Hashable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double

        init(_ rect: CGRect) {
            self.x = rect.origin.x
            self.y = rect.origin.y
            self.width = rect.size.width
            self.height = rect.size.height
        }
    }

    private final class PatchLayer {
        let container = CALayer()
        let textLayer = CATextLayer()
        var lastFrame: CGRect = .zero
        var lastText: String = ""
        var lastScale: CGFloat = 0

        init() {
            container.cornerRadius = GTOverlayMetrics.patchCornerRadius
            container.cornerCurve = .continuous
            container.masksToBounds = true
            textLayer.isWrapped = true
            textLayer.truncationMode = .end
            textLayer.alignmentMode = .left
            let font = NSFont.preferredFont(forTextStyle: .callout)
            textLayer.font = font
            textLayer.fontSize = font.pointSize
            container.addSublayer(textLayer)
        }

        func configure(
            frame: CGRect,
            text: String,
            textSize: CGSize,
            backgroundColor: CGColor,
            foregroundColor: CGColor,
            scale: CGFloat
        ) {
            container.backgroundColor = backgroundColor
            textLayer.foregroundColor = foregroundColor
            if lastScale != scale {
                container.contentsScale = scale
                textLayer.contentsScale = scale
                lastScale = scale
            }
            if lastFrame != frame || lastText != text {
                container.frame = frame
                let maxTextHeight = max(1, frame.height - GTOverlayMetrics.verticalPadding * 2)
                let resolvedTextHeight = min(maxTextHeight, max(textSize.height, OverlayLayout.estimatedLineHeight))
                let textY = max(GTOverlayMetrics.verticalPadding, (frame.height - resolvedTextHeight) / 2)
                textLayer.frame = CGRect(
                    x: GTOverlayMetrics.horizontalPadding,
                    y: textY,
                    width: max(1, frame.width - GTOverlayMetrics.horizontalPadding * 2),
                    height: resolvedTextHeight
                )
                lastFrame = frame
            }
            if lastText != text {
                textLayer.string = text
                lastText = text
            }
        }
    }

    private struct PatchRecord {
        let id: UUID
        let screenKey: ScreenKey
        let screenFrame: CGRect
        let sourceFrame: CGRect
        let text: String
        let textSize: CGSize
        let layer: PatchLayer
    }

    private var containerPanels: [ScreenKey: OverlayPanel] = [:]
    private var patches: [UUID: PatchRecord] = [:]
    private var layerPool: [PatchLayer] = []
    private static let maxPooledLayers = 64

    private var hoverPanel: OverlayPanel?
    private var hoverLayer: PatchLayer?
    private var hoveredID: UUID?

    nonisolated(unsafe) private var mouseMonitors: [Any] = []
    private var lastHoverSampleTime: TimeInterval = 0
    private var invalidatedThroughRevision: UInt64?
    private let visibleFramesProvider: () -> [CGRect]
    public var shouldSuppressHoverRaise: () -> Bool

    public var panelCount: Int {
        patches.count
    }

    /// Test seam: number of underlying AppKit `OverlayPanel` container windows currently kept active.
    var backingWindowCount: Int {
        containerPanels.values.filter(\.isVisible).count
    }

    /// Test seam: the text currently rendered by the patch for a region ID.
    public func panelText(for id: UUID) -> String? {
        patches[id]?.text
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

    func panelLevel(for id: UUID) -> NSWindow.Level? {
        guard patches[id] != nil else { return nil }
        return hoveredID == id ? .screenSaver : .floating
    }

    func updateHover(at point: CGPoint) {
        let suppressed = shouldSuppressHoverRaise()
        var target: PatchRecord?
        if !suppressed {
            for record in patches.values {
                let area = record.screenFrame.union(record.sourceFrame).insetBy(dx: -4, dy: -4)
                if area.contains(point) {
                    target = record
                    break
                }
            }
        }

        if let target {
            hoveredID = target.id
            let panel = ensureHoverPanel(frame: target.screenFrame)
            let layer = hoverLayer ?? PatchLayer()
            hoverLayer = layer
            if let root = panel.contentView?.layer, layer.container.superlayer !== root {
                root.addSublayer(layer.container)
            }
            let appearance = panel.contentView?.effectiveAppearance ?? NSAppearance.currentDrawing()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.configure(
                frame: CGRect(origin: .zero, size: target.screenFrame.size),
                text: target.text,
                textSize: target.textSize,
                backgroundColor: Self.resolvedBackgroundColor(for: appearance),
                foregroundColor: Self.resolvedForegroundColor(for: appearance),
                scale: panel.backingScaleFactor
            )
            CATransaction.commit()
            if panel.frame != target.screenFrame {
                panel.setFrame(target.screenFrame, display: true)
            }
            if panel.level != .screenSaver {
                panel.level = .screenSaver
            }
            if !panel.isVisible {
                panel.orderFrontRegardless()
            } else {
                panel.orderFrontRegardless()
            }
        } else {
            hoveredID = nil
            if let hoverPanel, hoverPanel.isVisible {
                hoverPanel.orderOut(nil)
            }
        }
    }

    private func ensureHoverPanel(frame: CGRect) -> OverlayPanel {
        if let hoverPanel {
            return hoverPanel
        }
        let panel = OverlayPanel(contentRect: frame)
        panel.level = .screenSaver
        let view = NSView(frame: CGRect(origin: .zero, size: frame.size))
        view.autoresizingMask = [.width, .height]
        view.wantsLayer = true
        panel.contentView = view
        hoverPanel = panel
        return panel
    }

    private func ensureContainerPanel(for visibleFrame: CGRect, key: ScreenKey) -> OverlayPanel {
        if let existing = containerPanels[key] {
            if existing.frame != visibleFrame {
                existing.setFrame(visibleFrame, display: true)
            }
            return existing
        }
        let panel = OverlayPanel(contentRect: visibleFrame)
        let view = NSView(frame: CGRect(origin: .zero, size: visibleFrame.size))
        view.autoresizingMask = [.width, .height]
        view.wantsLayer = true
        panel.contentView = view
        containerPanels[key] = panel
        return panel
    }

    private func borrowPatchLayer() -> PatchLayer {
        if let reused = layerPool.popLast() {
            reused.container.isHidden = false
            return reused
        }
        return PatchLayer()
    }

    private func recyclePatchLayer(_ layer: PatchLayer) {
        layer.container.removeFromSuperlayer()
        if layerPool.count < Self.maxPooledLayers {
            layerPool.append(layer)
        }
    }

    private static func resolvedBackgroundColor(for appearance: NSAppearance) -> CGColor {
        var resolved = NSColor.white.cgColor
        appearance.performAsCurrentDrawingAppearance {
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            resolved = (isDark ? NSColor.windowBackgroundColor : NSColor.white).cgColor
        }
        return resolved
    }

    private static func resolvedForegroundColor(for appearance: NSAppearance) -> CGColor {
        var resolved = NSColor.labelColor.cgColor
        appearance.performAsCurrentDrawingAppearance {
            resolved = NSColor.labelColor.cgColor
        }
        return resolved
    }

    private func trackHover() {
        guard !patches.isEmpty else {
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
                guard !self.patches.isEmpty else { return }
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
        var activeScreenKeys: Set<ScreenKey> = []

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        for translation in translations {
            guard !translation.text.isEmpty else { continue }
            let screenFrame = translation.region.screenFrame
            let center = CGPoint(x: screenFrame.midX, y: screenFrame.midY)
            guard let visibleFrame = OverlayLayout.owningVisibleFrame(for: center, in: visibleFrames)
                ?? OverlayLayout.owningVisibleFrame(for: screenFrame.origin, in: visibleFrames) else {
                continue
            }

            let screenKey = ScreenKey(visibleFrame)
            activeScreenKeys.insert(screenKey)
            seen.insert(translation.id)

            let textSize = OverlayLayout.estimatedTextSize(
                for: translation.text,
                maxWidth: GTOverlayMetrics.maxTextWidth,
                maxLines: GTOverlayMetrics.maxLines
            )
            let contentSize = CGSize(
                width: textSize.width + GTOverlayMetrics.horizontalPadding * 2,
                height: textSize.height + GTOverlayMetrics.verticalPadding * 2
            )
            let frame = OverlayLayout.placementFrame(
                originalFrame: screenFrame,
                contentSize: contentSize,
                screenVisibleFrame: visibleFrame
            )
            let localFrame = CGRect(
                x: frame.minX - visibleFrame.minX,
                y: frame.minY - visibleFrame.minY,
                width: frame.width,
                height: frame.height
            )

            let panel = ensureContainerPanel(for: visibleFrame, key: screenKey)
            let appearance = panel.contentView?.effectiveAppearance ?? NSAppearance.currentDrawing()
            let bgColor = Self.resolvedBackgroundColor(for: appearance)
            let fgColor = Self.resolvedForegroundColor(for: appearance)

            let patchLayer: PatchLayer
            if let existing = patches[translation.id] {
                if existing.screenKey != screenKey {
                    existing.layer.container.removeFromSuperlayer()
                }
                patchLayer = existing.layer
            } else {
                patchLayer = borrowPatchLayer()
            }

            if let rootLayer = panel.contentView?.layer, patchLayer.container.superlayer !== rootLayer {
                rootLayer.addSublayer(patchLayer.container)
            }
            patchLayer.configure(
                frame: localFrame,
                text: translation.text,
                textSize: textSize,
                backgroundColor: bgColor,
                foregroundColor: fgColor,
                scale: panel.backingScaleFactor
            )

            patches[translation.id] = PatchRecord(
                id: translation.id,
                screenKey: screenKey,
                screenFrame: frame,
                sourceFrame: screenFrame,
                text: translation.text,
                textSize: textSize,
                layer: patchLayer
            )
        }

        let staleIDs = patches.keys.filter { !seen.contains($0) }
        for id in staleIDs {
            if let removed = patches.removeValue(forKey: id) {
                recyclePatchLayer(removed.layer)
            }
            if hoveredID == id {
                hoveredID = nil
            }
        }

        CATransaction.commit()

        for (key, panel) in containerPanels {
            if activeScreenKeys.contains(key) {
                if !panel.isVisible { panel.orderFrontRegardless() }
            } else if panel.isVisible {
                panel.orderOut(nil)
            }
        }
        trackHover()
    }

    /// Hides and drops every patch immediately and invalidates in-flight work:
    /// an update carrying the pre-hide (equal) or an older revision cannot
    /// recreate patches; only a genuinely newer capture may.
    public func hideAll() {
        invalidatedThroughRevision = max(invalidatedThroughRevision ?? 0, currentRevision)
        hoveredID = nil
        if let hoverPanel, hoverPanel.isVisible {
            hoverPanel.orderOut(nil)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for record in patches.values {
            recyclePatchLayer(record.layer)
        }
        patches.removeAll()
        CATransaction.commit()
        for panel in containerPanels.values where panel.isVisible {
            panel.orderOut(nil)
        }
        stopMouseMonitors()
    }
}
