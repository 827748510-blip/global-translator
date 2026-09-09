import Foundation

enum TranslationRequestValidator {
    static let maximumItems = 24
    static let maximumSourceCharacters = 4_000
    static let maximumOutputCharacters = 4_000

    static func validate(_ request: TranslationRequest) throws {
        guard !request.items.isEmpty else {
            throw TranslationError.invalidRequest("translation request is empty")
        }
        guard request.items.count <= maximumItems else {
            throw TranslationError.invalidRequest("translation request has too many items")
        }
        guard Set(request.items.map { $0.id }).count == request.items.count else {
            throw TranslationError.invalidRequest("translation request has duplicate segment IDs")
        }
        let totalCharacters = request.items.reduce(into: 0) { total, item in
            total += item.sourceText.count
        }
        guard totalCharacters <= maximumSourceCharacters else {
            throw TranslationError.invalidRequest("translation request is too large")
        }
        guard request.items.allSatisfy({ !$0.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw TranslationError.invalidRequest("translation request contains empty source text")
        }
    }
}

struct PromptSegment: Encodable {
    let segmentId: UUID
    let sourceText: String

    init(item: TranslationItem) {
        segmentId = item.id
        sourceText = item.sourceText
    }
}

struct JSONSchemaFormat: Encodable {
    let type = "json_schema"
    let name = "translation_result"
    let strict = true
    let schema: JSONSchemaObject
}

struct JSONSchemaObject: Encodable {
    let type = "object"
    let properties: [String: JSONSchemaProperty]
    let required: [String]
    let additionalProperties = false

    init(properties: [String: JSONSchemaProperty], required: [String]) {
        self.properties = properties
        self.required = required
    }
}

struct JSONSchemaProperty: Encodable {
    let type: String
    let items: JSONSchemaObject?
    let properties: [String: JSONSchemaProperty]?
    let required: [String]?
    let additionalProperties: Bool?
    let allowedValues: [String]?
    let minItems: Int?
    let maxItems: Int?

    private enum CodingKeys: String, CodingKey {
        case type, items, properties, required, additionalProperties, minItems, maxItems
        case allowedValues = "enum"
    }

    static func translations(segmentIDs: [UUID]? = nil) -> JSONSchemaProperty {
        JSONSchemaProperty(
            type: "array",
            items: JSONSchemaObject(
                properties: [
                    "segmentId": JSONSchemaProperty(type: "string", items: nil, properties: nil, required: nil, additionalProperties: nil, allowedValues: segmentIDs?.map(\.uuidString)),
                    "text": JSONSchemaProperty(type: "string", items: nil, properties: nil, required: nil, additionalProperties: nil)
                ],
                required: ["segmentId", "text"]
            ),
            properties: nil,
            required: nil,
            additionalProperties: nil,
            minItems: segmentIDs?.count,
            maxItems: segmentIDs?.count
        )
    }

    init(
        type: String,
        items: JSONSchemaObject?,
        properties: [String: JSONSchemaProperty]?,
        required: [String]?,
        additionalProperties: Bool?,
        allowedValues: [String]? = nil,
        minItems: Int? = nil,
        maxItems: Int? = nil
    ) {
        self.type = type
        self.items = items
        self.properties = properties
        self.required = required
        self.additionalProperties = additionalProperties
        self.allowedValues = allowedValues
        self.minItems = minItems
        self.maxItems = maxItems
    }
}

enum TranslationSchema {
    static let object = JSONSchemaObject(
        properties: ["translations": .translations()],
        required: ["translations"]
    )

    static func object(segmentIDs: [UUID]) -> JSONSchemaObject {
        JSONSchemaObject(properties: ["translations": .translations(segmentIDs: segmentIDs)], required: ["translations"])
    }
}

enum TranslationParseMode {
    /// Cloud: require the canonical object, exact IDs, no extra fields.
    case strict
    /// Local `json_object`: accept a translations object or a bare array,
    /// ignore extra fields, and fall back to input order when IDs were rewritten.
    case localRelaxed
}

enum TranslationResponseParser {
    private struct ResponsesEnvelope: Decodable {
        let output: [ResponsesOutput]
    }

    private struct ResponsesOutput: Decodable {
        let type: String
        let content: [ResponsesContent]
    }

    private struct ResponsesContent: Decodable {
        let type: String
        let text: String
    }

    private struct ChatEnvelope: Decodable {
        let choices: [ChatChoice]
    }

