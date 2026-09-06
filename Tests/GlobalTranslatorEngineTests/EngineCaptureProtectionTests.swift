import Foundation
import Testing
import GlobalTranslatorCapture
import GlobalTranslatorCore
import GlobalTranslatorEngine

struct EngineCaptureProtectionTests {
    @Test(arguments: [CaptureSource.accessibility, .visionOCR])
    func protectedSnapshotNeverReachesTextOrVisionBackend(source: CaptureSource) async throws {
        let backend = VisionRecordingBackend(kind: .deepSeekCloud)
        let permissions = SystemPermissionController(snapshotProvider: {
            PermissionSnapshot(accessibilityTrusted: true, screenCaptureAuthorized: true, secureInputEnabled: true, sessionLocked: false)
        })
        let coordinator = TranslationCoordinator(backends: [backend], permissions: permissions)
        let snapshot = makeSnapshot(regions: [makeRegion(text: "Private sample", confidence: 0.3)], revision: 1, source: source, image: makeEngineTestImage())

        await #expect(throws: CaptureError.protected(.secureInput)) {
            _ = try await coordinator.translate(snapshot: snapshot, backend: .deepSeekCloud, modelIdentifier: "test", visionFallbackEnabled: true)
        }
        #expect(await backend.textRequestCount == 0)
        #expect(await backend.visionRequests.isEmpty)
    }

    @Test(arguments: [true, false])
    func protectionChangingAfterFirstBatchStopsRemainingRequests(secureInput: Bool) async throws {
        let state = EngineReadinessPermissions()
        let backend = RecordingBackend(kind: .local) { request, _ in
            state.set(PermissionSnapshot(accessibilityTrusted: true, screenCaptureAuthorized: true, secureInputEnabled: secureInput, sessionLocked: !secureInput))
            return TranslationResult(windowRevision: request.windowRevision, translations: request.items.map {
                Translation(segmentId: $0.id, simplifiedChineseText: "样例")
            })
        }
        let coordinator = TranslationCoordinator(backends: [backend], permissions: SystemPermissionController(snapshotProvider: { state.snapshot }))
        let snapshot = makeSnapshot(regions: (0..<7).map { makeRegion(text: "Sentence \($0)", y: CGFloat($0 * 30)) }, revision: 1)

        await #expect(throws: CaptureError.protected(secureInput ? .secureInput : .sessionLocked)) {
            _ = try await coordinator.translate(snapshot: snapshot, backend: .local, modelIdentifier: "test", visionFallbackEnabled: false)
        }
        #expect(await backend.requests.count == 1)
        #expect(await coordinator.state == .listening)
    }

    @Test
    func revokedSourcePermissionPreventsModelRequestEvenIfOtherPermissionRemains() async {
        let backend = VisionRecordingBackend(kind: .local)
        let permissions = SystemPermissionController(snapshotProvider: {
            PermissionSnapshot(accessibilityTrusted: false, screenCaptureAuthorized: true, secureInputEnabled: false, sessionLocked: false)
        })
        let coordinator = TranslationCoordinator(backends: [backend], permissions: permissions)
        let snapshot = makeSnapshot(regions: [makeRegion(text: "Private sample")], revision: 1)
        await #expect(throws: CaptureError.permissionRequired(.accessibility)) {
            _ = try await coordinator.translate(snapshot: snapshot, backend: .local, modelIdentifier: "test", visionFallbackEnabled: false)
        }
        #expect(await backend.textRequestCount == 0)
        #expect(await coordinator.state == .missingPermission)
    }
}

private final class EngineReadinessPermissions: @unchecked Sendable {
    private let lock = NSLock()
    private var value = PermissionSnapshot.allGranted
    var snapshot: PermissionSnapshot { lock.withLock { value } }
    func set(_ snapshot: PermissionSnapshot) { lock.withLock { value = snapshot } }
}
