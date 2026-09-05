import AppKit
import Foundation
@testable import GlobalTranslatorApp
import GlobalTranslatorCapture
import GlobalTranslatorCore
import GlobalTranslatorEngine
import GlobalTranslatorRuntime
import GlobalTranslatorUI

actor RecordingConfigurationStore: ConfigurationStoring {
    private(set) var saved: [AppConfiguration] = []
    let loadError: Error?
    let configuration: AppConfiguration

    init(loadError: Error? = nil, configuration: AppConfiguration = AppConfiguration()) {
        self.loadError = loadError
        self.configuration = configuration
    }

    func load() async throws -> AppConfiguration {
        if let loadError { throw loadError }
        return configuration
    }

    func save(_ configuration: AppConfiguration) async throws {
        saved.append(configuration)
    }
}

final class RecordingCredentialStore: CredentialStoring, @unchecked Sendable {
    private(set) var value: String?
    private(set) var savedValues: [String] = []

    init(value: String?) { self.value = value }
    func save(apiKey: String) throws { value = apiKey; savedValues.append(apiKey) }
    func read() throws -> String? { value }
    func delete() throws { value = nil }
}

final class StubBackendFactory: TranslationBackendFactory, @unchecked Sendable {
    let health: BackendHealth
    private(set) var healthCredentials: [String] = []

    init(health: BackendHealth) { self.health = health }
    func makeBackend(kind: BackendKind, configuration: AppConfiguration, credentials: any CredentialStoring) throws -> any TranslationBackend {
        StubBackend(kind: kind)
    }
    func healthCheck(kind: BackendKind, configuration: AppConfiguration, credentials: any CredentialStoring) async -> BackendHealth {
        if let value = try? credentials.read() { healthCredentials.append(value) }
        return health
    }
}

actor HealthCheckGate {
    private var started = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var resultWaiters: [CheckedContinuation<BackendHealth, Never>] = []
    private var releasedHealth: BackendHealth?

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startedWaiters.append(continuation)
        }
    }

    func check() async -> BackendHealth {
        started = true
        let waiters = startedWaiters
        startedWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if let releasedHealth { return releasedHealth }
        return await withCheckedContinuation { continuation in
            resultWaiters.append(continuation)
        }
    }

    func release(_ health: BackendHealth) {
        releasedHealth = health
        let waiters = resultWaiters
        resultWaiters.removeAll()
        waiters.forEach { $0.resume(returning: health) }
    }
}

final class GatedBackendFactory: TranslationBackendFactory, @unchecked Sendable {
    let gate: HealthCheckGate

    init(gate: HealthCheckGate = HealthCheckGate()) {
        self.gate = gate
    }

    func makeBackend(
        kind: BackendKind,
        configuration: AppConfiguration,
        credentials: any CredentialStoring
    ) throws -> any TranslationBackend {
        StubBackend(kind: kind)
    }

    func healthCheck(
        kind: BackendKind,
        configuration: AppConfiguration,
        credentials: any CredentialStoring
    ) async -> BackendHealth {
        await gate.check()
    }
}

actor CompletionProbe {
    private(set) var completed = false
    func markCompleted() { completed = true }
}

struct StubBackend: TranslationBackend, Sendable {
    let kind: BackendKind
    func healthCheck() async -> BackendHealth { BackendHealth(status: .healthy, message: "ok") }
    func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        TranslationResult(windowRevision: request.windowRevision, translations: request.items.map { Translation(segmentId: $0.id, simplifiedChineseText: "ok") })
    }
}

final class FakePermissionController: PermissionControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var currentSnapshot: PermissionSnapshot
    private(set) var accessibilityRequestCount = 0
    private(set) var screenCaptureRequestCount = 0
    init(snapshot: PermissionSnapshot) { self.currentSnapshot = snapshot }
    var snapshot: PermissionSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return currentSnapshot
    }
    var privacyURLs: [URL] { [] }
    func requestAccessibilityPermission() -> Bool {
        lock.lock()
        accessibilityRequestCount += 1
        lock.unlock()
        return true
    }
    func requestScreenCapturePermission() -> Bool {
        lock.lock()
        screenCaptureRequestCount += 1
        lock.unlock()
        return true
    }
    func update(_ snapshot: PermissionSnapshot) {
        lock.lock()
        currentSnapshot = snapshot
        lock.unlock()
    }
}

