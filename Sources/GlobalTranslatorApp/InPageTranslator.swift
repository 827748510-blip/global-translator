import Darwin
import Foundation
import GlobalTranslatorCore

/// One translatable text node discovered inside a web page.
public struct InPageText: Equatable, Sendable {
    public let nodeID: String
    public let id: UUID
    public let text: String
    public let sourceLanguage: TranslationSourceLanguage?

    public init(nodeID: String, id: UUID, text: String, sourceLanguage: TranslationSourceLanguage? = nil) {
        self.nodeID = nodeID
        self.id = id
        self.text = text
        self.sourceLanguage = sourceLanguage
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
    /// `windowPID` identifies the process owning the focused window: only
    /// windows owned by the debug-enabled browser instance are translated
    /// in-page — windows from any other browser process (same bundle
    /// identifier, no debug port) must fall through to the bubble pipeline.
    /// Callers pass <= 0 when the window's process is unknown.
    func isApplicable(bundleIdentifier: String, windowPID: Int32) async -> Bool
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
    private var browserPID: Int32?
    private var nodeIdentifiers: [String: UUID] = [:]
    private var cachedSession: IsolatedSession?
    private var nextRPCID = 1

    private struct IsolatedSession {
        let targetID: String
        let webSocketURL: String
        let webSocket: URLSessionWebSocketTask
        let contextID: Int
    }

    deinit {
        cachedSession?.webSocket.cancel(with: .normalClosure, reason: nil)
    }

    public init(port: UInt16 = 9_222) {
        self.port = port
        self.browserBundleIdentifiers = ChromiumBrowserBundles.identifiers
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 10
        self.urlSession = URLSession(configuration: configuration)
    }

    public func isApplicable(bundleIdentifier: String, windowPID: Int32) async -> Bool {
        guard browserBundleIdentifiers.contains(bundleIdentifier) else { return false }
        if let lastProbeAt, Date().timeIntervalSince(lastProbeAt) < 5 {
            return lastProbeResult && owns(windowPID: windowPID)
        }
        let available = await Self.probe(port: port, session: urlSession)
        browserPID = available ? await fetchBrowserPID() : nil
        lastProbeAt = Date()
        lastProbeResult = available
        return available && owns(windowPID: windowPID)
    }

    /// Only the browser instance exposing the debug port owned by the current
    /// OS user gets in-page translation; unknown PIDs or missing browser PIDs
    /// fail closed so normal/foreign windows fall through to the bubble
    /// pipeline instead of risking misattribution.
    private func owns(windowPID: Int32) -> Bool {
        guard windowPID > 0, let browserPID else { return false }
        return browserPID == windowPID
    }

    private static func isOwnedByCurrentUser(pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        let read = Darwin.proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        guard read == size else { return false }
        return info.pbi_uid == getuid()
    }

    static func validatedWebSocketURL(_ raw: String, port: UInt16) -> URL? {
        guard let components = URLComponents(string: raw),
              components.scheme?.lowercased() == "ws",
              components.user == nil,
              components.password == nil,
              let host = components.host?.lowercased(),
              ["127.0.0.1", "localhost", "::1"].contains(host),
              components.port == Int(port),
              components.path.hasPrefix("/devtools/") else {
            return nil
        }
        return components.url
    }

    /// Main-process PID of the debug-enabled browser, resolved through the
    /// browser-level DevTools target (`SystemInfo.getProcessInfo`).
    private func fetchBrowserPID() async -> Int32? {
        guard let versionURL = URL(string: "http://127.0.0.1:\(port)/json/version"),
              let (data, response) = try? await urlSession.data(from: versionURL),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let webSocketURL = object["webSocketDebuggerUrl"] as? String,
              Self.validatedWebSocketURL(webSocketURL, port: port) != nil,
              let payload = try? await rpc(webSocketURL: webSocketURL, method: "SystemInfo.getProcessInfo", params: [:]),
              let processes = payload["processInfo"] as? [[String: Any]] else { return nil }
        for process in processes where process["type"] as? String == "browser" {
            if let id = process["id"] as? Int {
                let candidate = Int32(clamping: id)
                guard Self.isOwnedByCurrentUser(pid: candidate) else { return nil }
                return candidate
            }
        }
        return nil
    }

    public func extract(windowRevision: UInt64) async throws -> [InPageText] {
        // Only the OS-focused, visible tab of the browser is translated —
        // other CDP targets (background tabs, automation browsers sharing the
        // debug port) are skipped so the wrong page is never rewritten.
        var targets = try await pageTargets()
        if let activeID = activePageIdentifier,
           let activeIndex = targets.firstIndex(where: { $0.identifier == activeID }),
           activeIndex > 0 {
            let active = targets.remove(at: activeIndex)
            targets.insert(active, at: 0)
        }
        for page in targets {
            let focused = try await evaluateInIsolatedWorld(page: page, expression: Self.focusScript)
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
        let payload = try await evaluateInIsolatedWorld(page: page, expression: Self.extractScript)
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
        var seenNodeIDs: Set<String> = []
        var collected: [InPageText] = []
        collected.reserveCapacity(min(entries.count, 200))
        for entry in entries.prefix(200) {
            guard let nodeID = entry["id"] as? String,
                  !nodeID.isEmpty,
                  seenNodeIDs.insert(nodeID).inserted,
                  let text = entry["text"] as? String,
                  !text.isEmpty,
                  text.count <= 4_000 else { continue }
            let id = nodeIdentifier(for: nodeID)
            collected.append(InPageText(
                nodeID: nodeID,
                id: id,
                text: text,
                sourceLanguage: (entry["sourceLanguage"] as? String).flatMap(TranslationSourceLanguage.init)
            ))
        }
        return collected
    }

    public func apply(_ replacements: [InPageReplacement]) async throws {
        guard !replacements.isEmpty else { return }
        let targets = try await pageTargets()
        let page = targets.first { $0.identifier == activePageIdentifier }
            ?? targets.first { $0.url == extractionTargetURL }
        guard let page else { return }
        let pairs = replacements.compactMap { replacement -> (String, String)? in
            let text = replacement.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : (replacement.nodeID, text)
        }
        let map = Dictionary(pairs, uniquingKeysWith: { _, latest in latest })
        let json = try JSONSerialization.data(withJSONObject: map)
        let expression = "(() => { const m = \(String(decoding: json, as: UTF8.self));"
            + " let applied = 0;"
            + " if (window.__gtTranslator) { for (const id in m) {"
            + " const node = window.__gtTranslator.nodes[id];"
            + " if (node && node.isConnected) { const original = node.nodeValue; const trimmed = original.trim();"
            + " if (trimmed && window.__gtTranslator.requested[id] === trimmed) {"
            + " window.__gtTranslator.entries[id] = { source: trimmed, translation: m[id] };"
            + " node.nodeValue = original.replace(trimmed, m[id]); applied++; } } } }"
            + " return String(applied); })()"
        let payload = try await evaluateInIsolatedWorld(page: page, expression: expression)
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
                  Self.validatedWebSocketURL(webSocketURL, port: port) != nil,
                  let kind = target["type"] as? String, kind == "page",
                  let pageURL = target["url"] as? String, pageURL.hasPrefix("http") else { return nil }
            return PageTarget(identifier: identifier, url: pageURL, kind: kind, webSocketURL: webSocketURL)
        }
    }

    private func evaluateInIsolatedWorld(page: PageTarget, expression: String) async throws -> [String: Any] {
        if let cached = cachedSession,
           cached.targetID == page.identifier,
           cached.webSocketURL == page.webSocketURL {
            do {
                return try await sendRPC(on: cached.webSocket, method: "Runtime.evaluate", params: [
                    "expression": expression,
                    "contextId": cached.contextID,
                    "returnByValue": true
                ])
            } catch {
                cached.webSocket.cancel(with: .normalClosure, reason: nil)
                cachedSession = nil
            }
        } else if let stale = cachedSession {
            stale.webSocket.cancel(with: .normalClosure, reason: nil)
            cachedSession = nil
        }

        let session = try await openIsolatedSession(for: page)
        cachedSession = session
        do {
            return try await sendRPC(on: session.webSocket, method: "Runtime.evaluate", params: [
                "expression": expression,
                "contextId": session.contextID,
                "returnByValue": true
            ])
        } catch {
            session.webSocket.cancel(with: .normalClosure, reason: nil)
            if cachedSession?.webSocket === session.webSocket {
                cachedSession = nil
            }
            throw error
        }
    }

    private func openIsolatedSession(for page: PageTarget) async throws -> IsolatedSession {
        guard let url = Self.validatedWebSocketURL(page.webSocketURL, port: port) else {
            throw CDPError.requestFailed("untrusted websocket url")
        }
        let webSocket = urlSession.webSocketTask(with: url)
        webSocket.resume()
        do {
            let frameTree = try await sendRPC(on: webSocket, method: "Page.getFrameTree", params: [:])
            guard let frame = frameTree["frameTree"] as? [String: Any],
                  let rootFrame = frame["frame"] as? [String: Any],
                  let frameID = rootFrame["id"] as? String, !frameID.isEmpty else {
                throw CDPError.requestFailed("missing root frame id")
            }
            let world = try await sendRPC(on: webSocket, method: "Page.createIsolatedWorld", params: [
                "frameId": frameID,
                "worldName": "GlobalTranslatorIsolated",
                "grantUniveralAccess": false
            ])
            guard let contextID = world["executionContextId"] as? Int else {
                throw CDPError.requestFailed("missing isolated executionContextId")
            }
            return IsolatedSession(
                targetID: page.identifier,
                webSocketURL: page.webSocketURL,
                webSocket: webSocket,
                contextID: contextID
            )
        } catch {
            webSocket.cancel(with: .normalClosure, reason: nil)
            throw error
        }
    }

    private func rpc(webSocketURL: String, method: String, params: [String: Any]) async throws -> [String: Any] {
        guard let url = Self.validatedWebSocketURL(webSocketURL, port: port) else {
            throw CDPError.requestFailed("untrusted websocket url")
        }
        let webSocket = urlSession.webSocketTask(with: url)
        webSocket.resume()
        defer { webSocket.cancel(with: .normalClosure, reason: nil) }
        return try await sendRPC(on: webSocket, method: method, params: params)
    }

    private func sendRPC(on webSocket: URLSessionWebSocketTask, method: String, params: [String: Any]) async throws -> [String: Any] {
        let requestID = nextRPCID
        nextRPCID &+= 1
        if nextRPCID <= 0 { nextRPCID = 1 }
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
      if (!window.__gtTranslator) window.__gtTranslator = { nodes: {}, nodeIds: new WeakMap(), next: 0 };
      const store = window.__gtTranslator;
      if (!store.entries) store.entries = {};
      if (!store.requested) store.requested = {};
      if (!store.nodeIds) {
        store.nodeIds = new WeakMap();
        for (const existing in store.nodes) {
          const n = store.nodes[existing];
          if (n) store.nodeIds.set(n, existing);
        }
      }
      const rawLang = document.documentElement.lang || '';
      const match = /^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{1,8})*$/.exec(rawLang);
      const pageLang = rawLang.length <= 63 && match && match[0] === rawLang ? rawLang.toLowerCase() : null;
      const parts = (pageLang || '').split('-');
      const script = parts[1] && parts[1].length === 4 ? parts[1] : null;
      const foreignCJKPage = parts[0] === 'ja' || parts[0] === 'ko' ||
        (parts[0] === 'zh' && script !== 'hans' &&
          (script === 'hant' || ['tw', 'hk', 'mo'].includes(parts[script ? 2 : 1])));
      const results = [];
      const pendingWrites = [];
      const skipped = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'CODE', 'PRE', 'TEXTAREA']);
      const walker = document.createTreeWalker(document.body || document.documentElement, NodeFilter.SHOW_TEXT);
      let node;
      while ((node = walker.nextNode())) {
        const original = node.nodeValue || '';
        const text = original.trim();
        if (text.length < 2) continue;
        if (!/\\p{L}/u.test(text)) continue;
        const kana = /[\\u3040-\\u30FF\\u31F0-\\u31FF]/.test(text);
        const hangul = /[\\u1100-\\u11FF\\u3130-\\u318F\\uAC00-\\uD7AF]/.test(text);
        const cjk = /[\\u3400-\\u4DBF\\u4E00-\\u9FFF\\uF900-\\uFAFF]/.test(text);
        if (cjk && !kana && !hangul && !foreignCJKPage && !/[A-Za-z]/.test(text)) continue;
        const element = node.parentElement;
        if (!element || skipped.has(element.tagName)) continue;
        if (element.closest && element.closest('[contenteditable="true"], [contenteditable=""]')) continue;
        const rect = element.getBoundingClientRect();
        if (rect.width < 4 || rect.height < 4) continue;
        const style = getComputedStyle(element);
        if (style.visibility === 'hidden' || style.display === 'none' || Number(style.opacity) === 0) continue;
        let id = store.nodeIds.get(node);
        if (id == null) {
          id = String(store.next++);
          store.nodes[id] = node;
          store.nodeIds.set(node, id);
        }
        const entry = store.entries[id];
        if (entry && entry.translation === text) continue;
        if (entry && entry.source === text) {
          pendingWrites.push([node, original.replace(text, entry.translation)]);
          continue;
        }
        store.requested[id] = text;
        results.push({ id: id, text: text, sourceLanguage: pageLang });
        if (results.length >= 200) break;
      }
      for (let i = 0; i < pendingWrites.length; i++) {
        pendingWrites[i][0].nodeValue = pendingWrites[i][1];
      }
      return JSON.stringify(results);
      } catch (error) { return JSON.stringify({ error: String(error) }); }
    })()
    """
}
