import Darwin
import Foundation

private let controlMaximumBytes = 4_096

public protocol RuntimeControlClient: Sendable {
    func request(_ action: ControlAction) throws -> ControlResponse
}

public final class UnixControlServer: @unchecked Sendable {
    public let socketURL: URL

    private let handler: @Sendable (ControlRequest) -> ControlResponse
    private let stateLock = NSLock()
    private var listener: Int32 = -1
    private var source: DispatchSourceRead?

    public init(
        socketURL: URL,
        handler: @escaping @Sendable (ControlRequest) -> ControlResponse
    ) {
        self.socketURL = socketURL
        self.handler = handler
    }

    deinit {
        stop()
    }

    public func start() throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard listener < 0, socketURL.isFileURL, socketURL.path.hasPrefix("/") else {
            throw RuntimeError.socketInUse
        }
        let parent = socketURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        } catch {
            throw RuntimeError.ioFailure
        }
        guard !FileManager.default.fileExists(atPath: socketURL.path) else {
            throw RuntimeError.socketInUse
        }

        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw RuntimeError.ioFailure
        }
        do {
            var address = try makeUnixAddress(path: socketURL.path)
            let bindResult = withUnsafePointer(to: &address.0) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    Darwin.bind(descriptor, sockaddrPointer, address.1)
                }
            }
            guard bindResult == 0 else {
                Darwin.close(descriptor)
                throw RuntimeError.socketInUse
            }
            guard Darwin.chmod(socketURL.path, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
                Darwin.close(descriptor)
                try? FileManager.default.removeItem(at: socketURL)
                throw RuntimeError.ioFailure
            }
            guard Darwin.listen(descriptor, 8) == 0,
                  Darwin.fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else {
                Darwin.close(descriptor)
                try? FileManager.default.removeItem(at: socketURL)
                throw RuntimeError.ioFailure
            }
            let readSource = DispatchSource.makeReadSource(
                fileDescriptor: descriptor,
                queue: DispatchQueue(label: "GlobalTranslatorRuntime.control")
            )
            readSource.setEventHandler { [weak self] in
                self?.acceptConnections()
            }
            readSource.setCancelHandler {
                _ = Darwin.close(descriptor)
            }
            listener = descriptor
            source = readSource
            readSource.resume()
        } catch let error as RuntimeError {
            throw error
        } catch {
            Darwin.close(descriptor)
            throw RuntimeError.ioFailure
        }
    }

    public func stop() {
        stateLock.lock()
        let readSource = source
        let descriptor = listener
        source = nil
        listener = -1
        stateLock.unlock()
        readSource?.cancel()
        if descriptor >= 0 {
            unlinkOwnedSocket()
        }
    }

    public var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return listener >= 0
    }

    private func acceptConnections() {
        while true {
            stateLock.lock()
            let listenerDescriptor = listener
            stateLock.unlock()
            guard listenerDescriptor >= 0 else {
                return
            }
            var address = sockaddr_un()
            var length = socklen_t(MemoryLayout<sockaddr_un>.size)
            let client = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    Darwin.accept(listenerDescriptor, sockaddrPointer, &length)
                }
            }
            guard client >= 0 else {
                if errno == EINTR {
                    continue
                }
                return
            }
            var noSignal: Int32 = 1
            _ = withUnsafePointer(to: &noSignal) { pointer in
                setsockopt(
                    client,
                    SOL_SOCKET,
                    SO_NOSIGPIPE,
                    pointer,
                    socklen_t(MemoryLayout<Int32>.size)
                )
            }
            handleConnection(client)
        }
    }

    private func handleConnection(_ descriptor: Int32) {
        defer { _ = Darwin.close(descriptor) }
        var noSignal: Int32 = 1
        _ = withUnsafePointer(to: &noSignal) { pointer in
            setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                pointer,
                socklen_t(MemoryLayout<Int32>.size)
            )
        }
        var receiveTimeout = timeval(tv_sec: 1, tv_usec: 0)
        _ = withUnsafePointer(to: &receiveTimeout) { pointer in
            setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_RCVTIMEO,
                pointer,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while true {
            let count = Darwin.recv(descriptor, &buffer, buffer.count, 0)
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
                if data.count > controlMaximumBytes {
                    sendError(.requestTooLarge, on: descriptor)
                    return
                }
                continue
            }
            if count == 0 {
                break
            }
            if errno == EINTR {
                continue
            }
            return
        }
        guard let request = try? JSONDecoder().decode(ControlRequest.self, from: data) else {
            sendResponse(ControlResponse(running: false, state: .error), on: descriptor)
            return
        }
        sendResponse(handler(request), on: descriptor)
    }

    private func sendError(_ error: RuntimeError, on descriptor: Int32) {
        let payload: Data
        switch error {
        case .requestTooLarge:
            payload = Data("{\"error\":\"request_too_large\"}\n".utf8)
        default:
            payload = Data("{\"error\":\"invalid_request\"}\n".utf8)
        }
        sendAll(payload, on: descriptor)
    }

    private func sendResponse(_ response: ControlResponse, on descriptor: Int32) {
        guard let payload = try? encodeJSON(response) else {
            return
        }
        sendAll(payload, on: descriptor)
    }

    private func sendAll(_ data: Data, on descriptor: Int32) {
        var offset = 0
        data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return
            }
            while offset < data.count {
                let written = Darwin.send(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    data.count - offset,
                    0
                )
                if written <= 0 {
                    if errno == EINTR {
                        continue
                    }
                    return
                }
                offset += written
            }
        }
    }

    private func unlinkOwnedSocket() {
        guard FileManager.default.fileExists(atPath: socketURL.path), isSocketFile(socketURL.path) else {
            return
        }
        _ = Darwin.unlink(socketURL.path)
    }
}

