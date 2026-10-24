import Foundation

public struct AppConfiguration: Codable, Equatable, Sendable {
    public var autoTranslateEnabled: Bool
    public var backend: BackendKind
    public var visionFallbackEnabled: Bool
    public var localBaseURL: URL
    public var localModel: String
    /// Cloud model id persisted in config.json. The API key itself is never stored here.
    public var deepSeekModel: String
    /// Non-secret UI flag: a DeepSeek key was saved (or later seen on a real API read).
    /// Settings must not call Keychain `read()` just to show 「已配置 · 钥匙串保存」.
    public var deepSeekAPIKeyConfigured: Bool
    public var translatedBundleIDs: [String]
    /// 划选文字后弹出译文。默认开启，与窗口覆盖层、扩展桥独立。
    public var selectionTranslateEnabled: Bool
    /// Chrome 视频字幕叠中文。默认关闭；与滑词翻译并列，仅用户打开后才跑。
    public var videoTranslateEnabled: Bool
    /// Last 优化提示词 scene. Default is workplace/social polish.
    public var promptOptimizeMode: PromptOptimizeMode
    /// Global hotkey that starts region-select screenshot translate.
    public var screenshotTranslateHotkey: KeyboardShortcutSpec
    /// Copy screenshot-translate result automatically. Default off.
    public var autoCopyScreenshotTranslation: Bool
    /// Save the captured region as a PNG file after a screenshot translate. Default off.
    public var saveScreenshotImage: Bool
    /// Copy the captured region image to the clipboard after a screenshot translate. Default off.
    public var copyScreenshotImage: Bool
    /// Directory that receives saved screenshot PNGs. Shown in Settings; user-editable.
    public var screenshotSaveDirectory: String

    public init(
        autoTranslateEnabled: Bool = false,
        backend: BackendKind = .deepSeekCloud,
        visionFallbackEnabled: Bool = false,
        localBaseURL: URL = Self.defaultLocalBaseURL,
        localModel: String = "",
        deepSeekModel: String = Self.defaultDeepSeekModel,
        deepSeekAPIKeyConfigured: Bool = false,
        translatedBundleIDs: [String] = [],
        selectionTranslateEnabled: Bool = true,
        videoTranslateEnabled: Bool = false,
        promptOptimizeMode: PromptOptimizeMode = .communicationPolish,
        screenshotTranslateHotkey: KeyboardShortcutSpec = .screenshotTranslateDefault,
        autoCopyScreenshotTranslation: Bool = false,
        saveScreenshotImage: Bool = false,
        copyScreenshotImage: Bool = false,
        screenshotSaveDirectory: String = Self.defaultScreenshotSaveDirectory
    ) {
        self.autoTranslateEnabled = autoTranslateEnabled
        self.backend = backend
        self.visionFallbackEnabled = visionFallbackEnabled
        self.localBaseURL = localBaseURL
        self.localModel = localModel
        self.deepSeekModel = Self.resolvedDeepSeekModel(deepSeekModel)
        self.deepSeekAPIKeyConfigured = deepSeekAPIKeyConfigured
        self.translatedBundleIDs = translatedBundleIDs
        self.selectionTranslateEnabled = selectionTranslateEnabled
        self.videoTranslateEnabled = videoTranslateEnabled
        self.promptOptimizeMode = promptOptimizeMode
        self.screenshotTranslateHotkey = screenshotTranslateHotkey.isValid
            ? screenshotTranslateHotkey
            : .screenshotTranslateDefault
        self.autoCopyScreenshotTranslation = autoCopyScreenshotTranslation
        self.saveScreenshotImage = saveScreenshotImage
        self.copyScreenshotImage = copyScreenshotImage
        let trimmedDirectory = screenshotSaveDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        self.screenshotSaveDirectory = trimmedDirectory.isEmpty ? Self.defaultScreenshotSaveDirectory : trimmedDirectory
    }

    public static let defaultLocalBaseURL = URL(string: "http://127.0.0.1:11434/v1")!
    public static let defaultDeepSeekModel = "deepseek-chat"

