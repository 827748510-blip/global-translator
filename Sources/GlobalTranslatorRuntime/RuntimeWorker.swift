import Darwin
import Foundation

public protocol RuntimeWorkerHook: Sendable {
    func workerDidStart()
    func workerWillStop()
}

public struct NoopRuntimeWorkerHook: RuntimeWorkerHook, Sendable {
    public init() {}

    public func workerDidStart() {}
    public func workerWillStop() {}
}

public final class RuntimeWorker: @unchecked Sendable {
    public let paths: RuntimePaths

    private let hook: any RuntimeWorkerHook
    private let logger: RuntimeLogger
    private let pidLock: PIDFileLock
    private lazy var server: UnixControlServer = UnixControlServer(socketURL: paths.socketURL) { [weak self] request in
        self?.handle(request) ?? ControlResponse(running: false, state: .stopped)
    }
    private let stateLock = NSLock()
    private var state: RuntimeState = .stopped
    private var signalSources: [DispatchSourceSignal] = []
    private var stopped = DispatchSemaphore(value: 0)

    public init(paths: RuntimePaths, hook: any RuntimeWorkerHook = NoopRuntimeWorkerHook()) throws {
        self.paths = paths
        self.hook = hook
        try paths.prepareDirectories()
        self.logger = try RuntimeLogger(url: paths.logURL)
        self.pidLock = PIDFileLock(url: paths.pidURL)
    }

    deinit {
        stop()
    }

    public func start() throws {
        stateLock.lock()
        guard state == .stopped else {
            let currentPID = pidLock.pid
            stateLock.unlock()
            throw RuntimeError.lockUnavailable(pid: currentPID)
        }
        state = .starting
        stateLock.unlock()

        let acquired = try pidLock.acquire()
        guard acquired else {
            stateLock.lock()
            state = .stopped
            stateLock.unlock()
            throw RuntimeError.lockUnavailable(pid: PIDFileLock.readPID(from: paths.pidURL))
        }

        stateLock.lock()
        let shouldContinue = state == .starting
        stateLock.unlock()
        guard shouldContinue else {
            pidLock.release()
            stateLock.lock()
            state = .stopped
            stateLock.unlock()
            return
        }

        do {
            try server.start()
            stateLock.lock()
            state = .running
            stateLock.unlock()
            installSignalHandlers()
            logger.log("runtime worker started", event: "worker_started")
            hook.workerDidStart()
        } catch {
            pidLock.release()
            stateLock.lock()
            state = .stopped
            stateLock.unlock()
            throw error
        }
    }

    public func run() throws {
        try start()
        while isRunning {
            _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.2))
        }
    }

    public func runUntilStopped() throws {
        try run()
    }

    @discardableResult
    public func waitUntilStopped(timeout: TimeInterval = 1.0) -> Bool {
        stopped.wait(timeout: .now() + max(timeout, 0)) == .success
    }

    public func stop() {
        stateLock.lock()
        guard state == .starting || state == .running else {
            stateLock.unlock()
            return
        }
        state = .stopping
        let sources = signalSources
        signalSources.removeAll()
        stateLock.unlock()

        for source in sources {
            source.cancel()
        }
        server.stop()
        hook.workerWillStop()
        logger.log("runtime worker stopped", event: "worker_stopped")
        pidLock.release()
        stateLock.lock()
        state = .stopped
        stateLock.unlock()
        stopped.signal()
    }

    public var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return state != .stopped
    }

    public var currentState: RuntimeState {
        stateLock.lock()
        defer { stateLock.unlock() }
        return state
    }

    public var statusResponse: ControlResponse {
        stateLock.lock()
        let currentState = state
        stateLock.unlock()
        let currentPID = pidLock.pid ?? 0
        return ControlResponse(
            running: currentState != .stopped,
            state: currentState,
            pid: currentPID
        )
    }

    private func handle(_ request: ControlRequest) -> ControlResponse {
        switch request.action {
        case .status:
            return statusResponse
        case .stop:
            let response = ControlResponse(running: true, state: .stopping, pid: pidLock.pid ?? 0)
            DispatchQueue.global(qos: .utility).async { [weak self] in
                self?.stop()
            }
            return response
        }
    }

    private func installSignalHandlers() {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let queue = DispatchQueue(label: "GlobalTranslatorRuntime.signals")
        for signalNumber in [SIGINT, SIGTERM] {
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: queue)
            source.setEventHandler { [weak self] in
                self?.stop()
            }
            source.resume()
            stateLock.lock()
            signalSources.append(source)
            stateLock.unlock()
        }
    }
}
