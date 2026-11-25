import Foundation

enum TranslationRequestValidator {
    static let maximumItems = 24
    static let maximumSourceCharacters = 4_000
    /// One selection chunk can emit ~2k Chinese characters at the scaled local `max_tokens`.
    /// Keep it as the floor of `outputCharacterLimit(sourceCharacters:)`.
    static let maximumOutputCharacters = 8_192
    /// 中文→英文的字符增长上限（见 `SelectionTranslationDirection.outputExpansion`）。
    /// 3 倍留出余量：正常译文过得去，模型复读整段的失控输出仍会被拒。
    static let maximumOutputExpansion = 3

    /// 结果长度上限按本次请求的源文长度放大。固定 8192 字的前提是「译文不比源文
    /// 长多少」，而中文译成英文天然膨胀一倍：一段 4000 字的中文源（跨窗口批或
    /// 长选区）译出来就可能超过 8192 字，被误判成 `translation text is empty or too long`。
    static func outputCharacterLimit(sourceCharacters: Int) -> Int {
        guard sourceCharacters > 0 else { return maximumOutputCharacters }
        return max(maximumOutputCharacters, sourceCharacters * maximumOutputExpansion)
    }

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
        let usage: RawUsage?
    }

    struct RawUsage: Decodable {
        let inputTokens: Int
        let cachedTokens: Int
        let outputTokens: Int
        let totalTokens: Int

        private struct InputTokenDetails: Decodable {
            let cachedTokens: Int?
            private enum CodingKeys: String, CodingKey {
                case cachedTokens = "cached_tokens"
            }
        }

        private enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case inputTokensDetails = "input_tokens_details"
            case outputTokens = "output_tokens"
            case totalTokens = "total_tokens"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            inputTokens = try container.decode(Int.self, forKey: .inputTokens)
            outputTokens = try container.decode(Int.self, forKey: .outputTokens)
            let details = try container.decodeIfPresent(InputTokenDetails.self, forKey: .inputTokensDetails)
            cachedTokens = details?.cachedTokens ?? 0
            totalTokens = try container.decodeIfPresent(Int.self, forKey: .totalTokens) ?? (inputTokens + outputTokens)
        }

        var tokenUsage: DeepSeekTokenUsage {
            DeepSeekTokenUsage(
                inputTokens: inputTokens,
                cachedInputTokens: cachedTokens,
                outputTokens: outputTokens,
                totalTokens: totalTokens
            )
        }
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
            let keys = container.allKeys
            guard keys.count == 1, keys.first == .translations else {
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
            let keys = container.allKeys
            guard keys.count == 2, keys.contains(.segmentId), keys.contains(.text) else {
                throw TranslationError.invalidResponse("translation item contains unknown fields")
            }
            segmentId = try container.decode(UUID.self, forKey: .segmentId)
            text = try container.decode(String.self, forKey: .text)
        }
    }

    static func parseResponses(
        _ data: Data,
        expectedIDs: [UUID],
        windowRevision: UInt64 = 0,
        sourceCharacters: Int = 0
    ) throws -> TranslationResult {
        try parseResponsesWithUsage(
            data,
            expectedIDs: expectedIDs,
            windowRevision: windowRevision,
            sourceCharacters: sourceCharacters
        ).result
    }

    static func parseResponsesWithUsage(
        _ data: Data,
        expectedIDs: [UUID],
        windowRevision: UInt64 = 0,
        sourceCharacters: Int = 0
    ) throws -> (result: TranslationResult, usage: DeepSeekTokenUsage?) {
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
            let result = try parseTranslationJSON(
                Data(content.text.utf8),
                expectedIDs: expectedIDs,
                windowRevision: windowRevision,
                sourceCharacters: sourceCharacters
            )
            return (result, envelope.usage?.tokenUsage)
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
        mode: TranslationParseMode = .strict,
        sourceCharacters: Int = 0
    ) throws -> TranslationResult {
        if mode == .localRelaxed {
            return try parseLocalChatCompletions(
                data,
                expectedIDs: expectedIDs,
                windowRevision: windowRevision,
                sourceCharacters: sourceCharacters
            )
        }
        do {
            let envelope = try JSONDecoder().decode(ChatEnvelope.self, from: data)
            guard envelope.choices.count == 1 else {
                throw TranslationError.invalidResponse("chat response choices are missing or ambiguous")
            }
            return try parseTranslationJSON(
                Data(envelope.choices[0].message.content.utf8),
                expectedIDs: expectedIDs,
                windowRevision: windowRevision,
                mode: .strict,
                sourceCharacters: sourceCharacters
            )
        } catch let error as TranslationError {
            throw error
        } catch {
            throw TranslationError.invalidResponse("chat response JSON is invalid")
        }
    }

    static func parsePlainChatCompletions(_ data: Data) throws -> String {
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw TranslationError.invalidResponse("chat response JSON is invalid")
        }
        return try parsePlainCompletionText(extractAssistantContent(from: root))
    }

    static func parsePlainResponses(_ data: Data) throws -> String {
        try parsePlainResponsesWithUsage(data).text
    }

    static func parsePlainResponsesWithUsage(_ data: Data) throws -> (text: String, usage: DeepSeekTokenUsage?) {
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
            return (try parsePlainCompletionText(content.text), envelope.usage?.tokenUsage)
        } catch let error as TranslationError {
            throw error
        } catch {
            throw TranslationError.invalidResponse("response JSON is invalid")
        }
    }

    static func parsePlainCompletionText(_ raw: String) throws -> String {
        var text = stripThinkTags(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            if let newline = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: newline)...])
            }
            if let fence = text.range(of: "```", options: .backwards) {
                text = String(text[..<fence.lowerBound])
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !text.isEmpty else {
            throw TranslationError.invalidResponse("plain completion is empty")
        }
        return text
    }

    private static func parseLocalChatCompletions(
        _ data: Data,
        expectedIDs: [UUID],
        windowRevision: UInt64,
        sourceCharacters: Int = 0
    ) throws -> TranslationResult {
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw TranslationError.invalidResponse("chat response JSON is invalid")
        }
        let content = try extractAssistantContent(from: root)
        return try parseLocalTranslationJSON(
            unwrapJSONPayload(stripThinkTags(content)),
            expectedIDs: expectedIDs,
            windowRevision: windowRevision,
            sourceCharacters: sourceCharacters
        )
    }

    private static func extractAssistantContent(from json: Any) throws -> String {
        guard let root = json as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let choice = choices.first else {
            throw TranslationError.invalidResponse("chat response JSON is invalid")
        }
        if let message = choice["message"] as? [String: Any],
           let content = stringifyContent(message["content"]) {
            return content
        }
        if let text = stringifyContent(choice["text"]) {
            return text
        }
        throw TranslationError.invalidResponse("chat response JSON is invalid")
    }

    private static func stringifyContent(_ value: Any?) -> String? {
        if let text = value as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        if let parts = value as? [[String: Any]],
           parts.contains(where: { ($0["type"] as? String)?.isEmpty == false }) {
            let joined = parts.compactMap { $0["text"] as? String }.joined()
            if !joined.isEmpty { return joined }
        }
        if let object = value as? [String: Any],
           JSONSerialization.isValidJSONObject(object),
           let data = try? JSONSerialization.data(withJSONObject: object),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        if let array = value as? [Any],
           JSONSerialization.isValidJSONObject(array),
           let data = try? JSONSerialization.data(withJSONObject: array),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return nil
    }

    private static let thinkTagsRegex = try! NSRegularExpression(pattern: #"<think>[\s\S]*?</think>"#)
    private static let trailingCommaRegex = try! NSRegularExpression(pattern: #",(\s*[}\]])"#)
    private static let compactIndexRegex = try! NSRegularExpression(pattern: #"^(\d+)(?:\s*[：:.]|[-_])"#)

    private static func stripThinkTags(_ raw: String) -> String {
        guard raw.contains("<think>") else { return raw }
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        return thinkTagsRegex.stringByReplacingMatches(in: raw, options: [], range: range, withTemplate: "")
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
        if text.contains(",") {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            text = trailingCommaRegex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "$1")
        }
        return Data(text.utf8)
    }

    private static func parseTranslationJSON(
        _ data: Data,
        expectedIDs: [UUID],
        windowRevision: UInt64,
        mode: TranslationParseMode = .strict,
        sourceCharacters: Int = 0
    ) throws -> TranslationResult {
        if mode == .localRelaxed {
            return try parseLocalTranslationJSON(
                data,
                expectedIDs: expectedIDs,
                windowRevision: windowRevision,
                sourceCharacters: sourceCharacters
            )
        }
        var recoverable: TranslationError?
        do {
            return try parseStrictTranslationJSON(
                data,
                expectedIDs: expectedIDs,
                windowRevision: windowRevision,
                sourceCharacters: sourceCharacters
            )
        } catch let error as TranslationError {
            if isRecoverableTranslationJSONError(error) {
                recoverable = error
            } else {
                throw error
            }
        } catch {
            recoverable = TranslationError.invalidResponse("translation JSON is invalid")
        }

        let candidates = translationJSONCandidates(data)
        for candidate in candidates where candidate != data {
            do {
                return try parseStrictTranslationJSON(
                    candidate,
                    expectedIDs: expectedIDs,
                    windowRevision: windowRevision,
                    sourceCharacters: sourceCharacters
                )
            } catch let error as TranslationError {
                if isRecoverableTranslationJSONError(error) {
                    recoverable = error
                    continue
                }
                throw error
            } catch {
                recoverable = TranslationError.invalidResponse("translation JSON is invalid")
            }
        }
        for candidate in candidates {
            do {
                return try parseLocalTranslationJSON(
                    candidate,
                    expectedIDs: expectedIDs,
                    windowRevision: windowRevision,
                    sourceCharacters: sourceCharacters
                )
            } catch {
                continue
            }
        }
        throw recoverable ?? TranslationError.invalidResponse("translation JSON is invalid")
    }

    private static func parseStrictTranslationJSON(
        _ data: Data,
        expectedIDs: [UUID],
        windowRevision: UInt64,
        sourceCharacters: Int = 0
    ) throws -> TranslationResult {
        do {
            let envelope = try JSONDecoder().decode(TranslationEnvelope.self, from: data)
            guard envelope.translations.count == expectedIDs.count else {
                throw TranslationError.invalidResponse("translation count does not match request")
            }
            let expected = Set(expectedIDs)
            var actualSet = Set<UUID>()
            actualSet.reserveCapacity(envelope.translations.count)
            for translation in envelope.translations {
                guard actualSet.insert(translation.segmentId).inserted else {
                    throw TranslationError.invalidResponse("translation IDs are duplicated")
                }
            }
            guard actualSet == expected else {
                throw TranslationError.invalidResponse("translation IDs do not match request")
            }
            let characterLimit = TranslationRequestValidator.outputCharacterLimit(sourceCharacters: sourceCharacters)
            guard envelope.translations.allSatisfy({
                let text = $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return !text.isEmpty && text.count <= characterLimit
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

    /// Markdown fences, compact `{"0":"..."}` keys, and extra wrapper fields
    /// used to surface as `translation JSON is invalid` and 500 the video cue
    /// batch. Semantic mismatches (count / IDs / empty text) stay fatal.
    private static func isRecoverableTranslationJSONError(_ error: TranslationError) -> Bool {
        guard case .invalidResponse(let message) = error else { return false }
        return message == "translation JSON is invalid"
            || message == "translation response contains unknown fields"
            || message == "translation item contains unknown fields"
    }

    private static func translationJSONCandidates(_ data: Data) -> [Data] {
        var seen = Set<Data>()
        var list: [Data] = []
        func add(_ next: Data) {
            guard !next.isEmpty, seen.insert(next).inserted else { return }
            list.append(next)
        }
        add(data)
        let raw = String(decoding: data, as: UTF8.self)
        if let stripped = stripMarkdownFence(raw) {
            add(Data(stripped.utf8))
        }
        if let object = firstJSONValue(in: raw) {
            add(Data(object.utf8))
        }
        return list
    }

    private static func stripMarkdownFence(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```") else { return nil }
        var body = trimmed.dropFirst(3)
        let lowered = body.lowercased()
        if lowered.hasPrefix("json") {
            body = body.dropFirst(4)
        }
        if let end = body.range(of: "```") {
            body = body[..<end.lowerBound]
        }
        let inner = String(body).trimmingCharacters(in: .whitespacesAndNewlines)
        return inner.isEmpty ? nil : inner
    }

    private static func firstJSONValue(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(where: { $0 == "{" || $0 == "[" }) else { return nil }
        let opening = trimmed[start]
        let closing: Character = opening == "{" ? "}" : "]"
        var depth = 0
        var inString = false
        var escape = false
        var end = start
        var index = start
        while index < trimmed.endIndex {
            let character = trimmed[index]
            if inString {
                if escape {
                    escape = false
                } else if character == "\\" {
                    escape = true
                } else if character == "\"" {
                    inString = false
                }
            } else if character == "\"" {
                inString = true
            } else if character == opening {
                depth += 1
            } else if character == closing {
                depth -= 1
                if depth == 0 {
                    end = index
                    break
                }
            }
            index = trimmed.index(after: index)
        }
        guard depth == 0 else { return nil }
        let value = String(trimmed[start...end]).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || value == trimmed ? nil : value
    }

    private static func parseLocalTranslationJSON(
        _ data: Data,
        expectedIDs: [UUID],
        windowRevision: UInt64,
        sourceCharacters: Int = 0
    ) throws -> TranslationResult {
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data)
        } catch {
            let trimmed = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let texts = recoverMalformedCompactJSON(trimmed, count: expectedIDs.count)
                ?? fallbackTexts(fromRaw: trimmed, count: expectedIDs.count) {
                return try localResult(
                    texts: texts,
                    expectedIDs: expectedIDs,
                    windowRevision: windowRevision,
                    sourceCharacters: sourceCharacters
                )
            }
            throw TranslationError.invalidResponse("translation JSON is invalid")
        }
        let texts = try extractLocalTexts(json, count: expectedIDs.count)
        return try localResult(
            texts: texts,
            expectedIDs: expectedIDs,
            windowRevision: windowRevision,
            sourceCharacters: sourceCharacters
        )
    }

    private static func fallbackTexts(fromRaw trimmed: String, count: Int) -> [String]? {
        guard !trimmed.isEmpty, !trimmed.hasPrefix("{"), !trimmed.hasPrefix("[") else { return nil }
        if count == 1 { return [trimmed] }
        return LocalTranslationCleanup.splitNumberedBlob(trimmed, count: count)
    }

    private static let compactKeyValueRegex = try! NSRegularExpression(
        pattern: #""([^"\\]+)"\s*:\s*"((?:[^"\\]|\\.)*)""#
    )

    /// Recovers complete key-value pairs when a local 4B model drops a closing
    /// brace or leaves trailing garbage inside a `{"0":"..."}` object.
    /// Truncated mid-string values are rejected so cut-off text never leaks out.
    private static func recoverMalformedCompactJSON(_ trimmed: String, count: Int) -> [String]? {
        guard count > 0, trimmed.hasPrefix("{") else { return nil }
        if let data = (trimmed + "}").data(using: .utf8),
           let repaired = try? JSONSerialization.jsonObject(with: data),
           let texts = matchLocalTexts(repaired, count: count) {
            return texts
        }
        let fullRange = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        let matches = compactKeyValueRegex.matches(in: trimmed, range: fullRange)
        guard !matches.isEmpty else { return nil }
        var found: [Int: String] = [:]
        for match in matches {
            guard let keyRange = Range(match.range(at: 1), in: trimmed),
                  let valueRange = Range(match.range(at: 2), in: trimmed) else { continue }
            let rawKey = String(trimmed[keyRange])
            guard let index = compactIndex(fromKey: rawKey) ?? letterIndex(fromKey: rawKey) else { continue }
            let quoted = "\"\(trimmed[valueRange])\""
            guard let decoded = try? JSONDecoder().decode(String.self, from: Data(quoted.utf8)) else { continue }
            let value = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty, found[index] == nil {
                found[index] = value
            }
        }
        return LocalTranslationCleanup.alignedIndices(found, count: count)
    }

    private static func localResult(
        texts: [String],
        expectedIDs: [UUID],
        windowRevision: UInt64,
        sourceCharacters: Int = 0
    ) throws -> TranslationResult {
        guard texts.count == expectedIDs.count else {
            throw TranslationError.invalidResponse("translation count does not match request")
        }
        let cleaned = texts.enumerated().map { index, text in
            LocalTranslationCleanup.stripKeyLeak(text, compactIndex: index)
        }
        let characterLimit = TranslationRequestValidator.outputCharacterLimit(sourceCharacters: sourceCharacters)
        guard cleaned.allSatisfy({
            let text = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return !text.isEmpty && text.count <= characterLimit
        }) else {
            throw TranslationError.invalidResponse("translation text is empty or too long")
        }
        let translations = zip(expectedIDs, cleaned).map {
            Translation(segmentId: $0.0, simplifiedChineseText: $0.1)
        }
        return TranslationResult(windowRevision: windowRevision, translations: translations)
    }

    private static func extractLocalTexts(_ json: Any, count: Int) throws -> [String] {
        if let texts = matchLocalTexts(json, count: count) {
            return texts
        }
        throw TranslationError.invalidResponse("translation JSON is invalid")
    }

    private static func matchLocalTexts(_ json: Any, count: Int) -> [String]? {
        if let text = json as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if count == 1, !trimmed.isEmpty { return [trimmed] }
            return LocalTranslationCleanup.splitNumberedBlob(trimmed, count: count)
        }
        if let strings = json as? [String] {
            if strings.count == count { return strings }
            if count > 1, strings.count == 1 {
                return LocalTranslationCleanup.splitNumberedBlob(strings[0], count: count)
            }
        }
        if let objects = json as? [[String: Any]], let texts = matchObjectArray(objects, count: count) {
            return texts
        }
        guard let object = json as? [String: Any] else { return nil }

        let numeric = (0..<count).map(String.init)
        if let texts = keyedTexts(object, keys: numeric) { return texts }
        if let letters = letterKeys(count: count), let texts = keyedTexts(object, keys: letters) {
            return texts
        }
        if count > 1, let texts = keyedTexts(object, keys: (1...count).map(String.init)) {
            return texts
        }
        if let texts = textsByPrefixedKeys(object, count: count) { return texts }

        for key in [
            "t", "translations", "texts", "results", "items", "data", "output", "result",
            "text", "translation", "translated", "content", "response", "message"
        ] {
            if let nested = object[key], let texts = matchLocalTexts(nested, count: count) {
                return texts
            }
        }

        if count > 1, let blob = uniqueString(object),
           let texts = LocalTranslationCleanup.splitNumberedBlob(blob, count: count) {
            return texts
        }

        if count == 1, let text = objectText(object) {
            return [text]
        }

        if count == 1 {
            let strings = object.values.compactMap(stringValue)
            if strings.count == 1 { return strings }
        }
        return nil
    }

    private static let compactLetters = Array("abcdefghijklmnopqrstuvwxyz")

    private static func letterKeys(count: Int) -> [String]? {
        guard (1...26).contains(count) else { return nil }
        return (0..<count).map { String(compactLetters[$0]) }
    }

    private static func keyedTexts(_ object: [String: Any], keys: [String]) -> [String]? {
        let texts = keys.compactMap { stringValue(object[$0]) }
        return texts.count == keys.count ? texts : nil
    }

    private static func textsByPrefixedKeys(_ object: [String: Any], count: Int) -> [String]? {
        var found: [Int: String] = [:]
        for (key, value) in object {
            guard let text = stringValue(value) else { continue }
            guard let index = compactIndex(fromKey: key) ?? letterIndex(fromKey: key) else { continue }
            if found[index] == nil {
                found[index] = text
            }
        }
        return LocalTranslationCleanup.alignedIndices(found, count: count)
    }

    private static func compactIndex(fromKey key: String) -> Int? {
        let t = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if let n = Int(t), String(n) == t { return n }
        guard let match = compactIndexRegex.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
              let range = Range(match.range(at: 1), in: t) else {
            return nil
        }
        return Int(t[range])
    }

    private static func letterIndex(fromKey key: String) -> Int? {
        let t = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let first = t.first, let idx = compactLetters.firstIndex(of: first) else { return nil }
        if t.count == 1 { return idx }
        let second = t[t.index(after: t.startIndex)]
        guard ":：.-_".contains(second) else { return nil }
        return idx
    }

    private static func matchObjectArray(_ objects: [[String: Any]], count: Int) -> [String]? {
        let labeled = objects.compactMap(objectText)
        if labeled.count == count { return labeled }

        if objects.count == count {
            var texts: [String] = []
            for (index, object) in objects.enumerated() {
                if let text = objectText(object)
                    ?? stringValue(object[String(index)])
                    ?? stringValue(object[String(index + 1)])
                    ?? uniqueString(object) {
                    texts.append(text)
                } else {
                    return nil
                }
            }
            return texts
        }

        if objects.count == 1, let blob = objectText(objects[0]) ?? uniqueString(objects[0]) {
            return LocalTranslationCleanup.splitNumberedBlob(blob, count: count)
        }
        return nil
    }

    private static func objectText(_ object: [String: Any]) -> String? {
        for key in ["text", "translation", "translated", "zh", "zh-Hans", "zh_cn", "chinese", "dst", "value", "content", "t"] {
            if let text = stringValue(object[key]) { return text }
        }
        return nil
    }

    private static func uniqueString(_ object: [String: Any]) -> String? {
        let strings = object.values.compactMap(stringValue)
        return strings.count == 1 ? strings[0] : nil
    }

    private static func stringValue(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum LocalTranslationCleanup {
    static func stripKeyLeak(_ text: String, compactIndex: Int) -> String {
        let original = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var current = original
        for _ in 0..<4 {
            let next = stripLeadingOnce(current, compactIndex: compactIndex)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if next == current { break }
            current = next
        }
        current = stripTrailingIndex(current, compactIndex: compactIndex)
        return current.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func splitNumberedBlob(_ text: String, count: Int) -> [String]? {
        guard count > 1 else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var fromLines: [Int: String] = [:]
        for line in trimmed.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            let line = String(line).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, let parsed = numberedEntry(line), fromLines[parsed.index] == nil else { continue }
            fromLines[parsed.index] = parsed.text
        }
        if let texts = alignedIndices(fromLines, count: count) { return texts }
        return splitInlineNumbered(trimmed, count: count)
    }

    static func alignedIndices(_ found: [Int: String], count: Int) -> [String]? {
        let zeroBased = (0..<count).compactMap { found[$0] }
        if zeroBased.count == count { return zeroBased }
        let oneBased = (1...count).compactMap { found[$0] }
        if oneBased.count == count { return oneBased }
        return nil
    }

    private static let numberedEntryRegex = try! NSRegularExpression(pattern: #"^(\d+)\s*[：:.、)]\s*(.+)$"#)
    private static let inlineNumberedRegex = try! NSRegularExpression(pattern: #"(\d+)\s*[：:.、)]\s*"#)
    private static let leadingNumericPrefixRegex = try! NSRegularExpression(pattern: #"^(\d+)\s*[：:.、)]\s*"#)
    private static let leadingLetterPrefixRegex = try! NSRegularExpression(pattern: #"^([a-z])\s*[：:.、)]\s*"#, options: .caseInsensitive)
    private static let leadingCJKNumericPrefixRegex = try! NSRegularExpression(pattern: #"^\d+\s*[：:]\s*"#)
    private static let trailingIndexRegex = try! NSRegularExpression(pattern: #"^(.*?)\s+(\d+)\s*$"#)
    private static let compactLetterChars = Array("abcdefghijklmnopqrstuvwxyz")

    private static func numberedEntry(_ line: String) -> (index: Int, text: String)? {
        guard let match = numberedEntryRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let indexRange = Range(match.range(at: 1), in: line),
              let textRange = Range(match.range(at: 2), in: line),
              let index = Int(line[indexRange]) else {
            return nil
        }
        let text = String(line[textRange]).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return (index, text)
    }

    private static func splitInlineNumbered(_ text: String, count: Int) -> [String]? {
        let ns = text as NSString
        let matches = inlineNumberedRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard matches.count >= count else { return nil }
        var found: [Int: String] = [:]
        for (offset, match) in matches.enumerated() {
            guard let indexRange = Range(match.range(at: 1), in: text),
                  let index = Int(text[indexRange]) else { continue }
            let start = match.range.upperBound
            let end = offset + 1 < matches.count ? matches[offset + 1].range.location : ns.length
            guard end >= start else { continue }
            let value = ns.substring(with: NSRange(location: start, length: end - start))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if found[index] == nil, !value.isEmpty {
                found[index] = value
            }
        }
        return alignedIndices(found, count: count)
    }

    private static func stripLeadingOnce(_ text: String, compactIndex: Int) -> String {
        let fullRange = NSRange(text.startIndex..., in: text)
        if let match = leadingNumericPrefixRegex.firstMatch(in: text, range: fullRange),
           match.range.location == 0, match.range.length > 0,
           let numRange = Range(match.range(at: 1), in: text),
           Int(text[numRange]) == compactIndex,
           let matchedRange = Range(match.range, in: text) {
            return String(text[matchedRange.upperBound...])
        }
        if compactIndex < 26 {
            let expectedLetter = compactLetterChars[compactIndex]
            if let match = leadingLetterPrefixRegex.firstMatch(in: text, range: fullRange),
               match.range.location == 0, match.range.length > 0,
               let letterRange = Range(match.range(at: 1), in: text),
               text[letterRange].lowercased().first == expectedLetter,
               let matchedRange = Range(match.range, in: text) {
                return String(text[matchedRange.upperBound...])
            }
        }
        if let match = leadingCJKNumericPrefixRegex.firstMatch(in: text, range: fullRange),
           match.range.location == 0, match.range.length > 0,
           let matchedRange = Range(match.range, in: text) {
            let rest = String(text[matchedRange.upperBound...])
            if hasCJK(rest) {
                return rest
            }
        }
        return text
    }

    private static func stripTrailingIndex(_ text: String, compactIndex: Int) -> String {
        guard hasCJK(text),
              let match = trailingIndexRegex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.range.location == 0, match.range.length > 0,
              let numRange = Range(match.range(at: 2), in: text),
              Int(text[numRange]) == compactIndex,
              let bodyRange = Range(match.range(at: 1), in: text) else {
            return text
        }
        let trimmed = String(text[bodyRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? text : trimmed
    }

    private static func hasCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            let value = scalar.value
            return (0x4E00...0x9FFF).contains(value)
                || (0x3400...0x4DBF).contains(value)
                || (0xF900...0xFAFF).contains(value)
        }
    }
}

enum LocalTranslationQuality {
    @discardableResult
    static func applyCopiedSourcePolicy(
        _ result: TranslationResult,
        items: [TranslationItem],
        policy: CopiedSourcePolicy
    ) throws -> TranslationResult {
        switch policy {
        case .keep:
            return result
        case .reject:
            return try rejectCopiedSource(result, items: items)
        }
    }

    @discardableResult
    static func rejectCopiedSource(
        _ result: TranslationResult,
        items: [TranslationItem]
    ) throws -> TranslationResult {
        let sourceByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.sourceText) })
        for translation in result.translations {
            guard let source = sourceByID[translation.segmentId] else { continue }
            try rejectCopiedSource(
                translated: translation.simplifiedChineseText,
                source: source
            )
        }
        return result
    }

    static func rejectCopiedSource(translated: String, source: String) throws {
        guard CopiedSourceDetector.translationCopiesSource(translated, source: source) else { return }
        throw TranslationError.invalidResponse("translation copied the source")
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