    private struct ChatChoice: Decodable {
        let message: ChatMessage
    }

    private struct ChatMessage: Decodable {
        let content: String
    }

    private struct TranslationEnvelope: Decodable {
        let translations: [ExternalTranslation]

        private enum CodingKeys: String, CodingKey {
            case translations
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            guard Set(container.allKeys) == Set([.translations]) else {
                throw TranslationError.invalidResponse("translation response contains unknown fields")
            }
            translations = try container.decode([ExternalTranslation].self, forKey: .translations)
        }
    }

    private struct ExternalTranslation: Decodable {
        let segmentId: UUID
        let text: String

        private enum CodingKeys: String, CodingKey {
            case segmentId
            case text
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            guard Set(container.allKeys) == Set([.segmentId, .text]) else {
                throw TranslationError.invalidResponse("translation item contains unknown fields")
            }
            segmentId = try container.decode(UUID.self, forKey: .segmentId)
            text = try container.decode(String.self, forKey: .text)
        }
    }

    static func parseResponses(
        _ data: Data,
        expectedIDs: [UUID],
        windowRevision: UInt64 = 0
    ) throws -> TranslationResult {
        do {
            let envelope = try JSONDecoder().decode(ResponsesEnvelope.self, from: data)
            let messages = envelope.output.filter { $0.type == "message" }
            guard envelope.output.allSatisfy({ $0.type == "message" || $0.type == "reasoning" }),
                  messages.count == 1, let output = messages.first else {
                throw TranslationError.invalidResponse("response output message is missing or ambiguous")
            }
            guard output.content.count == 1, let content = output.content.first, content.type == "output_text" else {
                throw TranslationError.invalidResponse("response output_text is missing or ambiguous")
            }
            return try parseTranslationJSON(Data(content.text.utf8), expectedIDs: expectedIDs, windowRevision: windowRevision)
        } catch let error as TranslationError {
            throw error
        } catch {
            throw TranslationError.invalidResponse("response JSON is invalid")
        }
    }

    static func parseChatCompletions(
        _ data: Data,
        expectedIDs: [UUID],
        windowRevision: UInt64 = 0,
        mode: TranslationParseMode = .strict
    ) throws -> TranslationResult {
        do {
            let envelope = try JSONDecoder().decode(ChatEnvelope.self, from: data)
            guard envelope.choices.count == 1 else {
                throw TranslationError.invalidResponse("chat response choices are missing or ambiguous")
            }
            let payload = mode == .localRelaxed
                ? unwrapJSONPayload(envelope.choices[0].message.content)
                : Data(envelope.choices[0].message.content.utf8)
            return try parseTranslationJSON(
                payload,
                expectedIDs: expectedIDs,
                windowRevision: windowRevision,
                mode: mode
            )
        } catch let error as TranslationError {
            throw error
        } catch {
            throw TranslationError.invalidResponse("chat response JSON is invalid")
        }
    }