@MainActor
final class FakeWindowMonitor: ActiveWindowMonitoring {
    var current: ActiveWindowDescriptor?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    var callback: ActiveWindowCallback?
    func setCallback(_ callback: @escaping ActiveWindowCallback) { self.callback = callback }
    func start() { startCount += 1 }
    func stop() { stopCount += 1 }
    func emit(_ descriptor: ActiveWindowDescriptor?) { callback?(descriptor) }
}

struct FakeCapturePipeline: CapturePipelining, Sendable {
    func capture(_ descriptor: ActiveWindowDescriptor) async throws -> CaptureSnapshot {
        CaptureSnapshot(window: CapturedWindow(descriptor: descriptor, regions: [], source: .accessibility))
    }
}

struct FailingCapturePipeline: CapturePipelining, Sendable {
    func capture(_ descriptor: ActiveWindowDescriptor) async throws -> CaptureSnapshot {
        throw NSError(domain: "capture", code: 1, userInfo: [NSLocalizedDescriptionKey: "secret source text"])
    }
}

struct CaptureErrorPipeline: CapturePipelining, Sendable {
    let error: CaptureError

    func capture(_ descriptor: ActiveWindowDescriptor) async throws -> CaptureSnapshot {
        throw error
    }
}

struct SingleRegionCapturePipeline: CapturePipelining, Sendable {
    func capture(_ descriptor: ActiveWindowDescriptor) async throws -> CaptureSnapshot {
        let region = TextRegion(
            id: UUID(),
            sourceText: "hello",
            screenFrame: CGRect(x: 20, y: 20, width: 80, height: 20),
            confidence: 1,
            source: .accessibility,
            windowRevision: descriptor.revision
        )
        return CaptureSnapshot(window: CapturedWindow(
            descriptor: descriptor,
            regions: [region],
            source: .accessibility
        ))
    }
}

actor StaleFailureCapturePipeline: CapturePipelining {
    private var firstCaptureStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var failureContinuation: CheckedContinuation<Void, Never>?

    func waitUntilFirstCaptureStarts() async {
        if firstCaptureStarted { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releaseFirstFailure() {
        failureContinuation?.resume()
        failureContinuation = nil
    }

    func capture(_ descriptor: ActiveWindowDescriptor) async throws -> CaptureSnapshot {
        if descriptor.revision == 1 {
            firstCaptureStarted = true
            let waiters = startWaiters
            startWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                failureContinuation = continuation
            }
            throw CaptureError.captureFailed
        }
        return CaptureSnapshot(window: CapturedWindow(descriptor: descriptor, regions: [], source: .accessibility))
    }
}

final class EngineEventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var sink: EngineEventSink?

    func set(_ sink: EngineEventSink?) {
        lock.lock()
        self.sink = sink
        lock.unlock()
    }

    func emit(_ event: EngineEvent) {
        lock.lock()
        let sink = self.sink
        lock.unlock()
        sink?(event)
    }
}

@MainActor
final class SchedulerBox {
    var value: FakeScheduler?
    func emit(_ output: EngineOutput) { value?.emit(output) }
}

@MainActor
final class FakeStatusItem: StatusItemControlling {
    private(set) var statuses: [MenuBarStatus] = []
    private(set) var stopCount = 0
    func applyStatus(_ status: MenuBarStatus) { statuses.append(status) }
    func stop() { stopCount += 1 }
}

@MainActor
final class FakeOverlay: OverlayControlling {
    private(set) var hideCount = 0
    private(set) var lastTranslations: [RenderedTranslation] = []
    private(set) var lastRevision: UInt64 = 0
    func update(translations: [RenderedTranslation], revision: UInt64) {
        lastTranslations = translations
        lastRevision = revision
    }
    func hideAll() { hideCount += 1 }
}

