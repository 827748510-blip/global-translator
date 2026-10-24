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
    func quit() {}
}

@MainActor
struct GlassUIRenderTests {
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
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
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

    @Test
    func glassBackgroundHonorsReduceTransparencyFlag() {
        #expect(GTGlassBackground.usesMaterial(reduceTransparency: false))
        #expect(!GTGlassBackground.usesMaterial(reduceTransparency: true))
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
