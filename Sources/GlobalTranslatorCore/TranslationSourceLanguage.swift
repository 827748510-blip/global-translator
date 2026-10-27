import Foundation

/// An optional, untrusted page-language hint. Accept a bounded BCP-47-shaped
/// tag, never arbitrary prompt text. Missing hints retain text-only detection.
public struct TranslationSourceLanguage: Hashable, Sendable, Codable {
    public let tag: String

    public init?(_ value: String) {
        guard value.utf8.count <= 63,
              let range = value.range(of: #"^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{1,8})*$"#, options: .regularExpression),
              range == value.startIndex..<value.endIndex else {
            return nil
        }
        tag = value.lowercased()
    }

    /// Only exact language/script/region subtags can disambiguate Han-only
    /// text. In particular, `java`, `zh-Hans-TW`, and private-use `zh-x-tw`
    /// must not accidentally activate the foreign-CJK exception.
    public var requiresCJKTranslation: Bool {
        let parts = tag.split(separator: "-")
        if parts[0] == "ja" || parts[0] == "ko" { return true }
        guard parts[0] == "zh", parts.count > 1 else { return false }
        let script = parts[1].count == 4 ? parts[1] : nil
        if script == "hans" { return false }
        if script == "hant" { return true }
        let regionIndex = script == nil ? 1 : 2
        return parts.count > regionIndex && ["tw", "hk", "mo"].contains(String(parts[regionIndex]))
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let language = Self(value) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "invalid source language")
        }
        self = language
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(tag)
    }
}
