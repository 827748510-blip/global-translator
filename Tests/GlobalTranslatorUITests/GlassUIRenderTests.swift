import AppKit
import Foundation
import SwiftUI
import Testing
@testable import GlobalTranslatorCapture
@testable import GlobalTranslatorCore
@testable import GlobalTranslatorUI

@MainActor
private final class RenderActions: SettingsActions {
    func setAutomaticTranslation(_ enabled: Bool) {}
    func setSelectionTranslate(_ enabled: Bool) {}
    func setVideoTranslate(_ enabled: Bool) {}
    func setPromptOptimizeMode(_ mode: PromptOptimizeMode) {}
    func setAutoCopyScreenshotTranslation(_ enabled: Bool) {}
    func setSaveScreenshotImage(_ enabled: Bool) {}
    func setCopyScreenshotImage(_ enabled: Bool) {}
    func chooseScreenshotSaveDirectory() {}
    func setScreenshotTranslateHotkey(_ spec: KeyboardShortcutSpec) {}
    func beginScreenshotHotkeyRecording() {}
    func cancelScreenshotHotkeyRecording() {}
    func selectBackend(_ kind: BackendKind) {}
    func saveAPIKey(_ draft: String) async throws {}
    func deleteAPIKey() async throws {}
    func testConnection() async throws -> BackendHealth {
        BackendHealth(status: .healthy, message: "ok")
    }
    func setVisionFallback(_ enabled: Bool) {}
    func setLocalConfiguration(baseURL: String, model: String) {}
    func setDeepSeekModel(_ model: String) {}
    func requestPermission(_ kind: PermissionKind) {}
    func refreshPermissions() {}
    func openSystemSettings(_ kind: PermissionKind) {}
    func addCurrentAppTranslation() {}
    func chooseTranslatedApplications() {}
    func removeTranslationApplication(bundleIdentifier: String) {}
    func clearCache() async throws {}
    func openLogs() {}
    func openDeepSeekStats() {}
    func quit() {}
}

@MainActor
struct GlassUIRenderTests {
    @Test
    func settingsUsesCompactLayoutTokens() {
        #expect(GTPopoverMetrics.width == 360)
        #expect(GTPopoverMetrics.defaultMaxHeight == 600)
        #expect(GTControlMetrics.settingRowHeight == 30)
        #expect(GTControlMetrics.fieldHeight == 30)
        #expect(GTControlMetrics.settingLabelWidth == 72)
        #expect(GTControlMetrics.segmentHeight == 28)
    }

    @Test
    func settingsGlassPageRenders() throws {
        let view = SettingsPopoverView(
            viewModel: SettingsViewModel(actions: RenderActions()),
            maxHeight: 640
        )
        .modifier(GTSettingsPanelChrome(cornerRadius: GTRadius.card))
        let image = try Self.renderHostingView(view)
        #expect(image.size.width > 0)
        #expect(image.size.height > 0)
        try Self.writeIfRequested(image, named: "gt-glass-settings.png")
    }

    @Test
    func settingsGlassPageRendersDarkAppearance() throws {
        let view = SettingsPopoverView(
            viewModel: SettingsViewModel(actions: RenderActions()),
            maxHeight: 640
        )
        .modifier(GTSettingsPanelChrome(cornerRadius: GTRadius.card))
        .colorScheme(.dark)
        let image = try Self.renderHostingView(view)
        #expect(image.size.width > 0)
        #expect(image.size.height > 0)
        try Self.writeIfRequested(image, named: "gt-glass-settings-dark.png")
    }

    @Test
    func deepSeekStatsViewRendersLiveTotals() throws {
        let store = DeepSeekUsageStore()
        store.record(
            usage: DeepSeekTokenUsage(inputTokens: 1_200, cachedInputTokens: 900, outputTokens: 300),
            model: AppConfiguration.defaultDeepSeekModel,
            durationSeconds: 2,
            requestedAt: Date(timeIntervalSince1970: 1_760_000_000)
        )
        let view = DeepSeekStatsView(viewModel: DeepSeekStatsViewModel(store: store))
            .frame(width: 420, height: 520)
        let image = try Self.renderHostingView(view)
        #expect(image.size.width == 420)
        #expect(image.size.height == 520)
        try Self.writeIfRequested(image, named: "gt-deepseek-stats.png")
    }

