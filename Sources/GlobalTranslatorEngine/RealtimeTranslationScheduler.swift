import Foundation
import GlobalTranslatorCapture
import GlobalTranslatorCore

@MainActor
public final class RealtimeTranslationScheduler {
    public typealias OutputHandler = @MainActor @Sendable (EngineOutput) -> Void
    public typealias StateHandler = @MainActor @Sendable (EngineState) -> Void

    public let debounceInterval: TimeInterval
    public let maximumFrequency: Double

    private let coordinator: TranslationCoordinator
    private let clock: any MonotonicClock
    private let sleeper: any TranslationSleeper
    private let outputHandler: OutputHandler
    private let stateHandler: StateHandler?
    private var pendingTask: Task<Void, Never>?
    private var submissionToken: UInt64 = 0
    private var lastDispatchAt: TimeInterval?

    public init(
        coordinator: TranslationCoordinator,
        debounceInterval: TimeInterval = 0.12,
        maximumFrequency: Double = 4,
        clock: any MonotonicClock = SystemMonotonicClock(),
        sleeper: any TranslationSleeper = TaskTranslationSleeper(),
        outputHandler: @escaping OutputHandler,
        stateHandler: StateHandler? = nil
    ) {
        self.coordinator = coordinator
        self.debounceInterval = max(0, debounceInterval)
        self.maximumFrequency = max(0.001, maximumFrequency)
        self.clock = clock
        self.sleeper = sleeper
        self.outputHandler = outputHandler
        self.stateHandler = stateHandler
    }

    deinit {
        pendingTask?.cancel()
    }

    public func submit(
        snapshot: CaptureSnapshot,
        backend: BackendKind,
        modelIdentifier: String,
        visionFallbackEnabled: Bool
    ) {
        pendingTask?.cancel()
        submissionToken &+= 1
        let token = submissionToken
        let revision = snapshot.descriptor.revision
        let coordinator = self.coordinator
        let sleeper = self.sleeper
        let clock = self.clock
        let debounceInterval = self.debounceInterval
        let minimumInterval = 1 / maximumFrequency
        let outputHandler = self.outputHandler
        let stateHandler = self.stateHandler
        coordinator.invalidate(revision: revision)
        let task = Task { @MainActor [weak self] in
            do {
                try await sleeper.sleep(for: debounceInterval)
                guard let self, self.submissionToken == token, !Task.isCancelled else { return }
                if let lastDispatchAt = self.lastDispatchAt {
                    let elapsed = clock.now() - lastDispatchAt
                    if elapsed < minimumInterval {
                        try await sleeper.sleep(for: minimumInterval - elapsed)
                        guard self.submissionToken == token, !Task.isCancelled else { return }
                    }
                }
                self.lastDispatchAt = clock.now()
                let output = try await coordinator.translate(
                    snapshot: snapshot,
                    backend: backend,
                    modelIdentifier: modelIdentifier,
                    visionFallbackEnabled: visionFallbackEnabled
                )
                guard self.submissionToken == token, !Task.isCancelled else { return }
                outputHandler(output)
                stateHandler?(await coordinator.state)
            } catch is CancellationError {
            } catch let error as TranslationCoordinatorError {
                guard let self else { return }
                guard self.submissionToken == token, !Task.isCancelled else { return }
                let state: EngineState
                switch error {
                case .circuitOpen:
                    state = .circuitOpen
                case .backendNotConfigured, .invalidModel, .visionUnavailable:
                    state = .backendError
                case .staleRevision:
                    return
                }
                stateHandler?(state)
            } catch {
                guard let self else { return }
                guard self.submissionToken == token, !Task.isCancelled else { return }
                let currentState = await coordinator.state
                stateHandler?(currentState == .off ? .backendError : currentState)
            }
        }
        pendingTask = task
    }

    public func cancel() {
        pendingTask?.cancel()
        pendingTask = nil
        submissionToken &+= 1
    }
}
