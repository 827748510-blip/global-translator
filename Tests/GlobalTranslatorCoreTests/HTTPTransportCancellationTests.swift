import Foundation
import Testing
@testable import GlobalTranslatorCore

struct HTTPTransportCancellationTests {
    @Test
    func cancellingTranslationStopsTheUnderlyingNetworkRequest() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SlowTranslationProtocol.self]
        let transport = URLSessionHTTPTransport(configuration: configuration)
        let task = Task {
            try? await transport.send(URLRequest(url: URL(string: "http://127.0.0.1/translation-cancellation-test")!))
        }
        for _ in 0..<100 where !SlowTranslationProtocol.events.started {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(SlowTranslationProtocol.events.started)
        task.cancel()
        try await Task.sleep(for: .milliseconds(100))
        #expect(SlowTranslationProtocol.events.stopped)
        _ = await task.value
    }
}

private final class RequestEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var didStart = false
    private var didStop = false
    var started: Bool { lock.withLock { didStart } }
    var stopped: Bool { lock.withLock { didStop } }
    func start() { lock.withLock { didStart = true } }
    func stop() { lock.withLock { didStop = true } }
}

private final class SlowTranslationProtocol: URLProtocol, @unchecked Sendable {
    static let events = RequestEvents()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.events.start()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [self] in
            guard !Self.events.stopped else { return }
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
        }
    }
    override func stopLoading() { Self.events.stop() }
}
