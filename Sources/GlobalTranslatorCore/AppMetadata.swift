import Foundation

/// Shared product identity, author attribution, and repository metadata.
public enum AppMetadata {
    public static let appName = "Global Translator"
    public static let displayName = "全局翻译"
    public static let author = "maodashu"
    public static let license = "MIT"
    public static let fallbackVersion = "1.2.0"
    public static let githubRepositoryURLString = "https://github.com/827748510-blip/global-translator"
    public static let githubRepositoryURL = URL(string: githubRepositoryURLString)!

    public static var shortVersion: String {
        let raw = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? fallbackVersion : trimmed
    }
}
