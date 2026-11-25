import Foundation

public struct LocalOpenAIBackend: TranslationBackend, Sendable {
    public let kind: BackendKind = .local
    public let baseURL: URL
    public let model: String

    private let transport: any HTTPTransport

    public init(
        baseURL: URL,
        model: String,
        transport: any HTTPTransport = URLSessionHTTPTransport(
            requestTimeout: 90,
            resourceTimeout: 180
        )
    ) throws {
        self.baseURL = try EndpointValidator.validateLocalBaseURL(baseURL)
        self.model = model
        self.transport = transport
    }

    public func healthCheck() async -> BackendHealth {
        let models: [String]
        do {
            models = try await listModels()
        } catch let error as TranslationError {
            return health(for: error)
        } catch {
            return BackendHealth(status: .unavailable, message: "Local health check failed")
        }
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return BackendHealth(
                status: .invalidConfiguration,
                message: "Local model is not configured",
                availableModels: models
            )
        }
        guard models.contains(model) else {
            return BackendHealth(
                status: .modelUnavailable,
                message: "Configured local model is unavailable",
                availableModels: models
            )
        }
        do {
            let sampleID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
            let sampleSource = "Hello"
            let result = try await translate(TranslationRequest(
                windowRevision: 0,
                items: [TranslationItem(id: sampleID, sourceText: sampleSource)]
            ))
            guard let sample = result.translations.first?.simplifiedChineseText
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !sample.isEmpty,
                  sample.caseInsensitiveCompare(sampleSource) != .orderedSame else {
                return BackendHealth(
                    status: .unavailable,
                    message: "Local structured translation check failed",
                    availableModels: models
                )
            }
            return BackendHealth(status: .healthy, message: "本地后端已就绪", availableModels: models)
        } catch let error as TranslationError {
            let failure = health(for: error)
            return BackendHealth(status: failure.status, message: failure.message, availableModels: models)
        } catch {
            return BackendHealth(
                status: .unavailable,
                message: "Local structured translation check failed",
                availableModels: models
            )
        }
    }

    public func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        try TranslationRequestValidator.validate(request)
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranslationError.invalidConfiguration("local model is not configured")
        }
        let body = try makePayload(for: request)
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = body
        let response: HTTPResponse
        do {
            response = try await transport.send(urlRequest)
        } catch {
            throw AdapterHTTPMapping.error(for: error)
        }
        if let error = AdapterHTTPMapping.error(for: response) {
            throw error
        }
        guard (200..<300).contains(response.statusCode) else {
            throw TranslationError.invalidResponse("unexpected local HTTP status")
        }
        return try LocalTranslationQuality.applyCopiedSourcePolicy(
            TranslationResponseParser.parseChatCompletions(
                response.body,
                expectedIDs: request.items.map { $0.id },
                windowRevision: request.windowRevision,
                mode: .localRelaxed,
                sourceCharacters: request.items.reduce(0) { $0 + $1.sourceText.count }
            ),
            items: request.items,
            policy: request.copiedSourcePolicy
        )
    }

    public func completePlain(system: String, user: String) async throws -> String {
        let trimmedSystem = system.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUser = user.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSystem.isEmpty, !trimmedUser.isEmpty else {
            throw TranslationError.invalidRequest("plain completion is empty")
        }
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranslationError.invalidConfiguration("local model is not configured")
        }
        let body = try makePlainPayload(system: trimmedSystem, user: trimmedUser)
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = body
        let response: HTTPResponse
        do {
            response = try await transport.send(urlRequest)
        } catch {
            throw AdapterHTTPMapping.error(for: error)
        }
        if let error = AdapterHTTPMapping.error(for: response) {
            throw error
        }
        guard (200..<300).contains(response.statusCode) else {
            throw TranslationError.invalidResponse("unexpected local HTTP status")
        }
        return try TranslationResponseParser.parsePlainChatCompletions(response.body)
    }

    public func streamPlain(
        system: String,
        user: String,
        onDelta: @escaping @Sendable (String) async -> Void
    ) async throws -> String {
        let trimmedSystem = system.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUser = user.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSystem.isEmpty, !trimmedUser.isEmpty else {
            throw TranslationError.invalidRequest("plain completion is empty")
        }
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranslationError.invalidConfiguration("local model is not configured")
        }
        let maxTokens = min(4_096, max(Self.plainCompletionMaxTokens, trimmedUser.count * 2 + 128))
        let body = try makePlainPayload(
            system: trimmedSystem,
            user: trimmedUser,
            stream: true,
            temperature: 0.1,
            maxTokens: maxTokens
        )
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        urlRequest.httpBody = body

        let collector = LocalSSEStreamCollector()
        let response: HTTPResponse
        do {
            response = try await transport.sendStreaming(urlRequest) { chunk in
                await collector.push(chunk, onDelta: onDelta)
            }
        } catch {
            throw AdapterHTTPMapping.error(for: error)
        }
        if let error = AdapterHTTPMapping.error(for: response) {
            throw error
        }
        guard (200..<300).contains(response.statusCode) else {
            throw TranslationError.invalidResponse("unexpected local HTTP status")
        }
        let finished = await collector.finish(onDelta: onDelta)
        let trimmed = finished.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        // Test stubs / non-SSE endpoints may return a standard non-streaming JSON body.
        if !finished.sawSSE {
            let fallbackData = !response.body.isEmpty ? response.body : finished.rawFallback
            if !fallbackData.isEmpty {
                let parsed = try TranslationResponseParser.parsePlainChatCompletions(fallbackData)
                await onDelta(parsed)
                return parsed
            }
        }
        throw TranslationError.invalidResponse("local stream completion is empty")
    }

    static func extractSSEDelta(from payload: String) -> String? {
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let choice = choices.first else {
            return nil
        }
        if let delta = choice["delta"] as? [String: Any],
           let content = delta["content"] as? String {
            return content
        }
        if let message = choice["message"] as? [String: Any],
           let content = message["content"] as? String {
            return content
        }
        return nil
    }

    /// Caps generation so a short UI string does not walk toward the
    /// Modelfile `num_predict` default. Overlay / page batches stay at
    /// 128 (one item) / 256 (three). Long selection chunks scale up so a
    /// 1500–2000 character piece can finish instead of truncating at 128.
    ///
    /// `expansion` is the target-language growth factor: the same 1800-char
    /// chunk needs roughly twice the budget once it is being rendered into
    /// English. Without it the JSON is cut mid-string, the parse fails, and a
    /// legal 中→英 translation surfaces as 「翻译失败」.
    static func maxTokens(itemCount: Int, sourceCharacters: Int = 0, expansion: Double = 1.0) -> Int {
        let overlayBudget = min(256, 64 + 64 * max(itemCount, 1))
        guard sourceCharacters > 320 else { return overlayBudget }
        let scaled = Int((Double(sourceCharacters) * max(expansion, 1.0)).rounded(.up)) + 128
        return min(4_096, max(overlayBudget, scaled))
    }

    static let plainCompletionMaxTokens = 1_024

    private func listModels() async throws -> [String] {
        var request = URLRequest(url: baseURL.appendingPathComponent("models"))
        request.httpMethod = "GET"
        let response: HTTPResponse
        do {
            response = try await transport.send(request)
        } catch {
            throw AdapterHTTPMapping.error(for: error)
        }
        if let error = AdapterHTTPMapping.error(for: response) {
            throw error
        }
        guard (200..<300).contains(response.statusCode) else {
            throw TranslationError.invalidResponse("unexpected local models HTTP status")
        }
        do {
            let result = try JSONDecoder().decode(ModelList.self, from: response.body)
            return result.data.map { $0.id }
        } catch {
            throw TranslationError.invalidResponse("local models response is invalid")
        }
    }

    private func makePayload(for request: TranslationRequest) throws -> Data {
        let direction = SelectionTranslationDirection(targetLanguage: request.targetLanguage) ?? .toChinese
        let payload = ChatPayload(
            model: model,
            messages: [
                ChatPrompt(role: "system", content: LocalTranslationPrompt.system(for: direction, sourceLanguage: request.sourceLanguage)),
                ChatPrompt(role: "user", content: LocalTranslationPrompt.userContent(
                    for: request.items,
                    direction: direction,
                    sourceLanguage: request.sourceLanguage
                ))
            ],
            maxTokens: Self.maxTokens(
                itemCount: request.items.count,
                sourceCharacters: request.items.reduce(0) { $0 + $1.sourceText.count },
                expansion: direction.outputExpansion
            ),
            responseFormat: ChatResponseFormat()
        )
        do {
            return try JSONEncoder().encode(payload)
        } catch {
            throw TranslationError.invalidRequest("unable to encode translation request")
        }
    }

    private func makePlainPayload(
        system: String,
        user: String,
        stream: Bool = false,
        temperature: Double = 0.3,
        maxTokens: Int = LocalOpenAIBackend.plainCompletionMaxTokens
    ) throws -> Data {
        let payload = PlainChatPayload(
            model: model,
            messages: [
                ChatPrompt(role: "system", content: system),
                ChatPrompt(role: "user", content: user)
            ],
            stream: stream,
            temperature: temperature,
            maxTokens: maxTokens
        )
        do {
            return try JSONEncoder().encode(payload)
        } catch {
            throw TranslationError.invalidRequest("unable to encode plain completion")
        }
    }

    private func health(for error: TranslationError) -> BackendHealth {
        switch error {
        case .unauthorized, .forbidden:
            return BackendHealth(status: .unavailable, message: "Local endpoint rejected the request")
        case .modelUnavailable:
            return BackendHealth(status: .modelUnavailable, message: "Configured local model is unavailable")
        case .invalidConfiguration:
            return BackendHealth(status: .invalidConfiguration, message: "Local endpoint configuration is invalid")
        default:
            return BackendHealth(status: .unavailable, message: "Local health check failed")
        }
    }
}