    /// 截图翻译的默认保存目录（「图片」下的独立子目录）。用户可在设置里改。
    public static var defaultScreenshotSaveDirectory: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures/Global Translator 截图", isDirectory: true)
            .path
    }

    public static func resolvedDeepSeekModel(_ model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultDeepSeekModel : trimmed
    }

    public static func preferredDeepSeekModel(current: String, available: [String]) -> String {
        let resolved = resolvedDeepSeekModel(current)
        if available.contains(resolved) { return resolved }
        if available.contains(defaultDeepSeekModel) { return defaultDeepSeekModel }
        return available.first ?? resolved
    }

    private enum CodingKeys: String, CodingKey {
        case autoTranslateEnabled
        case backend
        case visionFallbackEnabled
        case localBaseURL
        case localModel
        case deepSeekModel
        case deepSeekAPIKeyConfigured
        case translatedBundleIDs
        case selectionTranslateEnabled
        case videoTranslateEnabled
        case promptOptimizeMode
        case screenshotTranslateHotkey
        case autoCopyScreenshotTranslation
        case saveScreenshotImage
        case copyScreenshotImage
        case screenshotSaveDirectory
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        autoTranslateEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoTranslateEnabled) ?? false
        backend = try container.decodeIfPresent(BackendKind.self, forKey: .backend) ?? .deepSeekCloud
        visionFallbackEnabled = try container.decodeIfPresent(Bool.self, forKey: .visionFallbackEnabled) ?? false
        localBaseURL = try container.decodeIfPresent(URL.self, forKey: .localBaseURL) ?? Self.defaultLocalBaseURL
        localModel = try container.decodeIfPresent(String.self, forKey: .localModel) ?? ""
        deepSeekModel = Self.resolvedDeepSeekModel(try container.decodeIfPresent(String.self, forKey: .deepSeekModel) ?? "")
        deepSeekAPIKeyConfigured = try container.decodeIfPresent(Bool.self, forKey: .deepSeekAPIKeyConfigured) ?? false
        // Legacy `excludedBundleIDs` was a deny list and must never be
        // reinterpreted as the translation allow list: missing field means
        // "translate nothing" until the user picks applications.
        translatedBundleIDs = try container.decodeIfPresent([String].self, forKey: .translatedBundleIDs) ?? []
        selectionTranslateEnabled = try container.decodeIfPresent(Bool.self, forKey: .selectionTranslateEnabled) ?? true
        videoTranslateEnabled = try container.decodeIfPresent(Bool.self, forKey: .videoTranslateEnabled) ?? false
        promptOptimizeMode = try container.decodeIfPresent(PromptOptimizeMode.self, forKey: .promptOptimizeMode) ?? .communicationPolish
        if let hotkey = try container.decodeIfPresent(KeyboardShortcutSpec.self, forKey: .screenshotTranslateHotkey),
           hotkey.isValid {
            screenshotTranslateHotkey = hotkey
        } else {
            screenshotTranslateHotkey = .screenshotTranslateDefault
        }
        autoCopyScreenshotTranslation = try container.decodeIfPresent(Bool.self, forKey: .autoCopyScreenshotTranslation) ?? false
        saveScreenshotImage = try container.decodeIfPresent(Bool.self, forKey: .saveScreenshotImage) ?? false
        copyScreenshotImage = try container.decodeIfPresent(Bool.self, forKey: .copyScreenshotImage) ?? false
        let savedDirectory = try container.decodeIfPresent(String.self, forKey: .screenshotSaveDirectory) ?? Self.defaultScreenshotSaveDirectory
        let trimmedDirectory = savedDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        screenshotSaveDirectory = trimmedDirectory.isEmpty ? Self.defaultScreenshotSaveDirectory : trimmedDirectory
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(autoTranslateEnabled, forKey: .autoTranslateEnabled)
        try container.encode(backend, forKey: .backend)
        try container.encode(visionFallbackEnabled, forKey: .visionFallbackEnabled)
        try container.encode(localBaseURL, forKey: .localBaseURL)
        try container.encode(localModel, forKey: .localModel)
        try container.encode(deepSeekModel, forKey: .deepSeekModel)
        try container.encode(deepSeekAPIKeyConfigured, forKey: .deepSeekAPIKeyConfigured)
        try container.encode(translatedBundleIDs, forKey: .translatedBundleIDs)
        try container.encode(selectionTranslateEnabled, forKey: .selectionTranslateEnabled)
        try container.encode(videoTranslateEnabled, forKey: .videoTranslateEnabled)
        try container.encode(promptOptimizeMode, forKey: .promptOptimizeMode)
        try container.encode(screenshotTranslateHotkey, forKey: .screenshotTranslateHotkey)
        try container.encode(autoCopyScreenshotTranslation, forKey: .autoCopyScreenshotTranslation)
        try container.encode(saveScreenshotImage, forKey: .saveScreenshotImage)
        try container.encode(copyScreenshotImage, forKey: .copyScreenshotImage)
        try container.encode(screenshotSaveDirectory, forKey: .screenshotSaveDirectory)
    }
}