    private static func unwrapJSONPayload(_ raw: String) -> Data {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            if let newline = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: newline)...])
            }
            if let fence = text.range(of: "```", options: .backwards) {
                text = String(text[..<fence.lowerBound])
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let objectStart = text.firstIndex(of: "{"),
           let arrayStart = text.firstIndex(of: "["),
           arrayStart < objectStart,
           let end = text.lastIndex(of: "]") {
            text = String(text[arrayStart...end])
        } else if let objectStart = text.firstIndex(of: "{"),
                  let end = text.lastIndex(of: "}") {
            text = String(text[objectStart...end])
        } else if let arrayStart = text.firstIndex(of: "["),
                  let end = text.lastIndex(of: "]") {
            text = String(text[arrayStart...end])
        }
        return Data(text.utf8)
    }

    private static func parseTranslationJSON(
        _ data: Data,
        expectedIDs: [UUID],
        windowRevision: UInt64,
        mode: TranslationParseMode = .strict
    ) throws -> TranslationResult {
        if mode == .localRelaxed {
            return try parseLocalTranslationJSON(data, expectedIDs: expectedIDs, windowRevision: windowRevision)
        }
        do {
            let envelope = try JSONDecoder().decode(TranslationEnvelope.self, from: data)
            guard envelope.translations.count == expectedIDs.count else {
                throw TranslationError.invalidResponse("translation count does not match request")
            }
            let expected = Set(expectedIDs)
            let actual = envelope.translations.map(\.segmentId)
            guard Set(actual).count == actual.count else {
                throw TranslationError.invalidResponse("translation IDs are duplicated")
            }
            guard Set(actual) == expected else {
                throw TranslationError.invalidResponse("translation IDs do not match request")
            }
            guard envelope.translations.allSatisfy({
                let text = $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return !text.isEmpty && text.count <= TranslationRequestValidator.maximumOutputCharacters
            }) else {
                throw TranslationError.invalidResponse("translation text is empty or too long")
            }
            let translations = envelope.translations.map {
                Translation(segmentId: $0.segmentId, simplifiedChineseText: $0.text)
            }
            return TranslationResult(windowRevision: windowRevision, translations: translations)
        } catch let error as TranslationError {
            throw error
        } catch {
            throw TranslationError.invalidResponse("translation JSON is invalid")
        }
    }

    private struct LocalTranslationItem {
        let segmentId: UUID?
        let text: String
    }

    private static func parseLocalTranslationJSON(
        _ data: Data,
        expectedIDs: [UUID],
        windowRevision: UInt64
    ) throws -> TranslationResult {
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw TranslationError.invalidResponse("translation JSON is invalid")
        }
        let items = try localItems(from: json)
        guard items.count == expectedIDs.count else {
            throw TranslationError.invalidResponse("translation count does not match request")
        }
        guard items.allSatisfy({
            let text = $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return !text.isEmpty && text.count <= TranslationRequestValidator.maximumOutputCharacters
        }) else {
            throw TranslationError.invalidResponse("translation text is empty or too long")
        }
        let parsedIDs = items.compactMap(\.segmentId)
        if parsedIDs.count == items.count,
           Set(parsedIDs).count == parsedIDs.count,
           Set(parsedIDs) == Set(expectedIDs) {
            let translations = zip(items, parsedIDs).map {
                Translation(segmentId: $0.1, simplifiedChineseText: $0.0.text)
            }
            return TranslationResult(windowRevision: windowRevision, translations: translations)
        }
        let translations = zip(expectedIDs, items).map {
            Translation(segmentId: $0.0, simplifiedChineseText: $0.1.text)
        }
        return TranslationResult(windowRevision: windowRevision, translations: translations)
    }

    private static func localItems(from json: Any) throws -> [LocalTranslationItem] {
        if let object = json as? [String: Any] {
            guard let translations = object["translations"] else {
                throw TranslationError.invalidResponse("translation JSON is invalid")
            }
            return try decodeLocalItems(translations)
        }
        return try decodeLocalItems(json)
    }

    private static func decodeLocalItems(_ json: Any) throws -> [LocalTranslationItem] {
        if let objects = json as? [[String: Any]] {
            return try objects.map { object in
                guard let text = object["text"] as? String else {
                    throw TranslationError.invalidResponse("translation JSON is invalid")
                }
                let segmentId: UUID?
                if let raw = object["segmentId"] as? String {
                    segmentId = UUID(uuidString: raw)
                } else {
                    segmentId = nil
                }
                return LocalTranslationItem(segmentId: segmentId, text: text)
            }
        }
        if let strings = json as? [String] {
            return strings.map { LocalTranslationItem(segmentId: nil, text: $0) }
        }
        throw TranslationError.invalidResponse("translation JSON is invalid")
    }
}

enum AdapterHTTPMapping {
    static func error(for response: HTTPResponse) -> TranslationError? {
        switch response.statusCode {
        case 401:
            return .unauthorized
        case 403:
            return .forbidden
        case 429:
            return .rateLimited(retryAfter: retryAfter(from: response.header("Retry-After")))
        case 500...599:
            return .serverFailure(statusCode: response.statusCode)
        default:
            return nil
        }
    }

    static func error(for transportError: Error) -> TranslationError {
        if let error = transportError as? HTTPTransportError {
            switch error {
            case .redirectRejected:
                return .redirectRejected
            case .timeout:
                return .timeout
            case .responseTooLarge, .invalidResponse:
                return .invalidResponse("response body is too large")
            case .networkFailure:
                return .networkFailure
            }
        }
        return .networkFailure
    }

    private static func retryAfter(from value: String?) -> TimeInterval? {
        guard let value, let seconds = TimeInterval(value.trimmingCharacters(in: .whitespacesAndNewlines)), seconds >= 0 else {
            return nil
        }
        return seconds
    }
}

struct ModelList: Decodable {
    struct Model: Decodable {
        let id: String
    }

    let data: [Model]
}