private struct ChatPayload: Encodable {
    let model: String
    let messages: [ChatPrompt]
    let stream = false
    let temperature = 0.0
    let maxTokens: Int
    let responseFormat: ChatResponseFormat

    private enum CodingKeys: String, CodingKey {
        case model
        case messages
        case stream
        case temperature
        case maxTokens = "max_tokens"
        case responseFormat = "response_format"
    }
}

private struct PlainChatPayload: Encodable {
    let model: String
    let messages: [ChatPrompt]
    let stream: Bool
    let temperature: Double
    let maxTokens: Int

    private enum CodingKeys: String, CodingKey {
        case model
        case messages
        case stream
        case temperature
        case maxTokens = "max_tokens"
    }
}

private actor LocalSSEStreamCollector {
    private var sse = SSELineParser()
    private var think = ThinkTagStreamFilter()
    private var accumulated = ""
    private var rawFallback = Data()
    private let maxFallbackBytes = 65_536

    func push(_ chunk: Data, onDelta: @Sendable (String) async -> Void) async {
        if !sse.sawDataLine && rawFallback.count < maxFallbackBytes {
            rawFallback.append(chunk.prefix(maxFallbackBytes - rawFallback.count))
        }
        for payload in sse.push(chunk) {
            await handlePayload(payload, onDelta: onDelta)
        }
    }

    func finish(onDelta: @Sendable (String) async -> Void) async -> (text: String, sawSSE: Bool, rawFallback: Data) {
        for payload in sse.finish() {
            await handlePayload(payload, onDelta: onDelta)
        }
        let trailing = think.finish()
        if !trailing.isEmpty {
            accumulated.append(trailing)
            await onDelta(trailing)
        }
        return (accumulated, sse.sawDataLine, rawFallback)
    }

    private func handlePayload(_ payload: String, onDelta: @Sendable (String) async -> Void) async {
        guard let rawDelta = LocalOpenAIBackend.extractSSEDelta(from: payload), !rawDelta.isEmpty else { return }
        let visible = think.push(rawDelta)
        if !visible.isEmpty {
            accumulated.append(visible)
            await onDelta(visible)
        }
    }
}

private struct ChatPrompt: Codable {
    let role: String
    let content: String
}

/// Local-only. `json_object` plus a tiny prompt; UUIDs never go to the model.
private struct ChatResponseFormat: Encodable {
    let type = "json_object"
}