    @Test
    func settingsGlassPageRendersOverColorfulBackdrop() throws {
        let content = SettingsPopoverView(
            viewModel: SettingsViewModel(actions: RenderActions()),
            maxHeight: 640
        )
        .modifier(GTSettingsPanelChrome(cornerRadius: GTRadius.card))
        let view = ZStack {
            LinearGradient(
                colors: [.indigo, .blue, .purple, .pink],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            content
        }
        let image = try Self.renderHostingView(view)
        #expect(image.size.width > 0)
        #expect(image.size.height > 0)
        try Self.writeIfRequested(image, named: "gt-glass-settings-backdrop.png")
    }

    @Test
    func nativeGlassButtonHonorsExplicitWidth() {
        let button = Button("拷贝") {}
            .frame(width: 284, height: 28)
            .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: GTRadius.row, style: .continuous))
        let size = NSHostingView(rootView: button).fittingSize
        #expect(size.width == 284)
        #expect(size.height == 28)
    }

    @Test
    func selectionPopoverActionGlassSurfacesFillTheirCells() {
        let selection = Self.actionSurfaceFrames(in: SelectionTranslatePopoverView(
            content: .translated(
                original: "Hello world",
                translation: "你好，世界",
                screenFrame: .zero
            ),
            chrome: SelectionPopoverChrome()
        ))
        Self.expectActionSurfacesFillRow(
            selection.frames,
            names: ["translate", "optimize", "copy"],
            detail: selection.tree
        )

        let screenshot = Self.actionSurfaceFrames(in: SelectionTranslatePopoverView(
            content: .translated(
                original: "Hello world",
                translation: "你好，世界",
                screenFrame: .zero
            ).asScreenshotResult(),
            chrome: SelectionPopoverChrome()
        ))
        Self.expectActionSurfacesFillRow(
            screenshot.frames,
            names: ["copy"],
            detail: screenshot.tree
        )
    }

    private static let actionSurfaceTolerance: CGFloat = 1

    private static func expectActionSurfacesFillRow(
        _ frames: [String: [CGRect]],
        names: [String],
        detail: String
    ) {
        let rowWidth = GTSelectionMetrics.width - GTSelectionMetrics.horizontalPadding * 2
        let spacing = GTSpacing.xSmall
        let cellWidth = names.count == 1
            ? rowWidth
            : GTEqualWidthMetrics.itemWidth(total: rowWidth, count: names.count, spacing: spacing)
        #expect(frames.count == names.count, "surfaces=\(frames) tree=\(detail)")
        var ordered: [CGRect] = []
        for name in names {
            let matches = frames[name] ?? []
            #expect(matches.count == 1, "\(name) frames=\(matches) tree=\(detail)")
            guard let frame = matches.first else { continue }
            ordered.append(frame)
            #expect(
                abs(frame.width - cellWidth) <= actionSurfaceTolerance,
                "\(name) width \(frame.width) expected \(cellWidth) tree=\(detail)"
            )
            #expect(
                abs(frame.height - GTSelectionMetrics.actionRowHeight) <= actionSurfaceTolerance,
                "\(name) height \(frame.height) tree=\(detail)"
            )
        }
        guard ordered.count == names.count else { return }
        #expect(
            abs(ordered[0].minX - GTSelectionMetrics.horizontalPadding) <= actionSurfaceTolerance,
            "leading \(ordered[0].minX) tree=\(detail)"
        )
        let trailing = GTSelectionMetrics.horizontalPadding + rowWidth
        #expect(
            abs(ordered[ordered.count - 1].maxX - trailing) <= actionSurfaceTolerance,
            "trailing \(ordered[ordered.count - 1].maxX) expected \(trailing) tree=\(detail)"
        )
        #expect(
            abs((ordered[ordered.count - 1].maxX - ordered[0].minX) - rowWidth) <= actionSurfaceTolerance,
            "coverage \(ordered) tree=\(detail)"
        )
        let midY = ordered.map(\.midY)
        #expect(
            (midY.max() ?? 0) - (midY.min() ?? 0) <= actionSurfaceTolerance,
            "row \(ordered) tree=\(detail)"
        )
        if names.count > 1 {
            for index in 1..<ordered.count {
                let gap = ordered[index].minX - ordered[index - 1].maxX
                #expect(
                    abs(gap - spacing) <= actionSurfaceTolerance,
                    "gap \(gap) between \(names[index - 1]) and \(names[index]) tree=\(detail)"
                )
            }
        }
    }

    private static func actionSurfaceFrames<V: View>(in root: V) -> (frames: [String: [CGRect]], tree: String) {
        let hosting = NSHostingView(rootView: root)
        let size = hosting.fittingSize
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        var frames: [String: [CGRect]] = [:]
        var lines: [String] = []
        func walk(_ view: NSView, depth: Int) {
            let rect = hosting.convert(view.bounds, from: view)
            let identifier = view.identifier?.rawValue ?? ""
            lines.append(
                "\(String(repeating: "  ", count: depth))\(type(of: view)) id=\(identifier) host=\(Self.formatRect(rect))"
            )
            if identifier.hasPrefix(SelectionActionSurface.identifierPrefix) {
                let name = String(identifier.dropFirst(SelectionActionSurface.identifierPrefix.count))
                frames[name, default: []].append(rect)
            }
            for child in view.subviews where depth < 16 {
                walk(child, depth: depth + 1)
            }
        }
        walk(hosting, depth: 0)
        return (frames, lines.joined(separator: "\n"))
    }

    private static func formatRect(_ rect: CGRect) -> String {
        String(format: "(%.2f,%.2f %.2fx%.2f)", rect.origin.x, rect.origin.y, rect.size.width, rect.size.height)
    }

    @Test
    func selectionPopoverTransmitsBackdrop() throws {
        let content = SelectionPopoverContent.translated(
            original: "Hello world",
            translation: "你好，世界",
            screenFrame: .zero
        )
        let view = ZStack {
            LinearGradient(
                colors: [.indigo, .blue, .purple, .pink],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            SelectionTranslatePopoverView(
                content: content,
                chrome: SelectionPopoverChrome()
            )
        }
        let image = try Self.renderHostingView(view)
        #expect(image.size.width > 0)
        #expect(image.size.height > 0)
        try Self.writeIfRequested(image, named: "gt-glass-selection-backdrop.png")
    }

    @Test
    func singleGlassCardRendersContent() throws {
        let view = GTSettingsCard {
            Text("截图翻译").font(GTType.sectionTitle)
            Text("保存位置 ~/Pictures/Global Translator 截图")
                .font(GTType.caption)
                .foregroundStyle(GTColor.secondaryText)
        }
        .padding(GTSpacing.medium)
        .frame(width: GTPopoverMetrics.width)
        .background(GTColor.panelBackground)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        #expect(image.size.width > 0)
        #expect(image.size.height > 0)
        try Self.writeIfRequested(image, named: "gt-glass-card.png")
    }

    @Test
    func selectionPopoverWithSavedPathRendersWithMeasuredSize() throws {
        var content = SelectionPopoverContent.translated(
            original: String(repeating: "A long original sentence for sizing. ", count: 4),
            translation: String(repeating: "一段用于尺寸检查的较长译文。", count: 8),
            screenFrame: .zero
        ).asScreenshotResult()
        content.savedImagePath = "/tmp/gt-shots/shot.png"
        let view = SelectionTranslatePopoverView(
            content: content,
            chrome: SelectionPopoverChrome()
        )
        let image = try Self.renderHostingView(view)
        let expected = SelectionTranslatePanelController.contentSize(for: content)
        #expect(image.size.width == expected.width)
        let fittingHeight = NSHostingView(rootView: view).fittingSize.height
        // AppKit/SwiftUI text measurement differs slightly from the explicit
        // estimator; allow a small, documented tolerance rather than only
        // checking that some image exists.
        #expect(abs(fittingHeight - expected.height) <= 12)
        let controller = SelectionTranslatePanelController(
            visibleFramesProvider: { [CGRect(x: 0, y: 0, width: 1440, height: 900)] }
        )
        controller.show(content)
        #expect(controller.panelFrame?.size == expected)
        #expect(content.savedImageHint == "已保存到 /tmp/gt-shots/shot.png")
        try Self.writeIfRequested(image, named: "gt-glass-selection.png")
    }

    private static func renderHostingView<V: View>(_ view: V) throws -> NSImage {
        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        let representation = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: representation)
        let image = NSImage(size: size)
        image.addRepresentation(representation)
        return image
    }

    private static func writeIfRequested(_ image: NSImage, named name: String) throws {
        guard ProcessInfo.processInfo.environment["GT_RENDER_UI"] == "1" else { return }
        let cgImage = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let data = try #require(NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: "/tmp/\(name)"))
    }
}
