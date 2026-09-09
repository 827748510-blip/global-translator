import Foundation

public struct DeepSeekBackend: VisionTranslationBackend, Sendable {
    private static let endpointURL = URL(string: "https://api.deepseek.com")!
    private static let requiredModel = "deepseek-v4-flash-vision-exp"

    public static let maximumVisionImages = 8
    public static let maximumVisionImageBytes = 4_194_304
    public static let maximumVisionTotalImageBytes = 16_777_216

    public let kind: BackendKind = .deepSeekCloud

    private let transport: any HTTPTransport
    private let credentialStore: any CredentialStoring

    public init(
        transport: any HTTPTransport = URLSessionHTTPTransport(),
        credentialStore: any CredentialStoring = MacOSKeychainStore()
    ) {
        self.transport = transport
        self.credentialStore = credentialStore
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
            let models = try await listModels(apiKey: apiKey)
            guard models.contains(Self.requiredModel) else {
                return BackendHealth(status: .modelUnavailable, message: "Required DeepSeek model is unavailable", availableModels: models)
            }
            return BackendHealth(status: .healthy, message: "DeepSeek backend is ready", availableModels: models)
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
        urlRequest.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization")
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
            throw TranslationError.invalidResponse("unexpected DeepSeek HTTP status")
        }
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
        urlRequest.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization")
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
            throw TranslationError.invalidResponse("unexpected DeepSeek HTTP status")
        }
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
        urlRequest.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization")
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
            throw TranslationError.invalidResponse("unexpected DeepSeek HTTP status")
        }
        return try TranslationResponseParser.parseResponses(
            response.body,
            expectedIDs: request.items.map { $0.id },
            windowRevision: request.windowRevision
        )
    }

    private func listModels(apiKey: String) async throws -> [String] {
        var request = URLRequest(url: Self.endpointURL.appendingPathComponent("models"))
        request.httpMethod = "GET"
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
        let userContent = try TranslationInstructions.userContent(for: request.items)
        let payload = ResponsesPayload(
            model: Self.requiredModel,
            input: [
                ResponseInputMessage(role: "system", content: TranslationInstructions.system),
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
            model: Self.requiredModel,
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
        let userText = try TranslationInstructions.userContent(for: request.items)
        var userContent: [VisionContentPart] = [.inputText(userText)]
        for image in images {
            userContent.append(.inputText("segmentId=\(image.segmentId.uuidString)"))
            userContent.append(.inputImage(
                imageURL: "data:\(image.mime);base64,\(image.pngData.base64EncodedString())",
                detail: "low"
            ))
        }
        let payload = VisionResponsesPayload(
            model: Self.requiredModel,
            input: [
                VisionResponseInputMessage(role: "system", content: [.inputText(TranslationInstructions.system)]),
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

    private func health(for error: TranslationError) -> BackendHealth {
        switch error {
        case .unauthorized, .forbidden:
            return BackendHealth(status: .invalidCredentials, message: "DeepSeek credentials were rejected")
        case .modelUnavailable:
            return BackendHealth(status: .modelUnavailable, message: "Required DeepSeek model is unavailable")
        case .invalidConfiguration:
            return BackendHealth(status: .invalidConfiguration, message: "DeepSeek configuration is invalid")
        default:
            return BackendHealth(status: .unavailable, message: "DeepSeek health check failed")
        }
    }
}

private struct ResponsesPayload: Encodable {
    let model: String
    let input: [ResponseInputMessage]
    let stream = false
    let reasoningEffort = "none"
    let temperature = 0.1
    let text: ResponsesText

    private enum CodingKeys: String, CodingKey {
        case model
        case input
        case stream
        case reasoningEffort = "reasoning_effort"
        case temperature
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
    let reasoningEffort = "none"
    let temperature = 0.3
    let maxOutputTokens = 1_024

    private enum CodingKeys: String, CodingKey {
        case model
        case input
        case stream
        case reasoningEffort = "reasoning_effort"
        case temperature
        case maxOutputTokens = "max_output_tokens"
    }
}

private struct VisionResponsesPayload: Encodable {
    let model: String
    let input: [VisionResponseInputMessage]
    let stream = false
    let reasoningEffort = "none"
    let temperature = 0.1
    let text: ResponsesText

    private enum CodingKeys: String, CodingKey {
        case model
        case input
        case stream
        case reasoningEffort = "reasoning_effort"
        case temperature
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
