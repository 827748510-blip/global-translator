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
}

struct HTTPResponseAccumulator {
    let maximumBytes: Int
    private(set) var data = Data()

    init(maximumBytes: Int) {
        self.maximumBytes = max(0, maximumBytes)
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

public final class URLSessionHTTPTransport: NSObject, HTTPTransport, URLSessionDataDelegate, @unchecked Sendable {
    private final class PendingTask {
        var response: HTTPURLResponse?
        var body: HTTPResponseAccumulator
        let continuation: CheckedContinuation<HTTPResponse, Error>
        var redirectRejected = false
        var responseTooLarge = false

        init(continuation: CheckedContinuation<HTTPResponse, Error>, maximumResponseBytes: Int) {
            self.continuation = continuation
            body = HTTPResponseAccumulator(maximumBytes: maximumResponseBytes)
        }
    }

    private let lock = NSLock()
    private var pending: [Int: PendingTask] = [:]
    private let configuration: URLSessionConfiguration
    public let maximumResponseBytes: Int
    private lazy var session: URLSession = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)

    public init(
        configuration: URLSessionConfiguration = .ephemeral,
        maximumResponseBytes: Int = 2 * 1024 * 1024
    ) {
        let configured = configuration
        configured.httpShouldSetCookies = false
        configured.httpCookieStorage = nil
        configured.timeoutIntervalForRequest = min(configured.timeoutIntervalForRequest, 30)
        configured.timeoutIntervalForResource = min(configured.timeoutIntervalForResource, 60)
        self.configuration = configured
        self.maximumResponseBytes = max(0, maximumResponseBytes)
        super.init()
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

    public func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @Sendable @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        lock.lock()
        pending[dataTask.taskIdentifier]?.response = response as? HTTPURLResponse
        lock.unlock()
        completionHandler(.allow)
    }

    public func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        var responseTooLarge = false
        lock.lock()
        if let state = pending[dataTask.taskIdentifier] {
            do {
                try state.body.append(data)
            } catch {
                state.responseTooLarge = true
                responseTooLarge = true
            }
        }
        lock.unlock()
        if responseTooLarge {
            dataTask.cancel()
        }
    }

    public func urlSession(
        _ session: URLSession,
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

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        let state = pending.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        guard let state else { return }

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
