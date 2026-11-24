import Foundation

/// Chromium-family apps whose in-page translation is owned by the Chrome
/// extension when the menu-bar master switch is on. Overlay AX/OCR of
/// those windows races the bridge on local Ollama.
public enum ChromiumBrowserBundles {
    public static let identifiers: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "org.chromium.Chromium",
        "com.microsoft.edgemac",
        "com.brave.Browser"
    ]

    public static func contains(_ bundleIdentifier: String) -> Bool {
        identifiers.contains(bundleIdentifier)
    }
}