public struct UnixControlClient: RuntimeControlClient, Sendable {
    public let socketURL: URL
    public let timeout: TimeInterval

    public init(socketURL: URL, timeout: TimeInterval = 0.5) {
        self.socketURL = socketURL
        self.timeout = min(max(timeout, 0.05), 2.0)
    }

    public func status() throws -> ControlResponse {
        try request(.status)
    }

    public func stop() throws -> ControlResponse {
        try request(.stop)
    }

    public func request(_ action: ControlAction) throws -> ControlResponse {
        let request = try encodeJSON(ControlRequest(action: action))
        let responseData = try sendRaw(request)
        guard let response = try? JSONDecoder().decode(ControlResponse.self, from: responseData) else {
            if responseData.contains(Data("request_too_large".utf8)) {
                throw RuntimeError.requestTooLarge
            }
            throw RuntimeError.invalidRequest
        }
        return response
    }

    public func sendRaw(_ payload: Data) throws -> Data {
        guard payload.count <= controlMaximumBytes else {
            throw RuntimeError.requestTooLarge
        }
        guard socketURL.isFileURL, socketURL.path.hasPrefix("/") else {
            throw RuntimeError.invalidPath
        }
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw RuntimeError.connectionFailure
        }
        defer { _ = Darwin.close(descriptor) }
        var noSignal: Int32 = 1
        _ = withUnsafePointer(to: &noSignal) { pointer in
            setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                pointer,
                socklen_t(MemoryLayout<Int32>.size)
            )
        }
        var receiveTimeout = timeval(
            tv_sec: Int(timeout),
            tv_usec: Int32((timeout - floor(timeout)) * 1_000_000)
        )
        _ = withUnsafePointer(to: &receiveTimeout) { pointer in
            setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, pointer, socklen_t(MemoryLayout<timeval>.size))
        }
        var address = try makeUnixAddress(path: socketURL.path)
        let connected = withUnsafePointer(to: &address.0) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(descriptor, sockaddrPointer, address.1)
            }
        }
        guard connected == 0 else {
            throw RuntimeError.connectionFailure
        }
        try sendAll(payload, descriptor: descriptor)
        _ = Darwin.shutdown(descriptor, SHUT_WR)
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while true {
            let count = Darwin.recv(descriptor, &buffer, buffer.count, 0)
            if count > 0 {
                response.append(contentsOf: buffer.prefix(count))
                if response.count > controlMaximumBytes {
                    throw RuntimeError.responseTooLarge
                }
                continue
            }
            if count == 0 {
                return response
            }
            if errno == EINTR {
                continue
            }
            throw RuntimeError.connectionFailure
        }
    }
}

private func encodeJSON<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(value) + Data([0x0A])
}

private func sendAll(_ data: Data, descriptor: Int32) throws {
    var offset = 0
    try data.withUnsafeBytes { buffer in
        guard let baseAddress = buffer.baseAddress else {
            return
        }
        while offset < data.count {
            let written = Darwin.send(descriptor, baseAddress.advanced(by: offset), data.count - offset, 0)
            if written > 0 {
                offset += written
            } else if errno != EINTR {
                throw RuntimeError.connectionFailure
            }
        }
    }
}

private func makeUnixAddress(path: String) throws -> (sockaddr_un, socklen_t) {
    let bytes = Array(path.utf8) + [0]
    var address = sockaddr_un()
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
        throw RuntimeError.invalidPath
    }
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { storage in
        storage.copyBytes(from: bytes)
    }
    let length = socklen_t(MemoryLayout<sa_family_t>.size + bytes.count)
    return (address, length)
}

private func isSocketFile(_ path: String) -> Bool {
    var information = stat()
    guard Darwin.lstat(path, &information) == 0 else {
        return false
    }
    return (information.st_mode & S_IFMT) == S_IFSOCK
}
