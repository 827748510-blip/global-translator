import AppKit
import Foundation
import GlobalTranslatorCapture
import GlobalTranslatorCore
import GlobalTranslatorEngine
import GlobalTranslatorRuntime
import GlobalTranslatorUI

@MainActor
extension ApplicationControllerComponents {
    public static func production(paths: RuntimePaths) -> ApplicationControllerComponents {
        let logger: any AppRuntimeLogger
        if let runtimeLogger = try? RuntimeLogger(url: paths.logURL) {
            logger = RuntimeLoggerAdapter(logger: runtimeLogger)
        } else {
            logger = NullAppRuntimeLogger()
        }
        let permissions = SystemPermissionController()
        let clipboardCoordinator = ClipboardBorrowCoordinator.shared
        return ApplicationControllerComponents(
            configurationStore: ConfigStore(url: paths.configURL),
            credentialStore: MacOSKeychainStore(),
            permissionController: permissions,
            backendFactory: LiveTranslationBackendFactory(
                localTransport: URLSessionHTTPTransport(requestTimeout: 90, resourceTimeout: 180)
            ),
            ollamaLifecycle: HomebrewOllamaLifecycle(),
            monitorFactory: { allowed in
                ActiveWindowMonitorAdapter(
                    ownBundleIdentifier: Bundle.main.bundleIdentifier,
                    translatedBundleIdentifiers: allowed
                )
            },
            capturePipelineFactory: { allowed in
                CapturePipeline(
                    translatedBundleIdentifiers: allowed,
                    permissions: permissions,
                    accessibility: AccessibilityTextCollector(translatedBundleIdentifiers: allowed),
                    screenshot: ScreenCaptureKitWindowCapturer(),
                    ocr: VisionOCRService(),
                    ownBundleIdentifier: Bundle.main.bundleIdentifier
                )
            },
            statusItemFactory: { viewModel in StatusItemController(viewModel: viewModel) },
            overlayFactory: { OverlayPanelController() },
            selectedTextReaderFactory: {
                AXSelectedTextReader(
                    clipboard: RestoringClipboardSelectionFallback(
                        permissions: permissions,
                        coordinator: clipboardCoordinator
                    ),
                    permissions: permissions
                )
            },
            selectionPopoverFactory: {
                SelectionTranslatePanelController(clipboardCoordinator: clipboardCoordinator)
            },
            selectionPointerMonitorFactory: { SystemSelectionPointerMonitor() },
            regionSelectorFactory: { RegionSelectionOverlayController() },
            regionCapturerFactory: { ScreenCaptureKitRegionCapturer(permissions: permissions) },
            regionOCRFactory: { RegionVisionOCRService() },
            hotkeyRegistrarFactory: { CarbonHotkeyRegistrar() },
            screenshotPopoverFactory: {
                SelectionTranslatePanelController(clipboardCoordinator: clipboardCoordinator)
            },
            coordinatorFactory: { backends, eventSink in
                TranslationCoordinator(backends: backends, eventSink: eventSink)
            },
            schedulerFactory: { coordinator, output, state in
                guard let concrete = coordinator as? TranslationCoordinator else {
                    return NoopTranslationScheduler()
                }
                return RealtimeTranslationScheduler(
                    coordinator: concrete,
                    debounceInterval: 0,
                    outputHandler: output,
                    stateHandler: state
                )
            },
            logger: logger,
            inPageFactory: { CDPInPageTranslator() }
        )
    }
}
