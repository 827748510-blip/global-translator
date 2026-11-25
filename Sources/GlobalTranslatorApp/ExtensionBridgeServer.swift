import Foundation
import GlobalTranslatorCapture
import GlobalTranslatorCore
import Network
import os

public enum ExtensionBridgeError: Error, Equatable, Sendable {
    /// Automatic translation is switched off in the menu bar app.
    case translatorInactive
    /// No configured session/coordinator is available to serve the request.
    case translatorUnavailable
}

/// Aligned with the request `texts` array. Filtered items (already Chinese,
/// URLs, identifiers) return their original text unchanged. Indexes in
/// `retryIndexes` (`translations` entry `nil`) were transient backend failures
/// and must not be treated as "already asked".
public struct ExtensionBridgeTranslation: Equatable, Sendable {
    public let translations: [String?]
    public let retryIndexes: [Int]

    public init(translations: [String?], retryIndexes: [Int] = []) {
        self.translations = translations
        self.retryIndexes = retryIndexes
    }
}

/// Loopback-only HTTP endpoint used by the "Global Translator Bridge"
/// browser extension. The extension pins its own key, so its extension ID —
/// and therefore its `Origin` header — is stable; requests carrying any
/// other origin (e.g. a website probing localhost) are rejected, and the
/// listener never leaves the loopback interface.
///
/// Protocol:
///   GET  /health           -> 200 {"ok":true,"videoTranslateEnabled":Bool,"autoTranslateEnabled":Bool,"backendReady":Bool,"videoAsrStatus":String}
///   POST /translate        {"texts":[String],"sourceLanguage"?:String,"pageOrigin"?:String} -> 200
///                           {"translations":[String?], "retry":[Int]}
///                           filtered items echo source text; `null` + `retry`
///                           lists indexes that failed transiently and should
///                           be asked again.
///   POST /video-translate  {"enabled":Bool} -> 200 {"ok":true,"videoTranslateEnabled":Bool}
///                           Requires desktop automatic translation to be active.
///   POST /video-asr        {"needed"?:Bool} -> 200 VideoASRSnapshot JSON
///                           English ASR cues for the extension to POST /translate.
///                           Audio never appears in this payload.
///   OPTIONS *              -> 204 with CORS headers for the extension origin.
public final class ExtensionBridgeServer: @unchecked Sendable {
    public typealias TranslateHandler = @MainActor @Sendable ([String]) async throws -> ExtensionBridgeTranslation
    public typealias ContextualTranslateHandler = @MainActor @Sendable ([String], TranslationSourceLanguage?) async throws -> ExtensionBridgeTranslation
    public typealias ScopedTranslateHandler = @MainActor @Sendable ([String], TranslationSourceLanguage?, String?) async throws -> ExtensionBridgeTranslation
    public typealias VideoTranslateEnabledHandler = @MainActor @Sendable () -> Bool
    public typealias SetVideoTranslateEnabledHandler = @MainActor @Sendable (Bool) -> Bool
    public typealias AutoTranslateEnabledHandler = @MainActor @Sendable () -> Bool
    public typealias BackendReadyHandler = @MainActor @Sendable () -> Bool
    public typealias BlockedReasonHandler = @MainActor @Sendable () -> String?
    public typealias VideoASRSnapshotHandler = @MainActor @Sendable () -> VideoASRSnapshot
    public typealias VideoASRNeededHandler = @MainActor @Sendable (Bool) -> Void

    /// Origin produced by the extension whose manifest pins the bundled key.
    /// The ID is what Chrome actually derives from the manifest key —
    /// verified stable across install paths. Re-verified 2026-09-08 against
    /// Chrome for Testing 151 with a fresh profile loading `extension/`:
    /// the live isolated-world origin is `fjggaipmhcfmgikhkjppkdliaoopaefc`.
    public static let allowedOrigin = "chrome-extension://fjggaipmhcfmgikhkjppkdliaoopaefc"
    /// Exactly one accepted origin: the shipped extension. The legacy sideload
    /// ID is deliberately not whitelisted any more.
    public static let allowedOrigins: Set<String> = [allowedOrigin]
    public static let defaultPort: UInt16 = 9_233

