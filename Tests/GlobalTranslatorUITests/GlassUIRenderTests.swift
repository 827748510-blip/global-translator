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
            maxHeight: 720
        )
        .modifier(GTSettingsPanelChrome(cornerRadius: GTRadius.card))
        .colorScheme(.dark)
        let image = try Self.renderHostingView(view, appearance: .darkAqua)
        #expect(image.size.width > 0)
        #expect(image.size.height > 0)
        try Self.writeIfRequested(image, named: "gt-glass-settings-dark.png")
    }

    @Test
    func deepSeekStatsSectionRendersLiveTotalsInsideSettingsWidth() throws {
        let store = DeepSeekUsageStore()
        store.record(
            usage: DeepSeekTokenUsage(inputTokens: 1_200, cachedInputTokens: 900, outputTokens: 300),
            model: AppConfiguration.defaultDeepSeekModel,
            durationSeconds: 2,
            requestedAt: Date(timeIntervalSince1970: 1_760_000_000)
        )
        let view = VStack(alignment: .leading) {
            DeepSeekStatsSection(store: store)
        }
        .padding(GTControlMetrics.cardHorizontalPadding)
        .frame(width: GTPopoverMetrics.width)
        .background(GTColor.panelBackground)
        let image = try Self.renderHostingView(view)
        #expect(image.size.width == GTPopoverMetrics.width)
        #expect(image.size.height > 0)
        try Self.writeIfRequested(image, named: "gt-deepseek-stats.png")
    }

    @Test
    func overlayPatchCoversSourceTextWithoutReadingAsAPopup() throws {
        let view = ZStack(alignment: .topLeading) {
            Color(red: 0.08, green: 0.08, blue: 0.10)
            Text("Ask anything, @ mention, or run actions")
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .padding(.leading, 6)
                .padding(.top, 4)
            OverlayView(text: "询问任何内容，@ 提及，或执行操作")
                .frame(width: 320, height: 26)
        }
        .frame(width: 336, height: 64)
        let image = try Self.renderHostingView(view)
        #expect(image.size.width == 336)
        #expect(image.size.height == 64)
        try Self.writeIfRequested(image, named: "gt-overlay-patch.png")
    }

    @Test
    func cloudBackendSectionRendersInlineStatsWithoutVisionToggle() throws {
        let viewModel = SettingsViewModel(actions: RenderActions())
        viewModel.keyConfigured = true
        viewModel.availableModels = [AppConfiguration.defaultDeepSeekModel]
        viewModel.deepSeekModel = AppConfiguration.defaultDeepSeekModel
        viewModel.connectionTest = .healthy("DeepSeek 后端已就绪")
        let view = CloudBackendSection(viewModel: viewModel)
            .padding(GTControlMetrics.cardHorizontalPadding)
            .frame(width: GTPopoverMetrics.width)
            .background(GTColor.panelBackground)
        let image = try Self.renderHostingView(view)
        #expect(image.size.width == GTPopoverMetrics.width)
        #expect(image.size.height > 0)
        try Self.writeIfRequested(image, named: "gt-cloud-backend-inline-stats.png")
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
            names: ["copyOriginal", "copy"],
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

    /// 07：保存路径提示曾按 `textBlockSpacing` 少算 8pt，并且只允许 2 行，
    /// 长路径会被切掉。这里用真实的 SwiftUI 排版高度和测量结果对照。
    @Test
    func selectionPopoverWithLongSavedPathIsNotClipped() throws {
        var content = SelectionPopoverContent.translated(
            original: "A saved screenshot",
            translation: "一段用于尺寸检查的译文。",
            screenFrame: .zero
        ).asScreenshotResult()
        content.savedImagePath = "/Volumes/ExternalSSD/交付/"
            + String(repeating: "设计评审与最终交付/", count: 4)
            + "截图翻译-20261110-113600-abcd.png"
        let view = SelectionTranslatePopoverView(
            content: content,
            chrome: SelectionPopoverChrome()
        )
        let expected = SelectionTranslatePanelController.contentSize(for: content)
        let fittingHeight = NSHostingView(rootView: view).fittingSize.height
        #expect(abs(fittingHeight - expected.height) <= 12)

        // 折行后的提示确实占到了多行：与单行路径相比高出两行以上。
        var shortContent = content
        shortContent.savedImagePath = "/tmp/a.png"
        let shortHeight = SelectionTranslatePanelController.contentSize(for: shortContent).height
        #expect(expected.height - shortHeight >= 20)

        // 保存路径 + 剪贴板提示同时存在时，两条都要计入高度。
        content.clipboardHint = SelectionTranslateSupport.clipboardImageKeptCopy
        let twoHintHeight = SelectionTranslatePanelController.contentSize(for: content).height
        #expect(twoHintHeight > expected.height)
        let twoHintFitting = NSHostingView(
            rootView: SelectionTranslatePopoverView(content: content, chrome: SelectionPopoverChrome())
        ).fittingSize.height
        #expect(abs(twoHintFitting - twoHintHeight) <= 12)
    }

    @Test(arguments: SettingsTab.allCases)
    func allThreeSettingsTabsRenderInLightAndDarkAppearances(tab: SettingsTab) throws {
        let viewModel = SettingsViewModel(actions: RenderActions())
        viewModel.selectedTab = tab
        for scheme in [ColorScheme.light, .dark] {
            let view = SettingsPopoverView(viewModel: viewModel, maxHeight: 720)
                .modifier(GTSettingsPanelChrome(cornerRadius: GTRadius.card))
                .colorScheme(scheme)
            let image = try Self.renderHostingView(
                view,
                appearance: scheme == .dark ? .darkAqua : .aqua
            )
            #expect(image.size.width == GTPopoverMetrics.width)
            #expect(image.size.height > 0)
        }
    }

    @Test
    func settingsTopTabBarStaysCompactInsideTallPopover() throws {
        let viewModel = SettingsViewModel(actions: RenderActions())
        viewModel.permissionSnapshot = .allGranted
        viewModel.backendReady = true
        viewModel.isAutomaticTranslationEnabled = true
        viewModel.translatedApplications = [
            TranslatedApplication(bundleIdentifier: "com.google.Chrome", displayName: "Google Chrome")
        ]
        let view = SettingsPopoverView(viewModel: viewModel, maxHeight: 720)
            .modifier(GTSettingsPanelChrome(cornerRadius: GTRadius.card))
        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()

        let frames = Self.collectSurfaceFrames(in: hosting, prefix: SegmentPickerSurface.identifierPrefix)
        let tabFrames = try #require(frames["设置分区"])
        #expect(tabFrames.count == 1)
        let tabHeight = tabFrames[0].height
        #expect(tabHeight >= 28 && tabHeight <= 42, "Unexpected tab picker height: \(tabHeight)")
    }

    @Test
    func translatedApplicationsSectionDoesNotClipSingleApp() {
        let viewModel = SettingsViewModel(actions: RenderActions())
        viewModel.translatedApplications = [
            TranslatedApplication(bundleIdentifier: "com.google.Chrome", displayName: "Google Chrome")
        ]
        let view = TranslatedApplicationsSection(viewModel: viewModel)
            .padding(GTControlMetrics.cardHorizontalPadding)
            .frame(width: GTPopoverMetrics.width)
        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()

        #expect(!Self.containsScrollView(hosting), "Single app list must not wrap in nested ScrollView")
        #expect(size.height >= 120)
    }

    @Test
    func allScreensRenderLightAndDarkForVisualVerification() throws {
        let transVM = SettingsViewModel(actions: RenderActions())
        transVM.selectedTab = .translation
        transVM.selectedBackend = .local
        transVM.localBaseURL = "http://127.0.0.1:11434/v1"
        transVM.localModel = "qwen3.5:9b"
        transVM.status = .listening
        transVM.isAutomaticTranslationEnabled = true
        transVM.backendReady = true
        transVM.healthMessage = "本地后端已就绪"
        transVM.permissionSnapshot = .allGranted
        transVM.translatedApplications = [
            TranslatedApplication(bundleIdentifier: "com.google.Chrome", displayName: "Google Chrome")
        ]

        let cloudVM = SettingsViewModel(actions: RenderActions())
        cloudVM.selectedTab = .backend
        cloudVM.selectedBackend = .deepSeekCloud
        cloudVM.keyConfigured = true
        cloudVM.availableModels = [AppConfiguration.defaultDeepSeekModel, "deepseek-reasoner"]
        cloudVM.deepSeekModel = AppConfiguration.defaultDeepSeekModel
        cloudVM.backendReady = true
        cloudVM.connectionTest = .healthy("DeepSeek 后端已就绪")
        cloudVM.permissionSnapshot = .allGranted

        let localVM = SettingsViewModel(actions: RenderActions())
        localVM.selectedTab = .backend
        localVM.selectedBackend = .local
        localVM.localBaseURL = "http://127.0.0.1:11434/v1"
        localVM.availableModels = ["qwen3.5:9b"]
        localVM.localModel = "qwen3.5:9b"
        localVM.backendReady = true
        localVM.connectionTest = .healthy("本地模型已就绪")
        localVM.permissionSnapshot = .allGranted

        let advVM = SettingsViewModel(actions: RenderActions())
        advVM.selectedTab = .advanced
        advVM.backendReady = true
        advVM.permissionSnapshot = PermissionSnapshot(
            accessibilityTrusted: true,
            screenCaptureAuthorized: false,
            secureInputEnabled: false,
            sessionLocked: false
        )

        let tabCases: [(String, SettingsViewModel)] = [
            ("gt-tab-translation", transVM),
            ("gt-tab-backend-cloud", cloudVM),
            ("gt-tab-backend-local", localVM),
            ("gt-tab-advanced", advVM)
        ]

        for (prefix, vm) in tabCases {
            for (suffix, scheme, appearance) in [
                ("light", ColorScheme.light, NSAppearance.Name.aqua),
                ("dark", ColorScheme.dark, NSAppearance.Name.darkAqua)
            ] {
                let panel = SettingsPopoverView(viewModel: vm, maxHeight: 780)
                    .modifier(GTSettingsPanelChrome(cornerRadius: GTRadius.card))
                let canvas = Self.wallpaperPreviewCanvas(scheme: scheme) { panel }
                    .colorScheme(scheme)
                let image = try Self.renderHostingView(canvas, appearance: appearance)
                #expect(image.size.width > 0 && image.size.height > 0)
                try Self.writeVerifyIfRequested(image, named: "\(prefix)-\(suffix).png")
            }
        }

        let selSuccess = SelectionTranslatePopoverView(
            content: .translated(
                original: "Ask anything, or run actions",
                translation: "询问任何问题，或执行操作",
                screenFrame: .zero
            ),
            chrome: SelectionPopoverChrome()
        )
        let selFailed = SelectionTranslatePopoverView(
            content: .failed(
                original: "Ask anything",
                message: "请先开启“辅助功能”权限或配置翻译后端",
                screenFrame: .zero,
                showsOpenSettingsAction: true
            ),
            chrome: SelectionPopoverChrome()
        )
        for (suffix, scheme, appearance) in [
            ("light", ColorScheme.light, NSAppearance.Name.aqua),
            ("dark", ColorScheme.dark, NSAppearance.Name.darkAqua)
        ] {
            let img = try Self.renderHostingView(
                Self.wallpaperPreviewCanvas(scheme: scheme) { selSuccess }.colorScheme(scheme),
                appearance: appearance
            )
            #expect(img.size.width > 0 && img.size.height > 0)
            try Self.writeVerifyIfRequested(img, named: "gt-selection-\(suffix).png")
        }
        let failImg = try Self.renderHostingView(
            Self.wallpaperPreviewCanvas(scheme: .light) { selFailed }.colorScheme(.light),
            appearance: .aqua
        )
        #expect(failImg.size.width > 0 && failImg.size.height > 0)
        try Self.writeVerifyIfRequested(failImg, named: "gt-selection-failed-light.png")
    }

    @Test
    func selectionPopoverControllerReusesSingleHostingViewAcrossUpdates() {
        let controller = SelectionTranslatePanelController(
            visibleFramesProvider: { [CGRect(x: 0, y: 0, width: 1440, height: 900)] }
        )
        controller.show(.loading(original: "Hello", screenFrame: CGRect(x: 100, y: 400, width: 80, height: 20)))
        let firstID = controller.hostingViewObjectIdentifier
        #expect(firstID != nil)

        controller.show(.translated(
            original: "Hello",
            translation: "你好",
            screenFrame: CGRect(x: 100, y: 400, width: 80, height: 20)
        ))
        #expect(controller.hostingViewObjectIdentifier == firstID)

        controller.show(.failed(
            original: "Hello",
            message: "请先配置 API Key",
            screenFrame: CGRect(x: 100, y: 400, width: 80, height: 20),
            showsOpenSettingsAction: true
        ))
        #expect(controller.hostingViewObjectIdentifier == firstID)
        controller.dismiss()
    }

    private static func collectSurfaceFrames(in root: NSView, prefix: String) -> [String: [CGRect]] {
        var frames: [String: [CGRect]] = [:]
        func walk(_ view: NSView, depth: Int) {
            let identifier = view.identifier?.rawValue ?? ""
            if identifier.hasPrefix(prefix) {
                let name = String(identifier.dropFirst(prefix.count))
                frames[name, default: []].append(root.convert(view.bounds, from: view))
            }
            for child in view.subviews where depth < 24 {
                walk(child, depth: depth + 1)
            }
        }
        walk(root, depth: 0)
        return frames
    }

    private static func containsScrollView(_ view: NSView, depth: Int = 0) -> Bool {
        if view is NSScrollView { return true }
        guard depth < 24 else { return false }
        return view.subviews.contains { containsScrollView($0, depth: depth + 1) }
    }

    @ViewBuilder
    private static func wallpaperPreviewCanvas<Content: View>(
        scheme: ColorScheme,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let colors: [Color] = scheme == .dark
            ? [Color(red: 0.10, green: 0.13, blue: 0.22), Color(red: 0.16, green: 0.12, blue: 0.24)]
            : [Color(red: 0.78, green: 0.86, blue: 0.96), Color(red: 0.88, green: 0.83, blue: 0.94)]
        ZStack {
            LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            content()
                .padding(16)
        }
        .fixedSize()
    }

    private static func renderHostingView<V: View>(
        _ view: V,
        appearance: NSAppearance.Name = .aqua
    ) throws -> NSImage {
        let hosting = NSHostingView(rootView: view)
        let nsAppearance = NSAppearance(named: appearance)
        hosting.appearance = nsAppearance
        let size = hosting.fittingSize
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.appearance = nsAppearance
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = hosting
        hosting.frame = CGRect(origin: .zero, size: size)
        var capturedRep: NSBitmapImageRep?
        let renderBlock = {
            hosting.layoutSubtreeIfNeeded()
            if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                hosting.cacheDisplay(in: hosting.bounds, to: rep)
                capturedRep = rep
            }
        }
        if let nsAppearance {
            nsAppearance.performAsCurrentDrawingAppearance(renderBlock)
        } else {
            renderBlock()
        }
        let representation = try #require(capturedRep)
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

    private static func writeVerifyIfRequested(_ image: NSImage, named name: String) throws {
        guard ProcessInfo.processInfo.environment["GT_RENDER_UI"] == "1" else { return }
        let dir = URL(fileURLWithPath: "/tmp/gt-verify", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cgImage = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let data = try #require(NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]))
        try data.write(to: dir.appendingPathComponent(name))
    }
}
