import Foundation

public struct HTTPResponse: Sendable, Equatable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data

    public init(statusCode: Int, headers: [String: String], body: Data) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

public enum HTTPTransportError: Error, Equatable, Sendable {
    case redirectRejected
    case timeout
    case networkFailure
    case invalidResponse
    case responseTooLarge
}

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
    func sendStreaming(
        _ request: URLRequest,
        onChunk: @escaping @Sendable (Data) async -> Void
    ) async throws -> HTTPResponse
}

public extension HTTPTransport {
    func sendStreaming(
        _ request: URLRequest,
        onChunk: @escaping @Sendable (Data) async -> Void
    ) async throws -> HTTPResponse {
        let response = try await send(request)
        if (200..<300).contains(response.statusCode), !response.body.isEmpty {
            await onChunk(response.body)
        }
        return response
    }
}

struct HTTPResponseAccumulator {
    let maximumBytes: Int
    private(set) var data = Data()

    init(maximumBytes: Int) {
        self.maximumBytes = max(0, maximumBytes)
    }

    mutating func reserveCapacity(_ expectedBytes: Int64) {
        guard expectedBytes > 0 else { return }
        let bounded = Int(min(expectedBytes, Int64(maximumBytes)))
        if bounded > 0 {
            data.reserveCapacity(bounded)
        }
    }

    mutating func append(_ chunk: Data) throws {
        guard chunk.count <= maximumBytes - data.count else {
            throw HTTPTransportError.responseTooLarge
        }
        data.append(chunk)
    }
}

private final class RequestCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var cancelled = false

    func start(_ task: URLSessionTask) {
        lock.lock()
        self.task = task
        let shouldCancel = cancelled
        if !shouldCancel { task.resume() }
        lock.unlock()
        if shouldCancel { task.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }
}

private final class SessionDelegateProxy: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    weak var owner: URLSessionHTTPTransport?

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @Sendable @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let owner else {
            completionHandler(.cancel)
            return
        }
        owner.handle(dataTask: dataTask, didReceive: response, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        owner?.handle(dataTask: dataTask, didReceive: data)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @Sendable @escaping (URLRequest?) -> Void
    ) {
        guard let owner else {
            completionHandler(nil)
            return
        }
        owner.handle(task: task, willPerformHTTPRedirection: response, newRequest: request, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        owner?.handle(task: task, didCompleteWithError: error)
    }
}

public final class URLSessionHTTPTransport: HTTPTransport, @unchecked Sendable {
    private final class PendingTask {
        var response: HTTPURLResponse?
        var body: HTTPResponseAccumulator
        let continuation: CheckedContinuation<HTTPResponse, Error>
        let streamContinuation: AsyncStream<Data>.Continuation?
        var streamedBytes = 0
        var redirectRejected = false
        var responseTooLarge = false

        init(
            continuation: CheckedContinuation<HTTPResponse, Error>,
            maximumResponseBytes: Int,
            streamContinuation: AsyncStream<Data>.Continuation? = nil
        ) {
            self.continuation = continuation
            self.streamContinuation = streamContinuation
            body = HTTPResponseAccumulator(maximumBytes: maximumResponseBytes)
        }
    }

    private let lock = NSLock()
    private var pending: [Int: PendingTask] = [:]
    public let maximumResponseBytes: Int
    private let delegateProxy: SessionDelegateProxy
    private let session: URLSession

