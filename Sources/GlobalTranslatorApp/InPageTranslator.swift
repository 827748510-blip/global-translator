import Foundation

/// One translatable text node discovered inside a web page.
public struct InPageText: Equatable, Sendable {
    public let nodeID: String
    public let id: UUID
    public let text: String

    public init(nodeID: String, id: UUID, text: String) {
        self.nodeID = nodeID
        self.id = id
        self.text = text
    }
}

/// A translated replacement to write back into the page.
public struct InPageReplacement: Equatable, Sendable {
    public let nodeID: String
    public let text: String

    public init(nodeID: String, text: String) {
        self.nodeID = nodeID
        self.text = text
    }
}

/// In-place translation surface: replaces page text (including buttons)
/// directly in the DOM instead of drawing overlay bubbles.
public protocol InPageTranslating: AnyObject, Sendable {
    /// Cheap check used to route browser windows away from overlay bubbles.
    func isApplicable(bundleIdentifier: String) async -> Bool
    func extract(windowRevision: UInt64) async throws -> [InPageText]
    func apply(_ replacements: [InPageReplacement]) async throws
}

/// Chromium DevTools Protocol client. Requires the browser to run with
/// `--remote-debugging-port=<port>`; unavailable endpoints simply fall back
/// to the overlay-bubble pipeline.
public actor CDPInPageTranslator: InPageTranslating {
    private let port: UInt16
    private let browserBundleIdentifiers: Set<String>
    private let urlSession: URLSession
    private var lastProbeAt: Date?
    private var lastProbeResult = false
    private var nodeIdentifiers: [String: UUID] = [:]

    public init(port: UInt16 = 9_222) {
        self.port = port
        self.browserBundleIdentifiers = [
            "com.google.Chrome",
            "com.google.Chrome.canary",
            "org.chromium.Chromium",
            "com.microsoft.edgemac",
            "com.brave.Browser"
        ]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 10
        self.urlSession = URLSession(configuration: configuration)
    }

    public func isApplicable(bundleIdentifier: String) async -> Bool {
        guard browserBundleIdentifiers.contains(bundleIdentifier) else { return false }
        if let lastProbeAt, Date().timeIntervalSince(lastProbeAt) < 5 { return lastProbeResult }
        let available = await Self.probe(port: port, session: urlSession)
        lastProbeAt = Date()
        lastProbeResult = available
        return available
    }

    public func extract(windowRevision: UInt64) async throws -> [InPageText] {
        // Only the OS-focused, visible tab of the browser is translated —
        // other CDP targets (background tabs, automation browsers sharing the
        // debug port) are skipped so the wrong page is never rewritten.
        for page in try await pageTargets() {
            let focused = try await rpc(page: page, method: "Runtime.evaluate", params: [
                "expression": Self.focusScript,
                "returnByValue": true
            ])
            guard Self.resultValue(focused) as? Bool == true else { continue }
            activePageIdentifier = page.identifier
            extractionTargetURL = page.url
            return try await extractTexts(from: page)
        }
        return []
    }

    private var extractionTargetURL: String?
    private var activePageIdentifier: String?

    private func extractTexts(from page: PageTarget) async throws -> [InPageText] {
        let payload = try await rpc(page: page, method: "Runtime.evaluate", params: [
            "expression": Self.extractScript,
            "returnByValue": true
        ])
        if let exception = payload["exceptionDetails"] as? [String: Any] {
            let detail = (exception["exception"] as? [String: Any])?["description"] as? String
                ?? (exception["text"] as? String) ?? "script exception"
            throw CDPError.requestFailed(detail)
        }
        guard let value = Self.resultValue(payload) as? String,
              let decoded = try? JSONSerialization.jsonObject(with: Data(value.utf8)) else { return [] }
        if let failure = decoded as? [String: Any], let message = failure["error"] as? String {
            throw CDPError.requestFailed(message)
        }
        guard let entries = decoded as? [[String: Any]] else { return [] }
        return entries.compactMap { entry in
            guard let nodeID = entry["id"] as? String,
                  let text = entry["text"] as? String, !text.isEmpty else { return nil }
            let id = nodeIdentifier(for: nodeID)
            return InPageText(nodeID: nodeID, id: id, text: text)
        }
    }

    public func apply(_ replacements: [InPageReplacement]) async throws {
        guard !replacements.isEmpty else { return }
        let targets = try await pageTargets()
        let page = targets.first { $0.identifier == activePageIdentifier }
            ?? targets.first { $0.url == extractionTargetURL }
            ?? targets.first
        guard let page else { return }
        let map = Dictionary(uniqueKeysWithValues: replacements.map { ($0.nodeID, $0.text) })
        let json = try JSONSerialization.data(withJSONObject: map)
        let expression = "(() => { const m = \(String(decoding: json, as: UTF8.self));"
            + " let applied = 0;"
            + " if (window.__gtTranslator) { for (const id in m) {"
            + " const node = window.__gtTranslator.nodes[id];"
            + " if (node && node.isConnected) { const original = node.nodeValue; const trimmed = original.trim();"
            + " if (trimmed) { node.nodeValue = original.replace(trimmed, m[id]); applied++; } } } }"
            + " return String(applied); })()"
        let payload = try await rpc(page: page, method: "Runtime.evaluate", params: [
            "expression": expression,
            "returnByValue": true
        ])
        _ = Self.resultValue(payload)
    }

    // MARK: - Plumbing

    private func nodeIdentifier(for nodeID: String) -> UUID {
        if let existing = nodeIdentifiers[nodeID] { return existing }
        let fresh = UUID()
        nodeIdentifiers[nodeID] = fresh
        return fresh
    }

    private struct PageTarget {
        let identifier: String
        let url: String
        let kind: String
        let webSocketURL: String
    }

    private func pageTargets() async throws -> [PageTarget] {
        guard let url = URL(string: "http://127.0.0.1:\(port)/json/list") else { return [] }
        let (data, response) = try await urlSession.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let targets = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return targets.compactMap { target in
            guard let identifier = target["id"] as? String,
                  let webSocketURL = target["webSocketDebuggerUrl"] as? String,
                  let kind = target["type"] as? String, kind == "page",
                  let pageURL = target["url"] as? String, pageURL.hasPrefix("http") else { return nil }
            return PageTarget(identifier: identifier, url: pageURL, kind: kind, webSocketURL: webSocketURL)
        }
    }

    private func rpc(page: PageTarget, method: String, params: [String: Any]) async throws -> [String: Any] {
        guard let url = URL(string: page.webSocketURL) else { throw URLError(.badURL) }
        let webSocket = urlSession.webSocketTask(with: url)
        webSocket.resume()
        defer { webSocket.cancel(with: .normalClosure, reason: nil) }
        let requestID = Int.random(in: 1...1_000_000)
        let body: [String: Any] = ["id": requestID, "method": method, "params": params]
        let data = try JSONSerialization.data(withJSONObject: body)
        try await webSocket.send(.string(String(decoding: data, as: UTF8.self)))
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            let message = try await Self.receive(webSocket, within: 5)
            let payload: Data
            switch message {
            case .string(let text): payload = Data(text.utf8)
            case .data(let bytes): payload = bytes
            @unknown default: continue
            }
            guard let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else { continue }
            if let event = object["method"] as? String, event.hasPrefix("Runtime.") { continue }
            guard let identifier = object["id"] as? Int, identifier == requestID else { continue }
            if let error = object["error"] as? [String: Any] {
                throw CDPError.requestFailed(error["message"] as? String ?? "cdp error")
            }
            return object["result"] as? [String: Any] ?? [:]
        }
        throw CDPError.timeout
    }

    private enum CDPError: Error, CustomStringConvertible {
        case requestFailed(String)
        case timeout

        var description: String {
            switch self {
            case .requestFailed(let message): return "cdp: \(message)"
            case .timeout: return "cdp: timeout"
            }
        }
    }

    private static func receive(_ webSocket: URLSessionWebSocketTask, within seconds: Double) async throws -> URLSessionWebSocketTask.Message {
        try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) { group in
            group.addTask { try await webSocket.receive() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw CDPError.timeout
            }
            guard let first = try await group.next() else { throw CDPError.timeout }
            group.cancelAll()
            return first
        }
    }

    private static func probe(port: UInt16, session: URLSession) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/json/version") else { return false }
        do {
            let (_, response) = try await session.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    private static func resultValue(_ payload: [String: Any]) -> Any? {
        (payload["result"] as? [String: Any])?["value"]
    }

    private static let focusScript = """
    document.hasFocus() && document.visibilityState === 'visible'
    """

    private static let extractScript = """
    (() => {
      try {
      if (!window.__gtTranslator) window.__gtTranslator = { nodes: {}, next: 0 };
      const store = window.__gtTranslator;
      const results = [];
      const skipped = ['SCRIPT', 'STYLE', 'NOSCRIPT', 'CODE', 'PRE', 'TEXTAREA'];
      const walker = document.createTreeWalker(document.body || document.documentElement, NodeFilter.SHOW_TEXT);
      let node;
      while ((node = walker.nextNode())) {
        const original = node.nodeValue || '';
        const text = original.trim();
        if (text.length < 2) continue;
        if (!/[A-Za-z]/.test(text) || /[\\u4e00-\\u9fff]/.test(text)) continue;
        const element = node.parentElement;
        if (!element || skipped.indexOf(element.tagName) !== -1) continue;
        if (element.closest && element.closest('[contenteditable="true"], [contenteditable=""]')) continue;
        const rect = element.getBoundingClientRect();
        if (rect.width < 4 || rect.height < 4) continue;
        const style = getComputedStyle(element);
        if (style.visibility === 'hidden' || style.display === 'none' || Number(style.opacity) === 0) continue;
        let id = null;
        for (const existing in store.nodes) if (store.nodes[existing] === node) { id = existing; break; }
        if (id == null) { id = String(store.next++); store.nodes[id] = node; }
        results.push({ id: id, text: text });
        if (results.length >= 200) break;
      }
      return JSON.stringify(results);
      } catch (error) { return JSON.stringify({ error: String(error) }); }
    })()
    """
}
