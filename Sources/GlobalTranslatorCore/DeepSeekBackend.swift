import Foundation

public struct DeepSeekBackend: VisionTranslationBackend, Sendable {
    private static let endpointURL = URL(string: "https://api.deepseek.com")!

    public static let defaultModel = AppConfiguration.defaultDeepSeekModel
    /// Official DeepSeek docs (2026-10): only deepseek-flash accepts
    /// `input_image` content parts. This build supports no other cloud model.
    public static let visionModel = "deepseek-flash"
    public static let maximumVisionImages = 8
    public static let maximumVisionImageBytes = 4_194_304
    public static let maximumVisionTotalImageBytes = 16_777_216

    public let kind: BackendKind = .deepSeekCloud
    public let model: String

    private let transport: any HTTPTransport
    private let credentialStore: any CredentialStoring
    private let usageStore: DeepSeekUsageStore

    public init(
        transport: any HTTPTransport = URLSessionHTTPTransport(),
        credentialStore: any CredentialStoring = MacOSKeychainStore(),
        model: String = AppConfiguration.defaultDeepSeekModel,
        usageStore: DeepSeekUsageStore = .shared
    ) {
        self.transport = transport
        self.credentialStore = credentialStore
        self.model = AppConfiguration.resolvedDeepSeekModel(model)
        self.usageStore = usageStore
    }

