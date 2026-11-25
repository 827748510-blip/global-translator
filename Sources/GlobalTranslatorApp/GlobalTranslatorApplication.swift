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
            timeInterval: 0.5,
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
    public static func showLaunchError(_ message: String) {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        application.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "全局翻译未能启动"
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    public static func launchDesktop(paths: RuntimePaths) async throws {
        let manager = RuntimeManager(paths: paths)
        if manager.status().running {
            _ = try manager.showSettings()
            return
        }
        do {
            try await run(paths: paths, mode: .foreground, showSettings: true)
        } catch RuntimeError.lockUnavailable {
            // A simultaneous open won the PID lock. Forward to its controller.
            _ = try manager.showSettings()
        }
    }

    public static func run(paths: RuntimePaths, mode: RunMode, showSettings: Bool = false) async throws {
        _ = mode
        let application = NSApplication.shared
        application.setActivationPolicy(Bundle.main.bundleURL.pathExtension == "app" ? .regular : .accessory)
        let eventLoop = NSApplicationEventLoop(application: application)
        let controller = ApplicationController(
            paths: paths,
            onQuit: { eventLoop.stop() }
        )
        let hook = MainThreadStopHook(callback: { eventLoop.stop() },
                                      settingsCallback: { controller.showSettings() })
        let worker = try RuntimeWorker(paths: paths, hook: hook)
        let delegate = DesktopApplicationDelegate(controller: controller, onQuit: { controller.quit() })
        application.delegate = delegate
        delegate.installMenu(application: application)
        if showSettings { controller.showSettings() }
        let runner = GlobalTranslatorApplicationRunner(
            worker: RuntimeWorkerAdapter(worker: worker),
            controller: controller,
            eventLoop: eventLoop
        )
        defer {
            withExtendedLifetime(delegate) {}
            application.delegate = nil
        }
        try await runner.run()
    }
}

private final class MainThreadStopHook: RuntimeWorkerHook, @unchecked Sendable {
    private let callback: @MainActor @Sendable () -> Void
    private let settingsCallback: @MainActor @Sendable () -> Void

    init(callback: @escaping @MainActor @Sendable () -> Void,
         settingsCallback: @escaping @MainActor @Sendable () -> Void) {
        self.callback = callback
        self.settingsCallback = settingsCallback
    }

    func workerDidStart() {}

    func workerDidRequestSettings() {
        Task { @MainActor in settingsCallback() }
    }

    func workerWillStop() {
        Task { @MainActor in
            callback()
        }
    }
}