    private static let maximumHeaderBytes = 16_384
    private static let maximumBodyBytes = 2_000_000
    private static let maximumTexts = 400
    private static let maximumTextUTF8 = 4_000
    private static let maximumConcurrentConnections = 32
    private static let maximumConcurrentTranslateTasks = 8
    private static let readTimeoutSeconds: TimeInterval = 5
    private static let keepAliveTimeoutSeconds: TimeInterval = 30
    private static let translateTimeoutSeconds: TimeInterval = 180
    private static let headerDelimiter = Data("\r\n\r\n".utf8)

    private struct ConnectionState: @unchecked Sendable {
        var connections: [ObjectIdentifier: NWConnection] = [:]
        var readTimers: [ObjectIdentifier: Task<Void, Never>] = [:]
        var activeTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
        var activeTranslateCount = 0
        var boundPort: UInt16?
    }

    private let requestedPort: UInt16
    private let logger: (any AppRuntimeLogger)?
    private let videoTranslateEnabled: VideoTranslateEnabledHandler
    private let setVideoTranslateEnabled: SetVideoTranslateEnabledHandler
    private let autoTranslateEnabled: AutoTranslateEnabledHandler
    private let backendReady: BackendReadyHandler
    private let blockedReason: BlockedReasonHandler
    private let videoASRSnapshot: VideoASRSnapshotHandler
    private let videoASRSetNeeded: VideoASRNeededHandler
    private let handler: ScopedTranslateHandler
    private let queue = DispatchQueue(label: "global-translator.extension-bridge")
    private var listener: NWListener?
    private let stateLock = OSAllocatedUnfairLock(initialState: ConnectionState())
    /// Token bucket: burst 30, refilled at 10/s. Normal page/video traffic stays
    /// well under this, while a page driving the extension cannot drain the
    /// user's translation quota.
    private let rateLimiter = BridgeRateLimiter(capacity: 30, refillPerSecond: 10)
    private let controlRateLimiter = BridgeRateLimiter(capacity: 20, refillPerSecond: 5)

    /// Actual bound port; populated once the listener reports `.ready`
    /// (mainly so tests can bind port 0).
    public var boundPort: UInt16? {
        stateLock.withLock { $0.boundPort }
    }

    public init(
        port: UInt16 = ExtensionBridgeServer.defaultPort,
        logger: (any AppRuntimeLogger)? = nil,
        videoTranslateEnabled: @escaping VideoTranslateEnabledHandler = { false },
        setVideoTranslateEnabled: @escaping SetVideoTranslateEnabledHandler = { $0 },
        autoTranslateEnabled: @escaping AutoTranslateEnabledHandler = { true },
        backendReady: @escaping BackendReadyHandler = { true },
        blockedReason: @escaping BlockedReasonHandler = { nil },
        videoASRSnapshot: @escaping VideoASRSnapshotHandler = { .idle },
        videoASRSetNeeded: @escaping VideoASRNeededHandler = { _ in },
        scopedHandler: @escaping ScopedTranslateHandler
    ) {
        self.requestedPort = port
        self.logger = logger
        self.videoTranslateEnabled = videoTranslateEnabled
        self.setVideoTranslateEnabled = setVideoTranslateEnabled
        self.autoTranslateEnabled = autoTranslateEnabled
        self.backendReady = backendReady
        self.blockedReason = blockedReason
        self.videoASRSnapshot = videoASRSnapshot
        self.videoASRSetNeeded = videoASRSetNeeded
        self.handler = scopedHandler
    }

    public convenience init(
        port: UInt16 = ExtensionBridgeServer.defaultPort,
        logger: (any AppRuntimeLogger)? = nil,
        videoTranslateEnabled: @escaping VideoTranslateEnabledHandler = { false },
        setVideoTranslateEnabled: @escaping SetVideoTranslateEnabledHandler = { $0 },
        autoTranslateEnabled: @escaping AutoTranslateEnabledHandler = { true },
        backendReady: @escaping BackendReadyHandler = { true },
        blockedReason: @escaping BlockedReasonHandler = { nil },
        videoASRSnapshot: @escaping VideoASRSnapshotHandler = { .idle },
        videoASRSetNeeded: @escaping VideoASRNeededHandler = { _ in },
        handler: @escaping ContextualTranslateHandler
    ) {
        self.init(
            port: port,
            logger: logger,
            videoTranslateEnabled: videoTranslateEnabled,
            setVideoTranslateEnabled: setVideoTranslateEnabled,
            autoTranslateEnabled: autoTranslateEnabled,
            backendReady: backendReady,
            blockedReason: blockedReason,
            videoASRSnapshot: videoASRSnapshot,
            videoASRSetNeeded: videoASRSetNeeded,
            scopedHandler: { texts, language, _ in
                try await handler(texts, language)
            }
        )
    }

