import Foundation
import Testing
@testable import GlobalTranslatorUI
import GlobalTranslatorEngine
import GlobalTranslatorCapture

@MainActor
private final class StatusItemTestActions: SettingsActions {
    func setAutomaticTranslation(_ enabled: Bool) {}
    func selectBackend(_ kind: BackendKind) {}
    func saveAPIKey(_ draft: String) async throws {}
    func deleteAPIKey() async throws {}
    func testConnection() async throws -> BackendHealth {
        BackendHealth(status: .healthy, message: "ok")
    }
    func setVisionFallback(_ enabled: Bool) {}
    func setLocalConfiguration(baseURL: String, model: String) {}
    func requestPermission(_ kind: PermissionKind) {}
    func openSystemSettings(_ kind: PermissionKind) {}
    func addCurrentAppExclusion() {}
    func removeExclusion(bundleIdentifier: String) {}
    func clearCache() async throws {}
    func openLogs() {}
    func quit() {}
}

struct StatusItemTests {
    @Test @MainActor
    func stoppingControllerIsIdempotentAndReleasesStatusItem() {
        let viewModel = SettingsViewModel(actions: StatusItemTestActions())
        let controller = StatusItemController(viewModel: viewModel)

        #expect(!controller.isStopped)
        controller.stop()
        controller.stop()

        #expect(controller.isStopped)
    }

    @Test @MainActor
    func statusItemUsesStableAutosaveIdentityAndRequestsVisibility() {
        let viewModel = SettingsViewModel(actions: StatusItemTestActions())
        let controller = StatusItemController(viewModel: viewModel)

        #expect(controller.statusItemAutosaveName == "com.maodashu.global-translator.status")
        #expect(controller.requestsStatusItemVisibility)

        controller.stop()
    }

    @Test
    func everyStateMapsToExpectedSFSymbol() {
        #expect(MenuBarStatus.listening.symbolName == "character.bubble")
        #expect(MenuBarStatus.off.symbolName == "pause.circle")
        #expect(MenuBarStatus.translating.symbolName == "ellipsis.bubble")
        #expect(MenuBarStatus.missingPermission.symbolName == "exclamationmark.triangle")
        #expect(MenuBarStatus.error.symbolName == "exclamationmark.triangle")
    }

    @Test
    func everyStateHasDistinctTextualAccessibilityLabel() {
        let labels = MenuBarStatus.allCases.map(\.accessibilityLabel)
        #expect(Set(labels).count == MenuBarStatus.allCases.count)
        for status in MenuBarStatus.allCases {
            #expect(!status.accessibilityLabel.isEmpty)
            #expect(!status.helpText.isEmpty)
        }
        // Error and missing permission share a symbol but never share text:
        // state is never conveyed by symbol/color alone.
        #expect(MenuBarStatus.missingPermission.accessibilityLabel != MenuBarStatus.error.accessibilityLabel)
    }

    @Test
    func engineStateMappingCoversAllEngineStates() {
        #expect(MenuBarStatus(engineState: .off) == .off)
        #expect(MenuBarStatus(engineState: .listening) == .listening)
        #expect(MenuBarStatus(engineState: .translating) == .translating)
        #expect(MenuBarStatus(engineState: .missingPermission) == .missingPermission)
        #expect(MenuBarStatus(engineState: .backendError) == .error)
        #expect(MenuBarStatus(engineState: .circuitOpen) == .error)
    }
}
