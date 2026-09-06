import AppKit
import Foundation
import GlobalTranslatorRuntime

@MainActor
public final class GlobalTranslatorApplicationRunner: NSObject {
    public let worker: ApplicationRuntimeWorker
    public let controller: ApplicationControlling
    public let eventLoop: ApplicationEventLoop

    private var stopTimer: Timer?
    private var controllerStartupTask: Task<Void, Error>?

    public init(
        worker: ApplicationRuntimeWorker,
        controller: ApplicationControlling,
        eventLoop: ApplicationEventLoop
    ) {
        self.worker = worker
        self.controller = controller
        self.eventLoop = eventLoop
        super.init()
    }

    public func run() async throws {
        do {
            eventLoop.prepare()
            try worker.start()
        } catch {
            await controller.stop()
            worker.stop()
            throw error
        }

        let timer = Timer(
            timeInterval: 0.1,
            target: self,
            selector: #selector(pollWorkerState),
            userInfo: nil,
            repeats: true
        )
        stopTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        defer {
            stopTimer?.invalidate()
            stopTimer = nil
        }

        await eventLoop.run { [weak self] in
            guard let self else { return }
            self.controllerStartupTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await self.controller.start()
                } catch {
                    if self.worker.isRunning { self.worker.stop() }
                    self.eventLoop.stop()
                    throw error
                }
            }
        }
        stopTimer?.invalidate()
        stopTimer = nil
        if let controllerStartupTask {
            do {
                try await controllerStartupTask.value
            } catch {
                self.controllerStartupTask = nil
                await controller.stop()
                if worker.isRunning { worker.stop() }
                throw error
            }
        }
        controllerStartupTask = nil
        await controller.stop()
        if worker.isRunning { worker.stop() }
    }

    @objc
    private func pollWorkerState() {
        guard !worker.isRunning else { return }
        eventLoop.stop()
    }
}

@MainActor
public final class GlobalTranslatorApplication {
    public static func run(paths: RuntimePaths, mode: RunMode) async throws {
        _ = mode
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let eventLoop = NSApplicationEventLoop(application: application)
        let hook = MainThreadStopHook {
            eventLoop.stop()
        }
        let worker = try RuntimeWorker(paths: paths, hook: hook)
        let controller = ApplicationController(
            paths: paths,
            onQuit: {
                worker.stop()
                eventLoop.stop()
            }
        )
        let runner = GlobalTranslatorApplicationRunner(
            worker: RuntimeWorkerAdapter(worker: worker),
            controller: controller,
            eventLoop: eventLoop
        )
        try await runner.run()
    }
}

private final class MainThreadStopHook: RuntimeWorkerHook, @unchecked Sendable {
    private let callback: @MainActor @Sendable () -> Void

    init(callback: @escaping @MainActor @Sendable () -> Void) {
        self.callback = callback
    }

    func workerDidStart() {}

    func workerWillStop() {
        Task { @MainActor in
            callback()
        }
    }
}
