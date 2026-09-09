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
            return BackendHealth(status: .healthy, message: "Local backend is ready", availableModels: models)
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
                mode: .localRelaxed
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

    /// Caps generation so a short UI string does not walk toward the
    /// Modelfile `num_predict` default. One translation JSON object fits in
    /// 128 tokens; three items still fit in 256.
    static func maxTokens(itemCount: Int) -> Int {
        min(256, 64 + 64 * max(itemCount, 1))
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
        let payload = ChatPayload(
            model: model,
            messages: [
                ChatPrompt(role: "system", content: LocalTranslationPrompt.system),
                ChatPrompt(role: "user", content: LocalTranslationPrompt.userContent(for: request.items))
            ],
            maxTokens: Self.maxTokens(itemCount: request.items.count),
            responseFormat: ChatResponseFormat()
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(payload)
        } catch {
            throw TranslationError.invalidRequest("unable to encode translation request")
        }
    }

    private func makePlainPayload(system: String, user: String) throws -> Data {
        let payload = PlainChatPayload(
            model: model,
            messages: [
                ChatPrompt(role: "system", content: system),
                ChatPrompt(role: "user", content: user)
            ],
            maxTokens: Self.plainCompletionMaxTokens
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(payload)
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
    let stream = false
    let temperature = 0.3
    let maxTokens: Int

    private enum CodingKeys: String, CodingKey {
        case model
        case messages
        case stream
        case temperature
        case maxTokens = "max_tokens"
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
