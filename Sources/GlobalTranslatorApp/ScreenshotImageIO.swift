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

    /// 后台编码。4K 截图的 PNG 编码在主线程要几十到几百毫秒，期间弹层和快捷键
    /// 一起卡住；编码是纯计算，放到后台只把结果带回主线程。
    public static func pngDataOffMain(_ image: CGImage) async -> Data? {
        let box = SendableImage(image: image)
        return await Task.detached(priority: .userInitiated) {
            pngData(box.image)
        }.value
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
        return try save(pngData: data, to: directory, filename: filename)
    }

    /// 已编码的 PNG 直接落盘：截图路径只编码一次，保存与复制共用同一份数据。
    public static func save(
        pngData data: Data,
        to directory: URL,
        filename: String? = nil
    ) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = filename ?? defaultFilename()
        let url = directory.appendingPathComponent(name, isDirectory: false)
        try data.write(to: url, options: .atomic)
        return url
    }

    public static func copyToClipboard(_ image: CGImage) {
        guard let data = pngData(image) else { return }
        copyToClipboard(pngData: data)
    }

    public static func copyToClipboard(pngData data: Data) {
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

/// `CGImage` 构造后不可变，跨线程只读是安全的；CoreGraphics 没有标注
/// `Sendable`，这里显式封箱，避免把整张图钉在主线程上编码。
struct SendableImage: @unchecked Sendable {
    let image: CGImage
}