actor FakeCoordinator: TranslationCoordinating {
    private(set) var selectedKinds: [BackendKind] = []
    func selectBackend(kind: BackendKind, modelIdentifier: String) async { selectedKinds.append(kind) }
    func clearCache() async {}
    func translate(snapshot: CaptureSnapshot, backend: BackendKind, modelIdentifier: String, visionFallbackEnabled: Bool) async throws -> EngineOutput {
        EngineOutput(windowRevision: snapshot.descriptor.revision, translations: [], metrics: EngineMetrics(inputRegionCount: 0, eligibleRegionCount: 0, cacheHitCount: 0, batchCount: 0, translatedRegionCount: 0, durationMilliseconds: 0, status: .cacheOnly))
    }
}

@MainActor
final class FakeScheduler: TranslationScheduling {
    let output: @MainActor @Sendable (EngineOutput) -> Void
    let state: @MainActor @Sendable (EngineState) -> Void
    private(set) var submitCount = 0
    private(set) var cancelCount = 0

    init(
        output: @escaping @MainActor @Sendable (EngineOutput) -> Void,
        state: @escaping @MainActor @Sendable (EngineState) -> Void
    ) {
        self.output = output
        self.state = state
    }

    convenience init() {
        self.init(output: { _ in }, state: { _ in })
    }

    func submit(snapshot: CaptureSnapshot, backend: BackendKind, modelIdentifier: String, visionFallbackEnabled: Bool) {
        submitCount += 1
    }
    func cancel() { cancelCount += 1 }
    func emit(_ output: EngineOutput) { self.output(output) }
}

final class RecordingLogger: AppRuntimeLogger, @unchecked Sendable {
    private(set) var records: [(String, [String: String])] = []
    func event(_ code: String, fields: [String: String]) { records.append((code, fields)) }
}

@MainActor
final class FakeRuntimeWorker: ApplicationRuntimeWorker {
    private(set) var events: [String] = []
    var isRunning = false
    func start() throws { events.append("start"); isRunning = true }
    func stop() { events.append("stop"); isRunning = false }
}

@MainActor
final class RunnerEventRecorder {
    var events: [String] = []
}

@MainActor
final class FakeApplicationController: ApplicationControlling {
    private(set) var events: [String] = []
    private let recorder: RunnerEventRecorder?
    init(recorder: RunnerEventRecorder? = nil) { self.recorder = recorder }
    func start() async throws {
        events.append("start")
        recorder?.events.append("controller-start")
    }
    func stop() async { events.append("stop") }
}

@MainActor
final class FakeEventLoop: ApplicationEventLoop {
    let onRun: () -> Void
    private let recorder: RunnerEventRecorder?
    private(set) var prepareCount = 0
    private(set) var runCount = 0
    private(set) var stopCount = 0
    init(onRun: @escaping () -> Void, recorder: RunnerEventRecorder? = nil) {
        self.onRun = onRun
        self.recorder = recorder
    }
    func prepare() { prepareCount += 1 }
    func run(onStarted: @escaping @MainActor @Sendable () -> Void) async {
        runCount += 1
        recorder?.events.append("event-loop-run")
        onStarted()
        onRun()
        stop()
    }
    func stop() { stopCount += 1 }
}

@MainActor
final class FakeNSApplicationDriver: NSApplicationDriving {
    private(set) var runCount = 0
    private(set) var stopCount = 0
    private(set) var postedEvents: [NSEvent] = []
    private(set) var finishLaunchingCount = 0
    private(set) var nextEventCount = 0
    private(set) var updateWindowsCount = 0
    var onNextEvent: (() -> Void)?

    func run() { runCount += 1 }
    func finishLaunching() { finishLaunchingCount += 1 }
    func nextEvent(
        matching mask: NSEvent.EventTypeMask,
        until expiration: Date?,
        inMode mode: RunLoop.Mode,
        dequeue deqFlag: Bool
    ) -> NSEvent? {
        nextEventCount += 1
        onNextEvent?()
        return nil
    }
    func sendEvent(_ event: NSEvent) {}
    func updateWindows() { updateWindowsCount += 1 }
    func stop(_ sender: Any?) { stopCount += 1 }
    func postEvent(_ event: NSEvent, atStart flag: Bool) { postedEvents.append(event) }
}