    public func healthCheck() async -> BackendHealth {
        let apiKey: String?
        do {
            apiKey = try credentialStore.read()
        } catch {
            return BackendHealth(status: .unavailable, message: "DeepSeek health check failed")
        }
        guard let apiKey, !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return BackendHealth(status: .invalidCredentials, message: "DeepSeek API key is not configured")
        }
        do {
            let discovered = try await listModels(apiKey: apiKey)
            // This build intentionally supports only deepseek-flash. Do not
            // surface deepseek-v4-pro or unknown IDs in Settings even if the
            // account's /models response includes them.
            let models = discovered.filter(AppConfiguration.isSupportedDeepSeekModel)
            guard !models.isEmpty else {
                return BackendHealth(
                    status: .modelUnavailable,
                    message: "deepseek-flash is not available for this account",
                    availableModels: models
                )
            }
            let resolved = AppConfiguration.resolvedDeepSeekModel(model)
            guard models.contains(resolved) else {
                return BackendHealth(status: .modelUnavailable, message: "Selected DeepSeek model is unavailable", availableModels: models)
            }
            return BackendHealth(status: .healthy, message: "DeepSeek 后端已就绪", availableModels: models)
        } catch let error as TranslationError {
            return health(for: error)
        } catch {
            return BackendHealth(status: .unavailable, message: "DeepSeek health check failed")
        }
    }

    public func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        try TranslationRequestValidator.validate(request)
        let apiKey: String?
        do {
            apiKey = try credentialStore.read()
        } catch {
            throw TranslationError.networkFailure
        }
        guard let apiKey, !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranslationError.missingCredential
        }
        let body = try makePayload(for: request)
        var urlRequest = URLRequest(url: Self.endpointURL.appendingPathComponent("responses"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = body
        let startedAt = ProcessInfo.processInfo.systemUptime
        let requestedAt = Date()
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
            throw TranslationError.invalidResponse("unexpected DeepSeek HTTP status")
        }
        recordUsage(from: response.body, startedAt: startedAt, requestedAt: requestedAt)
        return try TranslationResponseParser.parseResponses(
            response.body,
            expectedIDs: request.items.map { $0.id },
            windowRevision: request.windowRevision
        )
    }

    public func completePlain(system: String, user: String) async throws -> String {
        let trimmedSystem = system.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUser = user.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSystem.isEmpty, !trimmedUser.isEmpty else {
            throw TranslationError.invalidRequest("plain completion is empty")
        }
        let apiKey: String?
        do {
            apiKey = try credentialStore.read()
        } catch {
            throw TranslationError.networkFailure
        }
        guard let apiKey, !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranslationError.missingCredential
        }
        let body = try makePlainPayload(system: trimmedSystem, user: trimmedUser)
        var urlRequest = URLRequest(url: Self.endpointURL.appendingPathComponent("responses"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = body
        let startedAt = ProcessInfo.processInfo.systemUptime
        let requestedAt = Date()
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
            throw TranslationError.invalidResponse("unexpected DeepSeek HTTP status")
        }
        recordUsage(from: response.body, startedAt: startedAt, requestedAt: requestedAt)
        return try TranslationResponseParser.parsePlainResponses(response.body)
    }

    public func translate(
        _ request: TranslationRequest,
        images: [VisionTranslationImage]
    ) async throws -> TranslationResult {
        try TranslationRequestValidator.validate(request)
        try validate(images: images, request: request)
        let apiKey: String?
        do {
            apiKey = try credentialStore.read()
        } catch {
            throw TranslationError.networkFailure
        }
        guard let apiKey, !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranslationError.missingCredential
        }
        let body = try makeVisionPayload(for: request, images: images)
        var urlRequest = URLRequest(url: Self.endpointURL.appendingPathComponent("responses"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = body
        let startedAt = ProcessInfo.processInfo.systemUptime
        let requestedAt = Date()
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
            throw TranslationError.invalidResponse("unexpected DeepSeek HTTP status")
        }
        recordUsage(from: response.body, startedAt: startedAt, requestedAt: requestedAt)
        return try TranslationResponseParser.parseResponses(
            response.body,
            expectedIDs: request.items.map { $0.id },
            windowRevision: request.windowRevision
        )
    }

    private func listModels(apiKey: String) async throws -> [String] {
        var request = URLRequest(url: Self.endpointURL.appendingPathComponent("models"))
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization")
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
            throw TranslationError.invalidResponse("unexpected DeepSeek models HTTP status")
        }
        do {
            let result = try JSONDecoder().decode(ModelList.self, from: response.body)
            return result.data.map { $0.id }
        } catch {
            throw TranslationError.invalidResponse("DeepSeek models response is invalid")
        }
    }

    private func makePayload(for request: TranslationRequest) throws -> Data {
        let direction = SelectionTranslationDirection(targetLanguage: request.targetLanguage) ?? .toChinese
        let userContent = try TranslationInstructions.userContent(for: Self.stablePromptOrder(request.items))
        let payload = ResponsesPayload(
            model: model,
            input: [
                ResponseInputMessage(role: "system", content: TranslationInstructions.system(for: direction)),
                ResponseInputMessage(role: "user", content: userContent)
            ],
            text: ResponsesText(format: JSONSchemaFormat(schema: TranslationSchema.object))
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
        let payload = PlainResponsesPayload(
            model: model,
            input: [
                ResponseInputMessage(role: "system", content: system),
                ResponseInputMessage(role: "user", content: user)
            ]
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(payload)
        } catch {
            throw TranslationError.invalidRequest("unable to encode plain completion")
        }
    }

    private func validate(images: [VisionTranslationImage], request: TranslationRequest) throws {
        guard images.count <= Self.maximumVisionImages else {
            throw TranslationError.invalidRequest("vision request has too many images")
        }
        let expectedIDs = Set(request.items.map(\.id))
        var seenIDs = Set<UUID>()
        var totalBytes = 0
        for image in images {
            guard image.mime == "image/png" else {
                throw TranslationError.invalidRequest("vision image must be PNG")
            }
            guard expectedIDs.contains(image.segmentId), seenIDs.insert(image.segmentId).inserted else {
                throw TranslationError.invalidRequest("vision image segment ID is invalid")
            }
            guard image.pngData.count >= 8,
                  Array(image.pngData.prefix(8)) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] else {
                throw TranslationError.invalidRequest("vision image is not PNG")
            }
            guard image.pngData.count <= Self.maximumVisionImageBytes else {
                throw TranslationError.invalidRequest("vision image is too large")
            }
            totalBytes += image.pngData.count
            guard totalBytes <= Self.maximumVisionTotalImageBytes else {
                throw TranslationError.invalidRequest("vision images are too large")
            }
        }
    }

    private func makeVisionPayload(
        for request: TranslationRequest,
        images: [VisionTranslationImage]
    ) throws -> Data {
        let direction = SelectionTranslationDirection(targetLanguage: request.targetLanguage) ?? .toChinese
        let userText = try TranslationInstructions.userContent(for: Self.stablePromptOrder(request.items))
        var userContent: [VisionContentPart] = [.inputText(userText)]
        for image in images.sorted(by: { $0.segmentId.uuidString < $1.segmentId.uuidString }) {
            userContent.append(.inputText("segmentId=\(image.segmentId.uuidString)"))
            userContent.append(.inputImage(
                imageURL: "data:\(image.mime);base64,\(image.pngData.base64EncodedString())",
                detail: "low"
            ))
        }
        let payload = VisionResponsesPayload(
            model: Self.visionModel,
            input: [
                VisionResponseInputMessage(role: "system", content: [.inputText(TranslationInstructions.system(for: direction))]),
                VisionResponseInputMessage(role: "user", content: userContent)
            ],
            text: ResponsesText(format: JSONSchemaFormat(schema: TranslationSchema.object))
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(payload)
        } catch {
            throw TranslationError.invalidRequest("unable to encode vision translation request")
        }
    }

    /// Canonical item order makes an unchanged screen batch byte-identical.
    /// The model maps results by segment ID, so display order is unaffected.
    private static func stablePromptOrder(_ items: [TranslationItem]) -> [TranslationItem] {
        items.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    private func recordUsage(from body: Data, startedAt: TimeInterval, requestedAt: Date) {
        guard let usage = DeepSeekUsageParser.parse(body) else { return }
        usageStore.record(
            usage: usage,
            model: model,
            durationSeconds: ProcessInfo.processInfo.systemUptime - startedAt,
            requestedAt: requestedAt
        )
    }

    private func health(for error: TranslationError) -> BackendHealth {
        switch error {
        case .unauthorized, .forbidden:
            return BackendHealth(status: .invalidCredentials, message: "DeepSeek credentials were rejected")
        case .modelUnavailable:
            return BackendHealth(status: .modelUnavailable, message: "Selected DeepSeek model is unavailable")
        case .invalidConfiguration:
            return BackendHealth(status: .invalidConfiguration, message: "DeepSeek configuration is invalid")
        default:
            return BackendHealth(status: .unavailable, message: "DeepSeek health check failed")
        }
    }
}

