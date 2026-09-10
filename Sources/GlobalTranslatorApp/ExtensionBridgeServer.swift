import Foundation
import GlobalTranslatorCapture
import Network

public enum ExtensionBridgeError: Error, Equatable, Sendable {
    /// Automatic translation is switched off in the menu bar app.
    case translatorInactive
    /// No configured session/coordinator is available to serve the request.
    case translatorUnavailable
}

/// Aligned with the request `texts` array. `nil` is a deliberate skip
/// (already Chinese, filtered). Indexes in `retryIndexes` were transient
/// backend failures and must not be treated as "already asked".
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
///   GET  /health     -> 200 {"ok":true,"videoTranslateEnabled":Bool,"videoAsrStatus":String}
///   POST /translate  {"texts":[String]} -> 200
///                     {"translations":[String?], "retry":[Int]}
///                     null is a deliberate skip; `retry` lists indexes
///                     that failed transiently and should be asked again.
///   POST /video-asr  {"needed":Bool?} -> 200 VideoASRSnapshot JSON
///                     English ASR cues for the extension to POST /translate.
///                     Audio never appears in this payload.
///   OPTIONS *        -> 204 with CORS headers for the extension origin.
public final class ExtensionBridgeServer: @unchecked Sendable {
    public typealias TranslateHandler = @MainActor @Sendable ([String]) async throws -> ExtensionBridgeTranslation
    public typealias VideoTranslateEnabledHandler = @MainActor @Sendable () -> Bool
    public typealias VideoASRSnapshotHandler = @MainActor @Sendable () -> VideoASRSnapshot
    public typealias VideoASRNeededHandler = @MainActor @Sendable (Bool) -> Void

    /// Origin produced by the extension whose manifest pins the bundled key.
    /// The ID is what Chrome actually derives from the manifest key —
    /// verified stable across install paths. Re-verified 2026-09-08 against
    /// Chrome for Testing 151 with a fresh profile loading `extension/`:
    /// the live isolated-world origin is `fjggaipmhcfmgikhkjppkdliaoopaefc`.
    public static let allowedOrigin = "chrome-extension://fjggaipmhcfmgikhkjppkdliaoopaefc"
    /// Chrome `--load-extension` sideload sometimes derives this ID even
    /// when the manifest key is present (Chrome 152 experiment leftover).
    public static let sideloadOrigin = "chrome-extension://fignfifoniblkonapihmkfakmlgkbkcf"
    public static let allowedOrigins: Set<String> = [allowedOrigin, sideloadOrigin]
    public static let defaultPort: UInt16 = 9_233

    private static let maximumHeaderBytes = 16_384
    private static let maximumBodyBytes = 2_000_000
    private static let maximumTexts = 400
    private static let maximumTextUTF8 = 4_000

    private let requestedPort: UInt16
    private let logger: (any AppRuntimeLogger)?
    private let videoTranslateEnabled: VideoTranslateEnabledHandler
    private let videoASRSnapshot: VideoASRSnapshotHandler
    private let videoASRSetNeeded: VideoASRNeededHandler
    private let handler: TranslateHandler
    private let queue = DispatchQueue(label: "global-translator.extension-bridge")
    private var listener: NWListener?
    /// Token bucket: burst 30, refilled at 10/s. Normal page/video traffic stays
    /// well under this, while a page driving the extension cannot drain the
    /// user's translation quota.
    private let rateLimiter = BridgeRateLimiter(capacity: 30, refillPerSecond: 10)

    /// Actual bound port; populated once the listener reports `.ready`
    /// (mainly so tests can bind port 0).
    public private(set) var boundPort: UInt16?

