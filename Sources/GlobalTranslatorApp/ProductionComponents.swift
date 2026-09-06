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
        return ApplicationControllerComponents(
            configurationStore: ConfigStore(url: paths.configURL),
            credentialStore: MacOSKeychainStore(),
            permissionController: SystemPermissionController(),
            backendFactory: LiveTranslationBackendFactory(),
            monitorFactory: { excluded in
                ActiveWindowMonitorAdapter(
                    ownBundleIdentifier: Bundle.main.bundleIdentifier,
                    excludedBundleIdentifiers: excluded
                )
            },
            capturePipelineFactory: { excluded in
                CapturePipeline(
                    ownBundleIdentifier: Bundle.main.bundleIdentifier,
                    excludedBundleIdentifiers: excluded
                )
            },
            statusItemFactory: { viewModel in StatusItemController(viewModel: viewModel) },
            overlayFactory: { OverlayPanelController() },
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
            logger: logger
        )
    }
}
