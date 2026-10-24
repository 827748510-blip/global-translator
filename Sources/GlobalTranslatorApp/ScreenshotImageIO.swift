import AppKit
import Foundation

/// 截图翻译的落盘 / 剪贴板动作。PNG 写入、目录创建、文件名都在这里，便于测试注入。
public enum ScreenshotImageIO {
    public enum SaveError: Error, Equatable, Sendable {
        case pngEncodingFailed
    }

    public static func pngData(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    /// Writes `image` as a timestamped PNG into `directory`, creating it when
    /// missing. File names are unique to the second, with a short suffix so two
    /// screenshots in the same second never overwrite each other.
    public static func save(
        _ image: CGImage,
        to directory: URL,
        filename: String? = nil
    ) throws -> URL {
        guard let data = pngData(image) else { throw SaveError.pngEncodingFailed }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = filename ?? defaultFilename()
        let url = directory.appendingPathComponent(name, isDirectory: false)
        try data.write(to: url, options: .atomic)
        return url
    }

    public static func copyToClipboard(_ image: CGImage) {
        guard let data = pngData(image) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(data, forType: .png)
    }

    public static func defaultFilename(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: now)
        let suffix = UUID().uuidString.prefix(4)
        return "截图翻译-\(stamp)-\(suffix).png"
    }
}