    public init(
        port: UInt16 = ExtensionBridgeServer.defaultPort,
        logger: (any AppRuntimeLogger)? = nil,
        videoTranslateEnabled: @escaping VideoTranslateEnabledHandler = { false },
        videoASRSnapshot: @escaping VideoASRSnapshotHandler = { .idle },
        videoASRSetNeeded: @escaping VideoASRNeededHandler = { _ in },
        handler: @escaping TranslateHandler
    ) {
        self.requestedPort = port
        self.logger = logger
        self.videoTranslateEnabled = videoTranslateEnabled
        self.videoASRSnapshot = videoASRSnapshot
        self.videoASRSetNeeded = videoASRSetNeeded
        self.handler = handler
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
                    self?.boundPort = listener.port?.rawValue
                    self?.logger?.event("bridge_listening", fields: [
                        "port": String(self?.boundPort ?? 0)
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
        boundPort = nil
    }

    // MARK: - Connection plumbing

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] content, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let content { buffer.append(content) }
            if buffer.count > Self.maximumBodyBytes + Self.maximumHeaderBytes {
                connection.cancel()
                return
            }
            if let request = Self.parse(buffer) {
                self.dispatch(request, on: connection)
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: buffer)
            }
        }
    }

    private struct Request {
        let method: String
        let path: String
        let origin: String?
        let body: Data
    }

    private static func parse(_ buffer: Data) -> Request? {
        guard let headerRange = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return buffer.count > maximumHeaderBytes ? .some(Request(method: "", path: "", origin: nil, body: Data())) : nil
        }
        let headerData = buffer[buffer.startIndex..<headerRange.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
        var lines = headerText.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst()
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var origin: String?
        var contentLength = 0
        for line in lines {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            if name == "origin" { origin = value }
            if name == "content-length" { contentLength = Int(value) ?? 0 }
        }
        guard contentLength >= 0, contentLength <= maximumBodyBytes else { return nil }
        let bodyStart = headerRange.upperBound
        guard buffer.count >= bodyStart + contentLength else { return nil }
        return Request(
            method: String(parts[0]).uppercased(),
            path: String(parts[1]),
            origin: origin,
            body: buffer.subdata(in: bodyStart..<(bodyStart + contentLength))
        )
    }

    // MARK: - Routing

    private func dispatch(_ request: Request, on connection: NWConnection) {
        // Oversized/garbled headers arrive as an empty request line.
        guard !request.method.isEmpty else {
            send(.plain(status: 400, body: "bad request"), on: connection)
            return
        }
        if request.method == "OPTIONS" {
            send(corsPreflightResponse(for: request.origin), on: connection)
            return
        }
        guard Self.allowedOrigins.contains(request.origin ?? "") else {
            logger?.event("bridge_rejected", fields: ["status": "origin", "path": request.path])
            send(.json(status: 403, object: ["error": "forbidden"]), on: connection)
            return
        }
        switch (request.method, request.path) {
        // POST as well as GET: browsers omit the Origin header on plain GET
        // fetches, so the extension pings with POST to prove its identity.
        case ("GET", "/health"), ("POST", "/health"):
            Task { [weak self] in
                guard let self else { return }
                let enabled = await MainActor.run { self.videoTranslateEnabled() }
                let asr = await MainActor.run { self.videoASRSnapshot() }
                self.queue.async {
                    self.send(.json(status: 200, object: [
                        "ok": true,
                        "videoTranslateEnabled": enabled,
                        "videoAsrStatus": asr.status.rawValue
                    ]), on: connection, origin: request.origin)
                }
            }
        case ("POST", "/translate"):
            handleTranslate(request.body, origin: request.origin, on: connection)
        case ("POST", "/video-asr"):
            handleVideoASR(request.body, origin: request.origin, on: connection)
        default:
            send(.json(status: 404, object: ["error": "not found"]), on: connection, origin: request.origin)
        }
    }

    private func handleTranslate(_ body: Data, origin: String?, on connection: NWConnection) {
        guard rateLimiter.allow() else {
            logger?.event("bridge_translate", fields: ["status": "rate_limited"])
            send(.json(status: 429, object: ["error": "too many requests"]), on: connection, origin: origin)
            return
        }
        guard let payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let texts = payload["texts"] as? [String],
              !texts.isEmpty, texts.count <= Self.maximumTexts,
              texts.allSatisfy({ $0.utf8.count <= Self.maximumTextUTF8 }) else {
            send(.json(status: 400, object: ["error": "bad request"]), on: connection, origin: origin)
            return
        }
        logger?.event("bridge_translate", fields: ["count": String(texts.count)])
        Task { [weak self] in
            guard let self else { return }
            let response: Response
            do {
                let result = try await self.handler(texts)
                response = .json(status: 200, object: [
                    "translations": result.translations.map { $0 as Any },
                    "retry": result.retryIndexes
                ])
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
            self.queue.async { self.send(response, on: connection, origin: origin) }
        }
    }

    private func handleVideoASR(_ body: Data, origin: String?, on connection: NWConnection) {
        var needed: Bool?
        if !body.isEmpty,
           let payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let value = payload["needed"] as? Bool {
            needed = value
        }
        logger?.event("video_asr_bridge", fields: [
            "needed": needed.map { $0 ? "1" : "0" } ?? "poll"
        ])
        Task { [weak self] in
            guard let self else { return }
            if let needed {
                await MainActor.run { self.videoASRSetNeeded(needed) }
            }
            let snapshot = await MainActor.run { self.videoASRSnapshot() }
            self.queue.async {
                self.send(.json(status: 200, object: snapshot.jsonObject()), on: connection, origin: origin)
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

    private func send(_ response: Response, on connection: NWConnection, origin: String? = nil) {
        var head = "HTTP/1.1 \(response.status) \(Self.statusText(response.status))\r\n"
        head += "Content-Type: \(response.contentType)\r\n"
        head += "Content-Length: \(response.body.count)\r\n"
        head += "Connection: close\r\n"
        if response.cors {
            let allow = origin ?? response.origin
            let echoed = allow.flatMap { Self.allowedOrigins.contains($0) ? $0 : nil } ?? Self.allowedOrigin
            head += "Access-Control-Allow-Origin: \(echoed)\r\n"
            head += "Access-Control-Allow-Methods: POST, GET, OPTIONS\r\n"
            head += "Access-Control-Allow-Headers: content-type\r\n"
            head += "Vary: Origin\r\n"
        }
        head += "\r\n"
        var payload = Data(head.utf8)
        payload.append(response.body)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func statusText(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
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
        now: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 }
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
        lock.lock()
        defer { lock.unlock() }
        let timestamp = now()
        let elapsed = max(0, timestamp - lastRefill)
        tokens = min(capacity, tokens + elapsed * refillPerSecond)
        lastRefill = timestamp
        guard tokens >= 1 else { return false }
        tokens -= 1
        return true
    }
}