/// DeepSeek Responses API: nested `reasoning.effort` disables thinking.
/// A flat `reasoning_effort` is ignored by V4 / vision models, which then
/// burn `max_output_tokens` on reasoning and return no `message`.
private struct ResponsesReasoning: Encodable {
    let effort = "none"
}

private struct ResponsesPayload: Encodable {
    let model: String
    let input: [ResponseInputMessage]
    let stream = false
    let reasoning = ResponsesReasoning()
    let temperature = 0.1
    let maxOutputTokens = 8_192
    let text: ResponsesText

    private enum CodingKeys: String, CodingKey {
        case model
        case input
        case stream
        case reasoning
        case temperature
        case maxOutputTokens = "max_output_tokens"
        case text
    }
}

private struct ResponsesText: Encodable {
    let format: JSONSchemaFormat
}

private struct PlainResponsesPayload: Encodable {
    let model: String
    let input: [ResponseInputMessage]
    let stream = false
    let reasoning = ResponsesReasoning()
    let temperature = 0.3
    let maxOutputTokens = 2_048

    private enum CodingKeys: String, CodingKey {
        case model
        case input
        case stream
        case reasoning
        case temperature
        case maxOutputTokens = "max_output_tokens"
    }
}

private struct VisionResponsesPayload: Encodable {
    let model: String
    let input: [VisionResponseInputMessage]
    let stream = false
    let reasoning = ResponsesReasoning()
    let temperature = 0.1
    let maxOutputTokens = 8_192
    let text: ResponsesText

    private enum CodingKeys: String, CodingKey {
        case model
        case input
        case stream
        case reasoning
        case temperature
        case maxOutputTokens = "max_output_tokens"
        case text
    }
}

private struct VisionResponseInputMessage: Encodable {
    let role: String
    let content: [VisionContentPart]
}

private enum VisionContentPart: Encodable {
    case inputText(String)
    case inputImage(imageURL: String, detail: String)

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case imageURL = "image_url"
        case detail
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .inputText(let text):
            try container.encode("input_text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .inputImage(let imageURL, let detail):
            try container.encode("input_image", forKey: .type)
            try container.encode(imageURL, forKey: .imageURL)
            try container.encode(detail, forKey: .detail)
        }
    }
}
