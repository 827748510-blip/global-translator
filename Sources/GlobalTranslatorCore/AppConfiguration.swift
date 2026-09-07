import Foundation

public struct AppConfiguration: Codable, Equatable, Sendable {
    public var autoTranslateEnabled: Bool
    public var backend: BackendKind
    public var visionFallbackEnabled: Bool
    public var localBaseURL: URL
    public var localModel: String
    public var translatedBundleIDs: [String]

    public init(
        autoTranslateEnabled: Bool = false,
        backend: BackendKind = .deepSeekCloud,
        visionFallbackEnabled: Bool = false,
        localBaseURL: URL = Self.defaultLocalBaseURL,
        localModel: String = "",
        translatedBundleIDs: [String] = []
    ) {
        self.autoTranslateEnabled = autoTranslateEnabled
        self.backend = backend
        self.visionFallbackEnabled = visionFallbackEnabled
        self.localBaseURL = localBaseURL
        self.localModel = localModel
        self.translatedBundleIDs = translatedBundleIDs
    }

    public static let defaultLocalBaseURL = URL(string: "http://127.0.0.1:11434/v1")!

    private enum CodingKeys: String, CodingKey {
        case autoTranslateEnabled
        case backend
        case visionFallbackEnabled
        case localBaseURL
        case localModel
        case translatedBundleIDs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        autoTranslateEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoTranslateEnabled) ?? false
        backend = try container.decodeIfPresent(BackendKind.self, forKey: .backend) ?? .deepSeekCloud
        visionFallbackEnabled = try container.decodeIfPresent(Bool.self, forKey: .visionFallbackEnabled) ?? false
        localBaseURL = try container.decodeIfPresent(URL.self, forKey: .localBaseURL) ?? Self.defaultLocalBaseURL
        localModel = try container.decodeIfPresent(String.self, forKey: .localModel) ?? ""
        // Legacy `excludedBundleIDs` was a deny list and must never be
        // reinterpreted as the translation allow list: missing field means
        // "translate nothing" until the user picks applications.
        translatedBundleIDs = try container.decodeIfPresent([String].self, forKey: .translatedBundleIDs) ?? []
    }
}