    public init(
        configuration: URLSessionConfiguration = .ephemeral,
        maximumResponseBytes: Int = 2 * 1024 * 1024,
        requestTimeout: TimeInterval = 30,
        resourceTimeout: TimeInterval = 60
    ) {
        let configured = configuration
        configured.httpShouldSetCookies = false
        configured.httpCookieStorage = nil
        // Cloud stays snappy (30/60). Local Ollama, especially qwen3 thinking
        // models, often spend >30s before the first response byte because
        // `stream` is false; pass higher values for that TTFB.
        configured.timeoutIntervalForRequest = min(max(requestTimeout, 1), 180)
        configured.timeoutIntervalForResource = min(max(resourceTimeout, 1), 300)
        self.maximumResponseBytes = max(0, maximumResponseBytes)
        let proxy = SessionDelegateProxy()
        self.delegateProxy = proxy
        self.session = URLSession(configuration: configured, delegate: proxy, delegateQueue: nil)
        proxy.owner = self
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        let task = session.dataTask(with: request)
        let cancellation = RequestCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HTTPResponse, Error>) in
                lock.lock()
                pending[task.taskIdentifier] = PendingTask(
                    continuation: continuation,
                    maximumResponseBytes: maximumResponseBytes
                )
                lock.unlock()
                cancellation.start(task)
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    public func sendStreaming(
        _ request: URLRequest,
        onChunk: @escaping @Sendable (Data) async -> Void
    ) async throws -> HTTPResponse {
        let task = session.dataTask(with: request)
        let cancellation = RequestCancellation()
        let (stream, streamContinuation) = AsyncStream<Data>.makeStream()
        let consumer = Task {
            for await chunk in stream {
                await onChunk(chunk)
            }
        }
        do {
            let response = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HTTPResponse, Error>) in
                    lock.lock()
                    pending[task.taskIdentifier] = PendingTask(
                        continuation: continuation,
                        maximumResponseBytes: maximumResponseBytes,
                        streamContinuation: streamContinuation
                    )
                    lock.unlock()
                    cancellation.start(task)
                }
            } onCancel: {
                cancellation.cancel()
            }
            await consumer.value
            return response
        } catch {
            streamContinuation.finish()
            consumer.cancel()
            throw error
        }
    }

    fileprivate func handle(
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @Sendable @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        lock.lock()
        if let state = pending[dataTask.taskIdentifier] {
            state.response = response as? HTTPURLResponse
            if state.streamContinuation == nil {
                state.body.reserveCapacity(response.expectedContentLength)
            }
        }
        lock.unlock()
        completionHandler(.allow)
    }

    fileprivate func handle(
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        var responseTooLarge = false
        var streamToYield: AsyncStream<Data>.Continuation?
        lock.lock()
        if let state = pending[dataTask.taskIdentifier] {
            if let streamContinuation = state.streamContinuation,
               let statusCode = state.response?.statusCode,
               (200..<300).contains(statusCode) {
                if data.count > maximumResponseBytes - state.streamedBytes {
                    state.responseTooLarge = true
                    responseTooLarge = true
                } else {
                    state.streamedBytes += data.count
                    streamToYield = streamContinuation
                }
            } else {
                do {
                    try state.body.append(data)
                } catch {
                    state.responseTooLarge = true
                    responseTooLarge = true
                }
            }
        }
        lock.unlock()
        if let streamToYield {
            streamToYield.yield(data)
        }
        if responseTooLarge {
            dataTask.cancel()
        }
    }

    fileprivate func handle(
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @Sendable @escaping (URLRequest?) -> Void
    ) {
        lock.lock()
        pending[task.taskIdentifier]?.redirectRejected = true
        lock.unlock()
        completionHandler(nil)
    }

    fileprivate func handle(
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        let state = pending.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        guard let state else { return }
        state.streamContinuation?.finish()

        if state.redirectRejected {
            state.continuation.resume(throwing: HTTPTransportError.redirectRejected)
            return
        }
        if state.responseTooLarge {
            state.continuation.resume(throwing: HTTPTransportError.responseTooLarge)
            return
        }
        if let error {
            if (error as? URLError)?.code == .cancelled {
                state.continuation.resume(throwing: CancellationError())
                return
            }
            state.continuation.resume(throwing: map(error))
            return
        }
        guard let response = state.response else {
            state.continuation.resume(throwing: HTTPTransportError.invalidResponse)
            return
        }
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, pair in
            result[String(describing: pair.key)] = String(describing: pair.value)
        }
        state.continuation.resume(returning: HTTPResponse(statusCode: response.statusCode, headers: headers, body: state.body.data))
    }

    private func map(_ error: Error) -> HTTPTransportError {
        if let urlError = error as? URLError, urlError.code == .timedOut {
            return .timeout
        }
        return .networkFailure
    }
}