    /// Preserve callers of the original texts-only Swift API as well as the
    /// original HTTP payload. The application uses the contextual overload.
    public convenience init(
        port: UInt16 = ExtensionBridgeServer.defaultPort,
        logger: (any AppRuntimeLogger)? = nil,
        videoTranslateEnabled: @escaping VideoTranslateEnabledHandler = { false },
        videoASRSnapshot: @escaping VideoASRSnapshotHandler = { .idle },
        videoASRSetNeeded: @escaping VideoASRNeededHandler = { _ in },
        handler: @escaping TranslateHandler
    ) {
        self.init(
            port: port, logger: logger, videoTranslateEnabled: videoTranslateEnabled,
            videoASRSnapshot: videoASRSnapshot, videoASRSetNeeded: videoASRSetNeeded,
            scopedHandler: { texts, _, _ in try await handler(texts) }
        )
    }

    public func start() {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        do {
            let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: requestedPort) ?? .any)
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    let actualPort = listener.port?.rawValue
                    self?.stateLock.withLock { $0.boundPort = actualPort }
                    self?.logger?.event("bridge_listening", fields: [
                        "port": String(actualPort ?? 0)
                    ])
                case .failed(let error):
                    self?.logger?.event("bridge_failed", fields: ["status": error.localizedDescription])
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            logger?.event("bridge_failed", fields: ["status": error.localizedDescription])
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        let teardown = stateLock.withLock { current -> ([NWConnection], [Task<Void, Never>], [Task<Void, Never>]) in
            current.boundPort = nil
            let conns = Array(current.connections.values)
            let timers = Array(current.readTimers.values)
            let tasks = Array(current.activeTasks.values)
            current.connections.removeAll()
            current.readTimers.removeAll()
            current.activeTasks.removeAll()
            return (conns, timers, tasks)
        }
        teardown.1.forEach { $0.cancel() }
        teardown.2.forEach { $0.cancel() }
        teardown.0.forEach { $0.cancel() }
    }

    // MARK: - Connection plumbing

    private func handle(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        let accepted = stateLock.withLock { current -> Bool in
            guard current.connections.count < Self.maximumConcurrentConnections else { return false }
            current.connections[id] = connection
            return true
        }
        guard accepted else {
            logger?.event("bridge_rejected", fields: ["status": "connection_limit"])
            connection.cancel()
            return
        }

        let timeoutTask = armReadTimer(for: id, connection: connection, timeout: Self.readTimeoutSeconds)
        _ = timeoutTask

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                self?.cleanupConnection(id: id)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(on: connection, id: id, buffer: Data(), head: nil)
    }

    @discardableResult
    private func armReadTimer(
        for id: ObjectIdentifier,
        connection: NWConnection,
        timeout: TimeInterval
    ) -> Task<Void, Never> {
        let timeoutTask = Task { [weak self, weak connection] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled, let self, let connection else { return }
            self.cleanupConnection(id: id)
            self.logger?.event("bridge_rejected", fields: ["status": "read_timeout"])
            connection.cancel()
        }
        let previous = stateLock.withLock { current -> Task<Void, Never>? in
            guard current.connections[id] != nil else { return nil }
            let old = current.readTimers[id]
            current.readTimers[id] = timeoutTask
            return old
        }
        previous?.cancel()
        return timeoutTask
    }

    private func isConnectionTracked(id: ObjectIdentifier) -> Bool {
        stateLock.withLock { $0.connections[id] != nil }
    }

    private func cleanupConnection(id: ObjectIdentifier) {
        let (timer, task) = stateLock.withLock { current -> (Task<Void, Never>?, Task<Void, Never>?) in
            current.connections.removeValue(forKey: id)
            let t = current.readTimers.removeValue(forKey: id)
            let active = current.activeTasks.removeValue(forKey: id)
            return (t, active)
        }
        timer?.cancel()
        task?.cancel()
    }

    private func clearReadTimer(for id: ObjectIdentifier) {
        let timer = stateLock.withLock { $0.readTimers.removeValue(forKey: id) }
        timer?.cancel()
    }

    private func receive(on connection: NWConnection, id: ObjectIdentifier, buffer: Data, head: ParsedHead?) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] content, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let content { buffer.append(content) }
            self.processBufferedInput(on: connection, id: id, buffer: buffer, head: head, isComplete: isComplete, error: error)
        }
    }

    private func processBufferedInput(
        on connection: NWConnection,
        id: ObjectIdentifier,
        buffer: Data,
        head: ParsedHead?,
        isComplete: Bool,
        error: NWError?
    ) {
        if buffer.count > Self.maximumBodyBytes + Self.maximumHeaderBytes {
            clearReadTimer(for: id)
            send(.plain(status: 413, body: "payload too large"), on: connection, id: id)
            return
        }
        var activeHead = head
        if activeHead == nil {
            switch Self.parseHead(buffer) {
            case .incomplete:
                if isComplete || error != nil {
                    cleanupConnection(id: id)
                    connection.cancel()
                } else {
                    receive(on: connection, id: id, buffer: buffer, head: nil)
                }
                return
            case .malformed(let status, let message):
                clearReadTimer(for: id)
                send(.plain(status: status, body: message), on: connection, id: id)
                return
            case .complete(let parsed):
                guard isAllowedHost(parsed.host) else {
                    clearReadTimer(for: id)
                    logger?.event("bridge_rejected", fields: ["status": "host", "path": parsed.path])
                    send(.json(status: 403, object: ["error": "forbidden"]), on: connection, id: id)
                    return
                }
                if parsed.method != "OPTIONS" && !Self.allowedOrigins.contains(parsed.origin ?? "") {
                    clearReadTimer(for: id)
                    logger?.event("bridge_rejected", fields: ["status": "origin", "path": parsed.path])
                    send(.json(status: 403, object: ["error": "forbidden"]), on: connection, id: id)
                    return
                }
                activeHead = parsed
            }
        }
        guard let parsedHead = activeHead else { return }
        let bodyEnd = parsedHead.bodyStart + parsedHead.contentLength
        if buffer.count >= bodyEnd {
            clearReadTimer(for: id)
            let body = buffer.subdata(in: parsedHead.bodyStart..<bodyEnd)
            let trailing = buffer.count > bodyEnd ? Data(buffer[bodyEnd...]) : Data()
            let request = Request(
                method: parsedHead.method,
                path: parsedHead.path,
                origin: parsedHead.origin,
                body: body,
                keepAlive: parsedHead.keepAlive,
                trailingBuffer: trailing
            )
            dispatch(request, on: connection, id: id)
        } else if isComplete || error != nil {
            cleanupConnection(id: id)
            connection.cancel()
        } else {
            receive(on: connection, id: id, buffer: buffer, head: parsedHead)
        }
    }

    private func scheduleNextKeepAliveRequest(on connection: NWConnection, id: ObjectIdentifier, buffer: Data) {
        guard isConnectionTracked(id: id) else {
            connection.cancel()
            return
        }
        armReadTimer(for: id, connection: connection, timeout: Self.keepAliveTimeoutSeconds)
        if buffer.isEmpty {
            receive(on: connection, id: id, buffer: Data(), head: nil)
        } else {
            processBufferedInput(on: connection, id: id, buffer: buffer, head: nil, isComplete: false, error: nil)
        }
    }

    private struct ParsedHead {
        let method: String
        let path: String
        let origin: String?
        let host: String?
        let contentLength: Int
        let bodyStart: Int
        let keepAlive: Bool
    }

    private enum HeadParseResult {
        case incomplete
        case malformed(Int, String)
        case complete(ParsedHead)
    }

    private struct Request {
        let method: String
        let path: String
        let origin: String?
        let body: Data
        let keepAlive: Bool
        let trailingBuffer: Data
    }

    private static func parseHead(_ buffer: Data) -> HeadParseResult {
        let scanEnd = min(buffer.count, maximumHeaderBytes + 4)
        guard let headerRange = buffer[..<scanEnd].range(of: Self.headerDelimiter) else {
            return buffer.count > maximumHeaderBytes
                ? .malformed(431, "request header fields too large")
                : .incomplete
        }
        guard headerRange.lowerBound <= maximumHeaderBytes else {
            return .malformed(431, "request header fields too large")
        }
        let headerData = buffer[buffer.startIndex..<headerRange.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            return .malformed(400, "bad request")
        }
        var lines = headerText.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst()
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0].allSatisfy({ $0.isASCII && $0.isLetter }) else {
            return .malformed(400, "bad request")
        }
        let httpVersion = parts.count >= 3 ? String(parts[2]).uppercased() : "HTTP/1.0"
        var origin: String?
        var seenOrigin = false
        var host: String?
        var seenHost = false
        var contentLength: Int?
        var connectionClose = false
        var connectionKeepAlive = false
        for line in lines where !line.isEmpty {
            guard let separator = line.firstIndex(of: ":") else {
                return .malformed(400, "bad request")
            }
            let name = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            switch name {
            case "origin":
                guard !seenOrigin else { return .malformed(400, "duplicate origin") }
                seenOrigin = true
                origin = value
            case "host":
                guard !seenHost else { return .malformed(400, "duplicate host") }
                seenHost = true
                host = value
            case "connection":
                for rawToken in value.split(separator: ",") {
                    let token = rawToken.trimmingCharacters(in: .whitespaces).lowercased()
                    if token == "close" { connectionClose = true }
                    if token == "keep-alive" { connectionKeepAlive = true }
                }
            case "transfer-encoding":
                return .malformed(400, "transfer-encoding unsupported")
            case "content-length":
                guard contentLength == nil,
                      !value.isEmpty,
                      value.allSatisfy(\.isASCII),
                      value.allSatisfy(\.isNumber),
                      let parsed = Int(value),
                      parsed >= 0 else {
                    return .malformed(400, "invalid content-length")
                }
                guard parsed <= maximumBodyBytes else {
                    return .malformed(413, "payload too large")
                }
                contentLength = parsed
            default:
                break
            }
        }
        let keepAlive = httpVersion == "HTTP/1.1"
            ? !connectionClose
            : (connectionKeepAlive && !connectionClose)
        return .complete(ParsedHead(
            method: String(parts[0]).uppercased(),
            path: String(parts[1]),
            origin: origin,
            host: host,
            contentLength: contentLength ?? 0,
            bodyStart: headerRange.upperBound,
            keepAlive: keepAlive
        ))
    }

    private func isAllowedHost(_ rawHost: String?) -> Bool {
        guard let raw = rawHost?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else {
            return false
        }
        let expectedPort = stateLock.withLock { $0.boundPort } ?? (requestedPort > 0 ? requestedPort : nil)
        if raw.hasPrefix("[") {
            guard let close = raw.firstIndex(of: "]") else { return false }
            let bracketedHost = String(raw[raw.index(after: raw.startIndex)..<close])
            guard bracketedHost == "::1" else { return false }
            let rest = raw[raw.index(after: close)...]
            if rest.isEmpty { return true }
            guard rest.hasPrefix(":"), let port = UInt16(rest.dropFirst()) else { return false }
            return expectedPort == nil || port == expectedPort
        }
        if let colon = raw.firstIndex(of: ":") {
            let hostPart = String(raw[..<colon])
            let portPart = raw[raw.index(after: colon)...]
            guard ["127.0.0.1", "localhost"].contains(hostPart),
                  let port = UInt16(portPart) else { return false }
            return expectedPort == nil || port == expectedPort
        }
        return ["127.0.0.1", "localhost"].contains(raw)
    }

    // MARK: - Routing

    private func dispatch(_ request: Request, on connection: NWConnection, id: ObjectIdentifier) {
        guard !request.method.isEmpty else {
            send(.plain(status: 400, body: "bad request"), on: connection, id: id)
            return
        }
        if request.method == "OPTIONS" {
            send(
                corsPreflightResponse(for: request.origin),
                on: connection,
                id: id,
                keepAlive: request.keepAlive,
                trailingBuffer: request.trailingBuffer
            )
            return
        }
        guard Self.allowedOrigins.contains(request.origin ?? "") else {
            logger?.event("bridge_rejected", fields: ["status": "origin", "path": request.path])
            send(.json(status: 403, object: ["error": "forbidden"]), on: connection, id: id)
            return
        }
        switch (request.method, request.path) {
        // POST as well as GET: browsers omit the Origin header on plain GET
        // fetches, so the extension pings with POST to prove its identity.
        case ("GET", "/health"), ("POST", "/health"):
            guard controlRateLimiter.allow() else {
                send(.json(status: 429, object: ["error": "too many requests"]), on: connection, id: id, origin: request.origin)
                return
            }
            Task { [weak self] in
                guard let self else { return }
                let (videoOn, autoOn, ready, reason, asr) = await MainActor.run {
                    (
                        self.videoTranslateEnabled(),
                        self.autoTranslateEnabled(),
                        self.backendReady(),
                        self.blockedReason(),
                        self.videoASRSnapshot()
                    )
                }
                self.queue.async {
                    var object: [String: Any] = [
                        "ok": true,
                        "videoTranslateEnabled": videoOn,
                        "autoTranslateEnabled": autoOn,
                        "backendReady": ready,
                        "videoAsrStatus": asr.status.rawValue
                    ]
                    if let reason, !reason.isEmpty {
                        object["blockedReason"] = reason
                    }
                    self.send(
                        .json(status: 200, object: object),
                        on: connection,
                        id: id,
                        origin: request.origin,
                        keepAlive: request.keepAlive,
                        trailingBuffer: request.trailingBuffer
                    )
                }
            }
        case ("POST", "/video-translate"):
            handleSetVideoTranslate(request, on: connection, id: id)
        case ("POST", "/translate"):
            handleTranslate(request.body, origin: request.origin, on: connection, id: id)
        case ("POST", "/video-asr"):
            handleVideoASR(request, on: connection, id: id)
        default:
            send(
                .json(status: 404, object: ["error": "not found"]),
                on: connection,
                id: id,
                origin: request.origin,
                keepAlive: request.keepAlive,
                trailingBuffer: request.trailingBuffer
            )
        }
    }

    private func handleSetVideoTranslate(_ request: Request, on connection: NWConnection, id: ObjectIdentifier) {
        let origin = request.origin
        guard controlRateLimiter.allow() else {
            send(.json(status: 429, object: ["error": "too many requests"]), on: connection, id: id, origin: origin)
            return
        }
        guard let payload = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let enabled = payload["enabled"] as? Bool else {
            send(.json(status: 400, object: ["error": "bad request"]), on: connection, id: id, origin: origin)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let resolved: Bool? = await MainActor.run {
                if enabled && !self.autoTranslateEnabled() {
                    return nil
                }
                return self.setVideoTranslateEnabled(enabled)
            }
            self.queue.async {
                guard let resolved else {
                    self.send(
                        .json(status: 503, object: ["error": "inactive"]),
                        on: connection,
                        id: id,
                        origin: origin,
                        keepAlive: request.keepAlive,
                        trailingBuffer: request.trailingBuffer
                    )
                    return
                }
                self.send(
                    .json(status: 200, object: [
                        "ok": true,
                        "videoTranslateEnabled": resolved
                    ]),
                    on: connection,
                    id: id,
                    origin: origin,
                    keepAlive: request.keepAlive,
                    trailingBuffer: request.trailingBuffer
                )
            }
        }
    }

    private func handleTranslate(_ body: Data, origin: String?, on connection: NWConnection, id: ObjectIdentifier) {
        guard let payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let texts = payload["texts"] as? [String],
              !texts.isEmpty, texts.count <= Self.maximumTexts,
              texts.allSatisfy({ $0.utf8.count <= Self.maximumTextUTF8 }) else {
            send(.json(status: 400, object: ["error": "bad request"]), on: connection, id: id, origin: origin)
            return
        }
        // Missing hints retain the legacy protocol. Present hints must be
        // bounded tags, including their JSON type; null/objects are invalid.
        var sourceLanguage: TranslationSourceLanguage?
        if let raw = payload["sourceLanguage"] {
            guard let tag = raw as? String, let language = TranslationSourceLanguage(tag) else {
                send(.json(status: 400, object: ["error": "bad request"]), on: connection, id: id, origin: origin)
                return
            }
            sourceLanguage = language
        }
        var validatedPageOrigin: String?
        if let rawOrigin = payload["pageOrigin"] {
            guard let parsed = Self.normalizedPageOrigin(rawOrigin) else {
                send(.json(status: 400, object: ["error": "bad request"]), on: connection, id: id, origin: origin)
                return
            }
            validatedPageOrigin = parsed
        }
        let cost = min(30.0, 1.0 + floor(Double(max(0, texts.count - 1)) / 15.0))
        guard rateLimiter.allow(cost: cost) else {
            logger?.event("bridge_translate", fields: ["status": "rate_limited"])
            send(.json(status: 429, object: ["error": "too many requests"]), on: connection, id: id, origin: origin)
            return
        }
        let reservedSlot = stateLock.withLock { current -> Bool in
            guard current.activeTranslateCount < Self.maximumConcurrentTranslateTasks else { return false }
            current.activeTranslateCount += 1
            return true
        }
        guard reservedSlot else {
            logger?.event("bridge_translate", fields: ["status": "concurrency_limited"])
            send(.json(status: 429, object: ["error": "too many requests"]), on: connection, id: id, origin: origin)
            return
        }
        let validatedLanguage = sourceLanguage
        let resolvedOriginScope = validatedPageOrigin
        logger?.event("bridge_translate", fields: ["count": String(texts.count)])
        watchDisconnect(on: connection, id: id)
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                self.stateLock.withLock { current in
                    current.activeTasks.removeValue(forKey: id)
                    current.activeTranslateCount = max(0, current.activeTranslateCount - 1)
                }
            }
            let response: Response
            let translateHandler = self.handler
            do {
                let result = try await withThrowingTaskGroup(of: ExtensionBridgeTranslation.self) { group in
                    group.addTask {
                        try await translateHandler(texts, validatedLanguage, resolvedOriginScope)
                    }
                    group.addTask {
                        try await Task.sleep(for: .seconds(Self.translateTimeoutSeconds))
                        throw CancellationError()
                    }
                    guard let first = try await group.next() else {
                        throw CancellationError()
                    }
                    group.cancelAll()
                    return first
                }
                response = .json(status: 200, object: [
                    "translations": result.translations.map { $0 as Any },
                    "retry": result.retryIndexes
                ])
            } catch is CancellationError {
                return
            } catch ExtensionBridgeError.translatorInactive {
                response = .json(status: 503, object: ["error": "inactive"])
            } catch is CaptureError {
                // Screen locked / secure input / missing permission: the app
                // deliberately pauses all translation; the extension retries.
                response = .json(status: 503, object: ["error": "capture blocked"])
            } catch {
                self.logger?.event("bridge_translate_failed", fields: ["reason": String(describing: error)])
                response = .json(status: 500, object: ["error": "translation failed"])
            }
            guard !Task.isCancelled else { return }
            // Keep-Alive is disabled on POST /translate because watchDisconnect
            // has an active NWConnection.receive monitoring client aborts.
            self.queue.async { self.send(response, on: connection, id: id, origin: origin) }
        }
        let stored = stateLock.withLock { current -> Bool in
            guard current.connections[id] != nil else { return false }
            current.activeTasks[id] = task
            return true
        }
        if !stored {
            task.cancel()
        }
    }

    private func watchDisconnect(on connection: NWConnection, id: ObjectIdentifier) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64) { [weak self] _, _, isComplete, error in
            guard let self else { return }
            if isComplete || error != nil {
                self.cleanupConnection(id: id)
                connection.cancel()
            } else if self.stateLock.withLock({ $0.activeTasks[id] != nil }) {
                self.watchDisconnect(on: connection, id: id)
            }
        }
    }

    private static func normalizedPageOrigin(_ raw: Any) -> String? {
        guard let str = raw as? String,
              str.count <= 512,
              !str.isEmpty else { return nil }
        if str == "null" { return "opaque" }
        guard let components = URLComponents(string: str),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.user == nil,
              components.password == nil,
              let host = components.host?.lowercased(),
              !host.isEmpty else {
            return nil
        }
        if let port = components.port {
            return "\(scheme)://\(host):\(port)"
        }
        return "\(scheme)://\(host)"
    }

    private func handleVideoASR(_ request: Request, on connection: NWConnection, id: ObjectIdentifier) {
        let origin = request.origin
        guard controlRateLimiter.allow() else {
            send(.json(status: 429, object: ["error": "too many requests"]), on: connection, id: id, origin: origin)
            return
        }
        var needed: Bool?
        if !request.body.isEmpty {
            guard let payload = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
                send(.json(status: 400, object: ["error": "bad request"]), on: connection, id: id, origin: origin)
                return
            }
            if let rawNeeded = payload["needed"] {
                guard let value = rawNeeded as? Bool else {
                    send(.json(status: 400, object: ["error": "bad request"]), on: connection, id: id, origin: origin)
                    return
                }
                needed = value
            }
        }
        logger?.event("video_asr_bridge", fields: [
            "needed": needed.map { $0 ? "1" : "0" } ?? "poll"
        ])
        let requestedNeeded = needed
        Task { [weak self] in
            guard let self else { return }
            let snapshot = await MainActor.run {
                if let requestedNeeded {
                    let allowed = !requestedNeeded || (self.autoTranslateEnabled() && self.videoTranslateEnabled())
                    if allowed {
                        self.videoASRSetNeeded(requestedNeeded)
                    }
                }
                return self.videoASRSnapshot()
            }
            self.queue.async {
                self.send(
                    .json(status: 200, object: snapshot.jsonObject()),
                    on: connection,
                    id: id,
                    origin: origin,
                    keepAlive: request.keepAlive,
                    trailingBuffer: request.trailingBuffer
                )
            }
        }
    }

    // MARK: - Responses

    private struct Response {
        let status: Int
        let contentType: String
        let body: Data
        var cors: Bool = true
        var origin: String? = nil

        static func json(status: Int, object: [String: Any], origin: String? = nil) -> Response {
            let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
            return Response(status: status, contentType: "application/json", body: body, origin: origin)
        }

        static func plain(status: Int, body: String) -> Response {
            Response(status: status, contentType: "text/plain", body: Data(body.utf8), cors: false)
        }
    }

    private func corsPreflightResponse(for origin: String?) -> Response {
        guard let origin, Self.allowedOrigins.contains(origin) else {
            return .json(status: 403, object: ["error": "forbidden"])
        }
        return Response(status: 204, contentType: "text/plain", body: Data(), origin: origin)
    }

    private func send(
        _ response: Response,
        on connection: NWConnection,
        id: ObjectIdentifier? = nil,
        origin: String? = nil,
        keepAlive: Bool = false,
        trailingBuffer: Data = Data()
    ) {
        var head = "HTTP/1.1 \(response.status) \(Self.statusText(response.status))\r\n"
        head += "Content-Type: \(response.contentType)\r\n"
        head += "Content-Length: \(response.body.count)\r\n"
        if keepAlive {
            head += "Connection: keep-alive\r\n"
            head += "Keep-Alive: timeout=\(Int(Self.keepAliveTimeoutSeconds))\r\n"
        } else {
            head += "Connection: close\r\n"
        }
        if response.cors {
            let allow = origin ?? response.origin
            let echoed = allow.flatMap { Self.allowedOrigins.contains($0) ? $0 : nil } ?? Self.allowedOrigin
            head += "Access-Control-Allow-Origin: \(echoed)\r\n"
            head += "Access-Control-Allow-Methods: POST, GET, OPTIONS\r\n"
            head += "Access-Control-Allow-Headers: content-type\r\n"
            head += "Access-Control-Max-Age: 86400\r\n"
            head += "Vary: Origin\r\n"
        }
        head += "\r\n"
        let headData = Data(head.utf8)
        let completion: @Sendable (NWError?) -> Void = { [weak self] error in
            guard let self else {
                connection.cancel()
                return
            }
            guard keepAlive, error == nil, let id, self.isConnectionTracked(id: id) else {
                if let id { self.cleanupConnection(id: id) }
                connection.cancel()
                return
            }
            self.scheduleNextKeepAliveRequest(on: connection, id: id, buffer: trailingBuffer)
        }
        if response.body.isEmpty {
            connection.send(content: headData, completion: .contentProcessed(completion))
        } else {
            connection.batch {
                connection.send(content: headData, completion: .idempotent)
                connection.send(content: response.body, completion: .contentProcessed(completion))
            }
        }
    }

    private static func statusText(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 408: return "Request Timeout"
        case 413: return "Payload Too Large"
        case 429: return "Too Many Requests"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
        default: return "Status"
        }
    }
}

/// Minimal thread-safe token bucket guarding the bridge's translate endpoint.
/// Kept as a separate type so it can be unit tested directly.
final class BridgeRateLimiter: @unchecked Sendable {
    private let lock = NSLock()
    private let capacity: Double
    private let refillPerSecond: Double
    private let now: () -> TimeInterval
    private var tokens: Double
    private var lastRefill: TimeInterval

    init(
        capacity: Double,
        refillPerSecond: Double,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        let currentTime = now()
        self.capacity = capacity
        self.refillPerSecond = refillPerSecond
        self.now = now
        self.tokens = capacity
        self.lastRefill = currentTime
    }

    /// Consumes one token. Returns false when the caller should be throttled.
    func allow() -> Bool {
        allow(cost: 1)
    }

    func allow(cost: Double) -> Bool {
        let debit = max(1, cost)
        lock.lock()
        defer { lock.unlock() }
        let timestamp = now()
        let elapsed = max(0, timestamp - lastRefill)
        tokens = min(capacity, tokens + elapsed * refillPerSecond)
        lastRefill = timestamp
        guard tokens >= debit else { return false }
        tokens -= debit
        return true
    }
}
