import Foundation

public struct AppConfiguration: Codable, Equatable, Sendable {
    public var autoTranslateEnabled: Bool
    public var backend: BackendKind
    public var visionFallbackEnabled: Bool
    public var localBaseURL: URL
    public var localModel: String
    public var translatedBundleIDs: [String]
    /// 划选文字后弹出译文。默认开启，与窗口覆盖层、扩展桥独立。
    public var selectionTranslateEnabled: Bool

    public init(
        autoTranslateEnabled: Bool = false,
        backend: BackendKind = .deepSeekCloud,
        visionFallbackEnabled: Bool = false,
        localBaseURL: URL = Self.defaultLocalBaseURL,
        localModel: String = "",
        translatedBundleIDs: [String] = [],
        selectionTranslateEnabled: Bool = true
    ) {
        self.autoTranslateEnabled = autoTranslateEnabled
        self.backend = backend
        self.visionFallbackEnabled = visionFallbackEnabled
        self.localBaseURL = localBaseURL
        self.localModel = localModel
        self.translatedBundleIDs = translatedBundleIDs
        self.selectionTranslateEnabled = selectionTranslateEnabled
    }

    public static let defaultLocalBaseURL = URL(string: "http://127.0.0.1:11434/v1")!

    private enum CodingKeys: String, CodingKey {
        case autoTranslateEnabled
        case backend
        case visionFallbackEnabled
        case localBaseURL
        case localModel
        case translatedBundleIDs
        case selectionTranslateEnabled
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
        selectionTranslateEnabled = try container.decodeIfPresent(Bool.self, forKey: .selectionTranslateEnabled) ?? true
    }
}
